import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = HistoryStore()
    private(set) lazy var monitor = ClipboardMonitor(store: store)
    private(set) lazy var finale = FinaleClipService(store: store)
    private(set) lazy var logic = LogicClipService(store: store)
    private(set) lazy var grabber = ScreenTextGrabber(store: store, monitor: monitor)
    private var panelController: PanelController!
    private var statusBar: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        panelController = PanelController(store: store, monitor: monitor, grabber: grabber)
        grabber.panelController = panelController
        statusBar = StatusBarController(
            store: store, monitor: monitor, panelController: panelController, grabber: grabber
        )
        statusBar.logicService = logic

        monitor.finaleService = finale
        monitor.logicService = logic
        monitor.start()
        finale.start()
        registerHotKeys()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(shortcutsChanged),
            name: ShortcutStore.didChange,
            object: nil
        )
        panelController.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow()
    }

    // MARK: - Hotkeys

    /// Registers every binding from the shortcut store. Called again whenever
    /// the user edits one, so a changed binding takes effect immediately.
    @objc private func registerHotKeys() {
        let shortcuts = ShortcutStore.shared
        var refused: [String] = []

        for action in ShortcutAction.allCases {
            let shortcut = shortcuts[action]
            let claimed = HotKeyCenter.shared.register(shortcut, id: action.hotKeyID) { [weak self] in
                self?.perform(action)
            }
            if !claimed { refused.append("\(action.title) (\(shortcut.displayString))") }
        }

        // Another app owning a combination is the usual cause, and it's silent
        // otherwise — the user would just find the key doing nothing.
        if !refused.isEmpty {
            toast("Shortcut unavailable: \(refused.joined(separator: ", "))")
        }
    }

    @objc private func shortcutsChanged() {
        registerHotKeys()
    }

    private func perform(_ action: ShortcutAction) {
        if let slot = action.slotIndex {
            fireSlot(slot)
            return
        }
        switch action {
        case .togglePanel: panelController.toggle()
        case .grabScreenText: grabber.begin()
        case .captureLogic: logic.captureSelection()
        default: break
        }
    }

    /// Arms a hot slot from its global hotkey; auto-pastes when the
    /// Accessibility permission has been granted.
    private func fireSlot(_ index: Int) {
        guard store.slots.indices.contains(index), let item = store.slots[index] else {
            toast("Slot \(index + 1) is empty")
            return
        }
        guard monitor.arm(item) == .pasteboard else { return }  // adapter placed it itself
        if Paster.isTrusted {
            // The paste is aimed at whatever was frontmost when the key was
            // pressed; if focus moves during the delay, the keystroke is
            // dropped rather than sent into the wrong app.
            let target = NSWorkspace.shared.frontmostApplication?.processIdentifier
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                Paster.sendCmdV(ifFrontmostIs: target)
            }
            toast("Slot \(index + 1) pasted")
        } else {
            toast("Slot \(index + 1) copied — press ⌘V")
        }
    }

    private func toast(_ text: String) {
        NotificationCenter.default.post(name: .hotCopyToast, object: text)
    }
}
