import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon's RegisterEventHotKey — works without
/// Accessibility permission, unlike NSEvent global monitors.
///
/// Bindings are user-editable (see `ShortcutStore`), so every registration is
/// tracked by id and can be replaced individually without disturbing the rest.
final class HotKeyCenter {

    static let shared = HotKeyCenter()

    private var actions: [UInt32: () -> Void] = [:]
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private let signature = OSType(0x4357_495A) /* 'CWIZ' */

    private init() {}

    /// Registers (or re-registers) one hotkey. Returns false when the system
    /// refuses the combination — almost always because another app already
    /// owns it, which the shortcut editor reports back to the user.
    @discardableResult
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        unregister(id: id)

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            EventHotKeyID(signature: signature, id: id),
            GetEventDispatcherTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else { return false }
        hotKeyRefs[id] = ref
        actions[id] = action
        return true
    }

    /// Convenience for the shortcut-backed call sites.
    @discardableResult
    func register(_ shortcut: Shortcut, id: UInt32, action: @escaping () -> Void) -> Bool {
        register(id: id, keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, action: action)
    }

    func unregister(id: UInt32) {
        if let existing = hotKeyRefs.removeValue(forKey: id) {
            UnregisterEventHotKey(existing)
        }
        actions[id] = nil
    }

    func unregisterAll() {
        for ref in hotKeyRefs.values { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
        actions.removeAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                let id = hotKeyID.id
                DispatchQueue.main.async { center.actions[id]?() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }
}
