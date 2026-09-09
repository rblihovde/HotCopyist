import AppKit
import CryptoKit
import UniformTypeIdentifiers

/// One captured clipboard entry. Stores every representation (UTI + raw bytes)
/// that was on the pasteboard, so re-copying an item restores it exactly —
/// including exotic app-private payloads (Finale measures, Sketch layers, …).
struct ClipboardItem: Identifiable, Codable, Equatable {

    struct Representation: Codable, Equatable, Hashable {
        /// Which NSPasteboardItem this representation belonged to.
        /// (A multi-file copy in Finder produces several pasteboard items.)
        let itemIndex: Int
        /// The raw pasteboard type identifier (usually a UTI).
        let type: String
        let data: Data
    }

    let id: UUID
    var copiedAt: Date
    let sourceAppName: String?
    let sourceBundleID: String?
    let reps: [Representation]
    var isPinned: Bool
    let contentHash: String
    /// User-supplied label to tell similar clips apart. Optional so older
    /// stored history (without this field) still decodes.
    var customName: String?

    init(reps: [Representation], sourceAppName: String?, sourceBundleID: String?) {
        self.id = UUID()
        self.copiedAt = Date()
        self.sourceAppName = sourceAppName
        self.sourceBundleID = sourceBundleID
        self.reps = reps
        self.isPinned = false
        self.contentHash = Self.hash(of: reps)
        self.customName = nil
    }

    static func hash(of reps: [Representation]) -> String {
        var hasher = SHA256()
        for rep in reps.sorted(by: { ($0.itemIndex, $0.type) < ($1.itemIndex, $1.type) }) {
            hasher.update(data: Data(rep.type.utf8))
            hasher.update(data: rep.data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func data(for type: String) -> Data? {
        reps.first { $0.type == type }?.data
    }

    var totalBytes: Int {
        reps.reduce(0) { $0 + $1.data.count }
    }

    // MARK: - Content classification

    enum Kind {
        case text
        case rich
        case image
        case fileURL
        case music
        case mystery
    }

    private static let imageTypes: Set<String> = [
        "public.png", "public.tiff", "public.jpeg", "com.compuserve.gif", "public.heic"
    ]

    var kind: Kind {
        let types = Set(reps.map(\.type))
        if types.contains(FinaleClipService.repType)
            || types.contains(FinaleClipService.legacyRepType)
            || types.contains(LogicClipService.repType) { return .music }
        if types.contains("public.file-url") { return .fileURL }
        if !types.isDisjoint(with: Self.imageTypes) { return .image }
        if types.contains("public.utf8-plain-text") || types.contains("public.rtf") {
            if types.contains("public.rtf") || types.contains("public.html") { return .rich }
            return .text
        }
        return .mystery
    }

    var plainText: String? {
        if let d = data(for: "public.utf8-plain-text"), let s = String(data: d, encoding: .utf8) { return s }
        if let d = data(for: "public.rtf"), let a = NSAttributedString(rtf: d, documentAttributes: nil) { return a.string }
        if let d = data(for: "public.html"), let s = String(data: d, encoding: .utf8) { return s }
        return nil
    }

    var fileURLs: [URL] {
        reps.filter { $0.type == "public.file-url" }
            .compactMap { URL(dataRepresentation: $0.data, relativeTo: nil) }
    }

    var image: NSImage? {
        for type in ["public.png", "public.tiff", "public.jpeg", "com.compuserve.gif", "public.heic"] {
            if let d = data(for: type), let img = NSImage(data: d) { return img }
        }
        return nil
    }

    /// The most descriptive pasteboard type — used as the label for
    /// app-private payloads that carry no text or image representation.
    var interestingType: String? {
        let types = reps.map(\.type)
        return types.first { !$0.hasPrefix("dyn.") && $0 != ClipboardMonitor.markerType.rawValue } ?? types.first
    }

    /// Trimmed user label, or nil if unset/blank.
    var trimmedName: String? {
        guard let name = customName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        return name
    }

    /// What to show as the item's title: the user's label if present,
    /// otherwise the auto-generated preview.
    var displayName: String {
        trimmedName ?? previewText
    }

    var previewText: String {
        switch kind {
        case .text, .rich:
            let raw = plainText ?? ""
            // Logic's tabular event/region mirrors read as noise; translate.
            if let rows = LogicEventText.parse(raw) {
                return LogicEventText.summary(rows)
            }
            let collapsed = raw
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return collapsed.isEmpty ? "(empty text)" : String(collapsed.prefix(240))
        case .fileURL:
            let names = fileURLs.map(\.lastPathComponent)
            return names.isEmpty ? "(file)" : names.joined(separator: "  ·  ")
        case .image:
            if let img = image {
                return "Image · \(Int(img.size.width))×\(Int(img.size.height))"
            }
            return "Image"
        case .music:
            if data(for: LogicClipService.repType) != nil {
                return MidiSummaryCache.summary(for: self)?.summaryText ?? "♪ Logic clip"
            }
            return "♪ Finale music clip"
        case .mystery:
            return "⟨\(interestingType ?? "unknown payload")⟩"
        }
    }
}
