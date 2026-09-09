import Foundation
import Combine

/// Observable clipboard history plus five persistent "hot slots", saved to
/// ~/Library/Application Support/HotCopy/ as binary plists. The folder keeps
/// the app's pre-rename name (HotCopy → HotCopyist) on purpose: existing
/// users' history and slots must survive the rename.
final class HistoryStore: ObservableObject {

    static let slotCount = 5

    @Published private(set) var items: [ClipboardItem] = []

    /// Five saved items, always one click (or ⌃⌘1–5) away from pasting.
    /// Slots hold independent copies — deleting or clearing history never
    /// touches them.
    @Published private(set) var slots: [ClipboardItem?] = Array(repeating: nil, count: HistoryStore.slotCount)

    /// Named snapshots of the full hot-slot layout, so a whole slot
    /// configuration can be recalled later.
    @Published private(set) var slotSets: [SlotSet] = []

    let maxUnpinnedItems = 300

    private var saveWork: DispatchWorkItem?

    private static let directory: URL = {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("HotCopy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        migrateLegacyData(from: support.appendingPathComponent("CopyWiz", isDirectory: true), to: dir)
        return dir
    }()

    /// Moves data saved under the app's former name (CopyWiz) into the new
    /// HotCopy folder, once, if the new folder is still empty.
    private static func migrateLegacyData(from old: URL, to new: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path) else { return }
        for name in ["history.plist", "slots.plist", "slotsets.plist"] {
            let src = old.appendingPathComponent(name)
            let dst = new.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) {
                try? fm.copyItem(at: src, to: dst)
            }
        }
    }

    private let saveURL = HistoryStore.directory.appendingPathComponent("history.plist")
    private let slotsURL = HistoryStore.directory.appendingPathComponent("slots.plist")
    private let slotSetsURL = HistoryStore.directory.appendingPathComponent("slotsets.plist")

    init() {
        load()
        loadSlots()
        loadSlotSets()
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

    /// Sets (or clears, when passed nil/blank) a user label on an item,
    /// keeping any hot slot holding the same item in sync.
    func setName(_ name: String?, for id: UUID) {
        let cleaned = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (cleaned?.isEmpty ?? true) ? nil : cleaned
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].customName = value
        }
        for slotIndex in slots.indices where slots[slotIndex]?.id == id {
            slots[slotIndex]?.customName = value
        }
        scheduleSave()
        saveSlotsAsync()
    }

    /// Finds an item by id, searching history first, then the hot slots.
    func item(withID id: UUID) -> ClipboardItem? {
        items.first { $0.id == id } ?? slots.compactMap { $0 }.first { $0.id == id }
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

    // MARK: - Hot slots

    func setSlot(_ index: Int, to item: ClipboardItem?) {
        guard slots.indices.contains(index) else { return }
        slots[index] = item
        saveSlotsAsync()
    }

    // MARK: - Slot sets (saved hot-slot layouts)

    /// True when at least one hot slot is filled (nothing to save otherwise).
    var hasFilledSlots: Bool { slots.contains { $0 != nil } }

    /// Captures the current hot-slot layout as a new named set.
    func saveCurrentSlotsAsSet(named name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        slotSets.insert(SlotSet(name: cleaned, slots: slots), at: 0)
        saveSlotSetsAsync()
    }

    /// Overwrites an existing set with the current hot-slot layout.
    func updateSlotSet(_ id: UUID) {
        guard let index = slotSets.firstIndex(where: { $0.id == id }) else { return }
        slotSets[index].update(from: slots)
        saveSlotSetsAsync()
    }

    func renameSlotSet(_ id: UUID, to name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let index = slotSets.firstIndex(where: { $0.id == id }) else { return }
        slotSets[index].name = cleaned
        saveSlotSetsAsync()
    }

    func deleteSlotSet(_ id: UUID) {
        slotSets.removeAll { $0.id == id }
        saveSlotSetsAsync()
    }

    /// Replaces the live hot slots with a saved set's layout.
    func applySlotSet(_ id: UUID) {
        guard let set = slotSets.first(where: { $0.id == id }) else { return }
        slots = set.slotsArray(count: Self.slotCount)
        saveSlotsAsync()
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
        Self.write(storedSlots, to: slotsURL)
        Self.write(slotSets, to: slotSetsURL)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: saveURL) else { return }
        items = (try? PropertyListDecoder().decode([ClipboardItem].self, from: data)) ?? []
    }

    // MARK: - Slot persistence

    /// Plists can't represent nil array elements, so occupied slots are
    /// stored as (index, item) pairs.
    private struct StoredSlot: Codable {
        let index: Int
        let item: ClipboardItem
    }

    private var storedSlots: [StoredSlot] {
        slots.enumerated().compactMap { index, item in
            item.map { StoredSlot(index: index, item: $0) }
        }
    }

    private func saveSlotsAsync() {
        let snapshot = storedSlots
        let url = slotsURL
        DispatchQueue.global(qos: .utility).async {
            Self.write(snapshot, to: url)
        }
    }

    private func loadSlots() {
        guard let data = try? Data(contentsOf: slotsURL),
              let stored = try? PropertyListDecoder().decode([StoredSlot].self, from: data) else { return }
        for entry in stored where slots.indices.contains(entry.index) {
            slots[entry.index] = entry.item
        }
    }

    // MARK: - Slot-set persistence

    private func saveSlotSetsAsync() {
        let snapshot = slotSets
        let url = slotSetsURL
        DispatchQueue.global(qos: .utility).async {
            Self.write(snapshot, to: url)
        }
    }

    private func loadSlotSets() {
        guard let data = try? Data(contentsOf: slotSetsURL) else { return }
        slotSets = (try? PropertyListDecoder().decode([SlotSet].self, from: data)) ?? []
    }
}
