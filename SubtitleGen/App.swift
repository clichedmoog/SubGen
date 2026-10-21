import SwiftUI
import AppKit
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        let allowed = ["mp4", "mov", "mkv", "m4v", "m4a", "wav", "mp3", "avi", "webm", "flv"]
        let validURLs = urls.filter { allowed.contains($0.pathExtension.lowercased()) }
        guard !validURLs.isEmpty else { return }

        NotificationCenter.default.post(
            name: .addFilesToQueue,
            object: nil,
            userInfo: ["urls": validURLs]
        )
    }
}

extension Notification.Name {
    static let addFilesToQueue = Notification.Name("addFilesToQueue")
    static let startProcessing = Notification.Name("startProcessing")
    static let stopProcessing = Notification.Name("stopProcessing")
}

@main
struct SubtitleGeneratorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        TranslationModel.migratePreferences()
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    var body: some Scene {
        // A single Window scene appears in the Window menu, so a closed main window can be reopened.
        Window("SubGen", id: "main") {
            ContentView()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 940, height: 820)
        .windowResizability(.contentMinSize)
        .handlesExternalEvents(matching: ["*"])
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button(String(localized: "자막 생성 시작")) {
                    NotificationCenter.default.post(name: .startProcessing, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button(String(localized: "중단")) {
                    NotificationCenter.default.post(name: .stopProcessing, object: nil)
                }
                .keyboardShortcut(".", modifiers: .command)
            }
        }
    }
}
