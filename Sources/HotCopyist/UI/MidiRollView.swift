import SwiftUI

/// A tiny piano-roll rendering of a MIDI clip — note bars laid out in time
/// (x) and pitch (y), colored per track. Used as the thumbnail for Logic
/// clips in history rows, hot slots, and the inspector.
struct MidiRollView: View {
    let summary: MidiClipSummary

    /// Track colors cycle through the app accents so multi-track clips read
    /// at a glance.
    private static let trackColors: [Color] = [
        Theme.mint, Theme.amber, .purple, .teal, .pink, .indigo,
    ]

    var body: some View {
        Canvas { context, size in
            let total = summary.totalTicks
            guard total > 0, let range = summary.pitchRange else { return }

            // Pad the pitch axis so single-pitch clips still draw mid-height,
            // and clamp the span so sparse clips don't become giant blobs.
            let lo = range.lowerBound - 1
            let hi = range.upperBound + 1
            let span = CGFloat(max(hi - lo, 7))
            let rowHeight = min(max(size.height / span, 1.5), 4)

            for note in summary.notes {
                let x = CGFloat(note.start) / CGFloat(total) * size.width
                let width = max(1.5, CGFloat(note.duration) / CGFloat(total) * size.width - 0.5)
                let pitchNorm = CGFloat(hi - note.pitch) / CGFloat(hi - lo)
                let y = pitchNorm * (size.height - rowHeight)
                let rect = CGRect(x: x, y: y, width: width, height: rowHeight)
                let color = Self.trackColors[note.track % Self.trackColors.count]
                context.fill(
                    Path(roundedRect: rect, cornerRadius: rowHeight / 2),
                    with: .color(color.opacity(0.9))
                )
            }
        }
    }
}

/// The framed 30×30 thumbnail used in history rows.
struct MidiRollThumb: View {
    let summary: MidiClipSummary

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.mint.opacity(0.08))
            MidiRollView(summary: summary)
                .padding(4)
        }
        .frame(width: 30, height: 30)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        )
    }
}
