import SwiftUI
import AppKit

/// One of the five always-ready hot slots. Filled slots glow mint and arm on
/// click (⌘-click pastes immediately); empty slots are dashed sockets that
/// capture the latest copy when clicked. Global hotkey: ⌃⌘\(index+1).
struct HotSlotTile: View {
    let index: Int
    let item: ClipboardItem?
    var onActivate: (_ pasteNow: Bool) -> Void
    var onSaveLatest: () -> Void
    var onInspect: () -> Void
    var onClear: () -> Void

    @State private var hovering = false

    var body: some View {
        ZStack {
            if item != nil {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.mint.opacity(hovering ? 0.11 : 0.06))
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Theme.mint.opacity(hovering ? 0.6 : 0.3), lineWidth: 1)
            } else {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.045 : 0.015))
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }

            content
        }
        .overlay(alignment: .topLeading) {
            if item != nil {
                Text("\(index + 1)")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.mint.opacity(0.75))
                    .padding(.top, 3)
                    .padding(.leading, 5)
            }
        }
        .frame(height: 46)
        .frame(maxWidth: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture {
            if item != nil {
                onActivate(NSEvent.modifierFlags.contains(.command))
            } else {
                onSaveLatest()
            }
        }
        .contextMenu { menu }
        .help(helpText)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    // MARK: - Pieces

    @ViewBuilder
    private var content: some View {
        if let item {
            VStack(spacing: 3) {
                if item.kind == .image, let thumb = ThumbCache.image(for: item) {
                    Image(nsImage: thumb)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    Image(systemName: glyphName(for: item))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(item.kind == .mystery ? Theme.amber : Theme.mint)
                }
                Text(shortPreview(for: item))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 4)
            }
        } else {
            Text("\(index + 1)")
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textSecondary.opacity(0.55))
        }
    }

    private func glyphName(for item: ClipboardItem) -> String {
        switch item.kind {
        case .text: return "text.alignleft"
        case .rich: return "textformat"
        case .image: return "photo"
        case .fileURL: return "doc"
        case .mystery: return "cube.transparent"
        }
    }

    private func shortPreview(for item: ClipboardItem) -> String {
        String(item.previewText.prefix(14))
    }

    private var helpText: String {
        if let item {
            return "⌃⌘\(index + 1) — \(item.previewText)"
        }
        return "Empty slot — click to save your latest copy here (⌃⌘\(index + 1))"
    }

    @ViewBuilder
    private var menu: some View {
        if item != nil {
            Button("Copy — Ready for ⌘V") { onActivate(false) }
            Button("Paste Now") { onActivate(true) }
            Divider()
            Button("Replace with Latest Copy") { onSaveLatest() }
            Button("Inspect Payload") { onInspect() }
            Divider()
            Button("Clear Slot", role: .destructive) { onClear() }
        } else {
            Button("Save Latest Copy Here") { onSaveLatest() }
        }
    }
}
