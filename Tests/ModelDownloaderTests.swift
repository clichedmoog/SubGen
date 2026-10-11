import XCTest
@testable import SubtitleGen

final class ModelDownloaderTests: XCTestCase {
    private var root: URL!
    private var server: Process!
    private var baseURL: URL!

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("Local HTTP fixture requires Python 3")
        }
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ready = root.appendingPathComponent("port")
        server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-c", #"""
import http.server, pathlib, sys, time
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        if self.path == '/slow': time.sleep(1)
        payload = b'model-data'
        self.send_response(503 if self.path == '/error' else 200)
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        try: self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
pathlib.Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
"""#, ready.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: ready.path), server.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard let port = try? String(contentsOf: ready), let url = URL(string: "http://127.0.0.1:\(port)") else {
            if server.isRunning { server.terminate() }
            throw NSError(domain: "HTTP fixture startup", code: 1)
        }
        baseURL = url
    }

    override func tearDownWithError() throws {
        if server?.isRunning == true { server.terminate(); server.waitUntilExit() }
        if let root { try FileManager.default.removeItem(at: root) }
    }

    func testSuccessfulDownloadAndHTTPFailureLeavePreviousModelIntact() throws {
        let downloaded = root.appendingPathComponent("downloaded")
        let progressLock = NSLock()
        var received: Int64 = 0
        try ModelDownloader.download(baseURL.appendingPathComponent("model"), to: downloaded,
                                     timeout: 3, cancellation: CancellationToken(), onProgress: { count, total in
            progressLock.lock(); defer { progressLock.unlock() }
            received = max(received, count)
            if count > 0 { XCTAssertEqual(total, 10) }
        })
        XCTAssertEqual(try Data(contentsOf: downloaded), Data("model-data".utf8))
        progressLock.lock(); let finalReceived = received; progressLock.unlock()
        XCTAssertEqual(finalReceived, 10)
        let previous = root.appendingPathComponent("previous")
        try Data("existing-model".utf8).write(to: previous)
        XCTAssertThrowsError(try ModelDownloader.download(baseURL.appendingPathComponent("error"), to: previous,
                              timeout: 3, cancellation: CancellationToken())) { error in
            guard case ModelDownloader.Failure.http(503) = error else { return XCTFail("Expected HTTP failure: \(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: previous), Data("existing-model".utf8))
        // A successful HTTP transfer must also never overwrite an existing destination.
        XCTAssertThrowsError(try ModelDownloader.download(baseURL.appendingPathComponent("model"), to: previous,
                              timeout: 3, cancellation: CancellationToken()))
        XCTAssertEqual(try Data(contentsOf: previous), Data("existing-model".utf8))
    }

    func testCancellationStopsTransferWithoutCreatingAStagedFile() throws {
        let staged = root.appendingPathComponent("cancelled")
        let token = CancellationToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { token.cancel() }
        XCTAssertThrowsError(try ModelDownloader.download(baseURL.appendingPathComponent("slow"), to: staged,
                              timeout: 3, cancellation: token)) { error in
            guard case ModelDownloader.Failure.cancelled = error else { return XCTFail("Expected cancellation: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func testTimeoutAndPrecancelledTransferDoNotCreateAStagedFile() {
        let staged = root.appendingPathComponent("timed-out")
        XCTAssertThrowsError(try ModelDownloader.download(baseURL.appendingPathComponent("slow"), to: staged,
                              timeout: 0.1, cancellation: CancellationToken()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        let token = CancellationToken()
        token.cancel()
        XCTAssertThrowsError(try ModelDownloader.download(baseURL.appendingPathComponent("model"), to: staged,
                              timeout: 3, cancellation: token)) { error in
            guard case ModelDownloader.Failure.cancelled = error else { return XCTFail("Expected cancellation") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }
}
