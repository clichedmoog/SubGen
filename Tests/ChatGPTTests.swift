import XCTest
import CryptoKit
import Security
@testable import SubtitleGen

final class ChatGPTTests: XCTestCase {
    func testPKCEAndCallbackRejectTampering() throws {
        XCTAssertEqual(ChatGPTOAuth.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let redirect = URL(string: "http://127.0.0.1:4321/auth/callback")!
        let attempt = try ChatGPTOAuth.Attempt(redirect: redirect)
        let fields = URLComponents(url: attempt.authorizationURL(hostID: "urn:uuid:test"), resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(fields.first { $0.name == "client_id" }?.value, "dynamic_agent_client")
        XCTAssertEqual(fields.first { $0.name == "agent_name_hint" }?.value, "Subtitle Maker & Translator")
        let good = redirect.absoluteString + "?state=\(attempt.state)&code=abc&client_id=oaiapp_test"
        XCTAssertEqual(try attempt.callback(URL(string: good)!).clientID, "oaiapp_test")
        for bad in [good + "&code=second", good.replacingOccurrences(of: attempt.state, with: "wrong"),
                    good.replacingOccurrences(of: "4321", with: "1234"), good.replacingOccurrences(of: "oaiapp_test", with: "dynamic_agent_client"),
                    good + "&error=access_denied", good + "#fragment"] {
            XCTAssertThrowsError(try attempt.callback(URL(string: bad)!))
        }
        XCTAssertNoThrow(try attempt.callback(URL(string: good)!, now: attempt.expires.addingTimeInterval(-1)))
        XCTAssertThrowsError(try attempt.callback(URL(string: good)!, now: attempt.expires))
        XCTAssertThrowsError(try attempt.callback(URL(string: good)!, now: attempt.expires.addingTimeInterval(1)))
        let returning = try ChatGPTOAuth.Attempt(redirect: redirect, clientID: "oaiapp_old")
        XCTAssertThrowsError(try returning.callback(URL(string: good.replacingOccurrences(of: attempt.state, with: returning.state))!))
    }
    func testLoginAllowsTimeForSeparatePlanConsentButStillExpires() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let redirect = URL(string: "http://127.0.0.1:4321/auth/callback")!
        let attempt = try ChatGPTOAuth.Attempt(redirect: redirect, now: start)
        let callback = URL(string: redirect.absoluteString + "?state=\(attempt.state)&code=abc&client_id=oaiapp_test")!
        XCTAssertNoThrow(try attempt.callback(callback, now: start.addingTimeInterval(20 * 60)))
        XCTAssertThrowsError(try attempt.callback(callback, now: start.addingTimeInterval(30 * 60)))
    }
    func testECDSAIdentityChecksSignatureAndEveryBinding() throws {
        let fixture = IdentityFixture()
        let good = try fixture.jwt()
        XCTAssertEqual(try ChatGPTIdentity.validate(good, keys: [fixture.jwk], clientID: "oaiapp_test", nonce: "test-nonce").sub, "subject-1")
        for claims: [String: Any] in [["iss": "https://evil.example"], ["aud": "wrong"], ["nonce": "wrong"],
                                     ["exp": 1], ["iat": Date().timeIntervalSince1970 + 300], ["sub": ""],
                                     ["aud": ["oaiapp_test", "other"]], ["nbf": Date().timeIntervalSince1970 + 300]] {
            XCTAssertThrowsError(try ChatGPTIdentity.validate(fixture.jwt(overrides: claims), keys: [fixture.jwk], clientID: "oaiapp_test", nonce: "test-nonce"))
        }
        let other = IdentityFixture()
        XCTAssertThrowsError(try ChatGPTIdentity.validate(good, keys: [other.jwk], clientID: "oaiapp_test", nonce: "test-nonce"))
        XCTAssertThrowsError(try ChatGPTIdentity.header("eyJhbGciOiJub25lIiwia2lkIjoieCJ9.e30.signature"))
        let multi = try fixture.jwt(overrides: ["aud": ["oaiapp_test", "other"], "azp": "oaiapp_test"])
        XCTAssertNoThrow(try ChatGPTIdentity.validate(multi, keys: [fixture.jwk], clientID: "oaiapp_test", nonce: "test-nonce"))
    }
    func testRSAIdentityFromRealSecurityKey() throws {
        let key = try XCTUnwrap(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
        let der = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        // Decode the independent Security-generated PKCS#1 public key to a JWK.
        let bytes = Array(der); var cursor = 0
        func component(_ tag: UInt8) throws -> [UInt8] {
            XCTAssertEqual(bytes[cursor], tag); cursor += 1
            var length = Int(bytes[cursor]); cursor += 1
            if length & 128 != 0 { let count = length & 127; length = 0; for _ in 0..<count { length = length * 256 + Int(bytes[cursor]); cursor += 1 } }
            let value = Array(bytes[cursor..<cursor + length]); if tag != 0x30 { cursor += length }; return value
        }
        _ = try component(0x30)
        let n = Data(try component(2).drop(while: { $0 == 0 })), e = Data(try component(2))
        let jwk = ChatGPTIdentity.JWK(kty: "RSA", kid: "rsa-test", alg: "RS256", use: "sig", n: n.base64URL, e: e.base64URL, crv: nil, x: nil, y: nil)
        let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "rsa-test"]).base64URL
        let payload = try JSONSerialization.data(withJSONObject: IdentityFixture.claims()).base64URL
        let input = "\(header).\(payload)"
        let signature = try XCTUnwrap(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, nil)) as Data
        XCTAssertNoThrow(try ChatGPTIdentity.validate(input + "." + signature.base64URL, keys: [jwk], clientID: "oaiapp_test", nonce: "test-nonce"))
        XCTAssertThrowsError(try ChatGPTIdentity.validate(input + "." + Data(repeating: 0, count: 256).base64URL, keys: [jwk], clientID: "oaiapp_test", nonce: "test-nonce"))
    }
    func testStreamRequiresCompletionAndRejectsFailedPartialOutput() throws {
        var stream = ChatGPTResponseStream()
        try event(["type": "response.output_text.delta", "delta": "안녕하세요"], into: &stream)
        XCTAssertThrowsError(try stream.finish())
        try event(["type": "response.completed", "response": ["status": "completed"]], into: &stream)
        XCTAssertEqual(try stream.finish(), "안녕하세요")
        var failed = ChatGPTResponseStream()
        try event(["type": "response.output_text.delta", "delta": "partial"], into: &failed)
        XCTAssertThrowsError(try event(["type": "response.failed", "response": ["error": ["code": "subscription_sharing_usage_limit_exceeded"]]], into: &failed)) { error in
            XCTAssertFalse((error as? ChatGPTFailure)?.retryable ?? true)
        }
        XCTAssertThrowsError(try failed.finish())
        var incomplete = ChatGPTResponseStream()
        XCTAssertThrowsError(try event(["type": "response.incomplete"], into: &incomplete))
        var multiline = ChatGPTResponseStream()
        try multiline.consume(line: "data: {\"type\":\"response.output_text.delta\",")
        try multiline.consume(line: "data: \"delta\":\"one\"}"); try multiline.consume(line: "")
        try event(["type": "response.completed", "response": ["status": "completed"]], into: &multiline)
        XCTAssertEqual(try multiline.finish(), "one")
        var lines = ChatGPTEventLines(), received: [String] = []
        for byte in "data: 안녕\r\n\r\ndata: 끝\n\n".utf8 {
            if let line = try lines.consume(byte) { received.append(line) }
        }
        XCTAssertEqual(received, ["data: 안녕", "", "data: 끝", ""])
    }
    func testServiceFailureStopsAllChunkRetries() {
        var attempts = 0
        let srt = "1\n00:00:00,000 --> 00:00:01,000\nHello\n"
        let engine = TranslationEngine(authMethod: .codex, request: { _, _ in
            attempts += 1; return ProcessResult(failure: .service("usage limit", retryable: false))
        })
        let result = engine.translateSrt(srtContent: srt, sourceLang: "en", targetLangs: [.ko], onProgress: { _ in })
        XCTAssertEqual(attempts, 1); XCTAssertTrue(result.translations.isEmpty); XCTAssertEqual(result.failures[.ko], "usage limit")
    }
    func testLoopbackIgnoresUnrelatedPathsAndCancellationClosesListener() async throws {
        let server = ChatGPTLoopback(); let url = try await server.start(); defer { server.cancel() }
        XCTAssertEqual(url.host, "127.0.0.1")
        let (_, response) = try await URLSession.shared.data(from: url.deletingLastPathComponent().appendingPathComponent("favicon.ico"))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
        let callback = URL(string: url.absoluteString + "?code=test&state=test")!
        _ = try await URLSession.shared.data(from: callback)
        let received = try await server.callback(); XCTAssertEqual(received, callback)
        let cancelled = ChatGPTLoopback(); _ = try await cancelled.start()
        let pending = Task { try await cancelled.callback() }; pending.cancel()
        do { _ = try await pending.value; XCTFail("Expected cancellation") } catch {}
    }
    func testRefreshRotationIsSingleFlightAndLogoutCannotRestoreTokens() async throws {
        let memory = MemoryCredentials()
        memory.entries = [registration(expired: true)]
        let fixture = HTTPFixture()
        fixture.handler = { request in
            if request.url!.path == "/api/accounts/oauth/token" {
                XCTAssertFalse(String(data: request.httpBody ?? Data(), encoding: .utf8)!.contains("scope="))
                Thread.sleep(forTimeInterval: 0.15)
                return (200, ["Content-Type": "application/json"], try JSONSerialization.data(withJSONObject: self.tokenResponse(access: "rotated-access", refresh: "rotated-refresh")))
            }
            if request.url!.path.contains("openid") { return (200, [:], Data("{\"issuer\":\"https://auth.openai.com\",\"revocation_endpoint\":\"https://auth.openai.com/revoke\"}".utf8)) }
            return (200, [:], Data())
        }
        let service = ChatGPTAccountService(storage: memory, session: fixture.session)
        async let first = service.accessToken(accountID: "oaiapp_test")
        async let second = service.accessToken(accountID: "oaiapp_test")
        let values = try await [first, second]
        XCTAssertEqual(values, ["rotated-access", "rotated-access"])
        XCTAssertEqual(fixture.requests.filter { $0.url!.path == "/api/accounts/oauth/token" }.count, 1)
        XCTAssertEqual(memory.entries[0].credentials?.refreshToken, "rotated-refresh")

        let racingMemory = MemoryCredentials(); racingMemory.entries = [registration(expired: true)]
        let racing = ChatGPTAccountService(storage: racingMemory, session: fixture.session)
        let task = Task { try await racing.accessToken(accountID: "oaiapp_test") }
        try await Task.sleep(for: .milliseconds(30)); _ = try await racing.signOut(accountID: "oaiapp_test")
        do { _ = try await task.value; XCTFail("A logged-out session must not reappear") } catch {}
        XCTAssertNil(racingMemory.entries[0].credentials)
    }
    func testDynamicCatalogAndResponsesUsePlanBearerWithoutUnsupportedOptions() async throws {
        let memory = MemoryCredentials(); memory.entries = [registration()]
        let fixture = HTTPFixture()
        fixture.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")
            if request.url!.path == "/v1/models" {
                return (200, [:], Data("{\"models\":[{\"slug\":\"future-model\",\"display_name\":\"Future\",\"visibility\":\"list\"},{\"slug\":\"hidden\",\"display_name\":\"Hidden\",\"visibility\":\"hide\"}]}".utf8))
            }
            let object = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            XCTAssertEqual(Set(object.keys), ["model", "store", "stream", "instructions", "input"])
            XCTAssertEqual(object["model"] as? String, "future-model"); XCTAssertEqual(object["store"] as? Bool, false)
            XCTAssertTrue(object["input"] is [[String: Any]])
            let output = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"translated\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"
            return (200, ["Content-Type": "text/event-stream"], Data(output.utf8))
        }
        let service = ChatGPTAccountService(storage: memory, session: fixture.session)
        let models = try await service.models(accountID: "oaiapp_test")
        XCTAssertEqual(models.map(\.slug), ["future-model"])
        let client = ChatGPTSubtitleClient(accountID: "oaiapp_test", model: "future-model", service: service, session: fixture.session)
        let text = try await client.translate("srt", language: .ko); XCTAssertEqual(text, "translated")
        let requests = fixture.requests.count
        await service.recordFailure(.service(status: 429, code: "subscription_sharing_usage_limit_exceeded", requestID: nil), accountID: "oaiapp_test")
        do { _ = try await client.translate("srt", language: .ko); XCTFail("Usage-limited account must pause new requests") } catch {}
        XCTAssertEqual(requests, fixture.requests.count)
    }
    func testDeniedScopeNeverSendsInferenceAndErrorsDoNotExposeBody() async throws {
        let memory = MemoryCredentials(); var entry = registration(); entry.credentials!.scopes = ["openid", "profile"]
        memory.entries = [entry]
        let fixture = HTTPFixture(); fixture.handler = { _ in XCTFail("Must not send unauthorized request"); return (500, [:], Data()) }
        let service = ChatGPTAccountService(storage: memory, session: fixture.session)
        do { _ = try await service.authorizeTranslation(accountID: entry.id, model: "any"); XCTFail("Expected consent requirement") } catch {}
        XCTAssertTrue(fixture.requests.isEmpty)
        let failure = ChatGPTHTTP.failure(status: 403, object: ["detail": "secret bearer token transcript"], requestID: "request-1")
        XCTAssertFalse(failure.localizedDescription.contains("secret")); XCTAssertTrue(failure.localizedDescription.contains("request-1"))
    }
    func testSignInValidatesPKCEAndSignedIdentityBeforePersisting() async throws {
        let memory = MemoryCredentials(), fixture = HTTPFixture(), identity = IdentityFixture()
        let state = LoginFixtureState()
        fixture.handler = { request in
            if request.url!.path == "/.well-known/jwks.json" {
                let point = identity.key.publicKey.x963Representation
                return (200, [:], try JSONSerialization.data(withJSONObject: ["keys": [["kty": "EC", "kid": "test-key", "alg": "ES256", "use": "sig", "crv": "P-256", "x": point.subdata(in: 1..<33).base64URL, "y": point.subdata(in: 33..<65).base64URL]]]))
            }
            let form = URLComponents(string: "https://example.test/?" + String(decoding: request.httpBody!, as: UTF8.self))!.queryItems!
            let fields = Dictionary(uniqueKeysWithValues: form.map { ($0.name, $0.value!) })
            XCTAssertEqual(ChatGPTOAuth.challenge(fields["code_verifier"]!), state.challenge)
            XCTAssertEqual(fields["client_id"], "oaiapp_test"); XCTAssertEqual(fields["redirect_uri"], state.redirect)
            return (200, [:], try JSONSerialization.data(withJSONObject: ["access_token": "access", "refresh_token": "refresh", "expires_in": 3600, "token_type": "Bearer", "scope": ChatGPTOAuth.scopes, "id_token": identity.jwt(overrides: ["nonce": state.nonce])]))
        }
        let service = ChatGPTAccountService(storage: memory, session: fixture.session)
        let id = try await service.signIn(accountID: nil, hostID: "urn:uuid:test", open: { url in
            let fields = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
            state.set(nonce: fields["nonce"]!, challenge: fields["code_challenge"]!, redirect: fields["redirect_uri"]!)
            var callback = URLComponents(string: fields["redirect_uri"]!)!
            callback.queryItems = [URLQueryItem(name: "state", value: fields["state"]!), URLQueryItem(name: "code", value: "code"), URLQueryItem(name: "client_id", value: "oaiapp_test")]
            _ = try await URLSession.shared.data(from: callback.url!)
        })
        XCTAssertEqual(id, "oaiapp_test"); XCTAssertEqual(memory.entries.first?.subject, "subject-1")
        XCTAssertTrue(memory.entries.first?.credentials?.scopes.contains(ChatGPTOAuth.planScope) == true)
        let empty = MemoryCredentials()
        let denied = ChatGPTAccountService(storage: empty, session: fixture.session)
        let before = fixture.requests.count
        do {
            _ = try await denied.signIn(accountID: nil, hostID: "urn:uuid:test", open: { url in
                let fields = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
                _ = try await URLSession.shared.data(from: URL(string: fields["redirect_uri"]! + "?state=wrong&code=code&client_id=oaiapp_test")!)
            }); XCTFail("Tampered callback must fail")
        } catch {}
        XCTAssertTrue(empty.entries.isEmpty); XCTAssertEqual(before, fixture.requests.count)
    }

    private func event(_ value: [String: Any], into stream: inout ChatGPTResponseStream) throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        try stream.consume(line: "data: " + String(decoding: data, as: UTF8.self)); try stream.consume(line: "")
    }
    private func registration(expired: Bool = false) -> ChatGPTRegistration {
        ChatGPTRegistration(id: "oaiapp_test", issuer: ChatGPTOAuth.issuer, subject: "subject-1", email: "test@example.com",
            credentials: ChatGPTCredentials(accessToken: "access", refreshToken: "refresh", idToken: "verified-test-token",
                scopes: [ChatGPTOAuth.planScope, "resource.invoke"], expiresAt: Date().addingTimeInterval(expired ? -10 : 3600)))
    }
    private func tokenResponse(access: String, refresh: String) -> [String: Any] {
        ["access_token": access, "refresh_token": refresh, "expires_in": 3600, "token_type": "Bearer"]
    }
}

private struct IdentityFixture {
    let key = P256.Signing.PrivateKey()
    var jwk: ChatGPTIdentity.JWK {
        let point = key.publicKey.x963Representation
        return ChatGPTIdentity.JWK(kty: "EC", kid: "test-key", alg: "ES256", use: "sig", n: nil, e: nil, crv: "P-256",
                                  x: point.subdata(in: 1..<33).base64URL, y: point.subdata(in: 33..<65).base64URL)
    }
    static func claims() -> [String: Any] {
        ["iss": ChatGPTOAuth.issuer, "sub": "subject-1", "aud": "oaiapp_test", "nonce": "test-nonce",
         "iat": Date().timeIntervalSince1970 - 10, "exp": Date().timeIntervalSince1970 + 3600]
    }
    func jwt(overrides: [String: Any] = [:]) throws -> String {
        let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": "test-key"]).base64URL
        var claims = Self.claims(); claims.merge(overrides) { _, new in new }
        let payload = try JSONSerialization.data(withJSONObject: claims).base64URL
        let input = "\(header).\(payload)"
        return input + "." + (try key.signature(for: Data(input.utf8))).rawRepresentation.base64URL
    }
}
private final class MemoryCredentials: ChatGPTCredentialStorage, @unchecked Sendable {
    private let lock = NSLock(); private var values: [ChatGPTRegistration] = []
    var entries: [ChatGPTRegistration] { get { lock.lock(); defer { lock.unlock() }; return values }
        set { lock.lock(); defer { lock.unlock() }; values = newValue } }
    func load() throws -> [ChatGPTRegistration] { entries }
    func save(_ registrations: [ChatGPTRegistration]) throws { entries = registrations }
}
private final class HTTPFixture: @unchecked Sendable {
    var handler: (URLRequest) throws -> (Int, [String: String], Data) = { _ in (500, [:], Data()) }
    private let lock = NSLock(); private var recorded: [URLRequest] = []
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FixtureProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Test-Fixture": id]
        return URLSession(configuration: configuration)
    }()
    let id = UUID().uuidString
    init() { FixtureProtocol.lock.lock(); defer { FixtureProtocol.lock.unlock() }; FixtureProtocol.fixtures[id] = self }
    deinit { session.invalidateAndCancel(); FixtureProtocol.lock.lock(); defer { FixtureProtocol.lock.unlock() }; FixtureProtocol.fixtures.removeValue(forKey: id) }
    func receive(_ request: URLRequest) throws -> (Int, [String: String], Data) {
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var body = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count)) }
            request.httpBody = body
        }
        lock.lock(); recorded.append(request); lock.unlock(); return try handler(request)
    }
}
private final class LoginFixtureState: @unchecked Sendable {
    private let lock = NSLock(); private var fields = (nonce: "", challenge: "", redirect: "")
    var nonce: String { lock.lock(); defer { lock.unlock() }; return fields.nonce }
    var challenge: String { lock.lock(); defer { lock.unlock() }; return fields.challenge }
    var redirect: String { lock.lock(); defer { lock.unlock() }; return fields.redirect }
    func set(nonce: String, challenge: String, redirect: String) { lock.lock(); defer { lock.unlock() }; fields = (nonce, challenge, redirect) }
}
private final class FixtureProtocol: URLProtocol {
    static let lock = NSLock(); static var fixtures: [String: HTTPFixture] = [:]
    override class func canInit(with request: URLRequest) -> Bool { request.value(forHTTPHeaderField: "X-Test-Fixture") != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private let stateLock = NSRecursiveLock(); private var stopped = false
    override func startLoading() {
        Self.lock.lock(); let fixture = Self.fixtures[request.value(forHTTPHeaderField: "X-Test-Fixture") ?? ""]; Self.lock.unlock()
        DispatchQueue.global().async {
            do {
                let (status, headers, data) = try fixture!.receive(self.request)
                self.stateLock.lock(); defer { self.stateLock.unlock() }; guard !self.stopped else { return }
                self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: data); self.client?.urlProtocolDidFinishLoading(self)
            } catch { self.stateLock.lock(); defer { self.stateLock.unlock() }; if !self.stopped { self.client?.urlProtocol(self, didFailWithError: error) } }
        }
    }
    override func stopLoading() { stateLock.lock(); defer { stateLock.unlock() }; stopped = true }
}
