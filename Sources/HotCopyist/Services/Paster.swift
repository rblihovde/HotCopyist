import AppKit
import ApplicationServices

/// Optional auto-paste: synthesizes ⌘V into the frontmost app.
/// Requires the Accessibility permission (System Settings → Privacy & Security).
/// Without it, HotCopyist still works — items are armed on the pasteboard and the
/// user presses ⌘V themselves.
enum Paster {

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt that deep-links to the Accessibility pane.
    static func requestTrust() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Synthesizes ⌘V. `ifFrontmostIs` guards the short delay callers leave for
    /// the pasteboard to settle: if the user has switched apps in the meantime,
    /// the keystroke is dropped rather than delivered somewhere unintended.
    static func sendCmdV(ifFrontmostIs expectedPID: pid_t? = nil) {
        if let expectedPID,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != expectedPID {
            return
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        let vKeyCode: CGKeyCode = 9

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
