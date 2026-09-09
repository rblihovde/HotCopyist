import SwiftUI
import AppKit

/// Shared colors and fonts. Semantic system colors throughout so the panel
/// follows the system appearance; monospaced type is reserved for payload
/// data and type identifiers.
enum Theme {
    /// Subtle tint layered over the window blur.
    static let bgTint = Color(nsColor: .windowBackgroundColor).opacity(0.55)

    /// Primary accent — the user's system accent color.
    static let mint = Color.accentColor

    /// Secondary accent for pins, paused state, and app-private payloads.
    static let amber = Color.orange

    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let hairline = Color(nsColor: .separatorColor)
    static let rowHover = Color.primary.opacity(0.05)
    static let field = Color.primary.opacity(0.045)

    static let mono = Font.system(size: 12.5)
    static let monoSmall = Font.system(size: 10.5)
    static let monoData = Font.system(size: 11, design: .monospaced)
    static let wordmark = Font.system(size: 12, weight: .semibold)
}

enum Fmt {
    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        return f
    }()

    static let full: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    static func rel(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        return relative.localizedString(for: date, relativeTo: now)
    }

    static func size(_ count: Int) -> String {
        bytes.string(fromByteCount: Int64(count))
    }
}

/// A transparent region that lets the user move the panel by dragging it,
/// used behind the header now that window-background dragging is off (so
/// dragging a history row onto a hot slot doesn't move the whole window).
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

/// System blur behind the panel content.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Small capture-state indicator next to the app name.
struct StatusDot: View {
    let active: Bool

    var body: some View {
        Circle()
            .fill(active ? Color.green : Theme.amber)
            .frame(width: 6, height: 6)
    }
}
