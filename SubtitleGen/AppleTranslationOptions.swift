#if MAC_APP_STORE
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
                Text("Apple 번역은 macOS 26 이상에서 사용할 수 있습니다.").font(.caption).foregroundStyle(.red)
            } else {
                Text("계정 없이 이 Mac에서 번역합니다. 자막이 외부로 전송되지 않습니다.").font(.caption).foregroundStyle(.secondary)
                if source.isEmpty {
                    Text("자동 감지된 언어의 언어 팩이 없으면 번역 직전에 다운로드를 묻고, 받은 뒤 번역합니다.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else if !targets.isEmpty {
                    ForEach(targets.sorted { $0.rawValue < $1.rawValue }) { target in
                        if let status = coordinator.statuses[target] {
                            Text("\(target.label) 언어 팩: \(status.label)").font(.caption2)
                        }
                    }
                    Button("언어 팩 준비") { Task { await coordinator.prepare(source: source, targets: targets) { _ in } } }
                        .controlSize(.small).disabled(coordinator.isPreparing)
                }
                if let message = coordinator.message {
                    Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
        }
        .task(id: "\(source)|\(targets.map(\.rawValue).sorted().joined(separator: ","))") {
            await coordinator.refresh(source: source, targets: targets)
        }
    }
}
#endif
