import SwiftUI
import AppKit
import Combine

struct PanelRootView: View {
    let controller: PanelController
    @EnvironmentObject private var store: HistoryStore
    @EnvironmentObject private var monitor: ClipboardMonitor

    @State private var searchText = ""
    @State private var selectedID: UUID?
    @State private var inspecting: ClipboardItem?
    @State private var toast: String?
    @State private var toastWork: DispatchWorkItem?
    @State private var now = Date()
    @FocusState private var searchFocused: Bool

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

            VStack(spacing: 0) {
                header
                searchBar
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

            if let toast {
                toastView(toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onReceive(clock) { now = $0 }
        .onReceive(NotificationCenter.default.publisher(for: .copyWizPanelDidShow)) { _ in
            selectedID = flatList.first?.id
        }
        .onChange(of: searchText) { _, _ in
            selectedID = flatList.first?.id
        }
        .onChange(of: store.items) { _, newItems in
            if let inspecting, !newItems.contains(where: { $0.id == inspecting.id }) {
                self.inspecting = nil
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 9) {
            StatusDot(active: !monitor.isPaused)
            Text("COPYWIZ")
                .font(Theme.wordmark)
                .tracking(3.5)
                .foregroundStyle(Theme.textPrimary)
            Text(monitor.isPaused ? "· HOLD" : "· LIVE")
                .font(Theme.monoSmall)
                .tracking(1.5)
                .foregroundStyle(monitor.isPaused ? Theme.amber : Theme.mint.opacity(0.7))

            Spacer()

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
                    showToast("HISTORY CLEARED")
                }
                Button("Clear Everything", role: .destructive) {
                    store.clearAll()
                    inspecting = nil
                    showToast("WIPED")
                }
                Divider()
                if !Paster.isTrusted {
                    Button("Enable Auto-Paste (Accessibility)…") {
                        Paster.requestTrust()
                    }
                }
                Button("Hide Panel  ⎋") { controller.hide() }
                Divider()
                Button("Quit CopyWiz") { NSApp.terminate(nil) }
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
                prompt: Text("search history…").foregroundStyle(Theme.textSecondary)
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
                                sectionHeader("PINNED", color: Theme.amber)
                            }
                        }
                        if !historyItems.isEmpty {
                            Section {
                                rows(historyItems)
                            } header: {
                                sectionHeader("HISTORY", color: Theme.textSecondary)
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
                }
            )
            .id(item.id)
        }
    }

    private func sectionHeader(_ title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(Theme.monoSmall)
                .tracking(2)
                .foregroundStyle(color)
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
        .background(Theme.bgTint)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: searchText.isEmpty ? "sparkles" : "moon.stars")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.mint.opacity(0.55))
            Text(searchText.isEmpty ? "NOTHING CAPTURED YET" : "NO MATCHES")
                .font(Theme.monoSmall)
                .tracking(2)
                .foregroundStyle(Theme.textSecondary)
            Text(searchText.isEmpty
                 ? "Copy anything, anywhere.\nIt materializes here."
                 : "Try a looser incantation.")
                .font(Theme.monoSmall)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textSecondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Text("\(store.items.count) ITEMS")
            Text("·").foregroundStyle(Theme.hairline)
            Text(monitor.isPaused ? "PAUSED" : "CAPTURING")
                .foregroundStyle(monitor.isPaused ? Theme.amber : Theme.mint.opacity(0.8))
            Spacer()
            Text("⌃⌘V TOGGLE · ⌘-CLICK PASTES")
        }
        .font(Theme.monoSmall)
        .tracking(1)
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    // MARK: - Toast

    private func toastView(_ text: String) -> some View {
        Text(text)
            .font(Theme.monoSmall)
            .tracking(1.5)
            .foregroundStyle(Theme.mint)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.85))
                    .overlay(Capsule().stroke(Theme.mint.opacity(0.4), lineWidth: 1))
            )
            .shadow(color: Theme.mint.opacity(0.25), radius: 10)
            .padding(.top, 44)
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
        monitor.arm(item, plainTextOnly: plainOnly)
        selectedID = item.id
        searchFocused = false
        controller.returnKeyToUser()

        if paste {
            if Paster.isTrusted {
                showToast("PASTING…")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    Paster.sendCmdV()
                }
            } else {
                showToast("NEEDS ACCESSIBILITY — OPENING PROMPT")
                Paster.requestTrust()
            }
        } else {
            showToast(plainOnly ? "PLAIN TEXT ON DECK — HIT ⌘V" : "ON DECK — HIT ⌘V")
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
