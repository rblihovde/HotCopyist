import SwiftUI
import AppKit
import Combine

struct PanelRootView: View {
    @ObservedObject var controller: PanelController
    @EnvironmentObject private var store: HistoryStore
    @EnvironmentObject private var monitor: ClipboardMonitor

    @State private var searchText = ""
    @State private var selectedID: UUID?
    @State private var inspecting: ClipboardItem?
    @State private var toast: String?
    @State private var toastWork: DispatchWorkItem?
    @State private var now = Date()
    @FocusState private var searchFocused: Bool

    // Reusable inline naming prompt (rename a clip, name a slot set, …).
    @State private var promptTitle: String?
    @State private var promptText = ""
    @State private var promptPlaceholder = ""
    @State private var promptCommit: ((String) -> Void)?
    @FocusState private var promptFocused: Bool

    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    // MARK: - Filtering

    private var pinnedItems: [ClipboardItem] { store.items.filter { $0.isPinned && matches($0) } }
    private var historyItems: [ClipboardItem] { store.items.filter { !$0.isPinned && matches($0) } }
    private var flatList: [ClipboardItem] { pinnedItems + historyItems }

    private func matches(_ item: ClipboardItem) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        if item.previewText.lowercased().contains(query) { return true }
        if item.sourceAppName?.lowercased().contains(query) == true { return true }
        if item.reps.contains(where: { $0.type.lowercased().contains(query) }) { return true }
        return false
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            VisualEffectBackground()
            Theme.bgTint

            if controller.collapsed {
                miniBar
            } else {
                VStack(spacing: 0) {
                    header
                    searchBar
                    hotSlotStrip
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    list
                    if let inspecting {
                        InspectorView(item: inspecting, monitor: monitor) {
                            withAnimation(.easeOut(duration: 0.15)) { self.inspecting = nil }
                        }
                        .frame(height: 290)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    footer
                }
            }

            if let toast {
                toastView(toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if promptTitle != nil {
                namePromptBar
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .ignoresSafeArea()
        .onReceive(clock) { now = $0 }
        .onReceive(NotificationCenter.default.publisher(for: .hotCopyPanelDidShow)) { _ in
            selectedID = flatList.first?.id
        }
        .onChange(of: searchText) { _, _ in
            selectedID = flatList.first?.id
        }
        .onReceive(NotificationCenter.default.publisher(for: .hotCopyToast)) { note in
            if let text = note.object as? String { showToast(text) }
        }
        .onChange(of: store.items) { _, newItems in
            if let inspecting,
               !newItems.contains(where: { $0.id == inspecting.id }),
               !store.slots.contains(where: { $0?.id == inspecting.id }) {
                self.inspecting = nil
            }
        }
    }

    // MARK: - Hot slots

    private var hotSlotStrip: some View {
        HStack(spacing: 6) {
            ForEach(0..<HistoryStore.slotCount, id: \.self) { index in
                slotTile(index)
            }
            slotSetsMenu
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    /// Save / recall named hot-slot layouts.
    private var slotSetsMenu: some View {
        Menu {
            Button("Save Current Slots as Set…") { promptSaveSlotSet() }
                .disabled(!store.hasFilledSlots)

            if !store.slotSets.isEmpty {
                Divider()
                Text("Saved Sets")
                ForEach(store.slotSets) { set in
                    Menu("\(set.name)  (\(set.filledCount))") {
                        Button("Load") {
                            store.applySlotSet(set.id)
                            showToast("Loaded “\(set.name)”")
                        }
                        Button("Update to Current Slots") {
                            store.updateSlotSet(set.id)
                            showToast("Updated “\(set.name)”")
                        }
                        Button("Rename…") { promptRenameSlotSet(set) }
                        Divider()
                        Button("Delete", role: .destructive) {
                            store.deleteSlotSet(set.id)
                            showToast("Deleted “\(set.name)”")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "bookmark")
                .font(.system(size: 12))
                .foregroundStyle(store.slotSets.isEmpty ? Theme.textSecondary : Theme.mint)
                .frame(width: 30, height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 1)
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Save or recall a hot-slot layout")
    }

    private func slotTile(_ index: Int) -> HotSlotTile {
        HotSlotTile(
            index: index,
            item: store.slots[index],
            onActivate: { pasteNow in
                if let item = store.slots[index] { arm(item, paste: pasteNow) }
            },
            onSaveLatest: {
                if let latest = store.items.first {
                    store.setSlot(index, to: latest)
                    showToast("Saved to slot \(index + 1)")
                } else {
                    showToast("Nothing to save yet")
                }
            },
            onInspect: {
                if let item = store.slots[index] {
                    withAnimation(.easeOut(duration: 0.15)) { inspecting = item }
                }
            },
            onClear: {
                if let cleared = store.slots[index], inspecting?.id == cleared.id {
                    inspecting = nil
                }
                store.setSlot(index, to: nil)
                showToast("Slot \(index + 1) cleared")
            },
            onRename: {
                if let item = store.slots[index] { promptRename(item) }
            },
            onDropItem: { id in
                guard let item = store.item(withID: id) else { return }
                store.setSlot(index, to: item)
                showToast("Dropped into slot \(index + 1)")
            }
        )
    }

    // MARK: - Mini mode

    /// Collapsed layout: just the status dot, the five hot slots, and the
    /// expand / pin controls in one slim bar.
    private var miniBar: some View {
        HStack(spacing: 6) {
            StatusDot(active: !monitor.isPaused)
                .padding(.trailing, 2)
                .padding(.vertical, 8)
                .background(WindowDragHandle())   // drag here to move the bar
            ForEach(0..<HistoryStore.slotCount, id: \.self) { index in
                slotTile(index)
            }
            VStack(spacing: 4) {
                Button {
                    controller.collapsed = false
                } label: {
                    Image(systemName: "rectangle.expand.vertical")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Expand panel")

                pinButton
            }
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
    }

    private var pinButton: some View {
        Button {
            controller.alwaysOnTop.toggle()
            showToast(controller.alwaysOnTop ? "Staying on top" : "Normal window")
        } label: {
            Image(systemName: controller.alwaysOnTop ? "pin.fill" : "pin")
                .font(.system(size: 10))
                .foregroundStyle(controller.alwaysOnTop ? Theme.mint.opacity(0.8) : Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .help(controller.alwaysOnTop ? "Stop floating above other windows" : "Keep on top of other windows")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                StatusDot(active: !monitor.isPaused)
                Text("HotCopyist")
                    .font(Theme.wordmark)
                    .foregroundStyle(Theme.textPrimary)
                if monitor.isPaused {
                    Text("Paused")
                        .font(Theme.monoSmall)
                        .foregroundStyle(Theme.amber)
                }
            }
            .allowsHitTesting(false)   // let drags here move the window

            Spacer()

            pinButton

            Button {
                controller.collapsed = true
            } label: {
                Image(systemName: "rectangle.compress.vertical")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Collapse to hot slots")

            Button {
                monitor.isPaused.toggle()
            } label: {
                Image(systemName: monitor.isPaused ? "play.circle" : "pause.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help(monitor.isPaused ? "Resume capture" : "Pause capture")

            Menu {
                Button("Clear History (keep pinned)") {
                    store.clearUnpinned()
                    showToast("History cleared")
                }
                Button("Clear Everything", role: .destructive) {
                    store.clearAll()
                    inspecting = nil
                    showToast("Everything cleared")
                }
                Divider()
                if !Paster.isTrusted {
                    Button("Enable Auto-Paste (Accessibility)…") {
                        Paster.requestTrust()
                    }
                }
                Button("Hide Panel  ⎋") { controller.hide() }
                Divider()
                Button("Quit HotCopyist") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(WindowDragHandle())
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(searchFocused ? Theme.mint : Theme.textSecondary)

            TextField(
                "search",
                text: $searchText,
                prompt: Text("Search").foregroundStyle(Theme.textSecondary)
            )
            .textFieldStyle(.plain)
            .font(Theme.mono)
            .foregroundStyle(Theme.textPrimary)
            .focused($searchFocused)
            .onKeyPress(.downArrow) { moveSelection(1); return .handled }
            .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
            .onKeyPress(.return) {
                guard let selected = flatList.first(where: { $0.id == selectedID }) else { return .ignored }
                arm(selected, paste: NSEvent.modifierFlags.contains(.command))
                return .handled
            }
            .onKeyPress(.escape) {
                if searchText.isEmpty {
                    controller.hide()
                } else {
                    searchText = ""
                }
                return .handled
            }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.field)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(searchFocused ? Theme.mint.opacity(0.45) : Theme.hairline, lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    // MARK: - List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 3, pinnedViews: [.sectionHeaders]) {
                    if flatList.isEmpty {
                        emptyState
                    } else {
                        if !pinnedItems.isEmpty {
                            Section {
                                rows(pinnedItems)
                            } header: {
                                sectionHeader("Pinned")
                            }
                        }
                        if !historyItems.isEmpty {
                            Section {
                                rows(historyItems)
                            } header: {
                                sectionHeader("History")
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .onChange(of: selectedID) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func rows(_ items: [ClipboardItem]) -> some View {
        ForEach(items) { item in
            HistoryRow(
                item: item,
                isSelected: selectedID == item.id,
                now: now,
                onArm: { pasteNow in arm(item, paste: pasteNow) },
                onArmPlain: { arm(item, paste: false, plainOnly: true) },
                onInspect: {
                    selectedID = item.id
                    withAnimation(.easeOut(duration: 0.15)) { inspecting = item }
                },
                onPin: { store.togglePin(item) },
                onDelete: {
                    if inspecting?.id == item.id { inspecting = nil }
                    store.delete(item)
                },
                onSaveToSlot: { slotIndex in
                    store.setSlot(slotIndex, to: item)
                    showToast("SAVED TO SLOT \(slotIndex + 1)")
                },
                onRename: { promptRename(item) },
                onClearName: {
                    store.setName(nil, for: item.id)
                    showToast("Name cleared")
                }
            )
            .id(item.id)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
        .background(Theme.bgTint)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: searchText.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Theme.textSecondary)
            Text(searchText.isEmpty ? "No Clips Yet" : "No Results")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(searchText.isEmpty
                 ? "Anything you copy will show up here."
                 : "No items match your search.")
                .font(Theme.monoSmall)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textSecondary.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 3) {
            HStack {
                Text("\(store.items.count) items")
                Spacer()
                Text("⌃⌘V to show or hide")
            }
            .font(Theme.monoSmall)
            .foregroundStyle(Theme.textSecondary)

            Text("© Ryan Blihovde")
                .font(.system(size: 8))
                .foregroundStyle(Theme.textSecondary.opacity(0.5))
        }
        .padding(.horizontal, 14)
        .padding(.top, 7)
        .padding(.bottom, 7)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    // MARK: - Name prompt

    private var namePromptBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(promptTitle ?? "")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)

            HStack(spacing: 8) {
                TextField(promptPlaceholder, text: $promptText)
                    .textFieldStyle(.plain)
                    .font(Theme.mono)
                    .foregroundStyle(Theme.textPrimary)
                    .focused($promptFocused)
                    .onSubmit { commitPrompt() }
                    .onKeyPress(.escape) { dismissPrompt(); return .handled }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.field))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Theme.mint.opacity(0.5), lineWidth: 1)
                    )

                Button("Save") { commitPrompt() }
                    .keyboardShortcut(.defaultAction)
                Button("Cancel") { dismissPrompt() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        .padding(.horizontal, 16)
        .padding(.top, 40)
    }

    private func askName(title: String, initial: String, placeholder: String,
                         commit: @escaping (String) -> Void) {
        promptText = initial
        promptPlaceholder = placeholder
        promptCommit = commit
        withAnimation(.easeOut(duration: 0.15)) { promptTitle = title }
        controller.makeKeyForInput()
        DispatchQueue.main.async { promptFocused = true }
    }

    private func dismissPrompt() {
        promptFocused = false
        promptCommit = nil
        withAnimation(.easeOut(duration: 0.15)) { promptTitle = nil }
        controller.returnKeyToUser()
    }

    private func commitPrompt() {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = promptCommit
        dismissPrompt()
        if !text.isEmpty { commit?(text) }
    }

    private func promptRename(_ item: ClipboardItem) {
        askName(title: item.trimmedName == nil ? "Name this clip" : "Rename clip",
                initial: item.trimmedName ?? "",
                placeholder: "Clip name") { name in
            store.setName(name, for: item.id)
            showToast("Named “\(name)”")
        }
    }

    private func promptSaveSlotSet() {
        askName(title: "Save current slots as a set", initial: "", placeholder: "Set name") { name in
            store.saveCurrentSlotsAsSet(named: name)
            showToast("Saved set “\(name)”")
        }
    }

    private func promptRenameSlotSet(_ set: SlotSet) {
        askName(title: "Rename set", initial: set.name, placeholder: "Set name") { name in
            store.renameSlotSet(set.id, to: name)
            showToast("Renamed to “\(name)”")
        }
    }

    // MARK: - Toast

    private func toastView(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
            .padding(.top, controller.collapsed ? 16 : 44)
    }

    private func showToast(_ text: String) {
        toastWork?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { toast = text }
        let work = DispatchWorkItem {
            withAnimation(.easeIn(duration: 0.3)) { toast = nil }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7, execute: work)
    }

    // MARK: - Actions

    private func arm(_ item: ClipboardItem, paste: Bool, plainOnly: Bool = false) {
        let result = monitor.arm(item, plainTextOnly: plainOnly)
        selectedID = item.id
        searchFocused = false
        controller.returnKeyToUser()

        // Adapter-placed clips (Logic) toast their own progress and never
        // need a ⌘V.
        guard result == .pasteboard else { return }

        if paste {
            if Paster.isTrusted {
                showToast("Pasting…")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    Paster.sendCmdV()
                }
            } else {
                showToast("Accessibility permission needed")
                Paster.requestTrust()
            }
        } else {
            showToast(plainOnly ? "Plain text copied — press ⌘V" : "Copied — press ⌘V")
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !flatList.isEmpty else { return }
        if let current = selectedID, let index = flatList.firstIndex(where: { $0.id == current }) {
            let next = min(max(index + delta, 0), flatList.count - 1)
            selectedID = flatList[next].id
        } else {
            selectedID = delta > 0 ? flatList.first?.id : flatList.last?.id
        }
    }
}
