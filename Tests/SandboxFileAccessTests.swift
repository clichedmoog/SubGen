import XCTest
@testable import SubtitleGen

final class SandboxFileAccessTests: XCTestCase {
    func testFolderGrantCoversNestedOutputButNotMatchingPrefixOrTheFolderItself() {
        let folder = URL(fileURLWithPath: "/tmp/subtitle-output")
        XCTAssertTrue(SandboxFileAccess.contains(folder, file: folder.appendingPathComponent("nested/movie.srt")))
        XCTAssertFalse(SandboxFileAccess.contains(folder, file: URL(fileURLWithPath: "/tmp/subtitle-output-other/movie.srt")))
        XCTAssertFalse(SandboxFileAccess.contains(folder, file: folder))
        XCTAssertFalse(SandboxFileAccess.contains(folder, file: folder.appendingPathComponent("../other/movie.srt")))
    }

    func testSymlinkCannotTurnAnOutsideInputIntoAnAuthorizedChild() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let allowed = root.appendingPathComponent("allowed")
        let outside = root.appendingPathComponent("outside")
        for directory in [allowed, outside] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let externalFile = outside.appendingPathComponent("movie.wav")
        try Data("audio".utf8).write(to: externalFile)
        let alias = allowed.appendingPathComponent("linked.wav")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: externalFile)
        XCTAssertFalse(SandboxFileAccess.contains(allowed, file: alias))
        XCTAssertTrue(SandboxFileAccess.contains(outside, file: alias))
    }
}
