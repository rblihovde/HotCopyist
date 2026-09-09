import Foundation

/// A parsed view of a Standard MIDI File payload (Logic clips), enough to
/// draw a mini piano roll and describe the clip in human terms. Parsing is
/// tolerant: anything malformed just ends the walk early — a partial summary
/// beats no summary for display purposes.
struct MidiClipSummary {

    struct Note {
        let start: Int      // absolute ticks
        let duration: Int   // ticks
        let pitch: Int      // 0–127
        let track: Int      // 0-based index among tracks that contain notes
    }

    let notes: [Note]
    let ppq: Int
    let timeSigNumerator: Int
    let timeSigDenominator: Int

    // MARK: - Derived

    var noteCount: Int { notes.count }

    /// Number of distinct note-bearing tracks.
    var trackCount: Int { Set(notes.map(\.track)).count }

    var totalTicks: Int { notes.map { $0.start + $0.duration }.max() ?? 0 }

    var pitchRange: ClosedRange<Int>? {
        guard let lo = notes.map(\.pitch).min(), let hi = notes.map(\.pitch).max() else { return nil }
        return lo...hi
    }

    var barCount: Int {
        let ticksPerBar = ppq * 4 * timeSigNumerator / max(1, timeSigDenominator)
        guard ticksPerBar > 0, totalTicks > 0 else { return 0 }
        return (totalTicks + ticksPerBar - 1) / ticksPerBar
    }

    /// Note 60 = C4, matching how this Logic install labels pitches.
    static func noteName(_ pitch: Int) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        return names[pitch % 12] + String(pitch / 12 - 1)
    }

    /// Chill, human description. Short single-line phrases get spelled out;
    /// anything bigger gets bars/notes/tracks.
    var summaryText: String {
        guard noteCount > 0 else { return "♪ empty clip" }
        if noteCount <= 6 && trackCount == 1 {
            let names = notes.sorted { $0.start < $1.start }.map { Self.noteName($0.pitch) }
            return "♪ " + names.joined(separator: " · ")
        }
        var parts: [String] = []
        let bars = barCount
        if bars > 0 { parts.append(bars == 1 ? "1 bar" : "\(bars) bars") }
        parts.append("\(noteCount) notes")
        if trackCount > 1 { parts.append("\(trackCount) tracks") }
        return "♪ " + parts.joined(separator: " · ")
    }

    // MARK: - Parsing

    init?(data: Data) {
        guard data.count > 14, data.starts(with: Data("MThd".utf8)) else { return nil }
        let headerLen = Int(data[4]) << 24 | Int(data[5]) << 16 | Int(data[6]) << 8 | Int(data[7])
        let division = Int(data[12]) << 8 | Int(data[13])
        guard division & 0x8000 == 0, division > 0 else { return nil }  // SMPTE division unsupported
        ppq = division

        var notes: [Note] = []
        var sigNum = 4
        var sigDen = 4
        var sawTimeSig = false
        var noteTrack = 0

        let mtrk = Data("MTrk".utf8)
        var i = 8 + headerLen
        while i + 8 <= data.count {
            let length = Int(data[i + 4]) << 24 | Int(data[i + 5]) << 16
                | Int(data[i + 6]) << 8 | Int(data[i + 7])
            let start = i + 8
            let end = min(start + length, data.count)
            if data[i..<i + 4].elementsEqual(mtrk) {
                let (trackNotes, sig) = Self.walkTrack(data, from: start, to: end,
                                                       track: noteTrack, ppq: ppq)
                if let sig, !sawTimeSig {
                    (sigNum, sigDen) = sig
                    sawTimeSig = true
                }
                if !trackNotes.isEmpty {
                    notes.append(contentsOf: trackNotes)
                    noteTrack += 1
                }
            }
            i = start + length
        }

        self.notes = notes
        self.timeSigNumerator = sigNum
        self.timeSigDenominator = sigDen
    }

    /// Walks one MTrk chunk. Returns its notes (with durations, matched
    /// note-on → note-off) and the first time signature found, if any.
    private static func walkTrack(_ data: Data, from: Int, to: Int,
                                  track: Int, ppq: Int) -> ([Note], (Int, Int)?) {
        var i = from
        var running: UInt8 = 0
        var tick = 0
        var pending: [Int: [Int]] = [:]     // pitch → start ticks (FIFO)
        var notes: [Note] = []
        var sig: (Int, Int)?

        func readVLQ() -> Int {
            var value = 0
            while i < to {
                value = (value << 7) | Int(data[i] & 0x7F)
                let more = data[i] & 0x80 != 0
                i += 1
                if !more { break }
            }
            return value
        }

        func closeNote(pitch: Int) {
            guard var starts = pending[pitch], !starts.isEmpty else { return }
            let start = starts.removeFirst()
            pending[pitch] = starts
            notes.append(Note(start: start, duration: max(1, tick - start),
                              pitch: pitch, track: track))
        }

        while i < to {
            tick += readVLQ()
            guard i < to else { break }
            var status = data[i]
            if status & 0x80 != 0 {
                i += 1
                if status < 0xF0 { running = status }
            } else {
                status = running
            }
            switch status {
            case 0x90...0x9F:
                guard i + 1 < to else { break }
                let pitch = Int(data[i])
                let velocity = data[i + 1]
                i += 2
                if velocity > 0 {
                    pending[pitch, default: []].append(tick)
                } else {
                    closeNote(pitch: pitch)
                }
            case 0x80...0x8F:
                guard i + 1 < to else { break }
                closeNote(pitch: Int(data[i]))
                i += 2
            case 0xA0...0xBF, 0xE0...0xEF:
                i += 2
            case 0xC0...0xDF:
                i += 1
            case 0xFF:
                guard i < to else { break }
                let metaType = data[i]
                i += 1
                let length = readVLQ()
                if metaType == 0x58, length >= 2, i + 1 < to {
                    sig = sig ?? (Int(data[i]), 1 << Int(data[i + 1]))
                }
                i += length
            case 0xF0, 0xF7:
                i += readVLQ()
            default:
                i += 1
            }
        }

        // Notes never closed (truncated file): give them a tail.
        for (pitch, starts) in pending {
            for start in starts {
                notes.append(Note(start: start, duration: ppq / 2, pitch: pitch, track: track))
            }
        }
        return (notes, sig)
    }
}

/// Parsed summaries are cached per item — history rows redraw constantly and
/// re-parsing MIDI on every frame would be wasteful.
enum MidiSummaryCache {
    private final class Box {
        let summary: MidiClipSummary?
        init(_ summary: MidiClipSummary?) { self.summary = summary }
    }

    private static let cache = NSCache<NSUUID, AnyObject>()

    static func summary(for item: ClipboardItem) -> MidiClipSummary? {
        if let boxed = cache.object(forKey: item.id as NSUUID) as? Box { return boxed.summary }
        let summary = item.data(for: LogicClipService.repType).flatMap(MidiClipSummary.init)
        cache.setObject(Box(summary), forKey: item.id as NSUUID)
        return summary
    }
}
