import Foundation

/// A named snapshot of the five hot slots, so a whole slot layout can be
/// saved and recalled later. Occupied slots are stored as (index, item)
/// pairs because plists can't represent nil array elements.
struct SlotSet: Identifiable, Codable, Equatable {

    struct Entry: Codable, Equatable {
        let index: Int
        let item: ClipboardItem
    }

    let id: UUID
    var name: String
    var savedAt: Date
    private(set) var entries: [Entry]

    init(name: String, slots: [ClipboardItem?]) {
        self.id = UUID()
        self.name = name
        self.savedAt = Date()
        self.entries = Self.entries(from: slots)
    }

    /// Number of filled slots in the set.
    var filledCount: Int { entries.count }

    /// Rebuilds a fixed-length slot array (with nils for empty slots).
    func slotsArray(count: Int) -> [ClipboardItem?] {
        var array = [ClipboardItem?](repeating: nil, count: count)
        for entry in entries where array.indices.contains(entry.index) {
            array[entry.index] = entry.item
        }
        return array
    }

    /// Re-captures the layout from the current live slots, refreshing the
    /// timestamp.
    mutating func update(from slots: [ClipboardItem?]) {
        entries = Self.entries(from: slots)
        savedAt = Date()
    }

    private static func entries(from slots: [ClipboardItem?]) -> [Entry] {
        slots.enumerated().compactMap { index, item in
            item.map { Entry(index: index, item: $0) }
        }
    }
}
