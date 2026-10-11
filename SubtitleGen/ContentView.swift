import SwiftUI
import UniformTypeIdentifiers
import CryptoKit

struct ContentView: View {
    @State private var files: [FileItem] = FileItem.loadSaved()
    @State private var selectedFileIDs: Set<UUID> = []
    @AppStorage("selectedModel") private var selectedModel: WhisperModel = .largev3turbo
    @AppStorage("outputMode") private var outputMode: OutputMode = .embedInVideo
    @AppStorage("language") private var language: Language = .auto
    @AppStorage("sensitivity") private var sensitivity: Sensitivity = .normal
    @State private var selectedTranslations: Set<TranslationLanguage> = {
        let key = AppDistribution.isStore ? "chatgpt.translationTargets" : "selectedTranslations"
        guard let data = UserDefaults.standard.data(forKey: key),
              let raw = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(raw.compactMap { TranslationLanguage(rawValue: $0) })
    }()
    @AppStorage("authMethod") private var authMethod: AuthMethod = .claudeCode
    @AppStorage("translationModel") private var translationModel: TranslationModel = .claudeOpus
    @State private var isDownloadingModel = false
    @State private var modelDownloadDetail = "연결 중…"
    @State private var modelDownloadToken: CancellationToken?
    @State private var isDropTargeted = false
    @AppStorage("initialSetupCompleted") private var initialSetupCompleted = false
    @State private var showSetup = false
    @State private var isSettingUp = false
    @State private var setupCancelled = false
    @State private var startAfterSetup = false
    @AppStorage("optionsExpanded") private var optionsExpanded = true
    @AppStorage("subtitleDelay") private var subtitleDelay: SubtitleDelay = .none
    @StateObject private var toolChecker = ToolChecker()
    @StateObject private var engine = TranscriptionEngine()
    #if MAC_APP_STORE
    @StateObject private var chatGPT = ChatGPTAccountController()
    @AppStorage("store.translationProvider") private var translationProvider: TranslationProvider = .chatGPT
    @StateObject private var appleTranslation = AppleTranslationCoordinator()
    #endif

    var body: some View {
        VStack(spacing: 0) {
            headerSection

            Divider()

            if !toolChecker.allInstalled {
                toolStatusSection
                    .transition(.opacity.combined(with: .move(edge: .top)))
                Divider()
            }

            fileListSection
                .frame(minHeight: 220)

            Divider()

            ScrollView {
                optionsSection
            }
            .frame(height: optionsExpanded ? 360 : 52)

            Divider()

            actionSection
        }
        .frame(minWidth: 860, idealWidth: 940, maxWidth: .infinity,
               minHeight: 760, idealHeight: 820, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("다운로드 실패", isPresented: Binding(get: { toolChecker.installationError != nil }, set: { if !$0 { toolChecker.installationError = nil } })) {
            Button("확인") { toolChecker.installationError = nil }
        } message: { Text(toolChecker.installationError ?? "") }
        .onAppear {
            toolChecker.checkAll()
            if !initialSetupCompleted { showSetup = true }
            #if MAC_APP_STORE
            chatGPT.reload()
            #endif
        }
        #if MAC_APP_STORE
        .modifier(AppleTranslationPreparationModifier(coordinator: appleTranslation))
        .onChange(of: translationProvider) { _, _ in requeueForChangedOptions() }
        #endif
        .sheet(isPresented: $showSetup) { setupSection }
        .onChange(of: files.map(\.url)) { _, _ in
            FileItem.save(files)
            if !engine.isProcessing { engine.resetProgress() }
        }
        .onChange(of: files.map(\.sourceLanguage)) { _, _ in
            FileItem.saveSourceLanguages(files)
        }
        .onReceive(NotificationCenter.default.publisher(for: .startProcessing)) { _ in
            if !engine.isProcessing && !files.isEmpty && !isDownloadingModel && !toolChecker.isInstalling {
                requestProcessing()
            }
        }
        .onDeleteCommand {
            if !selectedFileIDs.isEmpty {
                files.removeAll { selectedFileIDs.contains($0.id) && !$0.isActive }
                selectedFileIDs.removeAll()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stopProcessing)) { _ in
            if engine.isProcessing {
                engine.cancel()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .addFilesToQueue)) { notification in
            guard let urls = notification.userInfo?["urls"] as? [URL] else { return }
            if !engine.isProcessing { engine.resetProgress() }
            for url in urls {
                if let existingIndex = files.firstIndex(where: { $0.url == url }) {
                    if !engine.isProcessing { files[existingIndex].resetForProcessing() }
                } else {
                    files.append(FileItem(url: url))
                }
            }
        }
        .onChange(of: selectedTranslations) { _, newValue in
            let raw = newValue.map { $0.rawValue }
            if let data = try? JSONEncoder().encode(raw) {
                UserDefaults.standard.set(data, forKey: AppDistribution.isStore ? "chatgpt.translationTargets" : "selectedTranslations")
            }
            requeueForChangedOptions()
        }
        .onChange(of: language) { _, _ in requeueForChangedOptions() }
        .onChange(of: outputMode) { _, _ in requeueForChangedOptions() }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("SubGen")
                    .font(.title2.bold())
                Text("음성 전사 · 자막 번역")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Label("음성은 이 Mac에서 처리", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button { startAfterSetup = false; showSetup = true } label: {
                Label("작업 준비", systemImage: "slider.horizontal.3")
            }
                .help("음성 인식 모델과 도구 설치 상태 확인")
                .disabled(engine.isProcessing)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    // MARK: - Tool Status

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("자막 작업 준비", systemImage: "captions.bubble.fill")
                .font(.title2.bold())
            Text(AppDistribution.isStore ? "음성인식·영상 처리 도구는 앱에 포함되어 있습니다. 사용할 음성인식 모델을 선택하고 한 번 다운로드해주세요." : "음성인식·영상 처리 도구와 모델을 한 번 설치하면 다음 실행부터 바로 사용할 수 있습니다. 이 Mac에 맞는 도구를 자동으로 선택합니다.")
                .foregroundStyle(.secondary)

            ForEach(toolChecker.tools) { tool in
                HStack {
                    Image(systemName: tool.status.icon).foregroundStyle(tool.status.color)
                    VStack(alignment: .leading) {
                        Text(tool.name).bold()
                        Text(tool.description).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if tool.status == .installed {
                        Text("준비됨").foregroundStyle(.green)
                    } else if tool.status == .installing || tool.status == .checking {
                        ProgressView().controlSize(.small)
                    } else { Text("설치 필요").foregroundStyle(.secondary) }
                }
            }

            Divider()
            Picker("음성인식 모델", selection: $selectedModel) {
                ForEach(WhisperModel.allCases) { model in
                    Text("\(model.displayName) · \(model.sizeLabel)").tag(model)
                }
            }
            .disabled(isSettingUp || isDownloadingModel || toolChecker.isInstalling)
            Text(selectedModel.isCached ? "모델이 준비되어 있습니다." : "선택한 모델 \(selectedModel.sizeLabel)을 다운로드합니다. 인터넷 연결과 여유 저장 공간이 필요합니다.")
                .font(.caption).foregroundStyle(.secondary)
            Text(AppDistribution.isStore ? "번역은 ChatGPT 로그인 후 플랜 사용 권한을 허용하면 사용할 수 있습니다. 음성 전사는 로그인 없이 가능합니다." : "번역은 로그인된 Claude Code 또는 Codex CLI를 연결한 뒤 사용할 수 있습니다.")
                .font(.caption).foregroundStyle(.secondary)

            if let error = toolChecker.installationError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isSettingUp || isDownloadingModel || toolChecker.isInstalling {
                    ProgressView().controlSize(.small)
                    Text(isDownloadingModel ? "음성인식 모델 다운로드 중 · \(modelDownloadDetail)" : "필요한 도구 설치 중…")
                        .font(.caption)
                    Spacer()
                    Button("설치 중단") { cancelSetup() }
                } else {
                    Button("나중에") { startAfterSetup = false; showSetup = false }
                    Spacer()
                    Button(toolChecker.allInstalled && selectedModel.isCached ? "시작하기" : "필요한 항목 설치") {
                        installSetup()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(toolChecker.tools.isEmpty || toolChecker.tools.contains { $0.status == .checking })
                }
            }
        }
        .padding(28)
        .frame(width: 540)
        .interactiveDismissDisabled(isSettingUp || isDownloadingModel || toolChecker.isInstalling)
    }

    private func cancelSetup() {
        setupCancelled = true
        toolChecker.cancelInstall()
        modelDownloadToken?.cancel()
    }

    private func requestProcessing() {
        guard !engine.isProcessing, !isDownloadingModel, !toolChecker.isInstalling else { return }
        FileItem.requeueFailedOrCancelled(&files)
        if toolChecker.allInstalled {
            // Existing source subtitles can be processed without a speech model;
            // the engine checks that dependency only if transcription is needed.
            startProcessing()
        } else {
            startAfterSetup = true
            showSetup = true
        }
    }

    private func installSetup() {
        guard !isSettingUp && !isDownloadingModel && !toolChecker.isInstalling else { return }
        isSettingUp = true
        setupCancelled = false
        toolChecker.installationError = nil
        let prepareModel = {
            guard !setupCancelled, toolChecker.allInstalled else { isSettingUp = false; return }
            if selectedModel.isCached {
                finishSetup(success: true)
            } else {
                downloadModel { success in finishSetup(success: success) }
            }
        }
        let missing = toolChecker.tools.filter { $0.status != .installed }
        if missing.isEmpty { prepareModel() }
        else if AppDistribution.isStore {
            toolChecker.installationError = "앱에 포함된 도구를 실행하지 못했습니다. 앱을 다시 설치해주세요."
            isSettingUp = false
        } else { toolChecker.installAll(missing, completion: prepareModel) }
    }

    private func finishSetup(success: Bool) {
        isSettingUp = false
        guard success, !setupCancelled, toolChecker.allInstalled else { return }
        initialSetupCompleted = true
        showSetup = false
        if startAfterSetup { startAfterSetup = false; startProcessing() }
    }

    private var toolStatusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(.orange)
                Text("필요한 도구")
                    .font(.headline)
                Spacer()
                if toolChecker.isInstalling {
                    Button("설치 중단") { toolChecker.cancelInstall() }
                }
            }

            ForEach(toolChecker.tools) { tool in
                ToolRowView(tool: tool, downloadProgress: toolChecker.downloadProgress) {
                    toolChecker.install(tool)
                }
            }
        }
        .padding()
        .background(.orange.opacity(0.03))
    }

    // MARK: - File List

    private var fileListSection: some View {
        VStack(spacing: 0) {
            if files.isEmpty {
                dropZone
            } else {
                fileList
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var dropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.blue)
                .frame(width: 64, height: 64)
                .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))

            Text("파일을 추가해 시작하세요")
                .font(.title3.weight(.semibold))

            Text("영상·음성 파일을 이곳에 끌어 놓거나 선택하세요.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("MP4 · MOV · MKV · WebM · M4A · WAV · MP3 등")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button("파일 선택…") {
                openFilePicker()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityLabel("전사할 영상 또는 음성 파일 선택")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundStyle(isDropTargeted ? AnyShapeStyle(.blue) : AnyShapeStyle(.quaternary))
                .padding(16)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 18)
                    .fill(.blue.opacity(0.05))
                    .padding(16)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
            return true
        }
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(files.count)개 파일")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Button {
                    openFilePicker()
                } label: {
                    Label("추가", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.borderless)

                Button {
                    for i in files.indices {
                        if !files[i].isActive {
                            files[i].resetForProcessing()
                        }
                    }
                    engine.resetProgress()
                } label: {
                    Label("다시 처리", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(engine.isProcessing)
                .help("목록의 처리 상태만 초기화합니다. 영상과 자막 파일은 보존합니다.")

                Button {
                    files.removeAll { !$0.isActive }
                } label: {
                    Label("목록 비우기", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red.opacity(engine.isProcessing ? 0.3 : 1.0))
                .disabled(engine.isProcessing)
                .help("작업 목록에서 제거합니다. 실제 파일은 삭제하지 않습니다.")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            List(selection: $selectedFileIDs) {
                ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                    FileRowView(
                        file: file,
                        fileEtaText: file.status == .processing ? engine.calculateFileEta() : ""
                    )
                        .tag(file.id)
                        .contextMenu {
                            if selectedFileIDs.count > 1 && selectedFileIDs.contains(file.id) {
                                // Multi-selection context menu
                                Button {
                                    for id in selectedFileIDs {
                                        if let i = files.firstIndex(where: { $0.id == id }), !files[i].isActive {
                                            files[i].resetForProcessing()
                                        }
                                    }
                                    selectedFileIDs.removeAll()
                                    engine.resetProgress()
                                } label: {
                                    Label("선택 항목 초기화 (\(selectedFileIDs.count)개)", systemImage: "arrow.counterclockwise")
                                }
                                .disabled(engine.isProcessing)

                                Button(role: .destructive) {
                                    files.removeAll { selectedFileIDs.contains($0.id) && !$0.isActive }
                                    selectedFileIDs.removeAll()
                                } label: {
                                    Label("선택 항목 삭제 (\(selectedFileIDs.count)개)", systemImage: "trash")
                                }
                            } else {
                                // Single item context menu
                                if engine.isProcessing {
                                    if file.isActive {
                                        Button {
                                            engine.skipCurrent(fileID: file.id)
                                        } label: {
                                            Label("건너뛰기", systemImage: "forward.fill")
                                        }
                                    } else if file.status == .pending {
                                        Button {
                                            files[index].status = .skipped
                                        } label: {
                                            Label("건너뛰기", systemImage: "forward.fill")
                                        }
                                    }

                                    Divider()
                                }

                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([file.url])
                                } label: {
                                    Label("파인더에서 보기", systemImage: "folder")
                                }

                                Button {
                                    NSWorkspace.shared.open(file.url)
                                } label: {
                                    Label("기본 앱으로 열기", systemImage: "play.circle")
                                }

                                Divider()

                                Button {
                                    files[index].resetForProcessing()
                                    engine.resetProgress()
                                } label: {
                                    Label("상태 초기화", systemImage: "arrow.counterclockwise")
                                }
                                .disabled(engine.isProcessing)

                                Button(role: .destructive) {
                                    files.remove(at: index)
                                } label: {
                                    Label("목록에서 제거", systemImage: "trash")
                                }
                                .disabled(file.isActive)
                            }
                        }
                }
                .onDelete { indexSet in
                    for index in indexSet.sorted(by: >) where !files[index].isActive { files.remove(at: index) }
                }
                .onMove { from, to in
                    if !engine.isProcessing {
                        files.move(fromOffsets: from, toOffset: to)
                    }
                }
                .onInsert(of: [.fileURL]) { index, providers in
                    handleDrop(providers, at: engine.isProcessing ? files.count : index)
                }
            }
            .listStyle(.inset)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
            return true
        }
    }

    // MARK: - Options

    private var optionsSection: some View {
        DisclosureGroup(isExpanded: $optionsExpanded) {
            HStack {
                Spacer()
                Button("옵션 초기화") {
                    resetOptions()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
                .disabled(engine.isProcessing)
            }
            HStack(alignment: .top, spacing: 16) {
                // Left: 자막 생성 옵션
                VStack(alignment: .leading, spacing: 12) {
                    Label("음성 전사", systemImage: "waveform")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    optionRow("모델") {
                        VStack(alignment: .leading, spacing: 4) {
                            Picker("", selection: $selectedModel) {
                                ForEach(WhisperModel.allCases) { model in
                                    HStack {
                                        Text(model.displayName)
                                        if !model.isCached {
                                            Text("(\(model.sizeLabel))")
                                                .foregroundStyle(.tertiary)
                                        }
                                    }.tag(model)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .disabled(isDownloadingModel || isSettingUp || toolChecker.isInstalling)

                            if !selectedModel.isCached || isDownloadingModel {
                                HStack(spacing: 4) {
                                    if isDownloadingModel {
                                        ProgressView()
                                            .controlSize(.small)
                                        Button("중단") { modelDownloadToken?.cancel() }.controlSize(.mini)
                                        Text("다운로드 중 · \(modelDownloadDetail)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Image(systemName: "arrow.down.circle")
                                            .foregroundStyle(.orange)
                                            .font(.caption)
                                        Text("첫 사용 시 \(selectedModel.sizeLabel) 다운로드")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                        Button("미리 다운로드") {
                                            downloadModel()
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                    }
                                }
                            }
                        }
                    }

                    optionRow("출력") {
                        Picker("", selection: $outputMode) {
                            ForEach(OutputMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    optionRow("원본 언어") {
                        Picker("", selection: $language) {
                            ForEach(Language.allCases) { lang in
                                Text(lang.label).tag(lang)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    optionRow("감도") {
                        Picker("", selection: $sensitivity) {
                            ForEach(Sensitivity.allCases) { s in
                                Text(s.label).tag(s)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .horizontalRadioGroupLayout()
                        .labelsHidden()
                    }

                    optionRow("시간 보정") {
                        Picker("", selection: $subtitleDelay) {
                            ForEach(SubtitleDelay.allCases) { delay in
                                Text(delay.label).tag(delay)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
                .disabled(engine.isProcessing)

                // Right: 번역 옵션
                VStack(alignment: .leading, spacing: 12) {
                    Label("자막 번역", systemImage: "character.bubble")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    #if MAC_APP_STORE
                    chatGPTOptions
                    #else
                    optionRow("Agents") {
                        Picker("", selection: $authMethod) {
                            ForEach(AuthMethod.allCases) { method in
                                Text(method.label).tag(method)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .onChange(of: authMethod) { _, newValue in
                            let models = TranslationModel.models(for: newValue)
                            translationModel = models.first!
                        }
                    }

                    optionRow("모델") {
                        Picker("", selection: $translationModel) {
                            ForEach(TranslationModel.models(for: authMethod)) { model in
                                Text(model.label).tag(model)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .help(authMethod == .claudeCode
                              ? "CLI가 최신 모델 별칭을 해석합니다. 최신 버전을 사용하려면 Claude Code도 업데이트하세요."
                              : "자동은 사용자 설정의 고정 모델을 건너뛰고 CLI 권장 모델을 사용합니다. 최신 Codex CLI를 사용하세요.")
                    }

                    optionRow("") {
                        HStack(spacing: 8) {
                            let cliName = authMethod == .claudeCode ? "claude" : "codex"
                            let installed = TranslationEngine.findCLI(for: authMethod) != nil

                            if installed {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("\(cliName) 설치됨")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                                Text("\(cliName) 미설치")
                                    .font(.caption)
                                    .foregroundStyle(.red)

                                Button {
                                    if authMethod == .claudeCode {
                                        NSWorkspace.shared.open(URL(string: "https://claude.ai/download")!)
                                    } else {
                                        NSWorkspace.shared.open(URL(string: "https://openai.com/codex/download")!)
                                    }
                                } label: {
                                    Text("설치")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }

                    if TranslationEngine.findCLI(for: authMethod) != nil {
                        Divider()

                        optionRow("언어") {
                            FlowLayout(spacing: 8) {
                                ForEach(TranslationLanguage.allCases) { lang in
                                    Toggle(lang.label, isOn: Binding(
                                        get: { selectedTranslations.contains(lang) },
                                        set: { if $0 { selectedTranslations.insert(lang) } else { selectedTranslations.remove(lang) } }
                                    ))
                                    .toggleStyle(.checkbox)
                                    .font(.body)
                                }
                            }
                        }

                        if !selectedTranslations.isEmpty {
                            Text("\(selectedTranslations.count)개 언어에 병렬 번역")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 62)
                        }
                    }
                    #endif
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
                .disabled(engine.isProcessing)
            }
            .padding(.top, 8)
        } label: {
            Label("작업 설정", systemImage: "slider.horizontal.3")
                .font(.headline)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func optionRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
                .font(.body)
            content()
        }
    }

    // MARK: - Action

    private var actionSection: some View {
        HStack {
            if engine.isProcessing {
                ProgressView().progressViewStyle(.circular).controlSize(.small)
                    .accessibilityLabel("처리 중")
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: engine.overallProgress)

                    HStack {
                        Text(engine.currentStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)

                        Spacer()

                        Text("\(Int(engine.overallProgress * 100))%")
                            .font(.caption.monospacedDigit())

                        Text(engine.eta.isEmpty ? "계산 중..." : engine.eta + " 남음")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)

                Button("중단") {
                    engine.cancel()
                }
                .buttonStyle(.bordered)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(files.isEmpty ? "파일을 추가하면 자막 작업을 시작할 수 있습니다." : "\(files.count)개 파일 · \(outputMode.label)")
                        .font(.subheadline)
                    Text(engine.currentStatus.isEmpty
                         ? (selectedTranslations.isEmpty ? "번역 없이 원본 언어의 자막을 만듭니다." : "\(selectedTranslations.count)개 언어로 자막을 번역합니다.")
                         : engine.currentStatus)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()

                Button {
                    requestProcessing()
                } label: {
                    Label("자막 만들기", systemImage: "play.fill")
                        .frame(width: 160)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .help("자막 작업 시작 (⌘R)")
                .disabled(files.isEmpty || isDownloadingModel || toolChecker.isInstalling)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.bar)
    }

    // MARK: - Actions

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            .mpeg4Movie, .quickTimeMovie, .movie, .audio,
            UTType(filenameExtension: "mkv") ?? .movie,
            UTType(filenameExtension: "m4v") ?? .movie,
            UTType(filenameExtension: "m4a") ?? .audio,
        ]
        if panel.runModal() == .OK {
            for url in panel.urls {
                if !files.contains(where: { $0.url == url }) {
                    files.append(FileItem(url: url))
                }
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider], at insertIndex: Int? = nil) {
        var insertAt = insertIndex ?? files.count
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                let ext = url.pathExtension.lowercased()
                let allowed = ["mp4", "mov", "mkv", "m4v", "m4a", "wav", "mp3", "avi", "webm", "flv"]
                if allowed.contains(ext) {
                    DispatchQueue.main.async {
                        if let existingIndex = files.firstIndex(where: { $0.url == url }) {
                            if !engine.isProcessing {
                                files[existingIndex].resetForProcessing()
                                engine.resetProgress()
                            }
                        } else {
                            let safeIndex = min(insertAt, files.count)
                            files.insert(FileItem(url: url), at: safeIndex)
                            insertAt += 1
                        }
                    }
                }
            }
        }
    }


    private func downloadModel(completion: @escaping (Bool) -> Void = { _ in }) {
        guard !isDownloadingModel else { return }
        let token = CancellationToken()
        modelDownloadToken = token
        isDownloadingModel = true
        modelDownloadDetail = "연결 중…"
        let model = selectedModel
        DispatchQueue.global().async {
            var succeeded = false
            let modelURL = URL(fileURLWithPath: model.modelPath)
            do {
                try WhisperModelInstaller.ensureAvailable(at: modelURL, cancellation: token) { received, total in
                    let detail = WhisperModelInstaller.downloadDetail(received: received, total: total)
                    DispatchQueue.main.async { modelDownloadDetail = detail }
                }
                if !WhisperModelInstaller.isVadAvailable(at: WhisperModelInstaller.vadURL(nextTo: modelURL)) {
                    DispatchQueue.main.async { modelDownloadDetail = "음성 구간 감지 모델 준비 중…" }
                    try WhisperModelInstaller.ensureVadAvailable(nextTo: modelURL, cancellation: token)
                }
                succeeded = !token.isCancelled
            } catch {
                if !token.isCancelled { DispatchQueue.main.async { toolChecker.installationError = "모델 다운로드 실패: \(error.localizedDescription)" } }
            }
            let success = succeeded
            DispatchQueue.main.async {
                self.isDownloadingModel = false
                self.modelDownloadToken = nil
                completion(success)
            }
        }
    }

    private func resetOptions() {
        selectedModel = .largev3turbo
        outputMode = .embedInVideo
        language = .auto
        sensitivity = .normal
        subtitleDelay = .none
        selectedTranslations = []
        authMethod = .claudeCode
        translationModel = TranslationModel.defaultModel(for: authMethod)
    }

    private func requeueForChangedOptions() {
        guard !engine.isProcessing else { return }
        FileItem.requeueAfterOptionsChange(&files)
        engine.resetProgress()
    }

    private func startProcessing(applePrepared: Bool = false) {
        #if MAC_APP_STORE
        if !selectedTranslations.isEmpty {
            switch translationProvider {
            case .chatGPT where !chatGPT.canTranslate:
                engine.currentStatus = "번역하려면 ChatGPT 로그인·플랜 사용 권한·모델 선택을 확인해주세요."
                return
            case .apple where !applePrepared:
                guard !appleTranslation.isPreparing else { return }
                engine.currentStatus = "Apple 번역 언어 팩 확인 중..."
                Task {
                    await appleTranslation.prepare(source: language.rawValue, targets: selectedTranslations) { ready in
                        if ready { startProcessing(applePrepared: true) }
                        else { engine.currentStatus = appleTranslation.message ?? "Apple 번역을 준비하지 못했습니다." }
                    }
                }
                return
            default: break
            }
        }
        #endif
        if AppDistribution.isStore, !SandboxFileAccess.shared.authorizeOutputDirectories(for: files.filter { $0.status == .pending }.map(\.url)) {
            engine.currentStatus = "자막을 저장할 입력 폴더의 접근 허용이 필요합니다."
            return
        }
        var options = TranscriptionEngine.Options(
            model: selectedModel.modelPath,
            embedSubtitle: outputMode == .embedInVideo,
            keepSrtFile: outputMode == .srtOnly,
            subtitleDelay: subtitleDelay.seconds,
            sensitivity: sensitivity,
            language: language.rawValue,
            translationTargets: selectedTranslations,
            authMethod: authMethod,
            translationModel: translationModel.rawValue
        )
        #if MAC_APP_STORE
        options.chatGPTAccountID = chatGPT.activeID
        options.chatGPTModel = chatGPT.resolvedModel
        options.translationProvider = translationProvider
        engine.appleLanguagePack = translationProvider == .apple ? { [appleTranslation] source, target, token in
            AppleTranslationCoordinator.waitForLanguagePack(cancellation: token) {
                await appleTranslation.ensureInstalled(source: source, target: target)
            }
        } : nil
        #endif
        engine.process(getFiles: { self.files }, options: options, onFileUpdate: { id, status, elapsed in
            if let index = files.firstIndex(where: { $0.id == id }) {
                files[index].status = status
                if let elapsed { files[index].elapsedTime = elapsed }
            }
        }, onFileProgress: { id, progress in
            if let index = files.firstIndex(where: { $0.id == id }) { files[index].progress = progress }
        }, onTranslationComplete: { id, lang in
            if let index = files.firstIndex(where: { $0.id == id }), !files[index].translatedLangs.contains(lang) {
                files[index].translatedLangs.append(lang)
            }
        }, onFileDetail: { id, detail, phase in
            if let index = files.firstIndex(where: { $0.id == id }) {
                files[index].progressDetail = detail; files[index].phaseProgress = phase
            }
        }, onSourcePrepared: { id, sourceLanguage in
            if let index = files.firstIndex(where: { $0.id == id }) { files[index].sourceLanguage = sourceLanguage }
        })
    }

    #if MAC_APP_STORE
    private var chatGPTOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("번역 방식", selection: $translationProvider) {
                ForEach(TranslationProvider.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if translationProvider == .chatGPT {
                if !chatGPT.accounts.isEmpty {
                    Picker("계정", selection: Binding(get: { chatGPT.activeID ?? "" }, set: { chatGPT.select($0) })) {
                        ForEach(chatGPT.accounts) { account in
                            Text(account.label + (account.signedIn ? "" : " (로그아웃)")).tag(account.id)
                        }
                    }.disabled(chatGPT.busy)
                }
                if chatGPT.active?.signedIn != true || chatGPT.active?.planEnabled != true {
                    Text("번역할 자막 텍스트를 OpenAI로 보냅니다. 음성 전사는 이 Mac에서 처리합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Continue with ChatGPT") { chatGPT.signIn(consent: chatGPT.active?.signedIn == true) }
                        .buttonStyle(.borderedProminent).tint(.primary).disabled(chatGPT.busy)
                    Text("사용 가능한 ChatGPT 플랜이 필요합니다. 앱 자체는 무료입니다.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if chatGPT.isSigningIn {
                    HStack { ProgressView().controlSize(.small); Text("브라우저에서 계정을 선택하고 ChatGPT 플랜 사용을 허용한 뒤 계속을 눌러주세요. 연결은 30분간 기다립니다.").font(.caption)
                        Button("취소") { chatGPT.cancel() } }
                }
                if chatGPT.active?.signedIn == true {
                    HStack {
                        Button("로그아웃") { chatGPT.signOut() }
                        Button("다른 계정 연결") { chatGPT.signIn(newAccount: true) }
                    }.controlSize(.small).disabled(chatGPT.busy)
                }
                if chatGPT.active?.planEnabled == true && chatGPT.active?.signedIn == true {
                    Picker("모델", selection: $chatGPT.selectedModel) {
                        Text("자동").tag("")
                        ForEach(chatGPT.models) { Text($0.display_name).tag($0.slug) }
                    }.disabled(chatGPT.busy || chatGPT.models.isEmpty)
                        .help("자동은 서버 목록의 첫 번째 모델을 사용합니다. 최신 출시 순서나 번역 품질 순위를 뜻하지 않습니다.")
                    HStack {
                        Text("Using ChatGPT plan").font(.caption)
                        Link("Manage usage", destination: ChatGPTAccountController.usageURL).font(.caption)
                        Button { chatGPT.refreshModels() } label: { Image(systemName: "arrow.clockwise") }
                            .help("모델 새로고침 · 사용량 제한 후 다시 시도").disabled(chatGPT.busy)
                    }
                }
                if let error = chatGPT.error {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            } else {
                AppleTranslationOptionsView(coordinator: appleTranslation, source: language.rawValue, targets: selectedTranslations)
            }
            Divider()
            FlowLayout(spacing: 8) {
                ForEach(TranslationLanguage.allCases) { lang in
                    Toggle(lang.label, isOn: Binding(get: { selectedTranslations.contains(lang) },
                        set: { if $0 { selectedTranslations.insert(lang) } else { selectedTranslations.remove(lang) } }))
                        .toggleStyle(.checkbox).font(.body)
                }
            }
            Text(translationProvider == .apple ? "번역 언어를 선택하지 않으면 전사만 합니다." : "번역 언어를 선택하지 않으면 로그인 없이 전사할 수 있습니다.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $chatGPT.showWelcome) {
            VStack(alignment: .leading, spacing: 16) {
                Text("You're using your ChatGPT plan").font(.title2.bold())
                Text("이 앱의 번역 요청은 연결한 ChatGPT 플랜의 사용량 또는 크레딧을 사용합니다. ChatGPT 설정에서 사용량을 관리할 수 있습니다.")
                Link("Manage usage", destination: ChatGPTAccountController.usageURL)
                Button("Got it") { chatGPT.dismissWelcome() }.buttonStyle(.borderedProminent)
            }.padding(24).frame(width: 420)
        }
    }
    #endif
}

// MARK: - Tool Checker

class ToolChecker: ObservableObject {
    @Published var tools: [ToolInfo] = []
    @Published var downloadProgress: Double = 0
    @Published var installationError: String?
    @Published var isInstalling = false
    private var installationToken: CancellationToken?

    func cancelInstall() { installationToken?.cancel() }

    var allInstalled: Bool {
        !tools.isEmpty && tools.allSatisfy { $0.status == .installed }
    }

    struct ToolInfo: Identifiable {
        let id: String
        let name: String
        let description: String
        let installCommand: String
        var status: ToolStatus = .checking
    }

    enum ToolStatus {
        case checking, installed, notInstalled, installing

        var icon: String {
            switch self {
            case .checking: return "questionmark.circle"
            case .installed: return "checkmark.circle.fill"
            case .notInstalled: return "xmark.circle.fill"
            case .installing: return "arrow.down.circle"
            }
        }

        var color: Color {
            switch self {
            case .checking: return .secondary
            case .installed: return .green
            case .notInstalled: return .red
            case .installing: return .blue
            }
        }
    }

    /// App Support bin directory for downloaded binaries
    static var binDir: URL { ToolResolver.binDirectory }

    func checkAll() {
        guard !isInstalling else { return }
        tools = [
            ToolInfo(id: "whisper-cli", name: "whisper-cpp", description: "AI 음성인식 (Metal GPU)", installCommand: "brew install whisper-cpp"),
            ToolInfo(id: "ffmpeg", name: "ffmpeg", description: "오디오 변환 + 자막 내장", installCommand: "brew install ffmpeg"),
        ]

        for i in tools.indices {
            let tool = tools[i]
            DispatchQueue.global().async {
                let installed = self.isInstalled(tool.id)
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        self.tools[i].status = installed ? .installed : .notInstalled
                    }
                }
            }
        }
    }

    func findBinary(_ name: String) -> String? { ToolResolver.find(name) }

    private func isInstalled(_ id: String) -> Bool {
        if id == "ffmpeg" {
            return findBinary("ffmpeg") != nil && findBinary("ffprobe") != nil
        }
        return findBinary(id) != nil
    }

    func install(_ tool: ToolInfo) {
        guard !AppDistribution.isStore else { installationError = "도구는 앱에 포함되어 있습니다. 앱을 다시 설치해주세요."; return }
        guard !isInstalling else { return }
        guard let index = tools.firstIndex(where: { $0.id == tool.id }) else { return }
        isInstalling = true
        installationToken = CancellationToken()
        tools[index].status = .installing

        DispatchQueue.global().async {
            let success = self.downloadTool(tool)

            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.3)) {
                    self.tools[index].status = success ? .installed : .notInstalled
                }
                self.downloadProgress = 0
                self.isInstalling = false
                if !success && self.installationToken?.isCancelled != true && self.installationError == nil { self.installationError = "\(tool.name) 설치 또는 실행 검증에 실패했습니다. 다시 시도해주세요." }
            }
        }
    }

    func installAll(_ missingTools: [ToolInfo], completion: @escaping () -> Void) {
        guard !AppDistribution.isStore else { completion(); return }
        guard !isInstalling else { return }
        isInstalling = true
        installationToken = CancellationToken()
        let work = missingTools.compactMap { tool in tools.firstIndex(where: { $0.id == tool.id }).map { ($0, tool) } }
        DispatchQueue.global().async {
            for (index, tool) in work {
                if self.installationToken?.isCancelled == true { break }
                DispatchQueue.main.sync { self.tools[index].status = .installing }
                let success = self.downloadTool(tool)
                DispatchQueue.main.sync {
                    self.tools[index].status = success ? .installed : .notInstalled
                    self.downloadProgress = 0
                    if !success && self.installationToken?.isCancelled != true && self.installationError == nil {
                        self.installationError = "\(tool.name) 설치 또는 실행 검증에 실패했습니다."
                    }
                }
            }

            DispatchQueue.main.async {
                self.isInstalling = false
                completion()
            }
        }
    }

    private func downloadTool(_ tool: ToolInfo) -> Bool {
        #if MAC_APP_STORE
        return false
        #else
        switch tool.id {
        case "ffmpeg":
            return downloadFfmpeg()
        case "whisper-cli":
            return downloadWhisperCli()
        default:
            return brewInstall(tool.installCommand)
        }
        #endif
    }

    #if !MAC_APP_STORE
    private func brewInstall(_ command: String) -> Bool {
        ProcessRunner.run("/bin/zsh", arguments: ["-c", "export PATH=/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH && \(command)"], timeout: 1800, cancellation: installationToken).succeeded
    }

    /// Download native static binaries; verify hashes and execution before replacement.
    private func downloadFfmpeg() -> Bool {
        for (index, name) in ["ffmpeg", "ffprobe"].enumerated() {
            if installationToken?.isCancelled == true { return false }
            if findBinary(name) != nil { continue }
            let download = FFmpegDistribution.download(name)
            guard downloadAndExtractSingle(url: download.url,
                destPath: Self.binDir.appendingPathComponent(name), binaryName: name,
                sha256: download.sha256, progressRange: (Double(index) / 2, Double(index + 1) / 2)) else { return false }
        }
        return isInstalled("ffmpeg")
    }

    /// Download a prebuilt, signed native Whisper executable.
    private func downloadWhisperCli() -> Bool {
        if findBinary("whisper-cli") != nil { return true }
        guard let token = installationToken else { return false }
        do {
            let download = try WhisperDistribution.download()
            try ToolArchiveInstaller.install(download, to: Self.binDir.appendingPathComponent("whisper-cli"),
                cancellation: token) { progress in
                DispatchQueue.main.async { self.downloadProgress = progress }
            }
            return isInstalled("whisper-cli")
        } catch {
            logDebug("whisper-cli installation failed: \(error)")
            if !token.isCancelled {
                DispatchQueue.main.async { self.installationError = error.localizedDescription }
            }
            return false
        }
    }

    private func runShell(_ command: String) -> Bool {
        ProcessRunner.run("/bin/zsh", arguments: ["-c", command], timeout: 1800, cancellation: installationToken).succeeded
    }

    private func downloadAndExtractSingle(url: URL, destPath: URL, binaryName: String,
                                         sha256: String, progressRange: (Double, Double)) -> Bool {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("ffmpeg-download-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: temp) }
            let archive = temp.appendingPathComponent("download.zip")
            let result = ProcessRunner.run("/usr/bin/curl", arguments: ["-fL", "--connect-timeout", "20", "--max-time", "300", "--retry", "2", url.absoluteString, "-o", archive.path], timeout: 650, cancellation: installationToken)
            guard result.succeeded else { logDebug("Download failed: \(result.diagnostic)"); return false }
            DispatchQueue.main.async { self.downloadProgress = (progressRange.0 + progressRange.1) / 2 }
            let extracted = temp.appendingPathComponent("extracted")
            guard ProcessRunner.run("/usr/bin/unzip", arguments: ["-q", archive.path, "-d", extracted.path], timeout: 60, cancellation: installationToken).succeeded else { return false }
            let candidate = extracted.appendingPathComponent(binaryName)
            let data = try Data(contentsOf: candidate, options: .mappedIfSafe)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard hash == sha256 else { logDebug("\(binaryName): checksum mismatch"); return false }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: candidate.path)
            guard ToolResolver.isUsable(candidate.path) else { logDebug("\(binaryName): native execution check failed"); return false }
            try fm.createDirectory(at: destPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Stage alongside the destination so replacement is atomic on its filesystem.
            guard installationToken?.isCancelled != true else { return false }
            let staged = destPath.deletingLastPathComponent().appendingPathComponent(".\(binaryName)-\(UUID().uuidString)")
            try fm.copyItem(at: candidate, to: staged)
            defer { try? fm.removeItem(at: staged) }
            if fm.fileExists(atPath: destPath.path) {
                try SafeFileReplacement.replace(destPath, with: staged, expected: SafeFileReplacement.Snapshot(destPath))
            } else {
                try fm.moveItem(at: staged, to: destPath)
            }
            DispatchQueue.main.async { self.downloadProgress = progressRange.1 }
            return ToolResolver.isUsable(destPath.path)
        } catch {
            logDebug("\(binaryName) installation failed: \(error)")
            return false
        }
    }
    #endif
}

// MARK: - Tool Row

struct ToolRowView: View {
    let tool: ToolChecker.ToolInfo
    let downloadProgress: Double
    let onInstall: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tool.status.icon)
                .foregroundStyle(tool.status.color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(tool.name)
                    .font(.body.bold())
                Text(tool.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            switch tool.status {
            case .notInstalled:
                if AppDistribution.isStore {
                    Text("앱 도구 누락").foregroundStyle(.red)
                } else {
                    Button("다운로드") { onInstall() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            case .installing:
                if downloadProgress > 0 {
                    ProgressView(value: downloadProgress)
                        .frame(width: 60)
                    Text("\(Int(downloadProgress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 30)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("다운로드 중...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .installed:
                Text("설치됨")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .checking:
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - File Row

struct FileRowView: View {
    let file: FileItem
    var fileEtaText: String = ""

    var body: some View {
        HStack(spacing: 12) {
            if file.isActive {
                ProgressView().progressViewStyle(.circular).controlSize(.small)
                    .frame(width: 20, height: 20).accessibilityLabel("처리 중")
            } else {
                Image(systemName: file.status.icon)
                    .foregroundStyle(file.status.color).font(.title3)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(file.size)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if case .completed(let lang) = file.status {
                        Text(lang.uppercased())
                            .font(.caption.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.1))
                            .clipShape(Capsule())
                    }

                    ForEach(file.translatedLangs, id: \.self) { lang in
                        Text(lang.uppercased())
                            .font(.caption.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.purple.opacity(0.1))
                            .clipShape(Capsule())
                    }

                    if case .cancelled = file.status {
                        Text("중단됨").font(.caption).foregroundStyle(.orange)
                    }
                    if case .skipped = file.status {
                        Text("건너뜀")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if case .failed(let error) = file.status {
                        Text(error)
                            .lineLimit(2)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .help(error)
                    }

                    if let elapsed = file.elapsedTime {
                        Text(formatElapsed(elapsed))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                if file.isActive {
                    Text(file.progressDetail.isEmpty ? "처리 준비 중..." : file.progressDetail)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(file.status.color).lineLimit(2)
                        .help(file.progressDetail)
                }
            }

            Spacer()

            if file.isActive {
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(value: file.phaseProgress ?? file.progress)
                        .frame(width: 70).tint(file.status.color)
                    Text("\(file.phaseProgress == nil ? "전체 " : "단계 ")\(Int((file.phaseProgress ?? file.progress) * 100))%")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.tertiary)
                    if !fileEtaText.isEmpty {
                        Text(fileEtaText).font(.system(size: 9).monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func formatElapsed(_ interval: TimeInterval) -> String {
        let mins = Int(interval) / 60
        let secs = Int(interval) % 60
        return mins > 0 ? "\(mins)분 \(secs)초" : "\(secs)초"
    }
}
