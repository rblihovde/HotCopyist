import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon's RegisterEventHotKey — works without
/// Accessibility permission, unlike NSEvent global monitors.
/// HotCopyist registers ⌃⌘V (toggle panel) and ⌃⌘1…⌃⌘5 (hot slots).
final class HotKeyCenter {

    static let shared = HotKeyCenter()

    private var actions: [UInt32: () -> Void] = [:]
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private let signature = OSType(0x4357_495A) /* 'CWIZ' */

    private init() {}

    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        installHandlerIfNeeded()
        actions[id] = action

        var ref: EventHotKeyRef?
        RegisterEventHotKey(
            keyCode,
            modifiers,
            EventHotKeyID(signature: signature, id: id),
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        if let ref { hotKeyRefs.append(ref) }
    }

    func unregisterAll() {
        for ref in hotKeyRefs { UnregisterEventHotKey(ref) }
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
