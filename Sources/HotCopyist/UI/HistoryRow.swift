import SwiftUI
import AppKit

enum ThumbCache {
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
    var onSaveToSlot: (_ slotIndex: Int) -> Void
    var onRename: () -> Void
    var onClearName: () -> Void

    @State private var hovering = false
    @ObservedObject private var shortcuts = ShortcutStore.shared

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            glyph

            VStack(alignment: .leading, spacing: 3) {
                title
                Text(metaString)
                    .font(Theme.monoSmall)
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
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Theme.mint.opacity(0.16) : (hovering ? Theme.rowHover : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            onArm(NSEvent.modifierFlags.contains(.command))
        }
        .draggable(item.id.uuidString) {
            dragPreview
        }
        .contextMenu { menu }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// Small label shown under the cursor while dragging onto a hot slot.
    private var dragPreview: some View {
        HStack(spacing: 6) {
            Image(systemName: glyphName).font(.system(size: 11)).foregroundStyle(glyphColor)
            Text(String(item.displayName.prefix(28)))
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
    }

    // MARK: - Pieces

    @ViewBuilder
    private var glyph: some View {
        if item.kind == .music, let summary = MidiSummaryCache.summary(for: item) {
            MidiRollThumb(summary: summary)
        } else if item.kind == .image, let thumb = ThumbCache.image(for: item) {
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
                    .fill(Color.primary.opacity(0.05))
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
        case .music: return "music.note"
        case .mystery: return "cube.transparent"
        }
    }

    private var glyphColor: Color {
        switch item.kind {
        case .mystery: return Theme.amber
        case .music: return Theme.mint
        default: return Theme.textSecondary
        }
    }

    @ViewBuilder
    private var title: some View {
        if let name = item.trimmedName {
            // Named clip: label on top, auto-preview as a dim subtitle.
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: "tag.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.mint)
                    Text(name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(item.previewText)
                    .font(Theme.monoSmall)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else {
            Text(item.previewText)
                .font(item.kind == .mystery ? Theme.monoData : Theme.mono)
                .foregroundStyle(item.kind == .mystery ? Theme.textSecondary : Theme.textPrimary)
                .lineLimit(2)
                .truncationMode(.tail)
        }
    }

    /// The global shortcut currently bound to a hot slot.
    private func slotShortcut(_ index: Int) -> String {
        guard let action = ShortcutAction.allCases.first(where: { $0.slotIndex == index }) else {
            return ""
        }
        return shortcuts[action].displayString
    }

    private var metaString: String {
        var parts: [String] = []
        if let app = item.sourceAppName { parts.append(app) }
        parts.append(Fmt.rel(item.copiedAt, now: now))
        parts.append(Fmt.size(item.totalBytes))
        parts.append("\(item.reps.count) \(item.reps.count == 1 ? "type" : "types")")
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
                .background(Circle().fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Copy") { onArm(false) }
        Button("Paste Now") { onArm(true) }
        if item.plainText != nil && item.reps.count > 1 {
            Button("Copy as Plain Text") { onArmPlain() }
        }
        Divider()
        Button(item.trimmedName == nil ? "Name This Clip…" : "Rename…") { onRename() }
        if item.trimmedName != nil {
            Button("Clear Name") { onClearName() }
        }
        Divider()
        Menu("Save to Hot Slot") {
            ForEach(0..<HistoryStore.slotCount, id: \.self) { slotIndex in
                Button("Slot \(slotIndex + 1)  (\(slotShortcut(slotIndex)))") { onSaveToSlot(slotIndex) }
            }
        }
        Button(item.isPinned ? "Unpin" : "Pin") { onPin() }
        Button("Inspect Payload") { onInspect() }
        Divider()
        Button("Delete", role: .destructive) { onDelete() }
    }
}
