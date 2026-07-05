import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = HistoryStore()
    private(set) lazy var monitor = ClipboardMonitor(store: store)
    private var panelController: PanelController!
    private var statusBar: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        panelController = PanelController(store: store, monitor: monitor)
        statusBar = StatusBarController(store: store, monitor: monitor, panelController: panelController)

        monitor.start()
        registerHotKeys()
        panelController.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow()
    }

    // MARK: - Hotkeys

    private func registerHotKeys() {
        let modifiers = UInt32(cmdKey | controlKey)

        HotKeyCenter.shared.register(id: 1, keyCode: UInt32(kVK_ANSI_V), modifiers: modifiers) { [weak self] in
            self?.panelController.toggle()
        }

        // ⌃⌘1 … ⌃⌘5 fire the hot slots from anywhere — no panel needed.
        let slotKeyCodes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5]
        for (index, keyCode) in slotKeyCodes.enumerated() {
            HotKeyCenter.shared.register(id: UInt32(10 + index), keyCode: UInt32(keyCode), modifiers: modifiers) { [weak self] in
                self?.fireSlot(index)
            }
        }
    }

    /// Arms a hot slot from its global hotkey; auto-pastes when the
    /// Accessibility permission has been granted.
    private func fireSlot(_ index: Int) {
        guard store.slots.indices.contains(index), let item = store.slots[index] else {
            toast("SLOT \(index + 1) IS EMPTY")
            return
        }
        monitor.arm(item)
        if Paster.isTrusted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                Paster.sendCmdV()
            }
            toast("SLOT \(index + 1) → PASTED")
        } else {
            toast("SLOT \(index + 1) ON DECK — HIT ⌘V")
        }
    }

    private func toast(_ text: String) {
        NotificationCenter.default.post(name: .copyWizToast, object: text)
    }
}
