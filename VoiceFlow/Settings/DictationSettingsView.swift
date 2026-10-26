import SwiftUI
import Carbon

/// Dictation tab — Microphone · Engine (radio + per-engine config) · Shortcut ·
/// Dictation mode · Clipboard · Appearance · Permissions.
///
/// The engine + microphone selection still lives inside the existing
/// `EngineSettingsView`; this view embeds it as the upper portion of the tab
/// and adds the Shortcut / Clipboard / Appearance / Permissions sections
/// (ported from the old `GeneralSettingsView`) below.
///
/// The Appearance section is new for 3.15: System / Light / Dark picker
/// backed by `AppSettings.shared.appearance`.
struct DictationSettingsView: View {
    @ObservedObject var settings: AppSettings = AppSettings.shared

    var body: some View {
        // We render engine config in its existing ScrollView form via
        // `EngineSettingsView`, then a TabView would split the visual flow.
        // Instead we wrap the dictation-specific sections in a single
        // ScrollView that hosts the engine settings inline via a custom
        // section embed. To avoid nested ScrollViews we use the dedicated
        // `EngineSettingsContent` (the underlying Form) when possible, but
        // since EngineSettingsView ships its own ScrollView we embed it
        // directly and stack the General sections beneath in another
        // container — the user perceives one continuous scroll because
        // both views vertically size to fit and the parent provides the
        // outer container.
        //
        // SwiftUI on macOS handles nested ScrollViews gracefully when the
        // outer one drives scrolling and the inner one defers its own.
        // To keep behavior predictable we use a single outer ScrollView
        // and render the engine view's body inline by composition.
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Dictation")
                        .font(.title)
                        .fontWeight(.bold)
                    Text("Microphone, engine, shortcut, clipboard, and appearance.")
                        .foregroundStyle(.secondary)
                }

                // Engine + microphone — embed the existing EngineSettingsView.
                // It has its own ScrollView, so we render it in a sized
                // container. This is the pragmatic compose-rather-than-extract
                // approach taken for the 3.15 redesign per the redesign brief.
                EngineSettingsView(settings: settings)
                    .frame(minHeight: 600)

                ShortcutSection(settings: settings)
                ClipboardSection(settings: settings)
                StartupSection()
                AppearanceSection(settings: settings)
                PermissionsSection()
                AboutVersionSection()
            }
            .padding(24)
        }
    }
}

// MARK: - Shortcut section (3.16.5 — dictation shortcut table)

private struct ShortcutSection: View {
    @ObservedObject var settings: AppSettings
    /// Binding id currently in shortcut-recording state (nil = none).
    @State private var recordingID: UUID?

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Dictation Shortcuts")
                    .font(.headline)

                Text("Each shortcut can activate a specific profile and its own mode — e.g. one key for quick snippets, another for long-form dictation with AI formatting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(settings.hotkeyBindings.indices, id: \.self) { index in
                    bindingRow(index: index)
                    if index < settings.hotkeyBindings.count - 1 {
                        Divider()
                    }
                }

                HStack {
                    Menu("Add Shortcut") {
                        Button("Record key combo…") {
                            let new = HotkeyBinding(
                                key: .carbonCombo(keyCode: 0, modifiers: 0, display: "—"),
                                profileID: nil,
                                mode: .toggle
                            )
                            settings.hotkeyBindings.append(new)
                            recordingID = new.id
                        }
                        Button("Globe 🌐") { addBinding(.globe) }
                        Button("Right Option ⌥") { addBinding(.rightOption) }
                    }
                    .fixedSize()
                    Spacer()
                }
            }
        }
        .onChange(of: settings.hotkeyBindings) { _, _ in
            NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
        }
    }

    private func addBinding(_ key: HotkeyBinding.KeySpec) {
        settings.hotkeyBindings.append(
            HotkeyBinding(key: key, profileID: nil, mode: .holdToTalk)
        )
    }

    @ViewBuilder
    private func bindingRow(index: Int) -> some View {
        // Guard against transient index invalidation during deletes.
        if index < settings.hotkeyBindings.count {
            let binding = settings.hotkeyBindings[index]

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    // Key chip + change menu
                    Menu {
                        Button("Record key combo…") { recordingID = binding.id }
                        Button("Globe 🌐") { settings.hotkeyBindings[index].key = .globe }
                        Button("Right Option ⌥") { settings.hotkeyBindings[index].key = .rightOption }
                    } label: {
                        Text(binding.key.display)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .fixedSize()

                    // Profile picker — nil means app detection (legacy behavior)
                    Picker("", selection: profileSelection(index: index)) {
                        Text("Auto (app detection)").tag(UUID?.none)
                        ForEach(settings.profiles) { profile in
                            Text(profile.name).tag(UUID?.some(profile.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)

                    // Mode picker
                    Picker("", selection: modeSelection(index: index)) {
                        Text("Toggle").tag(DictationMode.toggle)
                        Text("Hold").tag(DictationMode.holdToTalk)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 140)

                    Spacer()

                    if settings.hotkeyBindings.count > 1 {
                        Button(role: .destructive) {
                            settings.hotkeyBindings.remove(at: index)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                if binding.mode == .holdToTalk && !binding.key.supportsHold {
                    Text("This key can't detect release — it will toggle instead. Use Globe or Right ⌥ for true hold-to-talk.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                if recordingID == binding.id {
                    HStack {
                        Text("Press new shortcut…")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Cancel") { recordingID = nil }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                    HotkeyRecorderView { keyCode, modifiers, displayString in
                        settings.hotkeyBindings[index].key = modifiers == 0
                            ? .singleKey(keyCode: keyCode, display: displayString)
                            : .carbonCombo(keyCode: keyCode, modifiers: modifiers, display: displayString)
                        recordingID = nil
                    }
                    .frame(height: 30)
                }
            }
        }
    }

    private func profileSelection(index: Int) -> Binding<UUID?> {
        Binding(
            get: { settings.hotkeyBindings.indices.contains(index) ? settings.hotkeyBindings[index].profileID : nil },
            set: { if settings.hotkeyBindings.indices.contains(index) { settings.hotkeyBindings[index].profileID = $0 } }
        )
    }

    private func modeSelection(index: Int) -> Binding<DictationMode> {
        Binding(
            get: { settings.hotkeyBindings.indices.contains(index) ? settings.hotkeyBindings[index].mode : .toggle },
            set: { if settings.hotkeyBindings.indices.contains(index) { settings.hotkeyBindings[index].mode = $0 } }
        )
    }
}

// MARK: - Clipboard section (ported from GeneralSettingsView)

private struct ClipboardSection: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Clipboard")
                    .font(.headline)

                Toggle("Keep transcription in clipboard", isOn: $settings.keepInClipboard)

                Text("When enabled, the transcribed (or translated) text stays in your clipboard after delivery so you can paste it again. When disabled, the previous clipboard content is restored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !settings.keepInClipboard {
                    Divider()

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Paste delay:")
                            Spacer()
                            Text(settings.clipboardRestoreDelay >= 1.0 ? String(format: "%.1fs", settings.clipboardRestoreDelay) : String(format: "%.0fms", settings.clipboardRestoreDelay * 1000))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        Slider(value: $settings.clipboardRestoreDelay, in: 0.15...3.0, step: 0.05)

                        Text("Increase for VMs and remote desktop apps. Default: 150ms. For Windows VMs, try 1–2s.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Startup section (NEW for 3.16.2 — launch at login)

private struct StartupSection: View {
    @ObservedObject private var loginItem = LoginItemService.shared

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Startup")
                    .font(.headline)

                Toggle("Start Sonotexta at login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))

                Text("Automatically launches Sonotexta in the menu bar when you log in, so dictation is ready after a restart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if loginItem.requiresApproval {
                    HStack(spacing: 6) {
                        Label("macOS needs your approval in System Settings → Login Items.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Open Login Items") {
                            loginItem.openSystemLoginItems()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }

                if let error = loginItem.lastError {
                    Label(error, systemImage: "xmark.octagon")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .onAppear { loginItem.refresh() }
    }
}

// MARK: - Appearance section (NEW for 3.15 — System / Light / Dark)

private struct AppearanceSection: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Appearance")
                    .font(.headline)

                Picker("Theme", selection: $settings.appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text("System follows your macOS appearance setting. Light or Dark overrides it for Sonotexta only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Toggle("Show in Dock", isOn: $settings.showInDock)

                Text("When enabled, Sonotexta appears in the Dock. Clicking the Dock icon opens Settings. When disabled, Sonotexta runs only in the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !settings.showInDock {
                    Label("Sonotexta is menu bar only. Use the waveform icon in the top-right to access Settings.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

// MARK: - Permissions section (ported from GeneralSettingsView)

private struct PermissionsSection: View {
    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Permissions")
                    .font(.headline)

                HStack {
                    Text("Accessibility")
                    Spacer()
                    if AccessibilityService.shared.hasPermission {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Granted")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Grant Access") {
                            AccessibilityService.shared.requestPermission()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Version footer (ported)

private struct AboutVersionSection: View {
    var body: some View {
        SettingsCard {
            HStack {
                Text("Version")
                    .font(.headline)
                Spacer()
                Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") (Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"))")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
