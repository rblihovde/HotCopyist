import SwiftUI
import AppKit

private enum ThumbCache {
    static let cache = NSCache<NSUUID, NSImage>()

    static func image(for item: ClipboardItem) -> NSImage? {
        if let cached = cache.object(forKey: item.id as NSUUID) { return cached }
        guard let image = item.image else { return nil }
        cache.setObject(image, forKey: item.id as NSUUID)
        return image
    }
}

struct HistoryRow: View {
    let item: ClipboardItem
    let isSelected: Bool
    let now: Date
    var onArm: (_ pasteNow: Bool) -> Void
    var onArmPlain: () -> Void
    var onInspect: () -> Void
    var onPin: () -> Void
    var onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            glyph

            VStack(alignment: .leading, spacing: 3) {
                preview
                Text(metaString)
                    .font(Theme.monoSmall)
                    .tracking(0.5)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if hovering || isSelected {
                actions
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Theme.mint.opacity(0.07) : (hovering ? Theme.rowHover : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Theme.mint.opacity(0.5) : .clear, lineWidth: 1)
        )
        .shadow(color: isSelected ? Theme.mint.opacity(0.15) : .clear, radius: 7)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            onArm(NSEvent.modifierFlags.contains(.command))
        }
        .contextMenu { menu }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    // MARK: - Pieces

    @ViewBuilder
    private var glyph: some View {
        if item.kind == .image, let thumb = ThumbCache.image(for: item) {
            Image(nsImage: thumb)
                .resizable()
                .scaledToFill()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 1)
                )
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 30, height: 30)
                Image(systemName: glyphName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(glyphColor)
            }
        }
    }

    private var glyphName: String {
        switch item.kind {
        case .text: return "text.alignleft"
        case .rich: return "textformat"
        case .image: return "photo"
        case .fileURL: return "doc"
        case .mystery: return "cube.transparent"
        }
    }

    private var glyphColor: Color {
        item.kind == .mystery ? Theme.amber : Theme.mint.opacity(0.85)
    }

    @ViewBuilder
    private var preview: some View {
        Text(item.previewText)
            .font(Theme.mono)
            .foregroundStyle(item.kind == .mystery ? Theme.amber.opacity(0.95) : Theme.textPrimary)
            .lineLimit(2)
            .truncationMode(.tail)
    }

    private var metaString: String {
        var parts: [String] = []
        if let app = item.sourceAppName { parts.append(app.uppercased()) }
        parts.append(Fmt.rel(item.copiedAt, now: now).uppercased())
        parts.append(Fmt.size(item.totalBytes).uppercased())
        parts.append("\(item.reps.count) \(item.reps.count == 1 ? "TYPE" : "TYPES")")
        return parts.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: 8) {
            rowButton(item.isPinned ? "pin.slash" : "pin",
                      help: item.isPinned ? "Unpin" : "Pin",
                      tint: item.isPinned ? Theme.amber : Theme.textSecondary,
                      action: onPin)
            rowButton("waveform.badge.magnifyingglass", help: "Inspect payload", tint: Theme.textSecondary, action: onInspect)
            rowButton("xmark", help: "Delete", tint: Theme.textSecondary, action: onDelete)
        }
    }

    private func rowButton(_ symbol: String, help: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Copy — Ready for ⌘V") { onArm(false) }
        Button("Paste Now") { onArm(true) }
        if item.plainText != nil && item.reps.count > 1 {
            Button("Copy as Plain Text") { onArmPlain() }
        }
        Divider()
        Button(item.isPinned ? "Unpin" : "Pin") { onPin() }
        Button("Inspect Payload") { onInspect() }
        Divider()
        Button("Delete", role: .destructive) { onDelete() }
    }
}
