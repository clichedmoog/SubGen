import Foundation
import AppKit
import UserNotifications

private let logLock = NSLock()
let appLog = AppDistribution.logURL
func logDebug(_ message: String) {
    logLock.lock(); defer { logLock.unlock() }
    let fm = FileManager.default
    try? fm.createDirectory(at: appLog.deletingLastPathComponent(), withIntermediateDirectories: true)
    if (try? fm.attributesOfItem(atPath: appLog.path)[.size] as? Int64) ?? 0 > 5_000_000 {
        let previous = appLog.appendingPathExtension("previous")
        try? fm.removeItem(at: previous)
        try? fm.moveItem(at: appLog, to: previous)
    }
    let data = Data("[\(Date())] \(message)\n".utf8)
    if let handle = try? FileHandle(forWritingTo: appLog) {
        defer { try? handle.close() }
        do { try handle.seekToEnd(); try handle.write(contentsOf: data) } catch {}
    } else { try? data.write(to: appLog) }
}

class TranscriptionEngine: ObservableObject {
    @Published var isProcessing = false
    @Published var currentIndex = 0
    @Published var currentStatus = ""
    @Published var fileProgress: Double = 0
    @Published var overallProgress: Double = 0 {
        didSet { updateDockProgress() }
    }
    var onFileProgressUpdate: ((UUID, Double) -> Void)?
    @Published var eta = ""
    private let stateLock = NSLock()
    private var cancelled = false
    private var tokens: [UUID: CancellationToken] = [:]
    private var activeFileID: UUID?
    private var sourceFileID: UUID?
    private var workProgress = ProcessingProgress()
    private var runID = UUID()
    private let binaryResolver: (String) -> String?
    private let prepareModel: (URL, CancellationToken, @escaping WhisperModelInstaller.Progress) throws -> Void
    private var onFileDetailUpdate: ((UUID, String, Double?) -> Void)?
    /// Store Apple Translation: blocks a translation worker until the pack for (source, target) is installed or refused.
    var appleLanguagePack: ((String, TranslationLanguage, CancellationToken) -> AppleLanguagePackResult)?

    init(binaryResolver: @escaping (String) -> String? = { ToolResolver.find($0) },
         prepareModel: @escaping (URL, CancellationToken, @escaping WhisperModelInstaller.Progress) throws -> Void = {
             try WhisperModelInstaller.ensureAvailable(at: $0, cancellation: $1, onProgress: $2)
             try WhisperModelInstaller.ensureVadAvailable(nextTo: $0, cancellation: $1)
         }) {
        self.binaryResolver = binaryResolver
        self.prepareModel = prepareModel
    }
    private var shouldCancel: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return cancelled
    }
    private var fileStartTime: Date = Date()
    private var totalStartTime: Date = Date()
    private var totalFileCount: Int { workProgress.files.count }
    private var dockProgressView: DockProgressView?

    /// Apple Translation needs installed language packs. An auto-detected source language is only known here,
    /// so missing packs are requested and awaited before translating instead of failing.
    func readyAppleTargets(_ targets: [TranslationLanguage], source: String, token: CancellationToken,
                           onStatus: (String) -> Void) -> (ready: [TranslationLanguage], failures: [String]) {
        guard let ensure = appleLanguagePack else { return (targets, []) }
        var ready: [TranslationLanguage] = [], failures: [String] = []
        for target in targets {
            guard target.rawValue != source else { ready.append(target); continue }
            onStatus(String(localized: "Apple 번역 \(target.label) 언어 팩 준비 중 · 다운로드 확인 창이 뜨면 허용해주세요"))
            switch ensure(source, target, token) {
            case .ready: ready.append(target)
            case .failed(let message): failures.append(String(localized: "\(target.label) 번역 실패: \(message)"))
            }
        }
        return (ready, failures)
    }

    /// External CLIs are disabled in the sandboxed app; there ChatGPT or Apple Translation translate instead.
    func makeTranslator(options: Options, sourceLanguage: String, token: CancellationToken) throws -> TranslationEngine {
        switch options.translationProvider {
        case .agentCLI:
            return TranslationEngine(authMethod: options.authMethod, translationModel: options.translationModel, cancellation: token)
        case .apple:
            guard #available(macOS 26.0, *) else { throw PipelineFailure(String(localized: "Apple 번역은 macOS 26 이상에서 사용할 수 있습니다.")) }
            return TranslationEngine(authMethod: options.authMethod, cancellation: token, request: { srt, language in
                guard let translator = AppleSubtitleTranslator(source: sourceLanguage, target: language) else {
                    return ProcessResult(failure: .service(String(localized: "Apple 번역이 이 언어 조합을 지원하지 않습니다. ChatGPT 번역을 사용해주세요."), retryable: false))
                }
                return translator.request(srt, cancellation: token)
            })
        case .chatGPT:
            guard let account = options.chatGPTAccountID, let model = options.chatGPTModel else {
                throw PipelineFailure(String(localized: "번역할 ChatGPT 계정과 모델을 선택해주세요."))
            }
            let client = ChatGPTSubtitleClient(accountID: account, model: model)
            return TranslationEngine(authMethod: options.authMethod, cancellation: token,
                request: { client.request($0, language: $1, cancellation: token) })
        }
    }

    struct Options {
        var model: String
        var embedSubtitle: Bool
        var keepSrtFile: Bool
        var subtitleDelay: Double
        var sensitivity: Sensitivity
        var language: String
        var translationTargets: Set<TranslationLanguage>
        var authMethod: AuthMethod
        var translationModel: String
        var chatGPTAccountID: String? = nil
        var chatGPTModel: String? = nil
        var translationProvider: TranslationProvider = AppDistribution.isStore ? .chatGPT : .agentCLI
    }

    private func updateDockProgress() {
        DispatchQueue.main.async {
            guard let app = NSApp else { return }
            let dockTile = app.dockTile
            if self.isProcessing {
                if self.dockProgressView == nil {
                    let view = DockProgressView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
                    self.dockProgressView = view
                    dockTile.contentView = view
                }
                self.dockProgressView?.progress = self.overallProgress
                dockTile.display()
            } else {
                self.dockProgressView = nil
                dockTile.contentView = nil
                dockTile.badgeLabel = nil
                dockTile.display()
            }
        }
    }

    private func publishProgress(_ id: UUID? = nil) {
        if let id, let work = workProgress.files[id] {
            onFileProgressUpdate?(id, work.fraction)
            onFileDetailUpdate?(id, work.detail, work.phaseFraction)
        }
        overallProgress = workProgress.overall
        currentIndex = workProgress.finishedCount
        let displayed = sourceFileID.flatMap { workProgress.files[$0] }
            ?? workProgress.files.values.first { $0.started && $0.terminal == nil }
        fileProgress = displayed?.fraction ?? 0
        if isProcessing, sourceFileID == nil {
            let active = workProgress.files.values.filter { $0.started && $0.terminal == nil }
            if active.count == 1 { currentStatus = active[0].detail }
            else if !active.isEmpty { currentStatus = String(localized: "\(active.count)개 파일 번역·자막 저장 중...") }
        }
        eta = sourceFileID == nil ? "" : calculateOverallEta()
    }

    func resetProgress() {
        guard !isProcessing else { return }
        workProgress = ProcessingProgress(); sourceFileID = nil
        fileProgress = 0; overallProgress = 0; currentIndex = 0; currentStatus = ""; eta = ""
    }

    private func bounceIcon() {
        DispatchQueue.main.async {
            guard let app = NSApp else { return }
            app.requestUserAttention(.criticalRequest)
            NSSound(named: .init("Glass"))?.play()
        }
    }

    private func sendCompletionNotification(getFiles: @escaping () -> [FileItem]) {
        guard NSApp != nil else { return }
        let files = getFiles().filter { workProgress.files[$0.id] != nil }
        let completed = files.filter { if case .completed = $0.status { return true }; return false }.count
        let failed = files.filter { if case .failed = $0.status { return true }; return false }.count
        let skipped = files.filter { $0.status == .skipped }.count

        let content = UNMutableNotificationContent()
        content.title = String(localized: "자막 생성 완료")
        var body = String(localized: "\(completed)개 완료")
        if skipped > 0 { body += String(localized: ", \(skipped)개 건너뜀") }
        if failed > 0 { body += String(localized: ", \(failed)개 실패") }
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func findBinary(_ name: String) -> String? { binaryResolver(name) }

    func cancel() {
        stateLock.lock()
        cancelled = true
        let running = Array(tokens.values)
        stateLock.unlock()
        running.forEach { $0.cancel() }
    }

    func skipCurrent(fileID: UUID? = nil) {
        stateLock.lock()
        let token = (fileID ?? activeFileID).flatMap { tokens[$0] }
        stateLock.unlock()
        token?.cancel()
    }

    func process(
        getFiles: @escaping () -> [FileItem],
        options: Options,
        onFileUpdate: @escaping (UUID, FileStatus, TimeInterval?) -> Void,
        onFileProgress: @escaping (UUID, Double) -> Void,
        onTranslationComplete: @escaping (UUID, String) -> Void,
        onFileDetail: @escaping (UUID, String, Double?) -> Void = { _, _, _ in },
        onSourcePrepared: @escaping (UUID, String) -> Void = { _, _ in }
    ) {
        guard !isProcessing else { return }
        guard getFiles().contains(where: { $0.status == .pending }) else {
            currentStatus = String(localized: "대기 중인 파일이 없습니다. 옵션을 바꾸거나 상태를 초기화해주세요.")
            return
        }
        guard let whisper = findBinary("whisper-cli"), let ffmpeg = findBinary("ffmpeg"), let ffprobe = findBinary("ffprobe") else {
            currentStatus = String(localized: "현재 CPU에서 실행 가능한 whisper-cli, ffmpeg, ffprobe를 설치해주세요.")
            return
        }
        resetProgress()
        let run = UUID(); runID = run
        workProgress.sync(getFiles(), embed: options.embedSubtitle, targets: options.translationTargets, sourceLanguage: options.language)
        stateLock.lock(); cancelled = false; tokens.removeAll(); stateLock.unlock()
        isProcessing = true; totalStartTime = Date()
        onFileProgressUpdate = onFileProgress; onFileDetailUpdate = onFileDetail
        publishProgress()
        logDebug("Starting: \(ToolResolver.architecture), ffmpeg=\(ffmpeg), ffprobe=\(ffprobe), whisper=\(whisper)")

        DispatchQueue.global(qos: .userInitiated).async {
            let translations = DispatchGroup(), translationSlots = DispatchSemaphore(value: 2)
            let finish: (UUID, FileStatus, Date) -> Void = { id, status, start in
                DispatchQueue.main.async {
                    guard self.runID == run else { return }
                    self.workProgress.finish(id, status: status); self.publishProgress(id)
                    onFileUpdate(id, status, Date().timeIntervalSince(start))
                }
            }
            while !self.shouldCancel {
                var next: FileItem?
                DispatchQueue.main.sync {
                    let files = getFiles()
                    self.workProgress.sync(files, embed: options.embedSubtitle, targets: options.translationTargets, sourceLanguage: options.language)
                    next = files.first { $0.status == .pending }
                    if let file = next {
                        self.sourceFileID = file.id; self.workProgress.start(file.id)
                        self.fileStartTime = Date(); self.currentStatus = String(localized: "자막 준비 중...")
                        onFileUpdate(file.id, .processing, nil); self.publishProgress(file.id)
                    } else { self.sourceFileID = nil; self.publishProgress() }
                }
                guard let file = next else { break }
                let token = CancellationToken()
                self.stateLock.lock(); self.tokens[file.id] = token; self.activeFileID = file.id
                let wasCancelled = self.cancelled; self.stateLock.unlock()
                if wasCancelled { token.cancel() }
                let start = Date()
                do {
                    let source = try self.prepareSource(file: file, whisper: whisper, ffmpeg: ffmpeg, ffprobe: ffprobe,
                        options: options, token: token, onProgress: { fraction, detail in
                            DispatchQueue.main.async {
                                guard self.runID == run else { return }
                                self.workProgress.update(file.id) { $0.source(fraction, detail: detail) }
                                if self.sourceFileID == file.id { self.currentStatus = detail }
                                self.publishProgress(file.id)
                            }
                        }, onModelDownload: { received, total in
                            DispatchQueue.main.async {
                                guard self.runID == run else { return }
                                let detail = String(localized: "음성인식 모델 다운로드 중 · ") + WhisperModelInstaller.downloadDetail(received: received, total: total)
                                self.workProgress.update(file.id) {
                                    $0.detail = detail
                                    $0.phaseFraction = total.flatMap { $0 > 0 ? min(1, max(0, Double(received) / Double($0))) : nil }
                                }
                                self.eta = ""
                                if self.sourceFileID == file.id { self.currentStatus = detail }
                                self.publishProgress(file.id)
                            }
                        })
                    DispatchQueue.main.async {
                        self.workProgress.update(file.id) { $0.sourceReady(language: source.language) }
                        onSourcePrepared(file.id, source.language); self.publishProgress(file.id)
                    }
                    var sourceEmbedded = false
                    if options.embedSubtitle {
                        DispatchQueue.main.async {
                            self.workProgress.update(file.id) { $0.detail = String(localized: "원본 자막 내장·검증 중..."); $0.phaseFraction = nil }
                            self.currentStatus = String(localized: "원본 자막 내장·검증 중..."); self.publishProgress(file.id)
                        }
                        sourceEmbedded = try self.embed(source.url, language: source.language, into: file.url, ffmpeg: ffmpeg, ffprobe: ffprobe, token: token)
                    }
                    guard !token.isCancelled else { throw PipelineFailure(String(localized: "작업이 중단되었습니다")) }
                    DispatchQueue.main.async {
                        self.workProgress.update(file.id) { $0.sourceOutputDone = true }; self.publishProgress(file.id)
                    }
                    if options.translationTargets.contains(where: { $0.rawValue != source.language }) {
                        while translationSlots.wait(timeout: .now() + 0.1) == .timedOut {
                            if token.isCancelled { throw PipelineFailure(String(localized: "작업이 중단되었습니다")) }
                        }
                        if token.isCancelled { translationSlots.signal(); throw PipelineFailure(String(localized: "작업이 중단되었습니다")) }
                        DispatchQueue.main.async {
                            self.workProgress.update(file.id) { $0.detail = String(localized: "번역 준비 중..."); $0.phaseFraction = 0 }
                            onFileUpdate(file.id, .translating(lang: String(localized: "번역 준비 중...")), nil); self.publishProgress(file.id)
                        }
                        translations.enter()
                        let embedded = sourceEmbedded
                        DispatchQueue.global(qos: .utility).async {
                            defer { translationSlots.signal(); translations.leave(); self.removeToken(file.id) }
                            let status = self.translateFile(file: file, source: source, sourceEmbedded: embedded, ffmpeg: ffmpeg, ffprobe: ffprobe,
                                options: options, token: token,
                                onStatusUpdate: { message in DispatchQueue.main.async {
                                    onFileUpdate(file.id, .translating(lang: message), nil)
                                    self.workProgress.update(file.id) { $0.detail = message + ($0.totalCues > 0 ? " · " + $0.translationDetail : "") }
                                    self.publishProgress(file.id)
                                } },
                                onLangComplete: { language in DispatchQueue.main.async {
                                    self.workProgress.update(file.id) { $0.languageSaved(language) }
                                    onTranslationComplete(file.id, language); self.publishProgress(file.id)
                                } },
                                onCueProgress: { language, completed, total in DispatchQueue.main.async {
                                    self.workProgress.update(file.id) { $0.translation(language: language.rawValue, completed: completed, total: total) }
                                    self.publishProgress(file.id)
                                } },
                                onSavingStatus: { message in DispatchQueue.main.async {
                                    onFileUpdate(file.id, .translating(lang: message), nil)
                                    self.workProgress.update(file.id) {
                                        $0.detail = message + ($0.totalCues > 0 ? " · " + $0.translationDetail : "")
                                        $0.phaseFraction = nil
                                    }
                                    self.publishProgress(file.id)
                                } })
                            let final = token.isCancelled ? (self.shouldCancel ? FileStatus.cancelled : .skipped) : status
                            finish(file.id, final, start)
                        }
                    } else {
                        if source.created && sourceEmbedded && !options.keepSrtFile { try FileManager.default.removeItem(at: source.url) }
                        finish(file.id, .completed(lang: source.language), start)
                        self.removeToken(file.id)
                    }
                } catch {
                    let status: FileStatus = token.isCancelled ? (self.shouldCancel ? .cancelled : .skipped) : .failed(error: error.localizedDescription)
                    logDebug("File failed: \(file.url.path): \(error.localizedDescription)")
                    finish(file.id, status, start); self.removeToken(file.id)
                }
            }
            if translations.wait(timeout: .now()) == .timedOut {
                DispatchQueue.main.async { self.currentStatus = String(localized: "남은 번역·자막 저장 작업을 기다리는 중..."); self.eta = "" }
                translations.wait()
            }
            DispatchQueue.main.async {
                guard self.runID == run else { return }
                self.sourceFileID = nil; self.isProcessing = false; self.publishProgress(); self.eta = ""
                let failed = self.workProgress.files.values.filter { if case .failed = $0.terminal { return true }; return false }.count
                self.currentStatus = self.shouldCancel ? String(localized: "중단됨") : (failed > 0 ? String(localized: "완료 — \(failed)개 실패") : String(localized: "완료"))
                if !self.shouldCancel { self.bounceIcon(); self.sendCompletionNotification(getFiles: getFiles) }
            }
        }
    }

    private func removeToken(_ id: UUID) {
        stateLock.lock(); defer { stateLock.unlock() }
        tokens.removeValue(forKey: id)
        if activeFileID == id { activeFileID = nil }
    }

    struct PipelineFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    struct SubtitleTrack {
        let index: Int
        let codec: String
        let language: String
        var isText: Bool { ["mov_text", "subrip", "ass", "ssa", "webvtt", "text"].contains(codec) }
    }

    struct MediaInfo {
        let duration: Double
        let subtitles: [SubtitleTrack]
        let hasVideo: Bool
        let audioCount: Int
        let videoCount: Int
    }

    private func mediaInfo(_ url: URL, ffprobe: String, token: CancellationToken) throws -> MediaInfo {
        let result = ProcessRunner.run(ffprobe, arguments: ["-v", "error", "-show_entries", "format=duration:stream=index,codec_name,codec_type:stream_tags=language", "-of", "json", url.path], timeout: 30, cancellation: token)
        guard result.succeeded, let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let format = json["format"] as? [String: Any],
              let durationText = format["duration"] as? String, let duration = Double(durationText), duration.isFinite, duration > 0,
              let streams = json["streams"] as? [[String: Any]] else {
            throw PipelineFailure(String(localized: "미디어 정보를 읽지 못했습니다: \(result.diagnostic)"))
        }
        let tracks = streams.filter { $0["codec_type"] as? String == "subtitle" }.compactMap { stream -> SubtitleTrack? in
            guard let index = stream["index"] as? Int, let codec = stream["codec_name"] as? String else { return nil }
            let language = (stream["tags"] as? [String: Any])?["language"] as? String ?? "und"
            return SubtitleTrack(index: index, codec: codec, language: Self.langCode2(language))
        }
        let videos = streams.filter { $0["codec_type"] as? String == "video" }.count
        return MediaInfo(duration: duration, subtitles: tracks, hasVideo: videos > 0,
                         audioCount: streams.filter { $0["codec_type"] as? String == "audio" }.count, videoCount: videos)
    }

    struct SourceSubtitle {
        let url: URL
        let language: String
        let created: Bool
    }

    static func sidecars(for media: URL) -> [(url: URL, language: String)] {
        let base = media.deletingPathExtension().lastPathComponent
        let directory = media.deletingLastPathComponent()
        return ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }.compactMap { url in
            let name = url.lastPathComponent
            if name == "\(base).srt" { return (url, "und") }
            guard name.hasPrefix("\(base)."), name.hasSuffix(".srt") else { return nil }
            let language = String(name.dropFirst(base.count + 1).dropLast(4))
            guard language.range(of: #"^[a-z]{2,3}$"#, options: .regularExpression) != nil else { return nil }
            return (url, Self.langCode2(language))
        }
    }

    private func sidecarURL(_ media: URL, language: String) -> URL {
        media.deletingPathExtension().appendingPathExtension("\(language).srt")
    }

    private func checked(_ result: ProcessResult, stage: String) throws {
        guard result.succeeded else { throw PipelineFailure("\(stage): \(result.diagnostic)") }
    }

    private func extractSubtitle(_ track: SubtitleTrack, media: URL, destination: URL, ffmpeg: String, token: CancellationToken) throws {
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".subtitle-\(UUID().uuidString).srt")
        defer { try? FileManager.default.removeItem(at: temp) }
        let result = ProcessRunner.run(ffmpeg, arguments: ["-nostdin", "-v", "error", "-y", "-i", media.path, "-map", "0:\(track.index)", "-c:s", "srt", temp.path], timeout: 120, cancellation: token)
        try checked(result, stage: String(localized: "내장 자막 추출 실패"))
        let content = try String(contentsOf: temp, encoding: .utf8)
        guard let document = try? SrtDocument(content) else { throw PipelineFailure(String(localized: "내장 자막이 비어 있거나 형식이 올바르지 않습니다")) }
        guard !token.isCancelled else { throw PipelineFailure(String(localized: "작업이 중단되었습니다")) }
        try document.render().write(to: destination, atomically: true, encoding: .utf8)
    }

    static func sourceSidecars(for file: FileItem, language: String) -> [(url: URL, language: String)] {
        let preferred = language.isEmpty ? file.sourceLanguage : language
        return sidecars(for: file.url).filter {
            language.isEmpty || $0.language == language
                || ($0.language == "und" && (file.sourceLanguage == nil || file.sourceLanguage == "und" || file.sourceLanguage == language))
        }.sorted {
            let left = $0.language == preferred ? 0 : ($0.language == "und" ? 2 : 1)
            let right = $1.language == preferred ? 0 : ($1.language == "und" ? 2 : 1)
            return left == right ? $0.url.path < $1.url.path : left < right
        }
    }

    func prepareSource(file: FileItem, whisper: String, ffmpeg: String, ffprobe: String, options: Options, token: CancellationToken,
                       onProgress: @escaping (Double, String) -> Void = { _, _ in },
                       onModelDownload: @escaping WhisperModelInstaller.Progress = { _, _ in }) throws -> SourceSubtitle {
        let matching = Self.sourceSidecars(for: file, language: options.language)
        if let existing = matching.first {
            guard (try? SrtDocument(String(contentsOf: existing.url, encoding: .utf8))) != nil else {
                throw PipelineFailure(String(localized: "기존 SRT 형식이 올바르지 않습니다: \(existing.url.lastPathComponent)"))
            }
            onProgress(1, String(localized: "기존 SRT 확인 완료 · \(existing.language)"))
            let assignedLanguage = existing.language == "und"
                ? (options.language.isEmpty ? file.sourceLanguage ?? "und" : options.language) : existing.language
            return SourceSubtitle(url: existing.url, language: assignedLanguage, created: false)
        }
        let info = try mediaInfo(file.url, ffprobe: ffprobe, token: token)
        if let track = info.subtitles.first(where: { $0.isText && (options.language.isEmpty || $0.language == options.language) }) {
            let destination = sidecarURL(file.url, language: track.language)
            try extractSubtitle(track, media: file.url, destination: destination, ffmpeg: ffmpeg, token: token)
            onProgress(1, String(localized: "내장 자막 추출 완료 · \(track.language)"))
            return SourceSubtitle(url: destination, language: track.language, created: true)
        }
        guard info.audioCount > 0 else { throw PipelineFailure(String(localized: "전사할 오디오 트랙이 없습니다")) }
        do { try prepareModel(URL(fileURLWithPath: options.model), token, onModelDownload) }
        catch {
            if token.isCancelled { throw PipelineFailure(String(localized: "작업이 중단되었습니다")) }
            throw PipelineFailure(String(localized: "음성인식 모델 준비 실패: \(error.localizedDescription)"))
        }
        let vad = WhisperModelInstaller.vadURL(nextTo: URL(fileURLWithPath: options.model))
        guard WhisperModelInstaller.isVadAvailable(at: vad) else {
            throw PipelineFailure(String(localized: "음성 구간 감지 모델이 없어 자막 시간을 맞출 수 없습니다. 시작 설정에서 모델을 다시 설치해주세요."))
        }
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("transcription-\(UUID().uuidString)")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        var language = options.language
        if language.isEmpty {
            let supported = Set(Language.allCases.map { $0.rawValue }.filter { !$0.isEmpty })
            for (index, sample) in AudioPreparation.samples(duration: info.duration).enumerated() {
                if token.isCancelled { throw PipelineFailure(String(localized: "작업이 중단되었습니다")) }
                onProgress(0, String(localized: "언어 감지 중... (\(index + 1))"))
                let wav = temp.appendingPathComponent("sample.wav")
                try checked(AudioPreparation.extract(source: file.url, chunk: sample, destination: wav, ffmpeg: ffmpeg, cancellation: token), stage: String(localized: "언어 감지용 오디오 추출 실패"))
                let result = ProcessRunner.run(whisper, arguments: ["-m", options.model, "-f", wav.path, "-dl"], timeout: 120, cancellation: token)
                try checked(result, stage: String(localized: "언어 감지 실패"))
                if let detected = AudioPreparation.detectLanguage(result.output) {
                    logDebug("Language sample at \(sample.start)s: \(detected.language), confidence=\(detected.probability)")
                    if supported.contains(detected.language), detected.probability >= 0.5 {
                        language = detected.language
                        break
                    }
                }
            }
            guard !language.isEmpty else { throw PipelineFailure(String(localized: "언어를 확실하게 감지하지 못했습니다. 원본 언어를 지정해주세요.")) }
        }
        var cues: [SrtDocument.Cue] = []
        let chunks = AudioPreparation.chunks(duration: info.duration)
        for (index, chunk) in chunks.enumerated() {
            if token.isCancelled { throw PipelineFailure(String(localized: "작업이 중단되었습니다")) }
            onProgress(chunk.start / info.duration, String(localized: "오디오 추출 중... (\(index + 1)/\(chunks.count))"))
            let wav = temp.appendingPathComponent("chunk.wav")
            try checked(AudioPreparation.extract(source: file.url, chunk: chunk, destination: wav, ffmpeg: ffmpeg, cancellation: token), stage: String(localized: "청크 오디오 추출 실패"))
            let output = temp.appendingPathComponent("chunk")
            let args = ["-m", options.model, "-f", wav.path, "-l", language, "-t", String(min(10, ProcessInfo.processInfo.activeProcessorCount)),
                "--beam-size", String(options.sensitivity.beamSize), "--best-of", String(options.sensitivity.bestOf),
                "--no-speech-thold", String(options.sensitivity.noSpeechThreshold), "--logprob-thold", String(options.sensitivity.logprobThreshold),
                "--entropy-thold", String(options.sensitivity.entropyThreshold), "--print-progress", "--output-srt", "-of", output.path,
                "--vad", "--vad-model", vad.path, "--vad-threshold", String(options.sensitivity.vadThreshold)]
            let reportTime: (Double, Bool) -> Void = { position, estimated in
                let elapsed = min(info.duration, max(chunk.start, position))
                onProgress(elapsed / info.duration,
                    String(localized: "전사\(estimated ? String(localized: " 추정") : "") \(SrtDocument.format(elapsed)) / \(SrtDocument.format(info.duration)) · 청크 \(index + 1)/\(chunks.count) · \(language)"))
            }
            reportTime(chunk.start, false)
            let result = ProcessRunner.run(whisper, arguments: args, timeout: max(300, chunk.duration * 4), cancellation: token) { line in
                if let position = AudioPreparation.transcriptionPosition(in: line, chunk: chunk) {
                    reportTime(position.seconds, position.estimated)
                }
            }
            try checked(result, stage: String(localized: "\(index + 1)번째 청크 음성 인식 실패"))
            guard let raw = try? Data(contentsOf: output.appendingPathExtension("srt")) else {
                throw PipelineFailure(String(localized: "\(index + 1)번째 청크의 자막 결과 파일이 생성되지 않았습니다"))
            }
            let text = String(decoding: raw, as: UTF8.self)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let document: WhisperSrtDocument
                do { document = try WhisperSrtDocument(text, duration: chunk.duration) }
                catch {
                    let diagnostic = file.url.deletingPathExtension().appendingPathExtension("whisper-chunk-\(index + 1)-\(UUID().uuidString).diagnostic.srt")
                    let preserved = (try? raw.write(to: diagnostic, options: .withoutOverwriting)) != nil
                    let detail = preserved ? String(localized: " 전사 SRT 원문을 \(diagnostic.lastPathComponent)에 보존했습니다.") : ""
                    throw PipelineFailure(String(localized: "\(index + 1)번째 청크 전사 결과를 읽지 못했습니다. \(error.localizedDescription)\(detail)"))
                }
                if document.omittedCount > 0 { logDebug("Whisper chunk \(index + 1): omitted \(document.omittedCount) empty/zero-duration/out-of-range segments") }
                let speech = AudioPreparation.speechSegments(in: result.stderr)
                if speech.isEmpty { logDebug("Whisper chunk \(index + 1): no VAD speech segments reported; cue times not trimmed") }
                cues += WhisperSrtDocument.trim(document.cues, toSpeech: speech).map {
                    SrtDocument.Cue(number: $0.number, start: $0.start + chunk.start, end: $0.end + chunk.start, text: $0.text)
                }
            }
            logDebug("Chunk \(index + 1)/\(chunks.count) extracted at \(chunk.start)s: \(cues.count) cumulative cues")
            reportTime(chunk.start + chunk.duration, false)
        }
        guard !token.isCancelled else { throw PipelineFailure(String(localized: "작업이 중단되었습니다")) }
        let segments: [[String: Any]] = cues.map { ["start": $0.start, "end": $0.end, "text": $0.text] }
        let content = generateSrt(from: segments, delay: options.subtitleDelay, totalDuration: info.duration)
        guard (try? SrtDocument(content)) != nil else { throw PipelineFailure(String(localized: "자막 내용 없음 — 음성 또는 필터 설정을 확인해주세요")) }
        let destination = sidecarURL(file.url, language: language)
        try content.write(to: destination, atomically: true, encoding: .utf8)
        onProgress(1, String(localized: "전사·SRT 저장 완료 · \(language)"))
        return SourceSubtitle(url: destination, language: language, created: true)
    }

    @discardableResult
    func embed(_ srt: URL, language: String, into media: URL, ffmpeg: String, ffprobe: String, token: CancellationToken) throws -> Bool {
        let info = try mediaInfo(media, ffprobe: ffprobe, token: token)
        // Audio input produces sidecar SRTs even when the video option is selected.
        guard info.hasVideo else { return false }
        if info.subtitles.contains(where: { $0.language == language }) { return true }
        let codec: String
        switch media.pathExtension.lowercased() {
        case "mp4", "m4v", "mov": codec = "mov_text"
        case "mkv": codec = "srt"
        case "webm": codec = "webvtt"
        default: throw PipelineFailure(String(localized: "이 영상 형식은 자막 내장을 지원하지 않습니다. 생성된 SRT 파일은 보존했습니다."))
        }
        let snapshot = try SafeFileReplacement.Snapshot(media)
        let candidate = media.deletingLastPathComponent().appendingPathComponent(".subtitle-\(UUID().uuidString).\(media.pathExtension)")
        defer { try? FileManager.default.removeItem(at: candidate) }
        let result = ProcessRunner.run(ffmpeg, arguments: ["-nostdin", "-v", "error", "-y", "-i", media.path, "-i", srt.path,
            "-map", "0", "-map", "1:0", "-c", "copy", "-c:s:\(info.subtitles.count)", codec, "-max_interleave_delta", "0",
            "-metadata:s:s:\(info.subtitles.count)", "language=\(langCode3(language))", candidate.path], timeout: 1800, cancellation: token)
        try checked(result, stage: String(localized: "자막 내장 실패 — SRT 파일을 보존했습니다"))
        let verified = try mediaInfo(candidate, ffprobe: ffprobe, token: token)
        guard verified.subtitles.count == info.subtitles.count + 1,
              verified.subtitles.contains(where: { $0.language == language }),
              verified.audioCount == info.audioCount, verified.videoCount == info.videoCount,
              abs(verified.duration - info.duration) < 2 else {
            throw PipelineFailure(String(localized: "자막 내장 결과 검증 실패 — 원본 영상과 SRT 파일을 보존했습니다"))
        }
        guard !token.isCancelled else { throw PipelineFailure(String(localized: "작업이 중단되었습니다")) }
        try SafeFileReplacement.replace(media, with: candidate, expected: snapshot)
        return true
    }

    func translateFile(file: FileItem, source: SourceSubtitle, sourceEmbedded: Bool, ffmpeg: String, ffprobe: String,
                               options: Options, token: CancellationToken,
                               onStatusUpdate: @escaping (String) -> Void, onLangComplete: @escaping (String) -> Void,
                               onCueProgress: @escaping (TranslationLanguage, Int, Int) -> Void = { _, _, _ in },
                               onSavingStatus: ((String) -> Void)? = nil) -> FileStatus {
        // Saving/embedding has no measurable fraction; callers may show it as indeterminate.
        let onSavingStatus = onSavingStatus ?? onStatusUpdate
        var failures: [String] = []
        var cleanup: [URL] = []
        if source.created && sourceEmbedded { cleanup.append(source.url) }
        do {
            let content = try String(contentsOf: source.url, encoding: .utf8)
            let cueCount = try SrtDocument(content).cues.count
            let info = try mediaInfo(file.url, ffprobe: ffprobe, token: token)
            var pending: [TranslationLanguage] = []
            for lang in options.translationTargets.sorted(by: { $0.rawValue < $1.rawValue }) where lang.rawValue != source.language {
                if token.isCancelled { throw PipelineFailure(String(localized: "작업이 중단되었습니다")) }
                let destination = sidecarURL(file.url, language: lang.rawValue)
                let exists = FileManager.default.fileExists(atPath: destination.path)
                onCueProgress(lang, 0, cueCount)
                if exists {
                    guard (try? SrtDocument(String(contentsOf: destination, encoding: .utf8))) != nil else {
                        failures.append(String(localized: "\(lang.label): 기존 SRT 형식 오류")); continue
                    }
                    onCueProgress(lang, cueCount, cueCount)
                    if options.embedSubtitle {
                        onSavingStatus(String(localized: "\(lang.label) 자막 내장·검증 중..."))
                        try embed(destination, language: lang.rawValue, into: file.url, ffmpeg: ffmpeg, ffprobe: ffprobe, token: token)
                    }
                    onLangComplete(lang.rawValue)
                } else if let track = info.subtitles.first(where: { $0.language == lang.rawValue && $0.isText }) {
                    if options.keepSrtFile { try extractSubtitle(track, media: file.url, destination: destination, ffmpeg: ffmpeg, token: token) }
                    onCueProgress(lang, cueCount, cueCount)
                    onLangComplete(lang.rawValue)
                } else { pending.append(lang) }
            }
            if options.translationProvider == .apple, !pending.isEmpty {
                let prepared = readyAppleTargets(pending, source: source.language, token: token, onStatus: onStatusUpdate)
                pending = prepared.ready
                failures += prepared.failures
            }
            if !pending.isEmpty {
                let translator = try makeTranslator(options: options, sourceLanguage: source.language, token: token)
                let result = translator.translateSrt(srtContent: content, sourceLang: source.language, targetLangs: pending, onProgress: onStatusUpdate, onCueProgress: onCueProgress)
                for (language, error) in result.failures { failures.append(String(localized: "\(language.label) 번역 실패: \(error)")) }
                for lang in pending {
                    guard !token.isCancelled else { throw PipelineFailure(String(localized: "작업이 중단되었습니다")) }
                    guard let translated = result.translations[lang] else { continue }
                    let destination = sidecarURL(file.url, language: lang.rawValue)
                    do {
                        onSavingStatus(String(localized: "\(lang.label) 자막 저장·내장 검증 중..."))
                        try translated.write(to: destination, atomically: true, encoding: .utf8)
                        if options.embedSubtitle, try embed(destination, language: lang.rawValue, into: file.url, ffmpeg: ffmpeg, ffprobe: ffprobe, token: token) {
                            cleanup.append(destination)
                        }
                        onLangComplete(lang.rawValue)
                    } catch { failures.append("\(lang.label): \(error.localizedDescription)") }
                }
            }
            guard !token.isCancelled else { throw PipelineFailure(String(localized: "작업이 중단되었습니다")) }
            if !failures.isEmpty { return .failed(error: failures.joined(separator: "\n")) }
            if !options.keepSrtFile {
                for url in cleanup { try FileManager.default.removeItem(at: url) }
            }
            return .completed(lang: source.language)
        } catch { return .failed(error: error.localizedDescription) }
    }

    /// File-level ETA based on current file progress
    func calculateFileEta() -> String {
        guard let id = sourceFileID, let work = workProgress.files[id],
              work.sourceFraction > 0.05, work.sourceFraction < 1 else { return "" }
        let elapsed = Date().timeIntervalSince(work.transcriptionStartedAt ?? fileStartTime)
        guard elapsed >= 2 else { return "" }
        let remaining = (elapsed / work.sourceFraction) - elapsed
        guard remaining > 0 else { return "" }
        return formatEta(remaining)
    }

    /// Overall ETA based on total progress across all files
    func calculateOverallEta() -> String {
        guard overallProgress > 0.02 else { return "" }
        let elapsed = Date().timeIntervalSince(totalStartTime)
        let remaining = (elapsed / overallProgress) - elapsed
        guard remaining > 0 else { return "" }
        return formatEta(remaining)
    }

    private func formatEta(_ remaining: Double) -> String {
        let mins = Int(remaining) / 60
        let secs = Int(remaining) % 60
        if mins > 0 {
            return String(localized: "약 \(mins)분 \(secs)초")
        } else {
            return String(localized: "약 \(secs)초")
        }
    }

    func parseSrtTimestamp(_ str: String) -> Double {
        let parts = str.components(separatedBy: ":")
        guard parts.count == 2 else { return 0 }
        let minutes = Double(parts[0]) ?? 0
        let seconds = Double(parts[1]) ?? 0
        return minutes * 60 + seconds
    }

    // ISO 639-1 (2-char) to ISO 639-2 (3-char) for MP4 container
    private static let langMap: [String: String] = [
        "ja": "jpn", "ko": "kor", "en": "eng", "zh": "zho", "fr": "fra",
        "de": "deu", "es": "spa", "it": "ita", "pt": "por", "ru": "rus",
        "ar": "ara", "hi": "hin", "th": "tha", "vi": "vie", "id": "ind",
        "ms": "msa", "tl": "tgl", "tr": "tur", "pl": "pol", "nl": "nld",
        "sv": "swe", "da": "dan", "no": "nor", "fi": "fin", "el": "ell",
        "he": "heb", "uk": "ukr", "cs": "ces", "ro": "ron", "hu": "hun",
    ]

    static func langCode2(_ code: String) -> String {
        let lower = code.lowercased()
        let aliases = ["fre": "fr", "ger": "de", "chi": "zh", "dut": "nl", "cze": "cs", "rum": "ro", "gre": "el"]
        if let alias = aliases[lower] { return alias }
        if let entry = langMap.first(where: { $0.value == lower }) { return entry.key }
        return lower.range(of: #"^[a-z]{2,3}$"#, options: .regularExpression) != nil ? lower : "und"
    }

    func langCode3(_ code2: String) -> String {
        Self.langMap[code2] ?? code2
    }

    // MARK: - Post-processing filters

    /// Known whisper hallucination phrases
    private let hallucinationBlacklist: Set<String> = [
        // Japanese
        "ご視聴ありがとうございました", "ご視聴ありがとうございます",
        "チャンネル登録お願いします", "チャンネル登録よろしくお願いします",
        "高評価お願いします", "コメントお願いします",
        "次の動画でお会いしましょう", "また次の動画で",
        "おやすみなさい", "お疲れ様でした",
        "字幕は自動生成されています", "字幕の翻訳",
        // English
        "thank you for watching", "thanks for watching",
        "please subscribe", "please like and subscribe",
        "see you in the next video", "see you next time",
        "subtitles by", "subtitles created by",
        "translated by", "captions by",
        // Korean
        "시청해 주셔서 감사합니다", "구독과 좋아요 부탁드립니다",
    ]

    /// Detect repetitive text like "ああああ", "うっ、うっ、うっ", "ダメダメダメ", "はぁっはぁっはぁっ"
    func isRepetitive(_ text: String) -> Bool {
        let cleaned = text.replacingOccurrences(of: "、", with: "")
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "「", with: "")
            .replacingOccurrences(of: "」", with: "")

        guard cleaned.count >= 4 else { return false }

        // Few unique chars in long text: うっうううう..., ああああ
        let uniqueChars = Set(cleaned)
        if uniqueChars.count == 1 { return true }
        if uniqueChars.count <= 4 && cleaned.count >= 12 { return true }

        // Short pattern repeat (1~10 chars): ダメダメダメ, はぁっはぁっはぁっ
        for len in 1...min(10, cleaned.count / 2) {
            let pattern = String(cleaned.prefix(len))
            let repeatCount = cleaned.count / len
            guard repeatCount >= 3 else { continue }
            // Exact match or nearly exact (allow partial trailing)
            let repeated = String(repeating: pattern, count: repeatCount)
            if cleaned.hasPrefix(repeated) {
                return true
            }
        }

        // Comma-separated repeats: うっ、うっ、うっ or 「あ、いけ、いけ、いけ
        let parts = text.components(separatedBy: "、").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count >= 3 {
            let nonEmpty = parts.filter { !$0.isEmpty }
            let unique = Set(nonEmpty)
            // Allow 1-2 unique tokens if majority is the same
            if unique.count <= 2 {
                let mostCommon = unique.max(by: { a, b in nonEmpty.filter { $0 == a }.count < nonEmpty.filter { $0 == b }.count })!
                let ratio = Double(nonEmpty.filter { $0 == mostCommon }.count) / Double(nonEmpty.count)
                if ratio >= 0.7 { return true }
            }
        }

        return false
    }

    /// Check if text is only punctuation/symbols with no meaningful content
    func isPunctuationOnly(_ text: String) -> Bool {
        let stripped = text.replacingOccurrences(of: "[\\p{P}\\p{S}\\s]", with: "", options: .regularExpression)
        return stripped.isEmpty
    }

    /// Check if text is a known hallucination phrase
    func isHallucination(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .punctuationCharacters)
        return hallucinationBlacklist.contains { lower.contains($0.lowercased()) }
    }

    /// Check if text density is suspiciously high (chars per second)
    func isOverDense(text: String, duration: Double) -> Bool {
        guard duration > 0 else { return true }
        let charsPerSecond = Double(text.count) / duration
        return charsPerSecond > 25  // ~25 chars/sec is extreme even for fast Japanese
    }

    func generateSrt(from segments: [[String: Any]], delay: Double = 0, totalDuration: Double = 0) -> String {
        struct SrtEntry {
            var start: Double
            var end: Double
            var text: String
        }

        let minDuration = 0.3  // minimum segment duration in seconds

        var entries: [SrtEntry] = []
        for seg in segments {
            guard let start = seg["start"] as? Double,
                  let end = seg["end"] as? Double,
                  let text = seg["text"] as? String else { continue }
            guard start.isFinite, end.isFinite else { continue }

            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let cappedEnd = min(end, start + 30)  // Cap max duration to 30s
            let duration = cappedEnd - start

            // Filter 1: Too short segments (likely noise)
            if duration < minDuration { continue }

            // Filter 2: Repetitive text patterns
            if isRepetitive(trimmed) { continue }

            // Filter 3: Punctuation/symbols only
            if isPunctuationOnly(trimmed) { continue }

            // Filter 4: Known hallucination phrases
            if isHallucination(trimmed) { continue }

            // Filter 5: Suspiciously dense text (hallucination indicator)
            if isOverDense(text: trimmed, duration: duration) { continue }

            // Filter 6: End-of-video hallucination (last 30s, high no_speech_prob)
            if totalDuration > 0 && start > totalDuration - 30 {
                let noSpeechProb = seg["no_speech_prob"] as? Double ?? 0
                if noSpeechProb > 0.5 { continue }
            }

            // Merge consecutive duplicates (but cap merged duration to 30s)
            if let last = entries.last, last.text == trimmed, start <= last.end + 0.5 {
                let mergedEnd = min(cappedEnd, last.start + 30)
                entries[entries.count - 1].end = mergedEnd
            } else {
                entries.append(SrtEntry(start: start, end: cappedEnd, text: trimmed))
            }
        }

        var lines: [String] = []
        var sequence = 1
        for entry in entries {
            let start = max(0, entry.start + delay)
            let end = totalDuration > 0 ? min(totalDuration, max(0, entry.end + delay)) : max(0, entry.end + delay)
            guard end > start else { continue }
            lines.append("\(sequence)")
            sequence += 1
            lines.append("\(formatSrtTime(start)) --> \(formatSrtTime(end))")
            lines.append(entry.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    func formatSrtTime(_ seconds: Double) -> String {
        SrtDocument.format(seconds)
    }
}
