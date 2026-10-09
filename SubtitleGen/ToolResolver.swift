import Foundation
import Darwin

enum ToolResolver {
    static var binDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SubtitleGenerator/bin")
    }

    // Inspect the hardware, including when the app itself runs under Rosetta.
    static let architecture: String = {
        var arm: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &arm, &size, nil, 0) == 0 && arm == 1 ? "arm64" : "x86_64"
    }()
    static var cpuType: UInt32 { architecture == "arm64" ? 0x0100000c : 0x01000007 }

    private static let lock = NSLock()
    private static var cache: [String: (Date, Int64, Date)] = [:]

    static func find(_ name: String, candidates: [String]? = nil) -> String? {
        if AppDistribution.isStore, candidates == nil {
            guard let bundled = Bundle.main.url(forAuxiliaryExecutable: name) else { return nil }
            return find(name, candidates: [bundled.path])
        }
        let systemDirectories = architecture == "arm64"
            ? ["/opt/homebrew/bin", "/usr/local/bin"] : ["/usr/local/bin", "/opt/homebrew/bin"]
        var paths = candidates ?? [binDirectory.appendingPathComponent(name).path]
        if candidates == nil {
            if let bundled = Bundle.main.url(forAuxiliaryExecutable: name) { paths.append(bundled.path) }
            paths += systemDirectories.map { "\($0)/\(name)" }
            paths.append("\(NSHomeDirectory())/.local/bin/\(name)")
        }
        let arguments = name == "whisper-cli" ? ["--help"] : ["-version"]
        for path in paths where isUsable(path, arguments: arguments) { return path }
        return nil
    }

    static func isUsable(_ path: String, arguments: [String] = ["-version"]) -> Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: path),
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return false }
        let header = (try? handle.read(upToCount: 4096)) ?? Data()
        try? handle.close()
        guard hasArchitecture(header, cpuType: cpuType) else { return false }
        // Store tools are immutable, signed bundle resources; only external
        // installations need a file-modification cache key.
        let attrs = AppDistribution.isStore ? [:] : (try? fm.attributesOfItem(atPath: path)) ?? [:]
        let modified = attrs[.modificationDate] as? Date ?? .distantPast
        let size = attrs[.size] as? Int64 ?? 0
        lock.lock()
        let cached = cache[path]
        lock.unlock()
        if let cached, cached.0 == modified, cached.1 == size, Date().timeIntervalSince(cached.2) < 30 { return true }
        let result = ProcessRunner.run(path, arguments: arguments, timeout: 5)
        guard result.succeeded else { return false }
        lock.lock()
        cache[path] = (modified, size, Date())
        lock.unlock()
        return true
    }

    /// Read thin and universal Mach-O headers without executing foreign code.
    static func hasArchitecture(_ data: Data, cpuType: UInt32) -> Bool {
        func word(_ offset: Int, little: Bool = false) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            let bytes = Array(data[offset..<offset + 4])
            let ordered = little ? Array(bytes.reversed()) : bytes
            return ordered.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        switch word(0) {
        case 0xcffaedfe, 0xcefaedfe: return word(4, little: true) == cpuType
        case 0xfeedfacf, 0xfeedface: return word(4) == cpuType
        case 0xcafebabe, 0xcafebabf, 0xbebafeca, 0xbfbafeca:
            let magic = word(0)!
            let little = magic == 0xbebafeca || magic == 0xbfbafeca
            let stride = magic == 0xcafebabf || magic == 0xbfbafeca ? 32 : 20
            guard let count = word(4, little: little), count <= 64 else { return false }
            return (0..<Int(count)).contains { word(8 + $0 * stride, little: little) == cpuType }
        default: return false
        }
    }
}

enum FFmpegDistribution {
    struct Download {
        let url: URL
        let sha256: String
    }
    static func download(_ name: String, architecture: String = ToolResolver.architecture) -> Download {
        precondition(name == "ffmpeg" || name == "ffprobe")
        let arm = architecture == "arm64"
        let hash: String
        switch (name, arm) {
        case ("ffmpeg", true): hash = "591260c945d0eef150e3bf82b0ef988bd36a9cecc18ff05d6679617159f0a95e"
        case ("ffprobe", true): hash = "e11c17e8200b3ee4c4c186d245e2b4053f01d56957336c1817fca0b997469106"
        case ("ffmpeg", false): hash = "df3f1e3facdc1ae0ad0bd898cdfb072fbc9641bf47b11f172844525a05db8d11"
        default: hash = "5228e651e2bd67bb55819b27f6138351587b16d2b87446007bf35b7cf930d891"
        }
        return Download(url: URL(string: "https://www.osxexperts.net/\(name)\(arm ? "9arm" : "80intel").zip")!, sha256: hash)
    }
}
