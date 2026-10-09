import Foundation
import Security

struct ChatGPTCredentials: Codable {
    var accessToken: String
    var refreshToken: String
    var idToken: String
    var scopes: [String]
    var expiresAt: Date
    var earliestRefreshAt: Date?
    var revision = UUID()
}
struct ChatGPTRegistration: Codable, Identifiable {
    var id: String // Issued client ID; never an email address.
    var issuer: String
    var subject: String
    var email: String?
    var credentials: ChatGPTCredentials?
}
protocol ChatGPTCredentialStorage: Sendable {
    func load() throws -> [ChatGPTRegistration]
    func save(_ registrations: [ChatGPTRegistration]) throws
}
struct ChatGPTKeychain: ChatGPTCredentialStorage {
    let service: String
    init(service: String = (Bundle.main.bundleIdentifier ?? "com.clichedmoog.subtitle-generator.swiftpm") + ".chatgpt-siwc") {
        self.service = service
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "registrations", kSecAttrSynchronizable as String: false]
    }
    func load() throws -> [ChatGPTRegistration] {
        var request = query; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        do { return try JSONDecoder().decode([ChatGPTRegistration].self, from: data) }
        catch { throw ChatGPTFailure.message("저장된 ChatGPT 연결 정보를 읽을 수 없습니다. 키체인을 확인해주세요.") }
    }
    func save(_ registrations: [ChatGPTRegistration]) throws {
        let data = try JSONEncoder().encode(registrations)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure(status) }
    }
    private func failure(_ status: OSStatus) -> ChatGPTFailure {
        .message("ChatGPT 연결 정보를 키체인에 저장하거나 읽을 수 없습니다 (\(status)).")
    }
}
