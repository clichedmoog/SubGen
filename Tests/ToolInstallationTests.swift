import XCTest
import CryptoKit
@testable import SubtitleGen

final class ToolInstallationTests: XCTestCase {
    private var directory: URL!
    private var destination: URL!
    private var archive: URL!
    private var binaryHash: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("subtitlegen-install-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        destination = directory.appendingPathComponent("installed/ffmpeg")
        let source = directory.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        // Real native Mach-O with system dependencies; accepts the probe arguments.
        let binary = source.appendingPathComponent("ffmpeg")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: binary)
        binaryHash = SHA256.hash(data: try Data(contentsOf: binary)).map { String(format: "%02x", $0) }.joined()
        archive = directory.appendingPathComponent("tool.zip")
        XCTAssertTrue(ProcessRunner.run("/usr/bin/ditto", arguments: ["-c", "-k", "--keepParent", source.path, archive.path], timeout: 10).succeeded)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func existingTool() throws -> Data {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data("existing tool must survive a failed update".utf8)
        try data.write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
        return data
    }

    private var download: ToolArchiveInstaller.Download {
        .init(url: archive, binaryName: "ffmpeg", binarySHA256: binaryHash)
    }

    func testNativeArchiveInstallsAndRepairsNonExecutableOldFile() throws {
        _ = try existingTool()
        try ToolArchiveInstaller.install(download, to: destination, cancellation: CancellationToken())
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: destination.path))
        XCTAssertTrue(ToolResolver.isUsable(destination.path))
    }

    func testWrongChecksumPreservesExistingTool() throws {
        let original = try existingTool()
        let bad = ToolArchiveInstaller.Download(url: archive, binaryName: "ffmpeg", binarySHA256: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try ToolArchiveInstaller.install(bad, to: destination, cancellation: CancellationToken())) {
            XCTAssertEqual($0 as? ToolArchiveInstaller.Failure, .checksum)
        }
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testUnexpectedSigningTeamPreservesExistingTool() throws {
        let original = try existingTool()
        var signed = download
        signed.signingTeam = "NOTTHETEAM"
        XCTAssertThrowsError(try ToolArchiveInstaller.install(signed, to: destination, cancellation: CancellationToken())) {
            XCTAssertEqual($0 as? ToolArchiveInstaller.Failure, .signature)
        }
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testCancelledBeforeDownloadLeavesNoInstallation() {
        let token = CancellationToken(); token.cancel()
        XCTAssertThrowsError(try ToolArchiveInstaller.install(download, to: destination, cancellation: token)) {
            XCTAssertEqual($0 as? ToolArchiveInstaller.Failure, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testCancelledAfterExtractionPreservesExistingTool() throws {
        let original = try existingTool()
        let token = CancellationToken()
        XCTAssertThrowsError(try ToolArchiveInstaller.install(download, to: destination, cancellation: token) { progress in
            if progress == 0.85 { token.cancel() }
        }) { XCTAssertEqual($0 as? ToolArchiveInstaller.Failure, .cancelled) }
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testConcurrentChangeDoesNotGetOverwritten() throws {
        _ = try existingTool()
        let changed = Data("user modified this tool during download".utf8)
        XCTAssertThrowsError(try ToolArchiveInstaller.install(download, to: destination, cancellation: CancellationToken()) { progress in
            if progress == 0.65 { try! changed.write(to: self.destination) }
        }) { error in
            guard case SafeFileReplacement.Failure.sourceChanged = error else {
                return XCTFail("Expected refusal to overwrite a concurrent change: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: destination), changed)
    }

    func testFailedDownloadPreservesExistingTool() throws {
        let original = try existingTool()
        let missing = ToolArchiveInstaller.Download(url: directory.appendingPathComponent("missing.zip"), binaryName: "ffmpeg", binarySHA256: binaryHash)
        XCTAssertThrowsError(try ToolArchiveInstaller.install(missing, to: destination, cancellation: CancellationToken()))
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testAmbiguousExecutablesAreRejected() throws {
        let second = directory.appendingPathComponent("source/extra")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: second.appendingPathComponent("ffmpeg"))
        try FileManager.default.removeItem(at: archive)
        XCTAssertTrue(ProcessRunner.run("/usr/bin/ditto", arguments: ["-c", "-k", "--keepParent", directory.appendingPathComponent("source").path, archive.path], timeout: 10).succeeded)
        XCTAssertThrowsError(try ToolArchiveInstaller.install(download, to: destination, cancellation: CancellationToken())) {
            XCTAssertEqual($0 as? ToolArchiveInstaller.Failure, .extraction)
        }
    }

    func testSignedWhisperArchiveInstallsWithoutBuildTools() throws {
        let environment = ProcessInfo.processInfo.environment
        let archiveURL = environment["SUBTITLEGEN_WHISPER_URL"].flatMap(URL.init(string:))
            ?? environment["SUBTITLEGEN_WHISPER_ARCHIVE"].map { URL(fileURLWithPath: $0) }
        guard let archiveURL, let expected = environment["SUBTITLEGEN_WHISPER_SHA256"] else {
            throw XCTSkip("Provide the signed Whisper release ZIP and its pinned binary SHA256")
        }
        let download = ToolArchiveInstaller.Download(url: archiveURL, binaryName: "whisper-cli",
                                                     binarySHA256: expected, signingTeam: "N9LYHMUDKA")
        let installed = directory.appendingPathComponent("isolated/whisper-cli")
        try ToolArchiveInstaller.install(download, to: installed, cancellation: CancellationToken())
        XCTAssertTrue(ToolResolver.isUsable(installed.path, arguments: ["--help"]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.deletingLastPathComponent().appendingPathComponent("whisper-cli-LICENSE.txt").path))
    }
}
