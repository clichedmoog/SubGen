import Foundation
import Network

/// A single-use callback server, reachable only on the IPv4 loopback interface.
final class ChatGPTLoopback: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SubtitleGen.ChatGPT.loopback")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var result: Result<URL, Error>?
    private var waiter: CheckedContinuation<URL, Error>?
    private var ready: CheckedContinuation<URL, Error>?
    private var redirect: URL?

    func start() async throws -> URL {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if self.result != nil { continuation.resume(throwing: ChatGPTFailure.cancelled); return }
                    self.ready = continuation
                    do {
                        let parameters = NWParameters.tcp
                        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
                        let server = try NWListener(using: parameters)
                        self.listener = server
                        server.stateUpdateHandler = { state in
                            switch state {
                            case .ready:
                                guard let port = server.port else { self.complete(.failure(ChatGPTFailure.invalidIdentity)); return }
                                let url = URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback")!
                                self.redirect = url
                                self.ready?.resume(returning: url); self.ready = nil
                            case .failed: self.complete(.failure(ChatGPTFailure.message("로그인 연결을 받을 수 없습니다.")))
                            default: break
                            }
                        }
                        server.newConnectionHandler = { self.accept($0) }
                        server.start(queue: self.queue)
                        self.queue.asyncAfter(deadline: .now() + ChatGPTOAuth.loginTimeout) {
                            self.complete(.failure(ChatGPTFailure.message("ChatGPT 로그인 시간이 초과되었습니다.")))
                        }
                    } catch { self.complete(.failure(ChatGPTFailure.message("로그인 연결을 시작할 수 없습니다."))) }
                }
            }
        }, onCancel: { self.cancel() })
    }

    func callback() async throws -> URL {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.result { continuation.resume(with: result) }
                    else if self.waiter == nil { self.waiter = continuation }
                    else { continuation.resume(throwing: ChatGPTFailure.invalidIdentity) }
                }
            }
        }, onCancel: { self.cancel() })
    }
    func cancel() { queue.async { self.complete(.failure(ChatGPTFailure.cancelled)) } }

    private func complete(_ outcome: Result<URL, Error>) {
        guard result == nil else { return }
        result = outcome
        if case .failure(let error) = outcome { ready?.resume(throwing: error); ready = nil }
        waiter?.resume(with: outcome); waiter = nil
        listener?.cancel(); listener = nil
        connections.values.forEach { $0.cancel() }; connections.removeAll()
    }
    private func accept(_ connection: NWConnection) {
        guard result == nil, connections.count < 16 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { self.connections.removeValue(forKey: id)?.cancel() }
        receive(connection, id: id, buffer: Data())
    }
    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, ended, error in
            var bytes = buffer; if let data { bytes.append(data) }
            guard bytes.count <= 16_384, error == nil else {
                self.connections.removeValue(forKey: id)?.cancel(); return
            }
            guard let range = bytes.range(of: Data("\r\n\r\n".utf8)) else {
                if ended { self.connections.removeValue(forKey: id)?.cancel() }
                else { self.receive(connection, id: id, buffer: bytes) }; return
            }
            let header = String(decoding: bytes[..<range.lowerBound], as: UTF8.self)
            let lines = header.components(separatedBy: "\r\n")
            let fields = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
            let hosts = lines.dropFirst().filter { $0.lowercased().hasPrefix("host:") }
            let host = hosts.first.map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
            var callback: URL?
            if fields.count == 3, fields[0] == "GET", fields[2] == "HTTP/1.1", hosts.count == 1,
               let redirect = self.redirect, host == "127.0.0.1:\(redirect.port!)",
               fields[1].hasPrefix("/auth/callback?"),
               let url = URL(string: "http://\(host!)\(fields[1])"), url.path == redirect.path {
                callback = url
            }
            let body = callback == nil ? "Not found." : "You may return to Subtitle Maker & Translator."
            let reply = "HTTP/1.1 \(callback == nil ? "404 Not Found" : "200 OK")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\n\r\n\(body)"
            let resolved = callback
            connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in
                self.connections.removeValue(forKey: id)?.cancel()
                if let resolved { self.complete(.success(resolved)) }
            })
        }
    }
}
