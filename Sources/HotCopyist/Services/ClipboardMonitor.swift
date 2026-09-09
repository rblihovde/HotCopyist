import AppKit
import Combine

/// Polls the general pasteboard and captures every representation of every
/// new item. Polling is the only supported way to observe the pasteboard on
/// macOS — there is no change notification API.
final class ClipboardMonitor: ObservableObject {

    /// Written alongside anything HotCopyist itself puts on the pasteboard so the
    /// monitor can skip its own writes. Extra private types are ignored by
    /// other apps when pasting.
    static let markerType = NSPasteboard.PasteboardType("com.blihovde.hotcopy.internal")

    /// Representations bigger than this are dropped (protects memory/disk from
    /// e.g. multi-hundred-megabyte image copies).
    static let maxRepresentationBytes = 8 * 1024 * 1024

    /// Ceiling for one captured item across all of its representations. The
    /// per-representation cap alone isn't enough: a single copy can carry
    /// dozens of types, and history is held in memory as well as on disk.
    static let maxItemBytes = 32 * 1024 * 1024

    @Published var isPaused = false

    /// Handles arming of Finale music clips, which live in Finale's clip
    /// file rather than on the system pasteboard.
    var finaleService: FinaleClipService?

    /// Handles capture and placement of Logic Pro clips (MIDI export/import
    /// automation — Logic's music clipboard is unreachable RAM).
    var logicService: LogicClipService?

    /// What arming an item did, so callers know whether a synthesized ⌘V
    /// still makes sense.
    enum ArmResult {
        /// Item is on the pasteboard (or in Finale's clip file) — ⌘V pastes it.
        case pasteboard
        /// An app adapter performed the placement itself; do not send ⌘V.
        case handledExternally
    }

    private let store: HistoryStore
    private var timer: Timer?
    private var lastChangeCount: Int

    init(store: HistoryStore) {
        self.store = store
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        guard !isPaused else { return }
        attemptCapture(changeCount: lastChangeCount, attemptsLeft: 10)
    }

    /// Tries to read every representation of the current pasteboard change.
    /// Apps that publish data lazily (promises — common in older apps like
    /// Finale) can return nil for every type at the moment the change count
    /// ticks, so an empty read is retried for a couple of seconds before the
    /// change is given up on.
    private func attemptCapture(changeCount: Int, attemptsLeft: Int) {
        let pb = NSPasteboard.general
        // A newer copy supersedes this one; poll() will pick it up.
        guard pb.changeCount == changeCount else { return }
        // Pausing part-way through a retry chain has to stop it too, or a clip
        // the user meant to keep out of history still lands there.
        guard !isPaused else { return }

        var reps: [ClipboardItem.Representation] = []
        var totalBytes = 0
        if let pbItems = pb.pasteboardItems, !pbItems.isEmpty {
            // Skip our own re-copies.
            if pbItems.contains(where: { $0.types.contains(Self.markerType) }) { return }

            for (index, pbItem) in pbItems.enumerated() {
                for type in pbItem.types {
                    guard let data = pbItem.data(forType: type) else { continue }
                    guard data.count <= Self.maxRepresentationBytes else { continue }
                    guard totalBytes + data.count <= Self.maxItemBytes else { continue }
                    totalBytes += data.count
                    reps.append(.init(itemIndex: index, type: type.rawValue, data: data))
                }
            }
        }

        guard !reps.isEmpty else {
            if attemptsLeft > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.attemptCapture(changeCount: changeCount, attemptsLeft: attemptsLeft - 1)
                }
            }
            return
        }

        let front = NSWorkspace.shared.frontmostApplication

        // Logic mirrors a useless textual track summary to the pasteboard on
        // every region ⌘C; the real music never leaves Logic's RAM. Keep
        // those rows out of history (capture happens via the Logic hotkey).
        if front?.bundleIdentifier == LogicClipService.bundleID,
           reps.allSatisfy({ $0.type.lowercased().contains("text") || $0.type.lowercased().contains("string") }),
           let text = reps.first.flatMap({ String(data: $0.data, encoding: .utf8) }),
           LogicClipService.isTrackSummaryText(text) {
            return
        }

        let item = ClipboardItem(
            reps: reps,
            sourceAppName: front?.localizedName,
            sourceBundleID: front?.bundleIdentifier
        )
        store.insert(item)
    }

    // MARK: - Writing back

    /// Puts a history item back on the pasteboard with every original
    /// representation intact, so the next ⌘V pastes it exactly as first copied.
    @discardableResult
    func arm(_ item: ClipboardItem, plainTextOnly: Bool = false) -> ArmResult {
        // Music clips bypass the pasteboard entirely. Logic clips are placed
        // into the project directly; Finale clips rewrite Finale's clip file
        // and still want the ⌘V.
        if item.kind == .music {
            if let logic = logicService, logic.arm(item) {
                return .handledExternally
            }
            if let finale = finaleService {
                finale.arm(item)
                return .pasteboard
            }
            return .pasteboard
        }

        let pb = NSPasteboard.general
        pb.clearContents()

        var pbItems: [NSPasteboardItem] = []
        let grouped = Dictionary(grouping: item.reps, by: \.itemIndex)
        for index in grouped.keys.sorted() {
            let pbItem = NSPasteboardItem()
            var wroteAnything = false
            for rep in grouped[index] ?? [] {
                if plainTextOnly && rep.type != "public.utf8-plain-text" { continue }
                pbItem.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.type))
                wroteAnything = true
            }
            if wroteAnything {
                pbItem.setData(Data(), forType: Self.markerType)
                pbItems.append(pbItem)
            }
        }

        // Fall back to the full payload if plain-text filtering emptied it.
        if pbItems.isEmpty {
            return arm(item, plainTextOnly: false)
        }

        pb.writeObjects(pbItems)
        lastChangeCount = pb.changeCount
        return .pasteboard
    }

    /// Copies a plain string (used by the inspector's "copy dump" button)
    /// without recording it in history.
    func copyText(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let pbItem = NSPasteboardItem()
        pbItem.setString(string, forType: .string)
        pbItem.setData(Data(), forType: Self.markerType)
        pb.writeObjects([pbItem])
        lastChangeCount = pb.changeCount
    }
}
