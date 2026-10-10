import SwiftUI

struct FileItem: Identifiable, Equatable {
    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.id == rhs.id && lhs.url == rhs.url && lhs.status == rhs.status && lhs.elapsedTime == rhs.elapsedTime && lhs.translatedLangs == rhs.translatedLangs && lhs.progress == rhs.progress && lhs.progressDetail == rhs.progressDetail && lhs.phaseProgress == rhs.phaseProgress && lhs.sourceLanguage == rhs.sourceLanguage
    }

    let id = UUID()
    let url: URL
    var status: FileStatus = .pending
    var elapsedTime: TimeInterval?
    var translatedLangs: [String] = []
    var progress: Double = 0  // 0.0 ~ 1.0
    var phaseProgress: Double?
    var progressDetail = ""
    var sourceLanguage: String?

    mutating func resetForProcessing() {
        guard !isActive else { return }
        status = .pending; elapsedTime = nil; translatedLangs = []; progress = 0
        phaseProgress = nil; progressDetail = ""
        // Retain the known source language when automatic mode reuses existing subtitles.
    }

    static func requeueAfterOptionsChange(_ files: inout [FileItem]) {
        for index in files.indices where !files[index].isActive { files[index].resetForProcessing() }
    }

    static func requeueFailedOrCancelled(_ files: inout [FileItem]) {
        for index in files.indices {
            switch files[index].status {
            case .failed, .cancelled: files[index].resetForProcessing()
            default: break
            }
        }
    }

    var isActive: Bool {
        switch status {
        case .processing, .translating: return true
        default: return false
        }
    }

    var name: String { url.lastPathComponent }
    var size: String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func save(_ files: [FileItem]) {
        saveSourceLanguages(files)
        if AppDistribution.isStore { SandboxFileAccess.shared.save(files.map(\.url)); return }
        let paths = files.map { $0.url.path }
        UserDefaults.standard.set(paths, forKey: "savedFiles")
    }

    static func loadSaved() -> [FileItem] {
        let urls: [URL]
        if AppDistribution.isStore { urls = SandboxFileAccess.shared.restore() }
        else {
            urls = (UserDefaults.standard.stringArray(forKey: "savedFiles") ?? []).map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        return urls.map { url in
            var file = FileItem(url: url); file.sourceLanguage = savedSourceLanguage(for: url); return file
        }
    }

    static func saveSourceLanguages(_ files: [FileItem], defaults: UserDefaults = .standard) {
        var known: [String: String] = [:]
        for file in files {
            if let language = file.sourceLanguage { known[file.url.path] = language }
        }
        defaults.set(known, forKey: "savedFileSourceLanguages")
    }
    static func savedSourceLanguage(for url: URL, defaults: UserDefaults = .standard) -> String? {
        guard let language = (defaults.dictionary(forKey: "savedFileSourceLanguages") as? [String: String])?[url.path],
              language.range(of: #"^[a-z]{2,3}$"#, options: .regularExpression) != nil else { return nil }
        return language
    }
}

enum FileStatus: Equatable {
    case pending, processing, translating(lang: String), skipped, cancelled
    case completed(lang: String), failed(error: String)

    var icon: String {
        switch self {
        case .pending: return "circle"
        case .processing: return "progress.indicator"
        case .translating: return "text.bubble"
        case .skipped: return "forward.circle.fill"
        case .cancelled: return "stop.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .pending: return .secondary
        case .processing: return .blue
        case .translating: return .purple
        case .skipped: return .orange
        case .cancelled: return .orange
        case .completed: return .green
        case .failed: return .red
        }
    }
}

enum WhisperModel: String, CaseIterable, Identifiable {
    case largev3 = "ggml-large-v3.bin"
    case largev3turbo = "ggml-large-v3-turbo.bin"
    case medium = "ggml-medium.bin"
    case small = "ggml-small.bin"
    case base = "ggml-base.bin"
    case tiny = "ggml-tiny.bin"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .largev3: return "Large v3 (최고 품질)"
        case .largev3turbo: return "Large v3 Turbo (추천)"
        case .medium: return "Medium (좋은 품질)"
        case .small: return "Small (균형)"
        case .base: return "Base (빠름)"
        case .tiny: return "Tiny (가장 빠름, 낮은 품질)"
        }
    }

    /// Full path to the GGML model file
    var modelPath: String {
        AppDistribution.modelDirectory.appendingPathComponent(rawValue).path
    }

    var isCached: Bool {
        WhisperModelInstaller.isAvailable(at: URL(fileURLWithPath: modelPath))
    }

    var sizeLabel: String {
        switch self {
        case .largev3: return "~3.1GB"
        case .largev3turbo: return "~1.6GB"
        case .medium: return "~1.5GB"
        case .small: return "~490MB"
        case .base: return "~150MB"
        case .tiny: return "~78MB"
        }
    }

    var downloadURL: String {
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(rawValue)"
    }
}

enum OutputMode: String, CaseIterable, Identifiable {
    case embedInVideo
    case srtOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .embedInVideo: return "영상에 자막 포함"
        case .srtOnly: return "srt 파일 생성"
        }
    }
}

enum Language: String, CaseIterable, Identifiable {
    case auto = ""
    case ko, ja, en, zh, fr, de, es, it, pt, ru
    case ar, hi, th, vi, id, ms, tl, tr, pl, nl
    case sv, da, no, fi, el, he, uk, cs, ro, hu

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "자동 감지"
        case .ja: return "일본어"
        case .ko: return "한국어"
        case .en: return "영어"
        case .zh: return "중국어"
        case .fr: return "프랑스어"
        case .de: return "독일어"
        case .es: return "스페인어"
        case .it: return "이탈리아어"
        case .pt: return "포르투갈어"
        case .ru: return "러시아어"
        case .ar: return "아랍어"
        case .hi: return "힌디어"
        case .th: return "태국어"
        case .vi: return "베트남어"
        case .id: return "인도네시아어"
        case .ms: return "말레이어"
        case .tl: return "타갈로그어"
        case .tr: return "터키어"
        case .pl: return "폴란드어"
        case .nl: return "네덜란드어"
        case .sv: return "스웨덴어"
        case .da: return "덴마크어"
        case .no: return "노르웨이어"
        case .fi: return "핀란드어"
        case .el: return "그리스어"
        case .he: return "히브리어"
        case .uk: return "우크라이나어"
        case .cs: return "체코어"
        case .ro: return "루마니아어"
        case .hu: return "헝가리어"
        }
    }
}

enum Sensitivity: String, CaseIterable, Identifiable {
    case sensitive
    case normal
    case accurate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sensitive: return "민감"
        case .normal: return "보통"
        case .accurate: return "정확"
        }
    }

    var noSpeechThreshold: Double {
        switch self {
        case .sensitive: return 0.2
        case .normal: return 0.3
        case .accurate: return 0.4
        }
    }

    var logprobThreshold: Double {
        switch self {
        case .sensitive: return -1.4
        case .normal: return -1.2
        case .accurate: return -1.0
        }
    }

    var entropyThreshold: Double {
        switch self {
        case .sensitive: return 3.2
        case .normal: return 3.0
        case .accurate: return 2.8
        }
    }

    var vadThreshold: Double {
        switch self {
        case .sensitive: return 0.02
        case .normal: return 0.2
        case .accurate: return 0.3
        }
    }

    var beamSize: Int { 3 }
    var bestOf: Int { 3 }
}

enum AuthMethod: String, CaseIterable, Identifiable {
    case claudeCode
    case codex

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claudeCode: return "Claude Code (구독)"
        case .codex: return "Codex CLI (구독)"
        }
    }
}

enum TranslationModel: String, CaseIterable, Identifiable {
    // CLI aliases follow provider releases instead of pinning dated versions.
    case claudeOpus = "opus"
    case claudeSonnet = "sonnet"
    case claudeHaiku = "haiku"
    case codexDefault = "codex-default"
    case codexSol = "gpt-6.1-sol"
    case codexLuna = "gpt-6-luna"
    case codexAstra = "gpt-6-astra"
    case codexConfigured = "codex-configured"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claudeOpus: return "Claude Opus (최신 · 품질 우선)"
        case .claudeSonnet: return "Claude Sonnet (최신 · 균형)"
        case .claudeHaiku: return "Claude Haiku (최신 · 속도 우선)"
        case .codexDefault: return "자동 (Codex 권장 모델)"
        case .codexSol: return "GPT-6.1 Sol (균형)"
        case .codexLuna: return "GPT-6 Luna (속도 우선)"
        case .codexAstra: return "GPT-6 Astra (품질 우선)"
        case .codexConfigured: return "Codex 사용자 설정 따르기"
        }
    }

    var isClaude: Bool {
        switch self {
        case .claudeOpus, .claudeSonnet, .claudeHaiku: return true
        default: return false
        }
    }

    var isCodex: Bool { !isClaude }

    static func defaultModel(for auth: AuthMethod) -> TranslationModel {
        auth == .claudeCode ? .claudeOpus : .codexDefault
    }

    /// Upgrade saved preferences while preserving the selected provider/family.
    static func resolve(_ value: String?, for auth: AuthMethod) -> TranslationModel {
        let legacy: [String: TranslationModel] = [
            "claude-opus-4-6[1m]": .claudeOpus,
            "claude-opus-4-20250514": .claudeOpus,
            "claude-sonnet-4-20250514": .claudeSonnet,
            "claude-haiku-4-5-20251001": .claudeHaiku
        ]
        if let value, let model = TranslationModel(rawValue: value) ?? legacy[value],
           models(for: auth).contains(model) { return model }
        return defaultModel(for: auth)
    }

    static func migratePreferences(in defaults: UserDefaults = .standard) {
        let auth = defaults.string(forKey: "authMethod").flatMap(AuthMethod.init(rawValue:)) ?? .claudeCode
        defaults.set(resolve(defaults.string(forKey: "translationModel"), for: auth).rawValue, forKey: "translationModel")
    }

    static func models(for auth: AuthMethod) -> [TranslationModel] {
        switch auth {
        case .claudeCode:
            return [.claudeOpus, .claudeSonnet, .claudeHaiku]
        case .codex:
            return [.codexDefault, .codexSol, .codexLuna, .codexAstra, .codexConfigured]
        }
    }
}

enum TranslationLanguage: String, CaseIterable, Identifiable {
    case ko, ja, en, zh, fr, de, es, pt, ru

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ko: return "한국어"
        case .ja: return "일본어"
        case .en: return "영어"
        case .zh: return "중국어"
        case .fr: return "프랑스어"
        case .de: return "독일어"
        case .es: return "스페인어"
        case .pt: return "포르투갈어"
        case .ru: return "러시아어"
        }
    }

    var langName: String {
        switch self {
        case .ko: return "Korean"
        case .ja: return "Japanese"
        case .en: return "English"
        case .zh: return "Chinese"
        case .fr: return "French"
        case .de: return "German"
        case .es: return "Spanish"
        case .pt: return "Portuguese"
        case .ru: return "Russian"
        }
    }
}

enum SubtitleDelay: String, CaseIterable, Identifiable {
    case earlyFull, earlyHalf, earlyQuarter, none, lateQuarter, lateHalf, lateFull

    var id: String { rawValue }

    var label: String {
        switch self {
        case .earlyFull: return "1.0초 빠르게"
        case .earlyHalf: return "0.5초 빠르게"
        case .earlyQuarter: return "0.25초 빠르게"
        case .none: return "조절 없음"
        case .lateQuarter: return "0.25초 늦게"
        case .lateHalf: return "0.5초 늦게"
        case .lateFull: return "1.0초 늦게"
        }
    }

    var seconds: Double {
        switch self {
        case .earlyFull: return -1.0
        case .earlyHalf: return -0.5
        case .earlyQuarter: return -0.25
        case .none: return 0.0
        case .lateQuarter: return 0.25
        case .lateHalf: return 0.5
        case .lateFull: return 1.0
        }
    }
}
