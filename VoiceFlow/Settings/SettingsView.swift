import SwiftUI
import Carbon

enum SettingsTab: String, CaseIterable, Identifiable {
    case dictation = "Dictation"
    case profiles = "Profiles"
    case connections = "Connections"
    case aiLanguage = "AI & Language"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .dictation: return "waveform"
        case .profiles: return "person.crop.rectangle.stack"
        case .connections: return "link"
        case .aiLanguage: return "sparkles"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var selectedTab: SettingsTab = .dictation

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return "v\(version)"
    }

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(alignment: .leading, spacing: 0) {
                // App name + version
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sonotexta")
                        .font(.headline)
                        .fontWeight(.bold)
                    Text(appVersion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)

                Divider()
                    .padding(.horizontal, 12)

                // Nav items
                VStack(spacing: 2) {
                    ForEach(SettingsTab.allCases) { tab in
                        SidebarButton(
                            title: tab.rawValue,
                            icon: tab.icon,
                            isSelected: selectedTab == tab
                        ) {
                            selectedTab = tab
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)

                Spacer()
            }
            .frame(width: 170)
            .background(.background.opacity(0.5))

            Divider()

            // Content
            Group {
                switch selectedTab {
                case .dictation:
                    DictationSettingsView(settings: settings)
                case .profiles:
                    ProfileSettingsView(settings: settings)
                case .connections:
                    ConnectionsSettingsView()
                case .aiLanguage:
                    AILanguageSettingsView()
                case .about:
                    AboutSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 700, minHeight: 500)
    }
}

struct SidebarButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 20)
                    .foregroundStyle(isSelected ? DesignTokens.surfacePrimary : .secondary)

                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? DesignTokens.surfacePrimary : .primary)

                Spacer()

                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isSelected ? DesignTokens.surfacePrimary.opacity(0.2) : DesignTokens.accent.opacity(0.15))
                        .foregroundStyle(isSelected ? DesignTokens.surfacePrimary : DesignTokens.accent)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? DesignTokens.accent : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared Card Component

struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
    }
}

// MARK: - Hotkey Recorder

struct HotkeyRecorderView: NSViewRepresentable {
    let onRecord: (UInt32, UInt32, String) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.onRecord = onRecord
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {}
}

class HotkeyRecorderNSView: NSView {
    var onRecord: ((UInt32, UInt32, String) -> Void)?
    private var monitor: Any?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleKeyEvent(event)
                return nil
            }
            DispatchQueue.main.async {
                self.window?.makeFirstResponder(self)
            }
        }
    }

    override func removeFromSuperview() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        super.removeFromSuperview()
    }

    private func handleKeyEvent(_ event: NSEvent) {
        let keyCode = UInt32(event.keyCode)
        var modifiers: UInt32 = 0
        var display = ""

        if event.modifierFlags.contains(.control) {
            modifiers |= UInt32(controlKey)
            display += "⌃"
        }
        if event.modifierFlags.contains(.option) {
            modifiers |= UInt32(optionKey)
            display += "⌥"
        }
        if event.modifierFlags.contains(.shift) {
            modifiers |= UInt32(shiftKey)
            display += "⇧"
        }
        if event.modifierFlags.contains(.command) {
            modifiers |= UInt32(cmdKey)
            display += "⌘"
        }

        // Build key name: use readable name for special/function keys, character for letters
        let keyName = Self.readableKeyName(for: keyCode) ?? event.charactersIgnoringModifiers?.uppercased() ?? "?"
        display += keyName

        // Allow single keys (F-keys, special keys) and modifier combos
        // Only block bare letter/number keys without modifiers to prevent accidental triggers
        if modifiers == 0 {
            let isFunctionKey = keyCode >= 122 && keyCode <= 131 || keyCode == 96 || keyCode == 97 || keyCode == 98 || keyCode == 99 || keyCode == 100 || keyCode == 101 || keyCode == 109 || keyCode == 103 || keyCode == 111
            let isSpecialKey = keyCode >= 36 // Return, Tab, Space, Delete, Escape, and above
            if !isFunctionKey && !isSpecialKey {
                print("[VoiceFlow] Single letter/number keys need a modifier — use F-keys or special keys for single-key shortcuts")
                return
            }
        }

        onRecord?(keyCode, modifiers, display)
    }

    /// Map key codes to readable names for special and function keys
    static func readableKeyName(for keyCode: UInt32) -> String? {
        switch Int(keyCode) {
        // Function keys
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        case kVK_F20: return "F20"
        // Special keys
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "PgUp"
        case kVK_PageDown: return "PgDn"
        default: return nil
        }
    }

    override func keyDown(with event: NSEvent) {}

    override func becomeFirstResponder() -> Bool {
        return true
    }
}

extension Notification.Name {
    static let hotkeyChanged = Notification.Name("VoiceFlowHotkeyChanged")
}
