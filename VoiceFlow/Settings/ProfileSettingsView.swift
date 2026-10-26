import SwiftUI
import AppKit
import ApplicationServices
import UniformTypeIdentifiers

struct ProfileSettingsView: View {
    @ObservedObject var settings: AppSettings
    @State private var selectedProfileID: UUID?

    var body: some View {
        HSplitView {
            // Profile list
            VStack(alignment: .leading, spacing: 0) {
                List(selection: $selectedProfileID) {
                    ForEach(settings.profiles) { profile in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(profile.name)
                                    .fontWeight(profile.isDefault ? .semibold : .regular)
                                let uniqueApps = Array(Set(profile.detectionRules.map { $0.appBundleIdentifier }.filter { !$0.isEmpty }))
                                if !uniqueApps.isEmpty {
                                    Text(uniqueApps.map { displayNameForBundleId($0) }.sorted().joined(separator: ", "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if profile.isDefault {
                                Text("Default")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.blue.opacity(0.2))
                                    .clipShape(Capsule())
                            }
                        }
                        .tag(profile.id)
                    }
                }
                .listStyle(.sidebar)

                Divider()

                HStack {
                    Button(action: addProfile) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)

                    Button(action: deleteSelectedProfile) {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedProfileID == nil || (selectedProfile?.isDefault == true && settings.profiles.filter(\.isDefault).count <= 1))

                    Spacer()
                }
                .padding(8)
            }
            .frame(minWidth: 160, idealWidth: 190, maxWidth: 220)

            // Profile detail
            if let profile = selectedProfile, let index = selectedProfileIndex {
                ProfileDetailView(profile: $settings.profiles[index])
                    .id(profile.id)
            } else {
                VStack {
                    Image(systemName: "person.crop.circle")
                        .font(.largeTitle)
                        .foregroundStyle(.quaternary)
                    Text("Select a profile")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
    }

    private var selectedProfile: Profile? {
        settings.profiles.first(where: { $0.id == selectedProfileID })
    }

    private var selectedProfileIndex: Int? {
        settings.profiles.firstIndex(where: { $0.id == selectedProfileID })
    }

    private func addProfile() {
        let profile = Profile(
            name: "New Profile",
            detectionRules: [DetectionRule(appBundleIdentifier: "", contactFilter: "")],
            outputLanguageCode: "en",
            tonePrompt: ""
        )
        settings.profiles.append(profile)
        selectedProfileID = profile.id
    }

    private func deleteSelectedProfile() {
        guard let id = selectedProfileID,
              let index = settings.profiles.firstIndex(where: { $0.id == id }) else { return }

        let profile = settings.profiles[index]

        // Always keep at least one default profile
        if profile.isDefault {
            let defaultCount = settings.profiles.filter(\.isDefault).count
            guard defaultCount > 1 else { return }
        }

        settings.profiles.remove(at: index)
        selectedProfileID = settings.profiles.first?.id
    }
}

struct ProfileDetailView: View {
    @Binding var profile: Profile

    static let commonApps: [(name: String, bundleId: String)] = [
        ("Microsoft Teams", "com.microsoft.teams2"),
        ("iMessage", "com.apple.MobileSMS"),
        ("Slack", "com.tinyspeck.slackmacgap"),
        ("Telegram", "ru.keepcoder.Telegram"),
        ("WhatsApp", "net.whatsapp.WhatsApp"),
        ("Discord", "com.hnc.Discord"),
        ("Mail", "com.apple.mail"),
        ("Notes", "com.apple.Notes"),
        ("Safari", "com.apple.Safari"),
        ("Chrome", "com.google.Chrome"),
        ("VS Code", "com.microsoft.VSCode"),
        ("Outlook", "com.microsoft.Outlook"),
    ]

    private var resolvedEngine: STTEngineType {
        profile.engineOverride ?? AppSettings.shared.selectedEngine
    }

    @ViewBuilder
    private var translationBackendBadge: some View {
        let hasDeepL = TranslationService.shared.hasDeepL
        let isRealtimeWithLive = (resolvedEngine == .openAIRealtime) && profile.translateNatively
        if isRealtimeWithLive {
            StatusBadge(status: .configured, label: "OpenAI Realtime (live)")
        } else if hasDeepL {
            StatusBadge(status: .configured, label: "DeepL")
        } else {
            StatusBadge(status: .unknown, label: "Apple Translate")
        }
    }

    private var translationBackendRow: some View {
        HStack(spacing: 8) {
            Text("Translation backend:")
                .font(.callout)
                .foregroundStyle(.secondary)
            translationBackendBadge
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // Profile Name
                GroupBox("Profile") {
                    TextField("Name", text: $profile.name)
                        .textFieldStyle(.roundedBorder)
                }

                // Detection Rules (replaces single Target App + Contact Filter)
                GroupBox("App & Contact Detection") {
                    VStack(alignment: .leading, spacing: 10) {
                        if profile.isDefault {
                            Label("Default profile — matches all apps and contacts not covered by other profiles.", systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        // Group detection rules by app so the user can attach multiple
                        // contacts to one profile within the same app (e.g. Filip,
                        // Markus, Andreas all using this profile in Teams) without
                        // creating a separate profile per contact.
                        ForEach(appGroups(for: profile), id: \.groupID) { group in
                            AppGroupCard(
                                profile: $profile,
                                group: group
                            )
                        }

                        Button {
                            profile.detectionRules.append(DetectionRule(appBundleIdentifier: "", contactFilter: ""))
                        } label: {
                            Label("Add App", systemImage: "plus.circle")
                                .font(.callout)
                        }
                        .buttonStyle(.borderless)

                        if !profile.isDefault && profile.detectionRules.isEmpty {
                            Label("Add at least one app to activate this profile. Without detection rules, this profile won't be used.", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        Text("Add multiple apps to use the same language and AI settings across iMessage, Teams, Slack, etc. Each app can have its own contact name to match.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                // Engine Override
                GroupBox("Speech Engine") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Engine", selection: Binding(
                            get: { profile.engineOverride?.rawValue ?? "global" },
                            set: { newValue in
                                profile.engineOverride = newValue == "global" ? nil : STTEngineType(rawValue: newValue)
                            }
                        )) {
                            Text("Use global setting (\(AppSettings.shared.selectedEngine.displayName))").tag("global")
                            ForEach(STTEngineType.allCases) { engine in
                                Text(engine.displayName).tag(engine.rawValue)
                            }
                        }
                        .labelsHidden()

                        if let override = profile.engineOverride {
                            Text("This profile will use \(override.displayName) regardless of the global engine setting.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Input Language
                GroupBox("Input Language (what you speak)") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("You speak", selection: $profile.inputLanguageCode) {
                            ForEach(Profile.inputLanguages, id: \.code) { lang in
                                Text(lang.name).tag(lang.code)
                            }
                        }
                        .labelsHidden()

                        if profile.inputLanguageCode == "auto" {
                            Text("The speech engine will auto-detect your language. Set a specific language for better accuracy on short dictations.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            let langName = Profile.inputLanguages.first(where: { $0.code == profile.inputLanguageCode })?.name ?? profile.inputLanguageCode
                            Text("Speech engine and AI will expect \(langName). This improves accuracy, especially for short phrases.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Output Language
                GroupBox("Output Language (what gets typed)") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Translate to", selection: $profile.outputLanguageCode) {
                            ForEach(Profile.supportedLanguages, id: \.code) { lang in
                                Text(lang.translationAvailable || lang.code == "auto" ? lang.name : "\(lang.name) (AI only)")
                                    .tag(lang.code)
                            }
                        }
                        .labelsHidden()

                        if profile.outputLanguageCode == "auto" {
                            Text("Text will be output in the same language you speak. No translation.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if let selected = Profile.supportedLanguages.first(where: { $0.code == profile.outputLanguageCode }) {
                            if !selected.translationAvailable {
                                Label("This language requires AI post-processing — enable it below and configure an API key in the Connections tab.", systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            } else {
                                // Show which translation backend is active so the user
                                // understands what fires when translateNatively is off.
                                if TranslationService.shared.hasDeepL {
                                    Label("Translation uses DeepL (your key is configured in the Connections tab). Fast, high quality, works on any macOS version.", systemImage: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                } else {
                                    Text("Translation uses Apple Translate (on-device, requires macOS 26). Add a DeepL API key in the Connections tab for higher quality translation on any macOS version.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        if profile.outputLanguageCode != "auto" && profile.outputLanguageCode != "en" {
                            translationBackendRow
                        }

                        if resolvedEngine == .openAIRealtime {
                            Toggle("Translate live via OpenAI Realtime (low-latency)", isOn: $profile.translateNatively)
                                .help("Only applies when the OpenAI Realtime engine is active. Translation happens inside the audio stream — ~1–2s lower latency than the DeepL/Apple Translate path. When off (or using any other engine), translation uses DeepL if a key is configured, otherwise Apple Translate. ~$0.034/min while active.")
                        }
                    }
                }

                // AI Post-Processing
                GroupBox("AI Post-Processing") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Process with AI", isOn: $profile.aiPostProcessing)

                        Text("Send transcription to an AI model for cleanup, translation, and styling. Configure a provider in the AI & Language tab — use Ollama for free local processing or any cloud provider with your own API key.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if profile.aiPostProcessing && !LLMService.shared.hasAPIKey {
                            Label("No AI provider ready. Go to the AI & Language tab and either select Ollama (free, local) or add an API key for a cloud provider.", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }

                        if profile.aiPostProcessing {
                            Divider()

                            Text("Enhancement Preset")
                                .font(.caption)
                                .fontWeight(.medium)

                            PresetPicker(profile: $profile)
                        }
                    }
                }

            }
            .padding()
        }
    }
}

// MARK: - Detection Rule Row

/// A logical "group" derived from a profile's flat detectionRules array — one entry
/// per (app, list-of-contacts) cluster. Pure presentation concept; the underlying
/// model stays a flat `[DetectionRule]`.
struct AppRuleGroup: Hashable {
    /// Stable id for SwiftUI ForEach. For non-empty bundle IDs we key by the
    /// bundleId so the group survives re-renders. For empty (pending) entries
    /// we key by the first rule's UUID so each empty group stays distinct.
    let groupID: String
    let appBundleIdentifier: String
    /// IDs of the rules in this group, in encounter order from detectionRules.
    /// Resolved to bindings at render time via firstIndex(where: id ==) lookups.
    let ruleIDs: [UUID]
}

private func appGroups(for profile: Profile) -> [AppRuleGroup] {
    var groups: [AppRuleGroup] = []
    for rule in profile.detectionRules {
        if rule.appBundleIdentifier.isEmpty {
            // Each unselected entry is its own pending group keyed by rule id.
            groups.append(AppRuleGroup(
                groupID: "empty-\(rule.id.uuidString)",
                appBundleIdentifier: "",
                ruleIDs: [rule.id]
            ))
        } else if let existingIdx = groups.firstIndex(where: { $0.appBundleIdentifier == rule.appBundleIdentifier }) {
            // Merge into the existing group for this app.
            let existing = groups[existingIdx]
            groups[existingIdx] = AppRuleGroup(
                groupID: existing.groupID,
                appBundleIdentifier: existing.appBundleIdentifier,
                ruleIDs: existing.ruleIDs + [rule.id]
            )
        } else {
            groups.append(AppRuleGroup(
                groupID: rule.appBundleIdentifier,
                appBundleIdentifier: rule.appBundleIdentifier,
                ruleIDs: [rule.id]
            ))
        }
    }
    return groups
}

private func displayNameForBundleId(_ bundleId: String) -> String {
    if let common = ProfileDetailView.commonApps.first(where: { $0.bundleId == bundleId })?.name {
        return common
    }
    if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }),
       let name = running.localizedName {
        return name
    }
    return bundleId
}

/// Build the dynamic app list shown in the picker:
/// - All hardcoded common apps (priority order, recognizable names)
/// - All currently running user-visible apps (so Obsidian, Linear, anything else
///   the user has open right now is selectable without typing a bundle ID)
/// - The currently-selected bundle ID even if neither hardcoded nor running
///   (so a saved profile referencing an app that's not running and not in
///    commonApps still displays correctly)
/// De-duped by bundle ID; sorted by display name.
private func availableApps(includingBundleId: String) -> [(name: String, bundleId: String)] {
    var apps: [String: String] = [:]
    for app in ProfileDetailView.commonApps {
        apps[app.bundleId] = app.name
    }
    for app in NSWorkspace.shared.runningApplications {
        guard app.activationPolicy != .prohibited,
              let bid = app.bundleIdentifier,
              !bid.isEmpty,
              bid != Bundle.main.bundleIdentifier
        else { continue }
        if apps[bid] == nil {
            apps[bid] = app.localizedName ?? bid
        }
    }
    if !includingBundleId.isEmpty, apps[includingBundleId] == nil {
        apps[includingBundleId] = includingBundleId
    }
    return apps
        .map { (name: $0.value, bundleId: $0.key) }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

/// Open NSOpenPanel filtered to .app bundles in /Applications.
/// Returns the bundle identifier of the chosen app, or nil if cancelled.
private func browseForApplication() -> String? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.application]
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.message = "Choose an application to add to this profile"
    panel.prompt = "Choose"
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return Bundle(url: url)?.bundleIdentifier
}

/// One app group card: app picker at top, list of contact filter rows underneath,
/// "Add another contact" button, delete-the-whole-group button.
struct AppGroupCard: View {
    @Binding var profile: Profile
    let group: AppRuleGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // Dynamic list: common apps + currently running apps (so e.g.
                // Obsidian shows up if it's open) + the currently-selected
                // bundle ID for back-compat with saved profiles.
                Picker("App", selection: appBundleBinding) {
                    Text("Select an app...").tag("")
                    ForEach(availableApps(includingBundleId: group.appBundleIdentifier), id: \.bundleId) { app in
                        Text(app.name).tag(app.bundleId)
                    }
                }
                .labelsHidden()

                // Browse the Applications folder for any .app not in the picker.
                Button {
                    if let bundleId = browseForApplication() {
                        appBundleBinding.wrappedValue = bundleId
                    }
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 14))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Browse the Applications folder for any installed app")

                Spacer()

                // Delete the whole group (all contact rules for this app).
                Button {
                    profile.detectionRules.removeAll { rule in
                        group.ruleIDs.contains(rule.id)
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .help("Remove this app and all its contacts from this profile")
            }

            // Contact rows
            ForEach(group.ruleIDs, id: \.self) { ruleID in
                if let idx = profile.detectionRules.firstIndex(where: { $0.id == ruleID }) {
                    ContactRow(
                        rule: $profile.detectionRules[idx],
                        canDelete: group.ruleIDs.count > 1,
                        onDelete: {
                            profile.detectionRules.removeAll { $0.id == ruleID }
                        }
                    )
                }
            }

            // Add another contact within this same app.
            Button {
                profile.detectionRules.append(
                    DetectionRule(appBundleIdentifier: group.appBundleIdentifier, contactFilter: "")
                )
            } label: {
                Label("Add another contact", systemImage: "plus.circle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(group.appBundleIdentifier.isEmpty)
            .help(group.appBundleIdentifier.isEmpty
                  ? "Pick an app first"
                  : "Add another contact filter for this app")
        }
        .padding(10)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Binding that, when written, updates `appBundleIdentifier` on every rule in
    /// this group. So changing the app picker rewires all that group's contacts
    /// to the new app at once.
    private var appBundleBinding: Binding<String> {
        Binding(
            get: { group.appBundleIdentifier },
            set: { newValue in
                for ruleID in group.ruleIDs {
                    if let idx = profile.detectionRules.firstIndex(where: { $0.id == ruleID }) {
                        profile.detectionRules[idx].appBundleIdentifier = newValue
                    }
                }
            }
        )
    }
}

/// Single contact-filter input within an app group.
struct ContactRow: View {
    @Binding var rule: DetectionRule
    let canDelete: Bool
    var onDelete: () -> Void

    @State private var detectedTitles: [String] = []
    @State private var showingTitlePicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Contact name (optional, leave blank to match any chat)", text: $rule.contactFilter)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)

                Button("Detect") {
                    let titles = detectWindowTitles(for: rule.appBundleIdentifier)
                    if titles.count == 1 {
                        rule.contactFilter = titles[0]
                    } else if titles.count > 1 {
                        detectedTitles = titles
                        showingTitlePicker = true
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(rule.appBundleIdentifier.isEmpty)
                .help("Open the target app first, then click Detect")
                .popover(isPresented: $showingTitlePicker) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Select a window title:")
                            .font(.caption)
                            .fontWeight(.medium)
                            .padding(.bottom, 4)
                        ForEach(detectedTitles, id: \.self) { title in
                            Button(title) {
                                rule.contactFilter = title
                                showingTitlePicker = false
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 2)
                            .padding(.horizontal, 4)
                        }
                    }
                    .padding(8)
                    .frame(minWidth: 200)
                }

                // Per-contact delete. Hidden when there's only one contact in
                // the group — deleting the last contact would leave an empty
                // group; use the group-level delete instead.
                if canDelete {
                    Button(action: onDelete) {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this contact from the profile")
                }
            }

            if !rule.contactFilter.isEmpty {
                Text("Matches when window title contains: \"\(rule.contactFilter)\"")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
        }
    }

    private func detectWindowTitles(for bundleId: String) -> [String] {
        guard !bundleId.isEmpty,
              let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) else {
            return []
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowList: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowList) == .success,
              let windows = windowList as? [AXUIElement] else { return [] }

        var titles: [String] = []
        for window in windows {
            var title: AnyObject?
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
               let windowTitle = title as? String, !windowTitle.isEmpty {
                let cleaned = windowTitle
                    .replacingOccurrences(of: " | Microsoft Teams", with: "")
                    .replacingOccurrences(of: " - Chat | Microsoft Teams", with: "")
                    .replacingOccurrences(of: " — ", with: " - ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    titles.append(cleaned)
                }
            }
        }
        return titles
    }
}


// MARK: - Preset Picker (built-ins + global custom presets)

/// Selection identity for the AI preset picker.
/// Distinguishes built-in cases from user-defined presets (UUID) and the
/// 'Add new custom…' sentinel.
enum PresetSelection: Hashable {
    case builtIn(AIPreset)
    case custom(UUID)
    case newCustom
}

struct PresetPicker: View {
    @Binding var profile: Profile
    @ObservedObject private var settings = AppSettings.shared

    @State private var editingPreset: CustomPreset?
    @State private var creatingNew = false

    private var currentSelection: PresetSelection {
        if let preset = profile.aiPreset, preset != .custom {
            return .builtIn(preset)
        }
        if let id = profile.customPresetID,
           settings.customPresets.contains(where: { $0.id == id }) {
            return .custom(id)
        }
        // Default fallback when nothing is set yet.
        return .builtIn(profile.aiPreset ?? .cleanCorrect)
    }

    /// Built-ins minus the legacy '.custom' option — custom is now its own
    /// section listing user presets by name + a 'New custom…' button.
    private var builtInPresets: [AIPreset] {
        AIPreset.allCases.filter { $0 != .custom }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Preset", selection: Binding(
                get: { currentSelection },
                set: { newValue in
                    switch newValue {
                    case .builtIn(let p):
                        profile.aiPreset = p
                        profile.customPresetID = nil
                    case .custom(let id):
                        profile.aiPreset = .custom
                        profile.customPresetID = id
                    case .newCustom:
                        creatingNew = true
                    }
                }
            )) {
                Section("Built-in") {
                    ForEach(builtInPresets) { preset in
                        Label(preset.displayName, systemImage: preset.icon)
                            .tag(PresetSelection.builtIn(preset))
                    }
                }
                if !settings.customPresets.isEmpty {
                    Section("Your Custom Presets") {
                        ForEach(settings.customPresets) { preset in
                            Label(preset.name, systemImage: "pencil")
                                .tag(PresetSelection.custom(preset.id))
                        }
                    }
                }
                Section {
                    Label("+ New custom preset…", systemImage: "plus")
                        .tag(PresetSelection.newCustom)
                }
            }
            .labelsHidden()

            // Preview / edit area for the currently selected preset.
            switch currentSelection {
            case .builtIn(let preset):
                Text(preset.promptText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            case .custom(let id):
                if let preset = settings.customPresets.first(where: { $0.id == id }) {
                    HStack(alignment: .top) {
                        Text(preset.promptText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            editingPreset = preset
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Edit this custom preset (changes apply to every profile using it)")
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            case .newCustom:
                EmptyView()
            }
        }
        .sheet(item: $editingPreset) { preset in
            CustomPresetEditor(
                preset: preset,
                onSave: { updated in
                    if let idx = settings.customPresets.firstIndex(where: { $0.id == updated.id }) {
                        settings.customPresets[idx] = updated
                    }
                    editingPreset = nil
                },
                onDelete: { id in
                    settings.customPresets.removeAll { $0.id == id }
                    // Detach this profile (and any other) — fall back to cleanCorrect.
                    for i in settings.profiles.indices where settings.profiles[i].customPresetID == id {
                        settings.profiles[i].customPresetID = nil
                        if settings.profiles[i].aiPreset == .custom {
                            settings.profiles[i].aiPreset = .cleanCorrect
                        }
                    }
                    if profile.customPresetID == id {
                        profile.customPresetID = nil
                        profile.aiPreset = .cleanCorrect
                    }
                    editingPreset = nil
                },
                onCancel: { editingPreset = nil }
            )
        }
        .sheet(isPresented: $creatingNew) {
            CustomPresetEditor(
                preset: CustomPreset(name: "", promptText: ""),
                onSave: { new in
                    settings.customPresets.append(new)
                    profile.aiPreset = .custom
                    profile.customPresetID = new.id
                    creatingNew = false
                },
                onDelete: { _ in creatingNew = false },
                onCancel: { creatingNew = false }
            )
        }
    }
}

/// Modal editor for a single CustomPreset. Used for both 'New' (fresh blank
/// preset) and 'Edit' (existing one). Delete only fires in the edit case —
/// new presets that haven't been saved yet just cancel.
struct CustomPresetEditor: View {
    @State var preset: CustomPreset
    var onSave: (CustomPreset) -> Void
    var onDelete: (UUID) -> Void
    var onCancel: () -> Void

    @State private var showingDeleteConfirm = false
    var isExisting: Bool { !preset.name.isEmpty || !preset.promptText.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isExisting ? "Edit Custom Preset" : "New Custom Preset")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.caption).fontWeight(.medium)
                TextField("e.g. Email tone, Slack casual, Bullet points punchy",
                          text: $preset.name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Prompt").font(.caption).fontWeight(.medium)
                TextEditor(text: $preset.promptText)
                    .font(.body)
                    .frame(minHeight: 100, maxHeight: 200)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 1))
                Text("This prompt is appended to the dictation cleanup instructions. Examples: \"Rewrite as a polite German email\", \"Convert to Slack-style casual English\".")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isExisting {
                    Button("Delete", role: .destructive) {
                        showingDeleteConfirm = true
                    }
                    .confirmationDialog("Delete this preset?",
                                        isPresented: $showingDeleteConfirm,
                                        titleVisibility: .visible) {
                        Button("Delete", role: .destructive) { onDelete(preset.id) }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Profiles using this preset will switch to Clean & Correct.")
                    }
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onSave(preset) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(preset.name.trimmingCharacters(in: .whitespaces).isEmpty
                              || preset.promptText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}
