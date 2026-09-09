import Foundation

/// Translator for the tab-separated text Logic mirrors to the pasteboard on
/// ⌘C. Two row shapes exist (verified live):
///
///   Tracks area  →  ` \t  \t 1 1 1 1 \t hc_test\t 1\t 1 0 0 0\t`
///                    (position · region name · track № · length)
///   Piano Roll / Score / Event List →
///                   ` \t  \t 1 1 1 1 \t Note\t 1\t C4\t 100\t 0 1 0 0\t`
///                    (position · type · channel · pitch · velocity · length)
///                   interleaved with `\t\t\t Rel Vel\t\t\t 0\t\t` rows.
///
/// Positions and lengths are `bar beat division tick`. New captures from
/// Logic are filtered out of history, but items captured by older builds
/// (and anything a user pastes deliberately) deserve a readable rendering.
enum LogicEventText {

    struct Position {
        let bar: Int, beat: Int, division: Int, tick: Int
        var display: String { "\(bar).\(beat).\(division).\(tick)" }
    }

    enum Row {
        case note(position: Position, pitch: String, velocity: Int, length: Position)
        case region(position: Position, name: String, track: String, length: Position)
        case other(position: Position, type: String, detail: String)
    }

    // MARK: - Parsing

    /// Non-nil only when every non-empty line is recognizably Logic's
    /// format — never mangles ordinary copied text.
    static func parse(_ text: String) -> [Row]? {
        var rows: [Row] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let first = line.first, first == " " || first == "\t" else { return nil }
            let tokens = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            // Continuation rows ("Rel Vel 0") annotate the previous note.
            if tokens.first == "Rel Vel" { continue }
            guard tokens.count >= 3, let position = fourInts(tokens[0]) else { return nil }

            if tokens[1] == "Note", tokens.count >= 6,
               let velocity = Int(tokens[4]), let length = fourInts(tokens[5]) {
                rows.append(.note(position: position, pitch: tokens[3],
                                  velocity: velocity, length: length))
            } else if tokens.count >= 4, let length = fourInts(tokens[3]) {
                rows.append(.region(position: position, name: tokens[1],
                                    track: tokens[2], length: length))
            } else {
                rows.append(.other(position: position, type: tokens[1],
                                   detail: tokens.dropFirst(2).joined(separator: " ")))
            }
        }
        return rows.isEmpty ? nil : rows
    }

    private static func fourInts(_ s: String) -> Position? {
        let parts = s.split(separator: " ").compactMap { Int($0) }
        guard parts.count == 4 else { return nil }
        return Position(bar: parts[0], beat: parts[1], division: parts[2], tick: parts[3])
    }

    // MARK: - Rendering

    /// One-line preview for history rows and slots.
    static func summary(_ rows: [Row]) -> String {
        var pitches: [String] = []
        var regionNames: [String] = []
        var others = 0
        for row in rows {
            switch row {
            case .note(_, let pitch, _, _): pitches.append(pitch)
            case .region(_, let name, _, _): regionNames.append(name)
            case .other: others += 1
            }
        }
        if !pitches.isEmpty && regionNames.isEmpty && others == 0 {
            if pitches.count <= 6 { return "♪ " + pitches.joined(separator: " · ") }
            return "♪ \(pitches.count) notes · \(pitches.first!)…\(pitches.last!)"
        }
        if !regionNames.isEmpty && pitches.isEmpty && others == 0 {
            let unique = Array(NSOrderedSet(array: regionNames)) as? [String] ?? regionNames
            let list = unique.prefix(3).joined(separator: ", ")
            let suffix = unique.count > 3 ? "…" : ""
            return regionNames.count == 1
                ? "▦ region \(list)"
                : "▦ \(regionNames.count) regions · \(list)\(suffix)"
        }
        return "♪ \(rows.count) Logic events"
    }

    /// Multi-line plain-English rendering for the inspector.
    static func translated(_ rows: [Row]) -> String {
        var lines = ["— Logic event list, translated —", ""]
        for row in rows {
            switch row {
            case .note(let position, let pitch, let velocity, let length):
                lines.append("\(position.display)  \(pitch)  vel \(velocity)  ·  \(human(length))")
            case .region(let position, let name, let track, let length):
                lines.append("\(position.display)  “\(name)”  track \(track)  ·  \(human(length))")
            case .other(let position, let type, let detail):
                lines.append("\(position.display)  \(type)  \(detail)")
            }
        }
        lines.append("")
        lines.append("(position and length are bar.beat.division.tick)")
        return lines.joined(separator: "\n")
    }

    /// "0 1 0 0" → "1 beat", "1 0 0 0" → "1 bar", "2 1 0 0" → "2 bars 1 beat".
    private static func human(_ length: Position) -> String {
        var parts: [String] = []
        if length.bar > 0 { parts.append("\(length.bar) bar\(length.bar == 1 ? "" : "s")") }
        if length.beat > 0 { parts.append("\(length.beat) beat\(length.beat == 1 ? "" : "s")") }
        if length.division > 0 || length.tick > 0 {
            parts.append("+\(length.division).\(length.tick)")
        }
        return parts.isEmpty ? "0 length" : parts.joined(separator: " ")
    }
}
