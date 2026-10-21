import Foundation
import CryptoKit

/// Installs a verified native executable without Homebrew, CMake or Xcode.
enum ToolArchiveInstaller {
    struct Download {
        let url: URL
        let binaryName: String
        let binarySHA256: String
        var signingTeam: String? = nil
    }

    enum Failure: LocalizedError {
        case download, extraction, checksum, signature, execution, cancelled, configuration
        var errorDescription: String? {
            switch self {
            case .download: return String(localized: "도구를 다운로드하지 못했습니다. 인터넷 연결을 확인하고 다시 시도해주세요.")
            case .extraction: return String(localized: "설치 파일을 열지 못했습니다. 다시 다운로드해주세요.")
            case .checksum: return String(localized: "다운로드한 파일의 무결성 검증에 실패했습니다.")
            case .signature: return String(localized: "음성인식 도구의 개발자 서명을 확인하지 못했습니다.")
            case .execution: return String(localized: "이 Mac에서 도구를 실행하지 못했습니다.")
            case .cancelled: return String(localized: "설치를 중단했습니다.")
            case .configuration: return String(localized: "음성인식 도구의 다운로드 정보를 찾지 못했습니다. 앱을 업데이트해주세요.")
            }
        }
    }

    static func install(_ download: Download, to destination: URL, cancellation: CancellationToken,
                        progress: (Double) -> Void = { _ in }) throws {
        let fm = FileManager.default
        let original = fm.fileExists(atPath: destination.path) ? try SafeFileReplacement.Snapshot(destination) : nil
        let temporary = fm.temporaryDirectory.appendingPathComponent("subtitlegen-tool-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        if cancellation.isCancelled { throw Failure.cancelled }
        let archive = temporary.appendingPathComponent("download.zip")
        progress(0.05)
        let transfer = ProcessRunner.run("/usr/bin/curl", arguments: ["-fL", "--connect-timeout", "20",
            "--max-time", "300", "--retry", "2", download.url.absoluteString, "-o", archive.path],
            timeout: 650, cancellation: cancellation)
        if cancellation.isCancelled { throw Failure.cancelled }
        guard transfer.succeeded else { throw Failure.download }
        let extracted = temporary.appendingPathComponent("extracted")
        progress(0.65)
        let listing = ProcessRunner.run("/usr/bin/unzip", arguments: ["-Z", "-1", archive.path], timeout: 30, cancellation: cancellation)
        guard listing.succeeded, listing.stdout.split(separator: "\n").allSatisfy({ entry in
            !entry.hasPrefix("/") && !entry.split(separator: "/").contains("..")
        }) else { throw Failure.extraction }
        guard ProcessRunner.run("/usr/bin/unzip", arguments: ["-q", archive.path, "-d", extracted.path],
                                timeout: 60, cancellation: cancellation).succeeded else { throw Failure.extraction }
        if cancellation.isCancelled { throw Failure.cancelled }
        let enumerator = fm.enumerator(at: extracted, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        var candidates: [URL] = []
        while let file = enumerator?.nextObject() as? URL {
            guard file.lastPathComponent == download.binaryName else { continue }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isRegularFile == true && values.isSymbolicLink != true { candidates.append(file) }
        }
        guard candidates.count == 1, let candidate = candidates.first else { throw Failure.extraction }
        let data = try Data(contentsOf: candidate, options: .mappedIfSafe)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == download.binarySHA256.lowercased() else { throw Failure.checksum }
        progress(0.85)
        if cancellation.isCancelled { throw Failure.cancelled }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: candidate.path)
        if let team = download.signingTeam {
            let requirement = "=anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            guard ProcessRunner.run("/usr/bin/codesign", arguments: ["--verify", "--strict", "-R", requirement, candidate.path],
                                    timeout: 30, cancellation: cancellation).succeeded else { throw Failure.signature }
        }
        let arguments = download.binaryName == "whisper-cli" ? ["--help"] : ["-version"]
        guard ToolResolver.isUsable(candidate.path, arguments: arguments) else { throw Failure.execution }
        if cancellation.isCancelled { throw Failure.cancelled }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".\(download.binaryName)-\(UUID().uuidString)")
        try fm.copyItem(at: candidate, to: staged)
        defer { try? fm.removeItem(at: staged) }
        if cancellation.isCancelled { throw Failure.cancelled }
        if let original {
            try SafeFileReplacement.replace(destination, with: staged, expected: original, preservingPermissions: false)
        } else {
            guard !fm.fileExists(atPath: destination.path) else { throw SafeFileReplacement.Failure.sourceChanged }
            try fm.moveItem(at: staged, to: destination)
        }
        // Retain the accompanying license beside downloaded tools.
        for license in ["LICENSE.txt", "whisper.cpp-MIT.txt"] {
            let source = candidate.deletingLastPathComponent().appendingPathComponent(license)
            if fm.fileExists(atPath: source.path), let text = try? Data(contentsOf: source) {
                try? text.write(to: destination.deletingLastPathComponent().appendingPathComponent("\(download.binaryName)-LICENSE.txt"), options: .atomic)
            }
        }
        progress(1)
    }
}

enum WhisperDistribution {
    static func download(architecture: String = ToolResolver.architecture, bundle: Bundle = .main) throws -> ToolArchiveInstaller.Download {
        guard let path = bundle.url(forResource: "ToolDownloads", withExtension: "plist"),
              let data = try? Data(contentsOf: path),
              let configuration = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let whisper = configuration["whisper-cli"] as? [String: [String: String]],
              let native = whisper[architecture], let urlString = native["url"],
              let url = URL(string: urlString), url.scheme == "https",
              let hash = native["sha256"], hash.count == 64,
              hash.allSatisfy({ $0.isHexDigit }) else { throw ToolArchiveInstaller.Failure.configuration }
        return ToolArchiveInstaller.Download(url: url, binaryName: "whisper-cli", binarySHA256: hash,
                                             signingTeam: "N9LYHMUDKA")
    }
}
