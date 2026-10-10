import AppKit
import Carbon.HIToolbox
import Observation
import ServiceManagement

/// A global shortcut: virtual key code, modifiers, and the key's printed name.
struct Shortcut: Equatable, Codable {
    var keyCode: UInt32
    var modifiers: UInt  // NSEvent.ModifierFlags raw value
    var label: String

    static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_G),
                                    modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, label: "G")

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: UInt32 {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.shift) { m |= shiftKey }
        return UInt32(m)
    }

    var display: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + label
    }

    static let named: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    init(keyCode: UInt32, modifiers: UInt, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    /// From a recorded key press.
    init(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let label = Shortcut.named[Int(event.keyCode)]
            ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
        self.init(keyCode: UInt32(event.keyCode), modifiers: flags.rawValue, label: label)
    }
}

/// One Carbon hot key for the whole app (no Accessibility permission needed).
@MainActor
final class HotKey {
    static weak var shared: HotKey?
    var onPress: () -> Void = {}
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init() {
        HotKey.shared = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in HotKey.shared?.onPress() }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    /// False when the system refuses the combination.
    @discardableResult
    func register(_ s: Shortcut) -> Bool {
        unregister()
        let id = EventHotKeyID(signature: OSType(0x6773_6420), id: 1)  // "gsd "
        let status = RegisterEventHotKey(s.keyCode, s.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
        NSLog("gsd: hot key %@ %@", s.display, status == noErr ? "registered" : "failed (\(status))")
        return status == noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}

/// Mac-only preferences: the hot key and launch at login.  Device-local, never synced.
@MainActor @Observable
final class MacPrefs {
    static let shortcutKey = "gsd.mac.shortcut"

    var shortcut: Shortcut {
        didSet {
            if let d = try? JSONEncoder().encode(shortcut) { defaults.set(d, forKey: MacPrefs.shortcutKey) }
            apply()
            onShortcut(shortcut)
        }
    }
    private(set) var hotKeyError: String?
    private(set) var launchAtLogin = false
    private(set) var loginNote: String?

    @ObservationIgnored var onShortcut: @MainActor (Shortcut) -> Void = { _ in }
    @ObservationIgnored let hotKey: HotKey
    @ObservationIgnored let defaults: UserDefaults

    init(hotKey: HotKey, defaults: UserDefaults) {
        self.hotKey = hotKey
        self.defaults = defaults
        shortcut = defaults.data(forKey: MacPrefs.shortcutKey).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .default
        refreshLoginState()
    }

    func apply() {
        hotKeyError = hotKey.register(shortcut) ? nil : "\(shortcut.display) couldn't be registered; pick another."
    }

    /// While recording, the current shortcut must not fire.
    func suspend() { hotKey.unregister() }

    func refreshLoginState() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        loginNote = status == .requiresApproval ? "Allow gsd in System Settings › General › Login Items." : nil
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            refreshLoginState()
        } catch {
            refreshLoginState()
            loginNote = error.localizedDescription
        }
    }
}
