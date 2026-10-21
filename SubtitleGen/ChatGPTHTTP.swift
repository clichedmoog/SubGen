import Foundation

enum ChatGPTHTTP {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }()
    static func json(_ request: URLRequest, session: URLSession = session) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count < 5_000_000 else {
            throw ChatGPTFailure.message(String(localized: "ChatGPT 서버 응답이 올바르지 않습니다."))
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(http.statusCode) else {
            throw failure(status: http.statusCode, object: (object["error"] as? [String: Any]) ?? object,
                          requestID: http.value(forHTTPHeaderField: "x-request-id") ?? http.value(forHTTPHeaderField: "openai-request-id"))
        }
        return object
    }
    static func failure(status: Int, object: [String: Any], requestID: String?) -> ChatGPTFailure {
        // Never surface raw response bodies, transcripts, tokens or authorization URLs.
        let code = object["code"] as? String ?? object["error"] as? String ?? "request_failed"
        func safe(_ value: String) -> String {
            String(value.unicodeScalars.filter { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.").contains($0) }.prefix(120))
        }
        return .service(status: status, code: safe(code), requestID: requestID.map(safe))
    }
    static func post(_ url: String, fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"; request.httpBody = ChatGPTOAuth.form(fields)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}
