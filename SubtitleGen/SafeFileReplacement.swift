import Foundation
import Darwin

enum SafeFileReplacement {
    enum Failure: Error { case emptyOutput, sourceChanged, replacement(Int32) }
    struct Snapshot: Equatable {
        let size: Int64
        let modified: Date
        let inode: UInt64
        init(_ url: URL) throws {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            size = (attrs[.size] as? Int64) ?? 0
            modified = (attrs[.modificationDate] as? Date) ?? .distantPast
            inode = (attrs[.systemFileNumber] as? UInt64) ?? 0
        }
    }

    /// The candidate is written alongside the original. A single atomic rename
    /// replaces it only after validation; a failed rename leaves the original.
    static func replace(_ original: URL, with candidate: URL, expected: Snapshot, preservingPermissions: Bool = true) throws {
        guard try Snapshot(candidate).size > 0 else { throw Failure.emptyOutput }
        guard try Snapshot(original) == expected else { throw Failure.sourceChanged }
        let attrs = try FileManager.default.attributesOfItem(atPath: original.path)
        if preservingPermissions, let permissions = attrs[.posixPermissions] {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: candidate.path)
        }
        let code = candidate.path.withCString { src in original.path.withCString { dst in Darwin.rename(src, dst) } }
        if code != 0 { throw Failure.replacement(errno) }
    }
}
