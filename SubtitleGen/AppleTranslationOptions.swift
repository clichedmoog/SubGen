import AppKit
import SwiftUI
import Translation

/// Attaches the language-pack download prompt to the window's root view.
struct AppleTranslationPreparationModifier: ViewModifier {
    @ObservedObject var coordinator: AppleTranslationCoordinator

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) { content.modifier(AppleTranslationPreparationTask(coordinator: coordinator)) }
        else { content }
    }
}

@available(macOS 26.0, *)
private struct AppleTranslationPreparationTask: ViewModifier {
    @ObservedObject var coordinator: AppleTranslationCoordinator
    @State private var configuration: TranslationSession.Configuration?
    @State private var activePair: AppleTranslationCoordinator.Pair?

    func body(content: Content) -> some View {
        content
            .translationTask(configuration) { session in
                var prepared = true
                do { try await session.prepareTranslation() }
                catch { prepared = false; logDebug("Apple translation preparation: \(error.localizedDescription)") }
                await MainActor.run {
                    configuration = nil
                    if let pair = activePair { activePair = nil; coordinator.finishPair(pair, prepared: prepared) }
                    showNextPrompt(coordinator.pendingPairs)
                }
            }
            .onChange(of: coordinator.pendingPairs) { _, pairs in showNextPrompt(pairs) }
    }

    /// Shows one system download prompt at a time and bounces the Dock if the app is in the background.
    private func showNextPrompt(_ pairs: [AppleTranslationCoordinator.Pair]) {
        guard configuration == nil, activePair == nil, let pair = pairs.first,
              let source = AppleTranslationMapping.languageIdentifier(for: pair.source),
              let target = AppleTranslationMapping.languageIdentifier(for: pair.target.rawValue) else { return }
        activePair = pair
        configuration = .init(source: Locale.Language(identifier: source), target: Locale.Language(identifier: target))
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }
}

struct AppleTranslationOptionsView: View {
    @ObservedObject var coordinator: AppleTranslationCoordinator
    let source: String
    let targets: Set<TranslationLanguage>

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !coordinator.isSupported {
                Text(String(localized: "Apple 번역은 macOS 26 이상에서 사용할 수 있습니다.")).font(.caption).foregroundStyle(.red)
            } else {
                Text(String(localized: "계정 없이 이 Mac에서 번역합니다. 자막이 외부로 전송되지 않습니다.")).font(.caption).foregroundStyle(.secondary)
                if source.isEmpty {
                    Text(String(localized: "자동 감지된 언어의 언어 팩이 없으면 번역 직전에 다운로드를 묻고, 받은 뒤 번역합니다."))
                        .font(.caption2).foregroundStyle(.secondary)
                } else if !targets.isEmpty {
                    ForEach(targets.sorted { $0.rawValue < $1.rawValue }) { target in
                        if let status = coordinator.statuses[target] {
                            Text(String(localized: "\(target.label) 언어 팩: \(status.label)")).font(.caption2)
                        }
                    }
                    Button(String(localized: "언어 팩 준비")) { Task { await coordinator.prepare(source: source, targets: targets) { _ in } } }
                        .controlSize(.small).disabled(coordinator.isPreparing)
                }
                if let message = coordinator.message {
                    Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                Link(String(localized: "언어 팩 확인·삭제 (시스템 설정)"), destination: AppleTranslationCoordinator.languageSettingsURL)
                    .font(.caption2)
                    .help(String(localized: "언어 및 지역 › 번역 언어에서 받은 언어를 확인하거나 삭제합니다. 다른 앱과 함께 쓰는 macOS 언어 팩입니다."))
            }
        }
        .task(id: "\(source)|\(targets.map(\.rawValue).sorted().joined(separator: ","))") {
            await coordinator.refresh(source: source, targets: targets)
        }
        // Packs may have been added or removed in System Settings while the app was in the background.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await coordinator.refresh(source: source, targets: targets) }
        }
    }
}
