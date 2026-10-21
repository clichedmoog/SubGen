import Foundation
import CryptoKit
import Security

enum ChatGPTFailure: LocalizedError {
    case message(String), cancelled, invalidIdentity, loginRequired, planPermissionRequired
    case service(status: Int, code: String, requestID: String?)

    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .cancelled: return String(localized: "ChatGPT 연결을 중단했습니다.")
        case .invalidIdentity: return String(localized: "ChatGPT 로그인 응답을 검증할 수 없습니다. 다시 로그인해주세요.")
        case .loginRequired: return String(localized: "선택한 ChatGPT 계정에 다시 로그인해주세요.")
        case .planPermissionRequired: return String(localized: "ChatGPT 플랜 사용 권한을 허용해주세요.")
        case .service(let status, let code, let requestID):
            let text: String
            switch code {
            case "subscription_sharing_usage_limit_exceeded":
                text = String(localized: "ChatGPT 사용량 제한에 도달했습니다. ChatGPT 설정의 Usage에서 한도를 확인해주세요.")
            case "subscription_sharing_user_not_eligible":
                text = String(localized: "이 계정 또는 워크스페이스에서는 ChatGPT 플랜을 사용할 수 없습니다.")
            case "subscription_sharing_unsupported_capability", "subscription_sharing_route_not_supported":
                text = String(localized: "이 ChatGPT 계정에서 요청한 모델 또는 번역 요청을 지원하지 않습니다.")
            case "invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                 "refresh_token_invalidated", "refresh_token_reused":
                text = String(localized: "ChatGPT 연결이 만료되었거나 취소되었습니다. 다시 로그인해주세요.")
            default: text = String(localized: "ChatGPT 요청에 실패했습니다 (HTTP \(status), \(code)).")
            }
            return text + (requestID.map { String(localized: " 요청 ID: \($0)") } ?? "")
        }
    }
    var retryable: Bool {
        guard case .service(let status, let code, _) = self else { return false }
        return !["subscription_sharing_usage_limit_exceeded", "subscription_sharing_user_not_eligible",
                 "subscription_sharing_unsupported_capability", "subscription_sharing_route_not_supported"].contains(code)
            && (status == 503 || (status == 429 && code == "rate_limit_exceeded"))
    }
    var invalidatesRefresh: Bool {
        guard case .service(_, let code, _) = self else { return false }
        return ["invalid_grant", "invalid_refresh_token", "token_expired", "refresh_token_expired",
                "refresh_token_invalidated", "refresh_token_reused"].contains(code)
    }
}

enum ChatGPTOAuth {
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let scopes = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
    static let planScope = "chatgpt.tokens.use.direct"
    // Allow time for account selection, MFA and separate plan-use approval.
    // The callback remains single-use, bound to state/PKCE and loopback only.
    static let loginTimeout: TimeInterval = 30 * 60

    static func randomValue(bytes: Int = 32) throws -> String {
        var data = Data(count: bytes)
        let status = data.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!)
        }
        guard status == errSecSuccess else { throw ChatGPTFailure.message(String(localized: "로그인용 난수를 만들 수 없습니다.")) }
        return data.base64URL
    }
    static func challenge(_ verifier: String) -> String { Data(SHA256.hash(data: Data(verifier.utf8))).base64URL }
    static func form(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(fields.sorted { $0.key < $1.key }.map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "="
                + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }

    struct Attempt {
        let state: String, nonce: String, verifier: String
        let redirect: URL
        let clientID: String?
        let expires: Date
        init(redirect: URL, clientID: String? = nil, now: Date = Date()) throws {
            self.redirect = redirect; self.clientID = clientID
            state = try randomValue(); nonce = try randomValue(); verifier = try randomValue(bytes: 48)
            expires = now.addingTimeInterval(ChatGPTOAuth.loginTimeout)
        }
        func authorizationURL(hostID: String, email: String? = nil, idToken: String? = nil,
                              requestConsent: Bool = false) -> URL {
            var url = URLComponents(string: ChatGPTOAuth.issuer + "/api/accounts/authorize")!
            var fields = ["client_id": clientID ?? "dynamic_agent_client", "ext_agent_host_id": hostID,
                          "redirect_uri": redirect.absoluteString, "response_type": "code", "scope": ChatGPTOAuth.scopes,
                          "resource": ChatGPTOAuth.resource, "state": state, "nonce": nonce,
                          "code_challenge_method": "S256", "code_challenge": ChatGPTOAuth.challenge(verifier)]
            if clientID == nil { fields["agent_name_hint"] = "Subtitle Maker & Translator" }
            if let email { fields["login_hint"] = email }
            if let idToken { fields["id_token_hint"] = idToken }
            if requestConsent { fields["prompt"] = "consent" }
            url.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            return url.url!
        }
        func callback(_ url: URL, now: Date = Date()) throws -> (code: String, clientID: String) {
            guard now < expires, url.scheme == redirect.scheme, url.host == redirect.host,
                  url.port == redirect.port, url.path == redirect.path, url.fragment == nil,
                  url.user == nil, url.password == nil,
                  var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw ChatGPTFailure.invalidIdentity }
            parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
            let items = parts.queryItems ?? []
            guard Set(items.map(\.name)).count == items.count else { throw ChatGPTFailure.invalidIdentity }
            let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            guard let returnedState = fields["state"], constantTimeEqual(returnedState, state) else { throw ChatGPTFailure.invalidIdentity }
            if fields["error"] != nil { throw ChatGPTFailure.message(String(localized: "ChatGPT 로그인을 승인하지 않았거나 완료하지 못했습니다.")) }
            guard let code = fields["code"], !code.isEmpty, code.count <= 4096 else { throw ChatGPTFailure.invalidIdentity }
            let issued = fields["client_id"] ?? clientID ?? ""
            guard !issued.isEmpty, issued != "dynamic_agent_client", issued.count <= 256,
                  issued.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil,
                  clientID.map({ $0 == issued }) ?? true else { throw ChatGPTFailure.invalidIdentity }
            return (code, issued)
        }
    }
    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let left = Array(a.utf8), right = Array(b.utf8)
        guard left.count == right.count else { return false }
        return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(base64URL: String) {
        guard !base64URL.isEmpty, base64URL.count % 4 != 1,
              base64URL.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
        let value = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: value + String(repeating: "=", count: (4 - value.count % 4) % 4))
    }
}

/// Accept output only at the terminal completed event; partial text is never a successful translation.
struct ChatGPTResponseStream {
    private var frame: [String] = []
    private(set) var text = ""
    private(set) var completed = false
    mutating func consume(line: String) throws {
        guard !completed else { return }
        if !line.isEmpty {
            if line.hasPrefix("data:") {
                let value = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                guard frame.reduce(0, { $0 + $1.utf8.count }) + value.utf8.count < 2_000_000 else {
                    throw ChatGPTFailure.message(String(localized: "ChatGPT 응답이 너무 큽니다."))
                }
                frame.append(value)
            }
            return
        }
        guard !frame.isEmpty else { return }
        let payload = frame.joined(separator: "\n"); frame.removeAll()
        guard payload != "[DONE]", let data = payload.data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = event["type"] as? String else { throw ChatGPTFailure.message(String(localized: "ChatGPT 응답 스트림이 올바르지 않습니다.")) }
        switch type {
        case "response.output_text.delta":
            guard let delta = event["delta"] as? String else { throw ChatGPTFailure.message(String(localized: "번역 응답이 올바르지 않습니다.")) }
            guard text.utf8.count + delta.utf8.count < 16_000_000 else { throw ChatGPTFailure.message(String(localized: "번역 결과가 너무 큽니다.")) }
            text += delta
        case "response.completed":
            guard let response = event["response"] as? [String: Any], response["status"] as? String == "completed",
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ChatGPTFailure.message(String(localized: "ChatGPT 번역이 완료되지 않았습니다."))
            }
            completed = true
        case "response.failed", "error":
            let response = event["response"] as? [String: Any]
            let error = (response?["error"] ?? event["error"]) as? [String: Any] ?? event
            let code = error["code"] as? String ?? ""
            let status = code == "subscription_sharing_usage_unavailable" ? 503 : (code == "subscription_sharing_usage_limit_exceeded" ? 429 : 400)
            throw ChatGPTHTTP.failure(status: status, object: error, requestID: nil)
        case "response.incomplete":
            throw ChatGPTFailure.message(String(localized: "ChatGPT 번역 결과가 잘렸습니다. 원본 자막을 보존했습니다."))
        default: break
        }
    }
    mutating func finish() throws -> String {
        if !frame.isEmpty { try consume(line: "") }
        guard completed else { throw ChatGPTFailure.message(String(localized: "ChatGPT 연결이 완료 전에 끊겼습니다. 원본 자막을 보존했습니다.")) }
        return text
    }
}

/// Foundation's AsyncBytes.lines drops empty lines; SSE requires them as event delimiters.
struct ChatGPTEventLines {
    private var bytes = Data()
    private var afterCR = false
    mutating func consume(_ byte: UInt8) throws -> String? {
        if afterCR { afterCR = false; if byte == 10 { return nil } }
        if byte == 10 || byte == 13 {
            afterCR = byte == 13
            guard let line = String(data: bytes, encoding: .utf8) else { throw ChatGPTFailure.message(String(localized: "번역 스트림의 문자 인코딩이 올바르지 않습니다.")) }
            bytes.removeAll(keepingCapacity: true); return line
        }
        guard bytes.count < 2_000_000 else { throw ChatGPTFailure.message(String(localized: "ChatGPT 응답이 너무 큽니다.")) }
        bytes.append(byte); return nil
    }
    mutating func finish() throws -> String? {
        guard !bytes.isEmpty else { return nil }
        guard let line = String(data: bytes, encoding: .utf8) else { throw ChatGPTFailure.message(String(localized: "번역 스트림의 문자 인코딩이 올바르지 않습니다.")) }
        bytes.removeAll(); return line
    }
}
