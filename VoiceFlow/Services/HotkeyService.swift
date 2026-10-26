import Carbon
import AppKit
import Combine

/// 3.16.5: registers the whole `AppSettings.hotkeyBindings` table instead of
/// one global hotkey. Three registration backends, matched per key type:
///
/// - **Carbon** (`RegisterEventHotKey`) for modifier+key combos — one
///   registration per binding, disambiguated via `EventHotKeyID.id`.
///   Press-only, so hold-to-talk degrades to toggle (`effectiveMode`).
/// - **keyDown NSEvent monitors** for bare non-modifier keys (F-keys,
///   Logitech buttons). Press-only as well.
/// - **flagsChanged NSEvent monitors** for Globe (keyCode 63, `.function`)
///   and Right Option (keyCode 61, `.option`). Press AND release are
///   observable → real hold-to-talk.
final class HotkeyService: ObservableObject {
    @Published var isRegistered = false

    // Carbon state: one shared handler, N hotkey registrations.
    private var eventHandler: EventHandlerRef?
    private var carbonRefs: [EventHotKeyRef] = []
    /// Carbon `EventHotKeyID.id` → binding (ids start at 1).
    private var carbonBindings: [UInt32: HotkeyBinding] = [:]

    // NSEvent monitor state (shared across all monitor-based bindings).
    private var globalMonitors: [Any] = []
    private var localMonitors: [Any] = []
    /// Per-binding pressed state for modifier keys (press/release tracking).
    private var modifierPressed: [UUID: Bool] = [:]

    private var onToggle: ((HotkeyBinding) -> Void)?
    private var onStartHold: ((HotkeyBinding) -> Void)?
    private var onStopHold: ((HotkeyBinding) -> Void)?
    private var changeObserver: NSObjectProtocol?

    /// Globe key code (Fn/🌐)
    private let globeKeyCode: UInt16 = 63
    /// Right Option (⌥) key code — the left one is 58. We deliberately only
    /// offer the RIGHT key: left ⌥ is heavily used for special characters
    /// (especially on European layouts), the right one rarely is.
    private let rightOptionKeyCode: UInt16 = 61

    func register(
        onToggle: @escaping (HotkeyBinding) -> Void,
        onStartHold: ((HotkeyBinding) -> Void)? = nil,
        onStopHold: ((HotkeyBinding) -> Void)? = nil
    ) {
        self.onToggle = onToggle
        self.onStartHold = onStartHold
        self.onStopHold = onStopHold
        registerAllBindings()

        // Listen for hotkey changes from settings
        changeObserver = NotificationCenter.default.addObserver(
            forName: .hotkeyChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.registerAllBindings()
        }
    }

    private func registerAllBindings() {
        unregister()

        let bindings = AppSettings.shared.hotkeyBindings
        var carbonID: UInt32 = 0
        var monitorBindings: [(HotkeyBinding, UInt16, NSEvent.ModifierFlags?)] = []

        for binding in bindings {
            switch binding.key {
            case .carbonCombo(let keyCode, let modifiers, _):
                carbonID += 1
                registerCarbonHotkey(binding: binding, keyCode: keyCode, modifiers: modifiers, id: carbonID)
            case .singleKey(let keyCode, _):
                monitorBindings.append((binding, UInt16(keyCode), nil))
            case .globe:
                monitorBindings.append((binding, globeKeyCode, .function))
            case .rightOption:
                monitorBindings.append((binding, rightOptionKeyCode, .option))
            }
        }

        if !monitorBindings.isEmpty {
            installSharedMonitors(monitorBindings)
        }

        isRegistered = !bindings.isEmpty
        let summary = bindings.map { "\($0.key.display)→\($0.effectiveMode.rawValue)" }.joined(separator: ", ")
        print("[VoiceFlow] Hotkeys registered: [\(summary)]")
    }

    // MARK: - Shared NSEvent monitors (single keys + modifier keys)

    private func installSharedMonitors(_ entries: [(HotkeyBinding, UInt16, NSEvent.ModifierFlags?)]) {
        let keyDownEntries = entries.filter { $0.2 == nil }
        let flagEntries = entries.filter { $0.2 != nil }

        if !keyDownEntries.isEmpty {
            let handler: (NSEvent) -> Bool = { [weak self] event in
                guard let self,
                      let (binding, _, _) = keyDownEntries.first(where: { $0.1 == event.keyCode })
                else { return false }
                // Press-only key: hold-to-talk isn't detectable → effectiveMode
                // is always .toggle here, fire toggle.
                self.onToggle?(binding)
                return true
            }
            globalMonitors.append(NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
                _ = handler(event)
            } as Any)
            if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
                handler(event) ? nil : event // consume when matched
            }) {
                localMonitors.append(local)
            }
        }

        if !flagEntries.isEmpty {
            let handler: (NSEvent) -> Void = { [weak self] event in
                guard let self, event.type == .flagsChanged,
                      let (binding, _, flag) = flagEntries.first(where: { $0.1 == event.keyCode }),
                      let flag
                else { return }
                self.handleModifierKeyEvent(event, binding: binding, flag: flag)
            }
            globalMonitors.append(NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler) as Any)
            if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
                handler(event)
                return event
            }) {
                localMonitors.append(local)
            }
        }
    }

    private func handleModifierKeyEvent(_ event: NSEvent, binding: HotkeyBinding, flag: NSEvent.ModifierFlags) {
        // Use modifierFlags to detect press vs release — the key sets its
        // modifier flag while held.
        let isPressed = event.modifierFlags.contains(flag)
        let wasPressed = modifierPressed[binding.id] ?? false

        switch binding.effectiveMode {
        case .toggle:
            // Fire only on press (not release)
            if isPressed && !wasPressed {
                modifierPressed[binding.id] = true
                onToggle?(binding)
            } else if !isPressed {
                modifierPressed[binding.id] = false
            }

        case .holdToTalk:
            if isPressed && !wasPressed {
                modifierPressed[binding.id] = true
                onStartHold?(binding)
            } else if !isPressed && wasPressed {
                modifierPressed[binding.id] = false
                onStopHold?(binding)
            }
        }
    }

    // MARK: - Carbon Hotkeys (modifier+key combos)

    private func registerCarbonHotkey(binding: HotkeyBinding, keyCode: UInt32, modifiers: UInt32, id: UInt32) {
        // Install the shared handler once.
        if eventHandler == nil {
            var eventType = EventTypeSpec()
            eventType.eventClass = OSType(kEventClassKeyboard)
            eventType.eventKind = UInt32(kEventHotKeyPressed)

            let handler: EventHandlerUPP = { _, event, userData -> OSStatus in
                guard let userData, let event else { return noErr }
                let service = Unmanaged<HotkeyService>.fromOpaque(userData).takeUnretainedValue()
                var hkID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                if let binding = service.carbonBindings[hkID.id] {
                    // Carbon fires on press only — effectiveMode is .toggle.
                    service.onToggle?(binding)
                }
                return noErr
            }

            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(GetApplicationEventTarget(), handler, 1, &eventType, selfPtr, &eventHandler)
        }

        var hotkeyID = EventHotKeyID()
        hotkeyID.signature = OSType(0x564F4943) // "VOIC"
        hotkeyID.id = id

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            carbonRefs.append(ref)
            carbonBindings[id] = binding
        } else {
            print("[VoiceFlow] RegisterEventHotKey failed (\(status)) for \(binding.key.display)")
        }
    }

    // MARK: - Cleanup

    func unregister() {
        for ref in carbonRefs {
            UnregisterEventHotKey(ref)
        }
        carbonRefs.removeAll()
        carbonBindings.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }

        for monitor in globalMonitors + localMonitors {
            NSEvent.removeMonitor(monitor)
        }
        globalMonitors.removeAll()
        localMonitors.removeAll()
        modifierPressed.removeAll()

        isRegistered = false
    }

    deinit {
        if let observer = changeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        unregister()
    }
}
