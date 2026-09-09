import SwiftUI
import AppKit
import Carbon.HIToolbox

/// The shortcut editor: one row per bindable action, each with a click-to-record
/// field.
///
/// Editable bindings exist mainly for remote-desktop work — Screen Sharing, RDP
/// and Citrix clients swallow a lot of key combinations, and which ones varies
/// by client, so a fixed hotkey is no good.
struct ShortcutsView: View {

    @ObservedObject private var shortcuts = ShortcutStore.shared

    /// The action currently listening for a keystroke, if any.
    @State private var recording: ShortcutAction?
    /// Feedback for the last attempt — a conflict, or a combination the system
    /// refused.
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(ShortcutAction.allCases, id: \.self) { action in
                        row(for: action)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
            }

            Divider()

            footer
        }
        .frame(width: 420, height: 380)
        .background(Theme.bgTint)
        .onDisappear { recording = nil }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Keyboard Shortcuts")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Click a shortcut, then press the keys you want. Needs at least one of ⌘, ⌃ or ⌥.")
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Rows

    private func row(for action: ShortcutAction) -> some View {
        HStack(spacing: 10) {
            Text(action.title)
                .font(Theme.mono)
                .foregroundStyle(Theme.textPrimary)

            Spacer(minLength: 8)

            if shortcuts[action] != action.defaultShortcut {
                Button("Reset") {
                    shortcuts.reset(action)
                    problem = nil
                }
                .buttonStyle(.plain)
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.textSecondary)
                .help("Restore the default shortcut")
            }

            recorderField(for: action)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(recording == action ? Theme.mint.opacity(0.10) : .clear)
        )
    }

    private func recorderField(for action: ShortcutAction) -> some View {
        let isRecording = recording == action

        return Button {
            problem = nil
            recording = isRecording ? nil : action
        } label: {
            Text(isRecording ? "Press keys…" : shortcuts[action].displayString)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(isRecording ? Theme.mint : Theme.textPrimary)
                .frame(width: 116, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.field)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isRecording ? Theme.mint : Theme.hairline, lineWidth: isRecording ? 1.5 : 1)
                )
                .overlay {
                    if isRecording {
                        KeyCaptureView { event in capture(event, for: action) }
                    }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let problem {
                Text(problem)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.amber)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Shortcuts work from any app, even while you're in a remote session.")
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button("Restore Defaults") {
                shortcuts.resetAll()
                recording = nil
                problem = nil
            }
            .font(Theme.monoSmall)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Capture

    private func capture(_ event: NSEvent, for action: ShortcutAction) {
        // ⎋ backs out without changing anything.
        if event.keyCode == UInt16(kVK_Escape),
           !event.modifierFlags.intersection(.deviceIndependentFlagsMask)
               .contains(where: [.command, .control, .option]) {
            recording = nil
            return
        }

        guard let shortcut = Shortcut(event: event) else {
            problem = "Add ⌘, ⌃ or ⌥ — a shortcut without one would swallow ordinary typing."
            return
        }

        if let clash = ShortcutStore.shared.conflict(for: shortcut, excluding: action) {
            problem = "\(shortcut.displayString) is already used by “\(clash.title)”."
            return
        }

        // Claim it for real before committing: another app may already own the
        // combination, and Carbon only says so at registration time.
        guard HotKeyCenter.shared.register(shortcut, id: action.hotKeyID, action: {}) else {
            problem = "\(shortcut.displayString) is taken by another app. Try a different combination."
            // Put the previous binding back, since the failed attempt cleared it.
            NotificationCenter.default.post(name: ShortcutStore.didChange, object: action)
            return
        }

        ShortcutStore.shared.set(shortcut, for: action)
        recording = nil
        problem = nil
    }
}

private extension NSEvent.ModifierFlags {
    /// True when any of the given flags is present.
    func contains(where flags: [NSEvent.ModifierFlags]) -> Bool {
        flags.contains { contains($0) }
    }
}

// MARK: - Key capture

/// Invisible first responder that swallows one key event and hands it back.
/// SwiftUI has no equivalent — `onKeyPress` never sees a bare ⌘-modified key.
private struct KeyCaptureView: NSViewRepresentable {

    let onKey: (NSEvent) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = CaptureView()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CaptureView)?.onKey = onKey
    }

    private final class CaptureView: NSView {
        var onKey: ((NSEvent) -> Void)?
        private var monitor: Any?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else {
                stopMonitoring()
                return
            }
            window.makeFirstResponder(self)

            // A local monitor rather than `keyDown` alone: it also catches the
            // combinations AppKit would otherwise route to a menu equivalent.
            stopMonitoring()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.onKey?(event)
                return nil
            }
        }

        override func keyDown(with event: NSEvent) {
            onKey?(event)
        }

        /// Modifier-only presses are ignored; the monitor waits for a real key.
        override func flagsChanged(with event: NSEvent) {}

        deinit { stopMonitoring() }

        private func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}

// MARK: - Window

/// Hosts the editor in a normal window. The app is an accessory (no Dock icon),
/// so it activates explicitly to take keyboard focus while recording.
final class ShortcutsWindowController {

    static let shared = ShortcutsWindowController()

    private var window: NSWindow?

    private init() {}

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Keyboard Shortcuts"
        window.contentView = NSHostingView(rootView: ShortcutsView())
        window.isReleasedWhenClosed = false
        window.center()
        window.level = .floating

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
