import Foundation
import AppKit

struct ChatGPTAccount: Identifiable, Equatable {
    let id: String
    let email: String?
    let signedIn: Bool
    let planEnabled: Bool
    var label: String { (email ?? String(localized: "ChatGPT 계정")) + " · " + id.suffix(8) }
}
struct ChatGPTModel: Identifiable, Decodable, Equatable {
    let slug: String
    let display_name: String
    let visibility: String
    var id: String { slug }
}

/// One refresh flight per issued registration, with revision checks at every credential commit.
actor ChatGPTAccountService {
    static let shared = ChatGPTAccountService(defaults: .standard)
    private let storage: any ChatGPTCredentialStorage
    private let session: URLSession
    private let defaults: UserDefaults?
    private var pendingRegistrationID: String?
    private var registrations: [ChatGPTRegistration]?
    private var refreshes: [String: (id: UUID, task: Task<ChatGPTCredentials, Error>)] = [:]
    private var catalog: [String: (models: [ChatGPTModel], date: Date)] = [:]
    private var usagePaused = Set<String>()
    private var keys: (values: [ChatGPTIdentity.JWK], date: Date)?
    private var loginInProgress = false

    init(storage: any ChatGPTCredentialStorage = ChatGPTKeychain(), session: URLSession = ChatGPTHTTP.session, defaults: UserDefaults? = nil) {
        self.storage = storage; self.session = session; self.defaults = defaults
        self.pendingRegistrationID = defaults?.string(forKey: "chatgpt.pendingRegistrationID")
    }
    private func load() throws {
        if registrations == nil { registrations = try storage.load() }
    }
    private func commit(_ entries: [ChatGPTRegistration]) throws {
        try storage.save(entries); registrations = entries
    }
    private func registration(_ id: String) throws -> ChatGPTRegistration {
        try load()
        guard let entry = registrations?.first(where: { $0.id == id }) else { throw ChatGPTFailure.loginRequired }
        return entry
    }
    func accounts() throws -> [ChatGPTAccount] {
        try load()
        return (registrations ?? []).map { entry in
            ChatGPTAccount(id: entry.id, email: entry.email, signedIn: entry.credentials != nil,
                           planEnabled: entry.credentials?.scopes.contains(ChatGPTOAuth.planScope) == true
                            && entry.credentials?.scopes.contains("resource.invoke") == true)
        }
    }

    func signIn(accountID: String?, hostID: String, consent: Bool = false,
                open: @escaping @Sendable (URL) async throws -> Void = { url in
                    let opened = await MainActor.run { NSWorkspace.shared.open(url) }
                    if !opened { throw ChatGPTFailure.message(String(localized: "브라우저를 열 수 없습니다.")) }
                }) async throws -> String {
        guard !loginInProgress else { throw ChatGPTFailure.message(String(localized: "진행 중인 ChatGPT 로그인을 먼저 완료하거나 취소해주세요.")) }
        loginInProgress = true; defer { loginInProgress = false }
        try load()
        let prior = try accountID.map { try registration($0) }
        let priorRevision = prior?.credentials?.revision
        let server = ChatGPTLoopback(); defer { server.cancel() }
        let redirect = try await server.start()
        let attempt = try ChatGPTOAuth.Attempt(redirect: redirect, clientID: prior?.id ?? pendingRegistrationID)
        try await open(attempt.authorizationURL(hostID: hostID, email: prior?.email,
                                                idToken: prior?.credentials?.idToken, requestConsent: consent))
        let callback = try attempt.callback(await server.callback())
        if prior == nil {
            pendingRegistrationID = callback.clientID
            defaults?.set(callback.clientID, forKey: "chatgpt.pendingRegistrationID")
        }
        let object = try await ChatGPTHTTP.json(ChatGPTHTTP.post(ChatGPTOAuth.issuer + "/api/accounts/oauth/token", fields: [
            "grant_type": "authorization_code", "client_id": callback.clientID, "code": callback.code,
            "code_verifier": attempt.verifier, "redirect_uri": redirect.absoluteString, "resource": ChatGPTOAuth.resource
        ]), session: session)
        guard let token = object["id_token"] as? String else { throw ChatGPTFailure.invalidIdentity }
        let jwks = try await identityKeys(for: token)
        let identity = try ChatGPTIdentity.validate(token, keys: jwks, clientID: callback.clientID, nonce: attempt.nonce)
        if let prior { guard identity.iss == prior.issuer, identity.sub == prior.subject else { throw ChatGPTFailure.invalidIdentity } }
        let credentials = try Self.credentials(object, prior: nil)
        try Task.checkCancellation()
        if let prior { guard try registration(prior.id).credentials?.revision == priorRevision else { throw ChatGPTFailure.loginRequired } }
        let entry = ChatGPTRegistration(id: callback.clientID, issuer: identity.iss, subject: identity.sub,
                                       email: identity.email, credentials: credentials)
        var entries = registrations ?? []
        if let existing = entries.first(where: { $0.id == entry.id }) {
            guard existing.issuer == entry.issuer, existing.subject == entry.subject else { throw ChatGPTFailure.invalidIdentity }
        }
        entries.removeAll { $0.id == entry.id }; entries.append(entry)
        try commit(entries); catalog.removeValue(forKey: entry.id); usagePaused.remove(entry.id)
        if prior == nil { pendingRegistrationID = nil; defaults?.removeObject(forKey: "chatgpt.pendingRegistrationID") }
        return entry.id
    }
    private func identityKeys(for token: String) async throws -> [ChatGPTIdentity.JWK] {
        let header = try ChatGPTIdentity.header(token)
        if let keys, Date().timeIntervalSince(keys.date) < 300, keys.values.contains(where: { $0.kid == header.kid }) { return keys.values }
        let object = try await ChatGPTHTTP.json(URLRequest(url: URL(string: ChatGPTOAuth.issuer + "/.well-known/jwks.json")!), session: session)
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let jwks = try? JSONDecoder().decode(ChatGPTIdentity.Keys.self, from: data), !jwks.keys.isEmpty else { throw ChatGPTFailure.invalidIdentity }
        keys = (jwks.keys, Date()); return jwks.keys
    }
    private static func credentials(_ object: [String: Any], prior: ChatGPTCredentials?) throws -> ChatGPTCredentials {
        guard let access = object["access_token"] as? String, !access.isEmpty,
              let refresh = object["refresh_token"] as? String, !refresh.isEmpty,
              let expires = object["expires_in"] as? Double, expires.isFinite, expires > 0,
              (object["token_type"] as? String)?.lowercased() == "bearer",
              let idToken = prior?.idToken ?? object["id_token"] as? String else { throw ChatGPTFailure.invalidIdentity }
        // Refresh is bound to the existing registration. Retain its verified ID token as a login hint.
        let scopes = (object["scope"] as? String)?.split(separator: " ").map(String.init) ?? prior?.scopes ?? []
        var earliest: Date?
        if let seconds = object["earliest_refresh_at"] as? Double, seconds.isFinite { earliest = Date(timeIntervalSince1970: seconds) }
        else if let text = object["earliest_refresh_at"] as? String { earliest = ISO8601DateFormatter().date(from: text) }
        return ChatGPTCredentials(accessToken: access, refreshToken: refresh, idToken: idToken, scopes: scopes,
                                  expiresAt: Date().addingTimeInterval(expires), earliestRefreshAt: earliest)
    }

    func accessToken(accountID: String) async throws -> String {
        let entry = try registration(accountID)
        guard let credentials = entry.credentials else { throw ChatGPTFailure.loginRequired }
        guard credentials.scopes.contains(ChatGPTOAuth.planScope), credentials.scopes.contains("resource.invoke") else { throw ChatGPTFailure.planPermissionRequired }
        let now = Date()
        if credentials.expiresAt > now.addingTimeInterval(60) { return credentials.accessToken }
        if let earliest = credentials.earliestRefreshAt, earliest > now {
            guard credentials.expiresAt > now else { throw ChatGPTFailure.message(String(localized: "ChatGPT 연결 갱신이 아직 허용되지 않습니다. 잠시 후 다시 시도해주세요.")) }
            return credentials.accessToken
        }
        let flight: (id: UUID, task: Task<ChatGPTCredentials, Error>)
        if let running = refreshes[accountID] { flight = running }
        else {
            let session = self.session
            flight = (UUID(), Task {
                let response = try await ChatGPTHTTP.json(ChatGPTHTTP.post(ChatGPTOAuth.issuer + "/api/accounts/oauth/token", fields: [
                    "grant_type": "refresh_token", "client_id": accountID, "refresh_token": credentials.refreshToken,
                    "resource": ChatGPTOAuth.resource
                ]), session: session)
                return try Self.credentials(response, prior: credentials)
            })
            refreshes[accountID] = flight
        }
        do {
            let refreshed = try await flight.task.value
            if refreshes[accountID]?.id == flight.id {
                guard try registration(accountID).credentials?.revision == credentials.revision else { throw ChatGPTFailure.loginRequired }
                var entries = registrations ?? []
                entries[entries.firstIndex(where: { $0.id == accountID })!].credentials = refreshed
                try commit(entries); refreshes.removeValue(forKey: accountID)
            }
            // Other waiters may already have committed, or a logout/relogin may have invalidated the flight.
            guard try registration(accountID).credentials?.revision == refreshed.revision else { throw ChatGPTFailure.loginRequired }
            try Task.checkCancellation(); return refreshed.accessToken
        } catch {
            if refreshes[accountID]?.id == flight.id {
                refreshes.removeValue(forKey: accountID)
                if (error as? ChatGPTFailure)?.invalidatesRefresh == true,
                   try registration(accountID).credentials?.revision == credentials.revision {
                    var entries = registrations ?? []; entries[entries.firstIndex(where: { $0.id == accountID })!].credentials = nil
                    try commit(entries); catalog.removeValue(forKey: accountID)
                }
            }
            throw error
        }
    }
    func models(accountID: String, force: Bool = false) async throws -> [ChatGPTModel] {
        let bearer = try await accessToken(accountID: accountID)
        if !force, let cached = catalog[accountID], Date().timeIntervalSince(cached.date) < 60 { return cached.models }
        let revision = try registration(accountID).credentials?.revision
        var request = URLRequest(url: URL(string: ChatGPTOAuth.resource + "/models")!)
        request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        let object = try await ChatGPTHTTP.json(request, session: session)
        guard let values = object["models"] as? [[String: Any]],
              let data = try? JSONSerialization.data(withJSONObject: values),
              let parsed = try? JSONDecoder().decode([ChatGPTModel].self, from: data) else {
            throw ChatGPTFailure.message(String(localized: "ChatGPT 모델 목록을 읽을 수 없습니다."))
        }
        var seen = Set<String>()
        let models = parsed.filter { $0.visibility == "list" && !$0.slug.isEmpty && seen.insert($0.slug).inserted }
        guard !models.isEmpty else { throw ChatGPTFailure.message(String(localized: "이 계정에 표시할 ChatGPT 모델이 없습니다.")) }
        guard try registration(accountID).credentials?.revision == revision else { throw ChatGPTFailure.loginRequired }
        catalog[accountID] = (models, Date()); return models
    }
    func authorizeTranslation(accountID: String, model: String) async throws -> String {
        guard !usagePaused.contains(accountID) else { throw ChatGPTFailure.service(status: 429, code: "subscription_sharing_usage_limit_exceeded", requestID: nil) }
        let available = try await models(accountID: accountID)
        guard available.contains(where: { $0.slug == model }) else { throw ChatGPTFailure.message(String(localized: "선택한 모델을 사용할 수 없습니다. 모델 목록을 새로고침해주세요.")) }
        return try await accessToken(accountID: accountID)
    }
    func recordFailure(_ failure: ChatGPTFailure, accountID: String) {
        if case .service(_, let code, _) = failure, code == "subscription_sharing_usage_limit_exceeded" { usagePaused.insert(accountID) }
    }
    func resumeUsage(accountID: String) { usagePaused.remove(accountID) }

    /// Clear local credentials even if server revocation cannot be confirmed; tell the user which happened.
    func signOut(accountID: String) async throws -> Bool {
        let entry = try registration(accountID)
        var entries = registrations ?? []
        entries[entries.firstIndex(where: { $0.id == accountID })!].credentials = nil
        try commit(entries)
        refreshes.removeValue(forKey: accountID)?.task.cancel()
        catalog.removeValue(forKey: accountID); usagePaused.remove(accountID)
        guard let refresh = entry.credentials?.refreshToken else { return true }
        do {
            let discovery = try await ChatGPTHTTP.json(URLRequest(url: URL(string: ChatGPTOAuth.issuer + "/.well-known/openid-configuration")!), session: session)
            guard discovery["issuer"] as? String == ChatGPTOAuth.issuer,
                  let endpoint = discovery["revocation_endpoint"] as? String, let url = URL(string: endpoint),
                  url.scheme == "https", url.host == "auth.openai.com", url.user == nil, url.password == nil,
                  url.fragment == nil, url.port == nil || url.port == 443 else { return false }
            for attempt in 0..<3 {
                do {
                    _ = try await ChatGPTHTTP.json(ChatGPTHTTP.post(endpoint, fields: ["client_id": accountID, "token": refresh, "token_type_hint": "refresh_token"]), session: session)
                    return true
                } catch {
                    var retry = error is URLError
                    if case .service(let status, _, _) = error as? ChatGPTFailure { retry = status >= 500 && status < 600 }
                    guard retry, attempt < 2 else { return false }
                    try await Task.sleep(for: .seconds(attempt + 1))
                }
            }
        } catch { return false }
        return false
    }
}
