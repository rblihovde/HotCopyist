import AppKit
import Carbon.HIToolbox

/// One global keyboard shortcut, stored as the Carbon key code + modifier mask
/// that `RegisterEventHotKey` wants.
///
/// Carbon's masks (`cmdKey`, `optionKey`, …) are not the same bits as AppKit's
/// `NSEvent.ModifierFlags`, so the translation lives here rather than being
/// re-derived at every call site.
struct Shortcut: Codable, Equatable {

    var keyCode: UInt32
    /// Carbon modifier mask: cmdKey | controlKey | optionKey | shiftKey.
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Builds a shortcut from a captured key event, or nil when the event
    /// can't serve as a global hotkey.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }

        // A global hotkey without ⌘/⌃/⌥ would swallow ordinary typing in every
        // app, so shift alone (or nothing) is rejected.
        guard carbon & UInt32(cmdKey | controlKey | optionKey) != 0 else { return nil }

        self.keyCode = UInt32(event.keyCode)
        self.modifiers = carbon
    }

    // MARK: - Display

    /// The familiar glyph form, e.g. "⌃⌘X". Order matches Apple's menu
    /// convention: ⌃ ⌥ ⇧ ⌘.
    var displayString: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + Self.keyName(for: keyCode)
    }

    /// Printable name for a virtual key code. Named keys are spelled out with
    /// their glyphs; everything else is resolved through the user's active
    /// keyboard layout so a French or Dvorak layout shows the right letter.
    static func keyName(for keyCode: UInt32) -> String {
        if let named = namedKeys[Int(keyCode)] { return named }
        return layoutCharacter(for: keyCode) ?? "Key \(keyCode)"
    }

    private static let namedKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_LeftArrow: "←",
        kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_ANSI_KeypadEnter: "⌤",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"
    ]

    /// Asks the current input source what character a key code produces, with
    /// no modifiers applied.
    private static func layoutCharacter(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data

        return layoutData.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)

            let status = UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,                                  // no modifiers
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length).uppercased()
        }
    }
}

// MARK: - Actions

/// Everything that can be bound to a global shortcut. The raw values are the
/// UserDefaults keys, so renaming a case would orphan a user's binding.
enum ShortcutAction: String, CaseIterable {
    case togglePanel
    case grabScreenText
    case captureLogic
    case slot1, slot2, slot3, slot4, slot5

    var title: String {
        switch self {
        case .togglePanel: return "Show / Hide Panel"
        case .grabScreenText: return "Grab Text from Screen"
        case .captureLogic: return "Capture Logic Selection"
        case .slot1: return "Hot Slot 1"
        case .slot2: return "Hot Slot 2"
        case .slot3: return "Hot Slot 3"
        case .slot4: return "Hot Slot 4"
        case .slot5: return "Hot Slot 5"
        }
    }

    /// Carbon hotkey id — stable across launches and distinct per action.
    var hotKeyID: UInt32 {
        switch self {
        case .togglePanel: return 1
        case .grabScreenText: return 2
        case .captureLogic: return 3
        case .slot1: return 10
        case .slot2: return 11
        case .slot3: return 12
        case .slot4: return 13
        case .slot5: return 14
        }
    }

    /// The hot slot this action fires, if it is one.
    var slotIndex: Int? {
        switch self {
        case .slot1: return 0
        case .slot2: return 1
        case .slot3: return 2
        case .slot4: return 3
        case .slot5: return 4
        default: return nil
        }
    }

    var defaultShortcut: Shortcut {
        let controlCommand = UInt32(cmdKey | controlKey)
        switch self {
        case .togglePanel: return Shortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: controlCommand)
        case .grabScreenText: return Shortcut(keyCode: UInt32(kVK_ANSI_X), modifiers: controlCommand)
        case .captureLogic: return Shortcut(keyCode: UInt32(kVK_ANSI_C), modifiers: controlCommand)
        case .slot1: return Shortcut(keyCode: UInt32(kVK_ANSI_1), modifiers: controlCommand)
        case .slot2: return Shortcut(keyCode: UInt32(kVK_ANSI_2), modifiers: controlCommand)
        case .slot3: return Shortcut(keyCode: UInt32(kVK_ANSI_3), modifiers: controlCommand)
        case .slot4: return Shortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: controlCommand)
        case .slot5: return Shortcut(keyCode: UInt32(kVK_ANSI_5), modifiers: controlCommand)
        }
    }
}

// MARK: - Store

/// The user's shortcut bindings, persisted in UserDefaults and observable so
/// the panel's tooltips and the menu bar update the moment one changes.
///
/// Remote-desktop software (Screen Sharing, RDP clients, Citrix) grabs a lot of
/// key combinations, which is exactly why these are editable rather than fixed.
final class ShortcutStore: ObservableObject {

    static let shared = ShortcutStore()

    /// Posted whenever a binding changes, so the hotkey registrations can be
    /// rebuilt.
    static let didChange = Notification.Name("com.blihovde.hotcopy.shortcutsDidChange")

    @Published private(set) var bindings: [ShortcutAction: Shortcut] = [:]

    private let defaults = UserDefaults.standard
    private static let prefix = "com.blihovde.hotcopy.shortcut."

    private init() {
        for action in ShortcutAction.allCases {
            bindings[action] = loadShortcut(for: action) ?? action.defaultShortcut
        }
    }

    subscript(action: ShortcutAction) -> Shortcut {
        bindings[action] ?? action.defaultShortcut
    }

    /// The action already using this key combination, ignoring `excluding`.
    func conflict(for shortcut: Shortcut, excluding action: ShortcutAction) -> ShortcutAction? {
        bindings.first { $0.key != action && $0.value == shortcut }?.key
    }

    func set(_ shortcut: Shortcut, for action: ShortcutAction) {
        bindings[action] = shortcut
        let encoded = try? JSONEncoder().encode(shortcut)
        defaults.set(encoded, forKey: Self.prefix + action.rawValue)
        NotificationCenter.default.post(name: Self.didChange, object: action)
    }

    func reset(_ action: ShortcutAction) {
        bindings[action] = action.defaultShortcut
        defaults.removeObject(forKey: Self.prefix + action.rawValue)
        NotificationCenter.default.post(name: Self.didChange, object: action)
    }

    func resetAll() {
        for action in ShortcutAction.allCases {
            bindings[action] = action.defaultShortcut
            defaults.removeObject(forKey: Self.prefix + action.rawValue)
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    private func loadShortcut(for action: ShortcutAction) -> Shortcut? {
        guard let data = defaults.data(forKey: Self.prefix + action.rawValue) else { return nil }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }
}
