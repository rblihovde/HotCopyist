import AppKit
import Combine

/// Polls the general pasteboard and captures every representation of every
/// new item. Polling is the only supported way to observe the pasteboard on
/// macOS — there is no change notification API.
final class ClipboardMonitor: ObservableObject {

    /// Written alongside anything CopyWiz itself puts on the pasteboard so the
    /// monitor can skip its own writes. Extra private types are ignored by
    /// other apps when pasting.
    static let markerType = NSPasteboard.PasteboardType("org.copywiz.internal")

    /// Representations bigger than this are dropped (protects memory/disk from
    /// e.g. multi-hundred-megabyte image copies).
    static let maxRepresentationBytes = 8 * 1024 * 1024

    @Published var isPaused = false

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
        guard let pbItems = pb.pasteboardItems, !pbItems.isEmpty else { return }

        // Skip our own re-copies.
        if pbItems.contains(where: { $0.types.contains(Self.markerType) }) { return }

        var reps: [ClipboardItem.Representation] = []
        for (index, pbItem) in pbItems.enumerated() {
            for type in pbItem.types {
                guard let data = pbItem.data(forType: type) else { continue }
                guard data.count <= Self.maxRepresentationBytes else { continue }
                reps.append(.init(itemIndex: index, type: type.rawValue, data: data))
            }
        }
        guard !reps.isEmpty else { return }

        let front = NSWorkspace.shared.frontmostApplication
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
    func arm(_ item: ClipboardItem, plainTextOnly: Bool = false) {
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
            arm(item, plainTextOnly: false)
            return
        }

        pb.writeObjects(pbItems)
        lastChangeCount = pb.changeCount
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
