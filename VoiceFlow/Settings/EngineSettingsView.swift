import SwiftUI
import Combine
import FluidAudio

struct EngineSettingsView: View {
    @ObservedObject var settings: AppSettings
    @StateObject private var modelManager = ModelManager.shared
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var modelStorageNote: String?
    @State private var migrationProgress: String?
    @State private var migrationID: UUID?
    @State private var qwenNote: String?
    @State private var qwenProgress: Double = 0
    @State private var qwenOperationRunning = false
    @ObservedObject private var storageActivity = ModelStorageActivity.shared

    var body: some View {
        ScrollView {
            Form {
                Section("Microphone") {
                    Picker("Input Device", selection: Binding(
                        get: { settings.selectedInputDeviceUID ?? "system_default" },
                        set: { settings.selectedInputDeviceUID = $0 == "system_default" ? nil : $0 }
                    )) {
                        Text("System Default").tag("system_default")
                        ForEach(inputDevices) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }

                    Text("Choose which microphone Sonotexta uses for recording. Changes take effect on next dictation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Refresh Devices") {
                        inputDevices = AudioSessionHelper.availableInputDevices()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }

                // 3.13.2-beta.3 — explicit "Active engine" banner. Several
                // beta users reported "I set X but the saved engine is Y" —
                // the issue was that all engine config sections appear below
                // (intentional, so profile overrides have somewhere to live)
                // and it was easy to think editing a section made it active.
                // This banner unambiguously shows what the global default IS
                // right now, separately from the radio group selection.
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Active default engine")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(settings.selectedEngine.displayName)
                                .font(.body)
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Picker("Engine", selection: $settings.selectedEngine) {
                        ForEach(STTEngineType.allCases) { engine in
                            Text(engine.displayName)
                                .tag(engine)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    Text("This is the global default. Individual profiles can override it under Settings → Profiles. The configuration sections below let you set up every engine in advance so any profile can use any of them.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Text("Note: model choices in the sections below are shared by ALL profiles that use that engine — profiles override which engine runs, not its model.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } header: {
                    Text("Default speech-to-text engine")
                }

                // Engine-specific config sections — visible regardless of
                // global selection so profile overrides have a place to set
                // API keys, model variants, etc. Each section's header is
                // tagged "Active" or "Available for profile overrides" so
                // the user always knows what's currently in effect.
                modelStorageSection
                whisperSection
                parakeetSection
                qwenSection
                parakeetRealtimeSection
                openAIRealtimeSection
                deepgramSection
                elevenLabsScribeSection

                engineInfoSection
            }
            .formStyle(.grouped)
            .padding()
        }
        .disabled(storageActivity.isBusy)
        .onAppear {
            inputDevices = AudioSessionHelper.availableInputDevices()
        }
    }

    /// Badge shown next to each engine section header so the user can see at
    /// a glance which engine is the active default vs which are configured
    /// only for profile-level overrides. Fixes a long-standing UX confusion
    /// where users would tweak an engine section and assume it became active.
    @ViewBuilder
    private func engineStatusBadge(for engine: STTEngineType) -> some View {
        if settings.selectedEngine == engine {
            Text("Active")
                .font(.caption2)
                .fontWeight(.semibold)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.green.opacity(0.2))
                .foregroundStyle(.green)
                .clipShape(Capsule())
        } else {
            Text("Profile-override only")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.secondary.opacity(0.15))
                .foregroundStyle(.secondary)
                .clipShape(Capsule())
        }
    }

    /// 3.16.6 — where model weights live (beta-tester request: external
    /// drive instead of the OS disk). Existing models are moved during the
    /// switch so nothing gets re-downloaded.
    private var modelStorageSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ModelStorage.isCustomRootSet ? "Custom folder" : "Default locations")
                    Text(ModelStorage.displayDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Change…") { chooseModelStorageFolder() }
                if ModelStorage.isCustomRootSet {
                    Button("Use Default") { resetModelStorage() }
                }
            }

            if ModelStorage.isCustomRootSet && !ModelStorage.isRootReachable {
                Label("Storage folder not reachable — is the drive connected? Local engines can't load or download models until it's back (nothing is re-downloaded to your system disk).", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let progress = migrationProgress {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.caption)
                }
                Text("Keep the drive connected. You can continue using other apps while models move.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let note = modelStorageNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Applies to Whisper and Parakeet model weights. Use Default moves reachable models back to this Mac. If the drive is disconnected, it switches to default storage; missing models download the next time you use them.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } header: {
            Text("Model Storage")
        }
    }

    private func chooseModelStorageFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose a folder for Sonotexta's model downloads (e.g. on an external drive)."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        migrateModelStorage(to: url)
    }

    private func resetModelStorage() {
        migrateModelStorage(to: nil)
    }

    @MainActor
    private func migrateModelStorage(to newRoot: URL?) {
        let lease: ModelStorageActivity.Lease
        do {
            lease = try storageActivity.beginMigration()
            try ModelStorage.validateRoot(newRoot)
        } catch {
            modelStorageNote = error.localizedDescription
            return
        }
        let oldRoot = ModelStorage.customRoot
        let sourceAvailable = ModelStorage.isRootReachable
        let pairs = sourceAvailable ? ModelStorage.migrationPairs(from: oldRoot, to: newRoot) : []
        let volumeUUID = ModelStorage.volumeUUID(at: newRoot)
        let operationID = UUID()
        migrationID = operationID
        migrationProgress = "Preparing model move…"
        modelStorageNote = nil
        // No load/session can be active while the migration lease is held.
        NotificationCenter.default.post(name: .modelStorageChanged, object: nil)
        Task { @MainActor in
            defer {
                migrationID = nil
                migrationProgress = nil
                withExtendedLifetime(lease) {}
            }
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try ModelStorageMigration.prepare(pairs: pairs) { message in
                        Task { @MainActor in
                            if migrationID == operationID { migrationProgress = message }
                        }
                    }
                }.value
                try ModelStorage.validateRoot(newRoot, expectedVolumeUUID: volumeUUID)
                // Original files still exist until AFTER the new setting is saved.
                settings.modelStorageVolumeUUID = volumeUUID
                settings.modelStoragePath = newRoot?.path
                NotificationCenter.default.post(name: .modelStorageChanged, object: nil)
                migrationProgress = "Removing old model copies…"
                let summary = await Task.detached(priority: .utility) {
                    prepared.removeOriginals()
                }.value
                modelStorageNote = sourceAvailable ? summary : "Previous drive unavailable. Missing models will download to the selected location when you use them."
            } catch {
                modelStorageNote = "Couldn't move models: \(error.localizedDescription) Location unchanged; original models were kept."
            }
        }
    }

    private var whisperSection: some View {
        Group {
            Section {
                Picker("Model Size", selection: $settings.selectedWhisperModel) {
                    ForEach(WhisperModelSize.allCases) { model in
                        HStack {
                            Text(model.displayName)
                            if modelManager.isDownloaded(model) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                            }
                        }
                        .tag(model)
                    }
                }

                Text(settings.selectedWhisperModel.qualityDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Whisper can auto-translate to English when the profile output language is set to English.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } header: {
                HStack {
                    Text("Whisper Model")
                    Spacer()
                    engineStatusBadge(for: .whisper)
                }
            }

            Section("Model Downloads") {
                ForEach(WhisperModelSize.allCases) { model in
                    WhisperModelRow(model: model, modelManager: modelManager)
                }
            }
        }
    }

private var parakeetSection: some View {
    Group {
        Section {
                Picker("Model Version", selection: $settings.selectedParakeetModel) {
                    ForEach(ParakeetModelVersion.allCases) { model in
                        HStack {
                            Text(model.displayName)
                            if ParakeetEngine.isDownloaded(version: model) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                            }
                        }
                        .tag(model)
                    }
                }

                Text(settings.selectedParakeetModel.qualityDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                HStack {
                    Text("Parakeet Model")
                    Spacer()
                    engineStatusBadge(for: .parakeet)
                }
            }

            Section("Parakeet Download") {
                ForEach(ParakeetModelVersion.allCases) { version in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(version.displayName)
                                .font(.body)
                            Text(version.qualityDescription)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if ParakeetEngine.isDownloaded(version: version) {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                if let size = ParakeetEngine.sizeOnDisk(version: version) {
                                    Text("Ready (\(size))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("Ready")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Button(role: .destructive) {
                                    ParakeetEngine.deleteModel(version: version)
                                    // Force the view to re-evaluate isDownloaded so the row
                                    // flips back to the Download state without the user
                                    // needing to close + reopen Settings.
                                    modelManager.objectWillChange.send()
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                            }
                        } else if modelManager.downloadingModel == "parakeet-\(version.rawValue)" {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                VStack(alignment: .leading) {
                                    Text("Downloading & compiling...")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("Elapsed: \(modelManager.formatElapsed(modelManager.downloadElapsed))")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .monospacedDigit()
                                }
                            }
                        } else {
                            Button("Download") {
                                downloadParakeet(version: version)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, 2)
                }

                Text("Parakeet transcribes in the spoken language. Use a profile with a different output language to enable translation via Apple Translate.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var qwenSection: some View {
        Section {
            Text("Qwen3-ASR 0.6B · Experimental")
                .font(.headline)
            Text("Runs locally after the initial download (allow approximately 4 GB of disk space). No API key or transcription fee. Supports 30 languages, including German. Text appears after you stop dictating.")
                .font(.caption).foregroundStyle(.secondary)
            Text("This CoreML conversion is experimental and may be less accurate than the original Qwen model. Review longer transcripts carefully: this version can insert extra words near chunk boundaries.")
                .font(.caption).foregroundStyle(.secondary)
            if qwenOperationRunning {
                ProgressView(value: qwenProgress)
                Text(qwenProgress >= 1 ? "Loading model…" : "Downloading model…")
                    .font(.caption)
            } else {
                HStack {
                    if QwenEngine.isDownloaded {
                        Label("Downloaded", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Delete model", role: .destructive) {
                            do {
                                try QwenEngine().deleteModel()
                                NotificationCenter.default.post(name: .modelStorageChanged, object: nil)
                                modelManager.objectWillChange.send()
                                qwenNote = nil
                            } catch { qwenNote = error.localizedDescription }
                        }
                    } else {
                        Button("Download Qwen3-ASR") { downloadQwen() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            if let note = qwenNote {
                Text(note).font(.caption).foregroundStyle(.red)
            }
        } header: {
            HStack {
                Text("Qwen3-ASR")
                Spacer()
                engineStatusBadge(for: .qwen)
            }
        }
    }

    private func downloadQwen() {
        qwenOperationRunning = true
        qwenProgress = 0
        qwenNote = nil
        Task { @MainActor in
            defer {
                qwenOperationRunning = false
                modelManager.objectWillChange.send()
            }
            do {
                try await QwenEngine().loadModel { progress in
                    Task { @MainActor in qwenProgress = min(1, progress.fractionCompleted * 2) }
                }
            } catch { qwenNote = "Qwen download failed: \(error.localizedDescription)" }
        }
    }

    private var openAIRealtimeSection: some View {
        Group {
            Section {
                Picker("Quality Mode", selection: $settings.selectedOpenAIRealtimeModel) {
                    ForEach(OpenAIRealtimeModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }

                Text(settings.selectedOpenAIRealtimeModel.qualityDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !LLMService.shared.hasAPIKey {
                    Label {
                        Text("OpenAI API key required. Add one in the Connections tab.")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                } else {
                    Label {
                        Text("API key configured — ready to use.")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                Text("Streams audio to OpenAI for real-time transcription. Auto-detects language. No model download needed. Requires internet connection. Your Vocabulary terms (AI & Language tab) are sent as free keyword hints to improve recognition.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } header: {
                HStack {
                    Text("OpenAI Realtime Transcription")
                    Spacer()
                    engineStatusBadge(for: .openAIRealtime)
                }
            }
        }
    }

    private var deepgramSection: some View {
        Group {
            Section {
                Picker("Model", selection: $settings.selectedDeepgramModel) {
                    ForEach(DeepgramModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }

                Text(settings.selectedDeepgramModel.qualityDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // API Key inline
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        SecureField("Deepgram API key", text: Binding(
                            get: { deepgramKeyInput },
                            set: { deepgramKeyInput = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))

                        if let engine = dictationManagerForKey {
                            if engine.apiKey != nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }

                        Button("Save") {
                            DeepgramEngine().apiKey = deepgramKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            deepgramTestStatus = nil
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(deepgramKeyInput.isEmpty)

                        Button {
                            testDeepgramKey()
                        } label: {
                            HStack(spacing: 4) {
                                if isTestingDeepgram { ProgressView().scaleEffect(0.6) }
                                Text("Test")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled((DeepgramEngine().apiKey ?? deepgramKeyInput).isEmpty || isTestingDeepgram)
                    }

                    if let status = deepgramTestStatus {
                        Label(status, systemImage: status.hasPrefix("✓") ? "checkmark.circle" : "xmark.circle")
                            .font(.caption)
                            .foregroundStyle(status.hasPrefix("✓") ? .green : .red)
                    }

                    Text("Get your key at console.deepgram.com — free $200 credit on signup.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Text("Streams audio to Deepgram for real-time transcription. 10 languages with code-switching. No model download needed.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } header: {
                HStack {
                    Text("Deepgram Streaming Transcription")
                    Spacer()
                    engineStatusBadge(for: .deepgram)
                }
            }
        }
    }

    @State private var deepgramKeyInput: String = DeepgramEngine().apiKey ?? ""
    private var dictationManagerForKey: DeepgramEngine? { DeepgramEngine() }
    @State private var deepgramTestStatus: String?
    @State private var isTestingDeepgram = false

    @State private var scribeKeyInput: String = ElevenLabsScribeRealtimeEngine().apiKey ?? ""
    @State private var scribeTestStatus: String?
    @State private var isTestingScribe = false

    private var elevenLabsScribeSection: some View {
        Group {
            Section {
                Picker("Model", selection: $settings.selectedElevenLabsScribeModel) {
                    ForEach(ElevenLabsScribeModel.allCases) { model in
                        Text(model.displayName).tag(model)
                    }
                }

                Text(settings.selectedElevenLabsScribeModel.qualityDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // API Key inline (same pattern as Deepgram)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        SecureField("ElevenLabs API key", text: $scribeKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))

                        if ElevenLabsScribeRealtimeEngine().apiKey != nil {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }

                        Button("Save") {
                            ElevenLabsScribeRealtimeEngine().apiKey = scribeKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            scribeTestStatus = nil
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(scribeKeyInput.isEmpty)

                        Button {
                            testElevenLabsKey()
                        } label: {
                            HStack(spacing: 4) {
                                if isTestingScribe { ProgressView().scaleEffect(0.6) }
                                Text("Test")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled((ElevenLabsScribeRealtimeEngine().apiKey ?? scribeKeyInput).isEmpty || isTestingScribe)
                    }

                    if let status = scribeTestStatus {
                        Label(status, systemImage: status.hasPrefix("✓") ? "checkmark.circle" : "xmark.circle")
                            .font(.caption)
                            .foregroundStyle(status.hasPrefix("✓") ? .green : .red)
                    }

                    Text("Get your key at elevenlabs.io — Scribe v2 Realtime is ~$0.39/hr (~$0.0065/min).")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // Opt-in keyterm biasing — off by default. Adds 20% to per-minute cost.
                Toggle("Bias model with Vocabulary terms (+20% cost)", isOn: $settings.elevenLabsScribeUseKeyterms)

                Text("When on, your Vocabulary glossary (up to 50 terms, 20 chars each) is sent to Scribe so the model itself is biased toward those terms while transcribing — better than only fixing them in AI cleanup afterwards. ElevenLabs adds a 20% premium to the per-minute cost when this is enabled.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Text("Streams audio to ElevenLabs Scribe v2 Realtime — ~150ms latency, 90+ languages, no model download needed.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } header: {
                HStack {
                    Text("ElevenLabs Scribe Realtime")
                    Spacer()
                    engineStatusBadge(for: .elevenLabsScribe)
                }
            }
        }
    }

    private var engineInfoSection: some View {
        Section("Engine Comparison") {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    VStack(alignment: .leading) {
                        Text("Apple Speech").fontWeight(.medium)
                        Text("Built-in, ~20 languages. No download.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "apple.logo").foregroundStyle(.primary)
                }

                Label {
                    VStack(alignment: .leading) {
                        Text("OpenAI Whisper").fontWeight(.medium)
                        Text("99+ languages. Can translate to English. Multiple model sizes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "waveform").foregroundStyle(.blue)
                }

                Label {
                    VStack(alignment: .leading) {
                        Text("NVIDIA Parakeet TDT").fontWeight(.medium)
                        Text("Ultra-fast. 25 European languages. Best for Bulgarian, Czech, etc.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "bolt.fill").foregroundStyle(.green)
                }

                Label {
                    VStack(alignment: .leading) {
                        Text("OpenAI Realtime").fontWeight(.medium)
                        Text("Streaming cloud transcription. Auto-detects 98+ languages. Requires API key.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(.purple)
                }

                Label {
                    VStack(alignment: .leading) {
                        Text("Deepgram Nova-3").fontWeight(.medium)
                        Text("Streaming cloud transcription. 10 languages with real-time code-switching.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "waveform.path").foregroundStyle(.cyan)
                }

                Label {
                    VStack(alignment: .leading) {
                        Text("ElevenLabs Scribe v2 Realtime").fontWeight(.medium)
                        Text("Streaming cloud transcription. 90+ languages, ~150ms latency. Optional keyterm biasing from Vocabulary.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "waveform.badge.mic").foregroundStyle(.orange)
                }
            }
        }
    }

    private func testDeepgramKey() {
        let key = (DeepgramEngine().apiKey ?? deepgramKeyInput).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        isTestingDeepgram = true
        deepgramTestStatus = nil
        Task {
            var req = URLRequest(url: URL(string: "https://api.deepgram.com/v1/auth/token")!)
            req.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
            let status: Int
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            } catch {
                await MainActor.run {
                    deepgramTestStatus = "✗ Network error: \(error.localizedDescription)"
                    isTestingDeepgram = false
                }
                return
            }
            await MainActor.run {
                deepgramTestStatus = status == 200 ? "✓ Key valid" : "✗ Invalid key (HTTP \(status))"
                isTestingDeepgram = false
            }
        }
    }

    private func testElevenLabsKey() {
        let key = (ElevenLabsScribeRealtimeEngine().apiKey ?? scribeKeyInput).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        isTestingScribe = true
        scribeTestStatus = nil
        Task {
            var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/user")!)
            req.setValue(key, forHTTPHeaderField: "xi-api-key")
            let status: Int
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            } catch {
                await MainActor.run {
                    scribeTestStatus = "✗ Network error: \(error.localizedDescription)"
                    isTestingScribe = false
                }
                return
            }
            await MainActor.run {
                scribeTestStatus = status == 200 ? "✓ Key valid" : "✗ Invalid key (HTTP \(status))"
                isTestingScribe = false
            }
        }
    }

private func downloadParakeet(version: ParakeetModelVersion = .v3) {
    Task {
        await MainActor.run {
            modelManager.downloadingModel = "parakeet-\(version.rawValue)"
                modelManager.downloadStartTime = Date()
                modelManager.downloadElapsed = 0
            }
            // Temporarily set the version and trigger download
            let previousVersion = AppSettings.shared.selectedParakeetModel
            await MainActor.run { AppSettings.shared.selectedParakeetModel = version }
            let tempEngine = ParakeetEngine()
            do {
                try await tempEngine.loadModel()
                await MainActor.run {
                    AppSettings.shared.selectedParakeetModel = previousVersion
                    modelManager.downloadingModel = nil
                }
            } catch {
                print("[VoiceFlow] Parakeet \(version.rawValue) download failed: \(error)")
                await MainActor.run {
                    AppSettings.shared.selectedParakeetModel = previousVersion
                    modelManager.downloadingModel = nil
                }
            }
        }
    }

    private func downloadParakeetRealtime(chunkSize: ParakeetRealtimeChunkSize = .ms160) {
        Task {
            await MainActor.run {
                modelManager.downloadingModel = "parakeet-realtime-\(chunkSize.rawValue)"
                modelManager.downloadStartTime = Date()
                modelManager.downloadElapsed = 0
            }
            let previousChunkSize = AppSettings.shared.selectedParakeetRealtimeChunkSize
            await MainActor.run { AppSettings.shared.selectedParakeetRealtimeChunkSize = chunkSize }
            let tempEngine = ParakeetRealtimeEngine()
            do {
                try await tempEngine.loadModel()
                await MainActor.run {
                    AppSettings.shared.selectedParakeetRealtimeChunkSize = previousChunkSize
                    modelManager.downloadingModel = nil
                }
            } catch {
                print("[VoiceFlow] Parakeet Live \(chunkSize.rawValue) download failed: \(error)")
                await MainActor.run {
                    AppSettings.shared.selectedParakeetRealtimeChunkSize = previousChunkSize
                    modelManager.downloadingModel = nil
                }
            }
        }
    }

    private var parakeetRealtimeSection: some View {
        Group {
            Section {
                Picker("Chunk Size", selection: $settings.selectedParakeetRealtimeChunkSize) {
                    ForEach(ParakeetRealtimeChunkSize.allCases) { chunkSize in
                        HStack {
                            Text(chunkSize.displayName)
                            if ParakeetRealtimeEngine.isDownloaded(chunkSize: chunkSize) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green).font(.caption)
                            }
                        }.tag(chunkSize)
                    }
                }
                Text(settings.selectedParakeetRealtimeChunkSize.qualityDescription)
                    .font(.caption).foregroundStyle(.secondary)

                Text("Tip: Parakeet Live outputs lowercase text without punctuation. Enable AI processing in your profile (Profiles tab) to add capitalization and punctuation automatically.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } header: {
                HStack {
                    Text("Parakeet Live Model")
                    Spacer()
                    engineStatusBadge(for: .parakeetRealtime)
                }
            }
            Section("Parakeet Live Download") {
                ForEach(ParakeetRealtimeChunkSize.allCases) { chunkSize in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(chunkSize.displayName).font(.body)
                            Text(chunkSize.qualityDescription).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if ParakeetRealtimeEngine.isDownloaded(chunkSize: chunkSize) {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                if let size = ParakeetRealtimeEngine.sizeOnDisk(chunkSize: chunkSize) {
                                    Text("Ready (\(size))").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text("Ready").font(.caption).foregroundStyle(.secondary)
                                }
                                Button(role: .destructive) {
                                    ParakeetRealtimeEngine.deleteModel(chunkSize: chunkSize)
                                    modelManager.objectWillChange.send()
                                } label: { Image(systemName: "trash").font(.caption) }
                                .buttonStyle(.borderless)
                            }
                        } else if modelManager.downloadingModel == "parakeet-realtime-\(chunkSize.rawValue)" {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                VStack(alignment: .leading) {
                                    Text("Downloading & compiling...").font(.caption).foregroundStyle(.secondary)
                                    Text("Elapsed: \(modelManager.formatElapsed(modelManager.downloadElapsed))")
                                        .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                                }
                            }
                        } else {
                            Button("Download") { downloadParakeetRealtime(chunkSize: chunkSize) }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                        }
                    }
                    .padding(.vertical, 2)
                }
                Text("English-only. ~240MB local model. Smaller and faster than Parakeet TDT v3. For multilingual dictation, use Parakeet TDT v3 or Whisper.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

struct WhisperModelRow: View {
    let model: WhisperModelSize
    @ObservedObject var modelManager: ModelManager
    @State private var isDownloading = false
    @State private var error: String?

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(model.displayName)
                    .font(.body)
                Text(model.qualityDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if modelManager.isDownloaded(model) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    if let size = modelManager.modelSizeOnDisk(model) {
                        Text("Ready (\(size))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Ready")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button(role: .destructive) {
                        modelManager.deleteModel(model)
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            } else if modelManager.downloadingModel == model.rawValue {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading) {
                        Text("Downloading & compiling...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Elapsed: \(modelManager.formatElapsed(modelManager.downloadElapsed))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
            } else {
                Button("Download") {
                    download()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 2)

        if let error {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func download() {
        isDownloading = true
        error = nil
        Task {
            do {
                try await modelManager.downloadModel(model)
                await MainActor.run { isDownloading = false }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    isDownloading = false
                }
            }
        }
    }
}
