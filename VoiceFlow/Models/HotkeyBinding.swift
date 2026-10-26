import Foundation

/// DictationMode predates Codable use; RawRepresentable(String) synthesizes it.
extension DictationMode: Codable {}

/// One dictation shortcut: which key, which profile it activates, which mode.
///
/// 3.16.5: the app moves from ONE global dictation key to a table of
/// bindings (beta-tester request — e.g. one key for quick snippets, another
/// for long-form dictation with AI formatting). A binding with `profileID ==
/// nil` keeps today's behavior: the profile is resolved by app-detection at
/// dictation time. A set `profileID` pins that profile for the session,
/// overriding app detection.
struct HotkeyBinding: Codable, Identifiable, Hashable {
    /// What physical key activates this binding.
    enum KeySpec: Codable, Hashable {
        /// Modifier+key combo registered via Carbon (⌃⇧D style).
        /// Carbon only reports presses — hold-to-talk falls back to toggle.
        case carbonCombo(keyCode: UInt32, modifiers: UInt32, display: String)
        /// Bare non-modifier key (F-keys, Logitech buttons) via keyDown
        /// monitor. No release detection — hold-to-talk falls back to toggle.
        case singleKey(keyCode: UInt32, display: String)
        /// Globe/Fn key via flagsChanged. Full press/release support.
        case globe
        /// Right Option (⌥) via flagsChanged. Full press/release support.
        case rightOption

        var display: String {
            switch self {
            case .carbonCombo(_, _, let display): return display
            case .singleKey(_, let display): return display
            case .globe: return "Globe 🌐"
            case .rightOption: return "Right ⌥"
            }
        }

        /// Whether press AND release are observable — i.e. true hold-to-talk.
        var supportsHold: Bool {
            switch self {
            case .globe, .rightOption: return true
            case .carbonCombo, .singleKey: return false
            }
        }
    }

    var id: UUID = UUID()
    var key: KeySpec
    /// Profile to activate; nil = resolve by app detection (legacy behavior).
    var profileID: UUID?
    var mode: DictationMode

    /// Effective mode after capability gating: keys that can't report a
    /// release can't hold-to-talk.
    var effectiveMode: DictationMode {
        mode == .holdToTalk && !key.supportsHold ? .toggle : mode
    }
}
