import XCTest
@testable import SubtitleGen

final class WhisperModelInstallerTests: XCTestCase {
    private var root: URL!
    private var destination: URL { root.appendingPathComponent(WhisperModel.tiny.rawValue) }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func writeModel(to url: URL, validHeader: Bool = true) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.write(contentsOf: validHeader ? Data([0x6c, 0x6d, 0x67, 0x67]) : Data("html".utf8))
        try handle.truncate(atOffset: 10_000_000)
    }
    private func assertNoStaging() throws {
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".") })
    }
    func testMissingModelInstallsBeforeUseAndCachedModelSkipsDownload() throws {
        var requests = 0, received: [Int64] = []
        let download: WhisperModelInstaller.Download = { source, staged, _, progress in
            requests += 1
            XCTAssertTrue(source.absoluteString.hasSuffix(WhisperModel.tiny.rawValue))
            progress(5_000_000, 10_000_000)
            try self.writeModel(to: staged); progress(10_000_000, 10_000_000)
        }
        try WhisperModelInstaller.ensureAvailable(at: destination, cancellation: CancellationToken(),
                                                 onProgress: { bytes, _ in received.append(bytes) }, download: download)
        XCTAssertTrue(WhisperModelInstaller.isAvailable(at: destination)); XCTAssertEqual(received.last, 10_000_000)
        try WhisperModelInstaller.ensureAvailable(at: destination, cancellation: CancellationToken(), download: download)
        XCTAssertEqual(requests, 1); try assertNoStaging()
    }
    func testIncompleteAndWrongHeaderModelsAreRepaired() throws {
        for wrongHeader in [false, true] {
            if wrongHeader { try writeModel(to: destination, validHeader: false) }
            else { try Data("partial-model".utf8).write(to: destination) }
            XCTAssertFalse(WhisperModelInstaller.isAvailable(at: destination))
            try WhisperModelInstaller.ensureAvailable(at: destination, cancellation: CancellationToken(), download: { _, staged, _, _ in
                try self.writeModel(to: staged)
            })
            XCTAssertTrue(WhisperModelInstaller.isAvailable(at: destination)); try assertNoStaging()
        }
    }
    func testFailedInvalidAndCancelledTransfersPreserveExistingModel() throws {
        let original = Data("partial-existing-model".utf8)
        for scenario in 0..<3 {
            try original.write(to: destination)
            let token = CancellationToken()
            XCTAssertThrowsError(try WhisperModelInstaller.ensureAvailable(at: destination, cancellation: token, download: { _, staged, _, _ in
                switch scenario {
                case 0: try Data("partial-transfer".utf8).write(to: staged); throw ModelDownloader.Failure.http(503)
                case 1: try self.writeModel(to: staged, validHeader: false)
                default: try self.writeModel(to: staged); token.cancel()
                }
            }))
            XCTAssertEqual(try Data(contentsOf: destination), original); try assertNoStaging()
        }
    }
    func testConcurrentChangeIsNotOverwrittenByDownload() throws {
        try Data("old-partial-model".utf8).write(to: destination)
        let changed = Data("different-model-installed-while-downloading".utf8)
        XCTAssertThrowsError(try WhisperModelInstaller.ensureAvailable(at: destination, cancellation: CancellationToken(), download: { _, staged, _, _ in
            try self.writeModel(to: staged); try changed.write(to: self.destination, options: .atomic)
        }))
        XCTAssertEqual(try Data(contentsOf: destination), changed); try assertNoStaging()
    }
    private func writeVad(to url: URL) throws {
        var data = Data([0x6c, 0x6d, 0x67, 0x67, 0x0a, 0, 0, 0]); data += Data("silero-16k".utf8)
        data += Data(count: 200_000); try data.write(to: url)
    }
    func testVadModelInstallsNextToSpeechModelOnce() throws {
        let vad = WhisperModelInstaller.vadURL(nextTo: destination)
        XCTAssertEqual(vad.deletingLastPathComponent(), destination.deletingLastPathComponent())
        XCTAssertFalse(WhisperModelInstaller.isVadAvailable(at: vad))
        var requests = 0
        let download: WhisperModelInstaller.Download = { source, staged, _, _ in
            requests += 1
            XCTAssertEqual(source.lastPathComponent, vad.lastPathComponent)
            try self.writeVad(to: staged)
        }
        try WhisperModelInstaller.ensureVadAvailable(nextTo: destination, cancellation: CancellationToken(), download: download)
        try WhisperModelInstaller.ensureVadAvailable(nextTo: destination, cancellation: CancellationToken(), download: download)
        XCTAssertTrue(WhisperModelInstaller.isVadAvailable(at: vad)); XCTAssertEqual(requests, 1); try assertNoStaging()
    }
    func testFailedOrInvalidVadTransferThrowsInsteadOfSilentlyDisablingVad() throws {
        for scenario in 0..<2 {
            XCTAssertThrowsError(try WhisperModelInstaller.ensureVadAvailable(nextTo: destination, cancellation: CancellationToken(), download: { _, staged, _, _ in
                if scenario == 0 { throw ModelDownloader.Failure.http(503) }
                try Data("<html>not a model</html>".utf8).write(to: staged)
            }))
            XCTAssertFalse(WhisperModelInstaller.isVadAvailable(at: WhisperModelInstaller.vadURL(nextTo: destination)))
            try assertNoStaging()
        }
    }
    func testSpeechModelIsNotReadyWithoutVad() throws {
        try writeModel(to: destination)
        XCTAssertTrue(WhisperModelInstaller.isAvailable(at: destination))
        XCTAssertFalse(WhisperModelInstaller.isReady(model: destination))
        try writeVad(to: WhisperModelInstaller.vadURL(nextTo: destination))
        XCTAssertTrue(WhisperModelInstaller.isReady(model: destination))
    }
    func testVadThresholdsDoNotClassifyBackgroundMusicAsSpeech() {
        // A narrated video with continuous music started the first cue at 0.16s with 0.2 and
        // 0.35s with 0.3; 0.35 and above matched the narration onset at 11.59s.
        XCTAssertEqual(Sensitivity.normal.vadThreshold, 0.5)
        for sensitivity in Sensitivity.allCases { XCTAssertGreaterThanOrEqual(sensitivity.vadThreshold, 0.35) }
    }
    func testAlreadyCancelledRequestDoesNotDownload() {
        let token = CancellationToken(); token.cancel()
        XCTAssertThrowsError(try WhisperModelInstaller.ensureAvailable(at: destination, cancellation: token, download: { _, _, _, _ in
            XCTFail("Cancelled processing must not start a transfer")
        }))
    }
    func testRetryRequeuesOnlyFailedAndCancelledItems() {
        let states: [FileStatus] = [.failed(error: "model missing"), .cancelled, .completed(lang: "en"), .skipped, .pending, .processing, .translating(lang: "ko")]
        var files = states.enumerated().map { index, status in
            var file = FileItem(url: root.appendingPathComponent("\(index).wav"))
            file.status = status; file.progress = 1; file.progressDetail = "previous"; file.sourceLanguage = "en"
            return file
        }
        FileItem.requeueFailedOrCancelled(&files)
        XCTAssertEqual(files.map(\.status), [.pending, .pending] + Array(states.dropFirst(2)))
        XCTAssertEqual(files[0].progress, 0); XCTAssertEqual(files[1].progressDetail, "")
        XCTAssertEqual(files[0].sourceLanguage, "en"); XCTAssertEqual(files[2].progress, 1)
    }
}
