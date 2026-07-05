import Foundation
import Combine

/// Observable clipboard history with debounced persistence to
/// ~/Library/Application Support/CopyWiz/history.plist (binary plist).
final class HistoryStore: ObservableObject {

    @Published private(set) var items: [ClipboardItem] = []

    let maxUnpinnedItems = 300

    private var saveWork: DispatchWorkItem?

    private let saveURL: URL = {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CopyWiz", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.plist")
    }()

    init() {
        load()
    }

    // MARK: - Mutations

    func insert(_ item: ClipboardItem) {
        // Re-copying identical content surfaces the existing entry instead of
        // duplicating it (pin state survives).
        if let existingIndex = items.firstIndex(where: { $0.contentHash == item.contentHash }) {
            var existing = items.remove(at: existingIndex)
            existing.copiedAt = item.copiedAt
            items.insert(existing, at: 0)
        } else {
            items.insert(item, at: 0)
        }
        trim()
        scheduleSave()
    }

    func togglePin(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isPinned.toggle()
        scheduleSave()
    }

    func delete(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        scheduleSave()
    }

    /// Removes everything except pinned items.
    func clearUnpinned() {
        items.removeAll { !$0.isPinned }
        scheduleSave()
    }

    func clearAll() {
        items.removeAll()
        scheduleSave()
    }

    private func trim() {
        var unpinnedSeen = 0
        items = items.filter { item in
            if item.isPinned { return true }
            unpinnedSeen += 1
            return unpinnedSeen <= maxUnpinnedItems
        }
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = items
        let url = saveURL
        let work = DispatchWorkItem {
            Self.write(snapshot, to: url)
        }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        Self.write(items, to: saveURL)
    }

    private static func write(_ items: [ClipboardItem], to url: URL) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: saveURL) else { return }
        items = (try? PropertyListDecoder().decode([ClipboardItem].self, from: data)) ?? []
    }
}
