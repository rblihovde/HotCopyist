import SwiftUI
import AppKit

/// CopyWiz visual language: retro-future-minimal, permanently dark.
/// Phosphor-mint signal color on near-black glass, monospaced data,
/// hairline separations — CRT terminal soul, Apple HIG manners.
enum Theme {
    /// Dark tint layered over the window blur.
    static let bgTint = Color(red: 0.043, green: 0.051, blue: 0.071).opacity(0.78)

    /// Primary accent — phosphor mint.
    static let mint = Color(red: 0.42, green: 0.96, blue: 0.80)

    /// Secondary accent — warm amber, for pins / paused / exotic payloads.
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.35)

    static let textPrimary = Color(white: 0.93)
    static let textSecondary = Color(white: 0.52)
    static let hairline = Color.white.opacity(0.08)
    static let rowHover = Color.white.opacity(0.05)
    static let field = Color.white.opacity(0.06)

    static let mono = Font.system(size: 12, design: .monospaced)
    static let monoSmall = Font.system(size: 9.5, design: .monospaced)
    static let monoData = Font.system(size: 10.5, design: .monospaced)
    static let wordmark = Font.system(size: 11, weight: .semibold, design: .monospaced)
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

/// System blur behind the panel content.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// The little pulsing capture indicator next to the wordmark.
struct StatusDot: View {
    let active: Bool
    @State private var pulsing = false

    private var color: Color { active ? Theme.mint : Theme.amber }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: color.opacity(active && pulsing ? 0.9 : 0.25), radius: active && pulsing ? 5 : 1.5)
            .opacity(active ? (pulsing ? 1.0 : 0.55) : 0.9)
            .animation(
                active ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true) : .easeOut(duration: 0.2),
                value: pulsing
            )
            .onAppear { pulsing = true }
    }
}
