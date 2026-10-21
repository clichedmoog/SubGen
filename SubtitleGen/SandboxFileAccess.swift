import AppKit

/// Keeps security scopes alive while queued files and their sibling output are in use.
final class SandboxFileAccess {
    static let shared = SandboxFileAccess()
    private let defaults: UserDefaults
    private var fileScopes: [String: Scope] = [:]
    private var directoryScopes: [String: Scope] = [:]
    private var fileBookmarks: [String: Data] = [:]
    private let lock = NSRecursiveLock()

    private final class Scope {
        let url: URL
        let started: Bool
        init(_ url: URL) { self.url = url; started = url.startAccessingSecurityScopedResource() }
        deinit { if started { url.stopAccessingSecurityScopedResource() } }
    }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func contains(_ directory: URL, file: URL) -> Bool {
        let parent = directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let child = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return child.count > parent.count && Array(child.prefix(parent.count)) == parent
    }

    func save(_ urls: [URL]) {
        lock.lock(); defer { lock.unlock() }
        let paths = Set(urls.map(\.path))
        fileScopes = fileScopes.filter { paths.contains($0.key) }
        fileBookmarks = fileBookmarks.filter { paths.contains($0.key) }
        for url in urls where fileBookmarks[url.path] == nil {
            if let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                fileBookmarks[url.path] = bookmark
                fileScopes[url.path] = Self.scope(for: bookmark) ?? Scope(url)
            }
        }
        // Bookmarks follow queue order, rather than dictionary iteration order.
        defaults.set(urls.compactMap { fileBookmarks[$0.path] }, forKey: "savedFileBookmarks")
    }

    func restore() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        let bookmarks = defaults.array(forKey: "savedFileBookmarks") as? [Data] ?? []
        let urls = bookmarks.compactMap { data -> URL? in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                     relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
            let scope = Scope(url)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            fileScopes[url.path] = scope
            fileBookmarks[url.path] = stale ? (try? url.bookmarkData(options: .withSecurityScope,
                includingResourceValuesForKeys: nil, relativeTo: nil)) ?? data : data
            return url
        }
        defaults.set(urls.compactMap { fileBookmarks[$0.path] }, forKey: "savedFileBookmarks")
        return urls
    }

    private static func scope(for bookmark: Data) -> Scope? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        return Scope(url)
    }

    /// Must be called on the main thread, before processing any queued input.
    func authorizeOutputDirectories(for inputs: [URL]) -> Bool {
        precondition(Thread.isMainThread)
        lock.lock(); defer { lock.unlock() }
        var stored = defaults.dictionary(forKey: "outputDirectoryBookmarks") as? [String: Data] ?? [:]
        for data in stored.values {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale) {
                if directoryScopes[url.path] == nil { directoryScopes[url.path] = Scope(url) }
                if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope,
                        includingResourceValuesForKeys: nil, relativeTo: nil) { stored[url.path] = fresh }
            }
        }
        for input in inputs {
            if directoryScopes.values.contains(where: { Self.contains($0.url, file: input) && $0.started }) { continue }
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = input.deletingLastPathComponent()
            panel.message = String(localized: "\(input.lastPathComponent)의 자막 저장·영상 교체를 위해 해당 파일이 있는 폴더의 접근을 허용해주세요.")
            panel.prompt = String(localized: "폴더 접근 허용")
            guard panel.runModal() == .OK, let directory = panel.url,
                  Self.contains(directory, file: input) else { return false }
            guard let bookmark = try? directory.bookmarkData(options: .withSecurityScope,
                       includingResourceValuesForKeys: nil, relativeTo: nil) else { return false }
            let scope = Self.scope(for: bookmark) ?? Scope(directory)
            directoryScopes[directory.path] = scope
            stored[directory.path] = bookmark
            defaults.set(stored, forKey: "outputDirectoryBookmarks")
        }
        defaults.set(stored, forKey: "outputDirectoryBookmarks")
        return true
    }
}
