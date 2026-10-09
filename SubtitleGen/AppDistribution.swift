import Foundation

enum AppDistribution {
    #if MAC_APP_STORE
    static let isStore = true
    #else
    static let isStore = false
    #endif

    static var modelDirectory: URL {
        if isStore {
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SubtitleGen/Models", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/whisper-cpp", isDirectory: true)
    }

    static var logURL: URL {
        if isStore {
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SubtitleGen/Logs/SubtitleGen.log")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SubtitleGen.log")
    }
}
