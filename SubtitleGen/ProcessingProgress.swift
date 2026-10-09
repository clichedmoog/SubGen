import Foundation

/// Tracks completed work by identity, independent of queue order and concurrent translations.
struct ProcessingProgress {
    struct FileWork {
        let embed: Bool
        var targets: Set<String>
        var started = false
        var sourceFraction: Double = 0
        var sourceOutputDone = false
        var languageFractions: [String: Double] = [:]
        var translatedCues: [String: Int] = [:]
        var totalCues = 0
        var terminal: FileStatus?
        var detail = "준비 중..."
        var phaseFraction: Double?
        var startedAt = Date()

        var fraction: Double {
            if case .completed = terminal { return 1 }
            let sourceWeight = targets.isEmpty ? (embed ? 0.85 : 0.95) : 0.6
            let outputWeight = embed ? 0.1 : 0
            let translationWeight = targets.isEmpty ? 0 : 0.95 - sourceWeight - outputWeight
            let translated = targets.isEmpty ? 0 : targets.reduce(0.0) { $0 + (languageFractions[$1] ?? 0) } / Double(targets.count)
            return min(0.95, sourceWeight * sourceFraction + (sourceOutputDone ? outputWeight : 0) + translationWeight * translated)
        }
        var translationDetail: String {
            targets.sorted().map { language in
                let label = TranslationLanguage(rawValue: language)?.label ?? language
                return "\(label) \(translatedCues[language] ?? 0)/\(totalCues)개"
            }.joined(separator: " · ")
        }
        mutating func source(_ fraction: Double, detail: String) {
            guard Self.clamp(fraction) >= sourceFraction else { return }
            sourceFraction = max(sourceFraction, Self.clamp(fraction)); phaseFraction = sourceFraction; self.detail = detail
        }
        mutating func sourceReady(language: String) { sourceFraction = 1; targets.remove(language) }
        mutating func translation(language: String, completed: Int, total: Int) {
            guard targets.contains(language), total > 0 else { return }
            totalCues = total; translatedCues[language] = max(translatedCues[language] ?? 0, min(total, max(0, completed)))
            let fraction = Double(translatedCues[language]!) / Double(total)
            // Retain room for SRT persistence, embedding and final validation.
            languageFractions[language] = max(languageFractions[language] ?? 0, fraction * 0.9)
            phaseFraction = targets.reduce(0.0) { $0 + Double(translatedCues[$1] ?? 0) / Double(total) } / Double(targets.count)
            detail = "번역 · " + translationDetail
        }
        mutating func languageSaved(_ language: String) {
            guard targets.contains(language) else { return }
            languageFractions[language] = 1
            if totalCues > 0 { translatedCues[language] = totalCues; detail = "번역 · " + translationDetail }
        }
        private static func clamp(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
    }
    private(set) var files: [UUID: FileWork] = [:]
    var overall: Double {
        guard !files.isEmpty else { return 0 }
        return files.values.reduce(0) { $0 + ($1.terminal == nil ? $1.fraction : 1) } / Double(files.count)
    }
    var finishedCount: Int { files.values.filter { $0.terminal != nil }.count }
    mutating func sync(_ queue: [FileItem], embed: Bool, targets: Set<TranslationLanguage>, sourceLanguage: String) {
        let present = Set(queue.map(\.id))
        files = files.filter { present.contains($0.key) || $0.value.started }
        for file in queue {
            if files[file.id] == nil, file.status == .pending {
                var languages = Set(targets.map(\.rawValue)); languages.remove(sourceLanguage)
                files[file.id] = FileWork(embed: embed, targets: languages)
            }
            if file.status == .skipped, files[file.id] != nil, files[file.id]?.started == false {
                files[file.id]?.terminal = .skipped
            }
        }
    }
    mutating func start(_ id: UUID) { files[id]?.started = true; files[id]?.startedAt = Date() }
    mutating func update(_ id: UUID, _ change: (inout FileWork) -> Void) {
        guard var work = files[id], work.terminal == nil else { return }
        change(&work); files[id] = work
    }
    mutating func finish(_ id: UUID, status: FileStatus) { files[id]?.terminal = status }
}
