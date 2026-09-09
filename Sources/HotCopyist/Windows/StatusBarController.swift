import AppKit
import ServiceManagement

final class StatusBarController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let store: HistoryStore
    private let monitor: ClipboardMonitor
    private let panelController: PanelController
    private let grabber: ScreenTextGrabber

    /// Set by the app delegate; enables the Logic capture menu item.
    weak var logicService: LogicClipService?

    private let toggleItem = NSMenuItem(title: "Show HotCopyist", action: #selector(StatusBarController.togglePanel), keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause Capture", action: #selector(StatusBarController.togglePause), keyEquivalent: "")
    private let autoPasteItem = NSMenuItem(title: "Enable Auto-Paste…", action: #selector(StatusBarController.enableAutoPaste), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(StatusBarController.toggleLaunchAtLogin), keyEquivalent: "")
    /// Titles carry the live shortcut, so an edited binding shows up here.
    private let grabItem = NSMenuItem(title: "Grab Text from Screen…", action: #selector(StatusBarController.grabScreenText), keyEquivalent: "")
    private let captureLogicItem = NSMenuItem(title: "Capture Logic Selection", action: #selector(StatusBarController.captureFromLogic), keyEquivalent: "")
    private var retentionItems: [NSMenuItem] = []

    init(store: HistoryStore, monitor: ClipboardMonitor, panelController: PanelController,
         grabber: ScreenTextGrabber) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.store = store
        self.monitor = monitor
        self.panelController = panelController
        self.grabber = grabber
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "doc.on.clipboard",
            accessibilityDescription: "HotCopyist"
        )

        let menu = NSMenu()
        menu.delegate = self

        for item in [toggleItem, pauseItem] {
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())

        grabItem.target = self
        menu.addItem(grabItem)

        captureLogicItem.target = self
        menu.addItem(captureLogicItem)

        menu.addItem(.separator())

        let clearItem = NSMenuItem(title: "Clear History…", action: #selector(clearHistory), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        // Retention: unpinned clips can age out on their own, which matters
        // when the day's copying was done on someone else's machine.
        let retentionMenu = NSMenu()
        for option in HistoryStore.Retention.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(setRetention(_:)), keyEquivalent: "")
            item.target = self
            item.tag = option.rawValue
            retentionMenu.addItem(item)
            retentionItems.append(item)
        }
        let retentionParent = NSMenuItem(title: "Auto-Delete History", action: nil, keyEquivalent: "")
        retentionParent.submenu = retentionMenu
        menu.addItem(retentionParent)

        menu.addItem(.separator())

        let shortcutsItem = NSMenuItem(title: "Keyboard Shortcuts…", action: #selector(showShortcuts), keyEquivalent: "")
        shortcutsItem.target = self
        menu.addItem(shortcutsItem)

        autoPasteItem.target = self
        menu.addItem(autoPasteItem)
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: "About HotCopyist", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "Quit HotCopyist", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let shortcuts = ShortcutStore.shared
        let toggleKey = shortcuts[.togglePanel].displayString
        toggleItem.title = (panelController.isVisible ? "Hide HotCopyist  (" : "Show HotCopyist  (") + toggleKey + ")"
        grabItem.title = "Grab Text from Screen…  (\(shortcuts[.grabScreenText].displayString))"
        captureLogicItem.title = "Capture Logic Selection  (\(shortcuts[.captureLogic].displayString))"
        for item in retentionItems {
            item.state = item.tag == store.retention.rawValue ? .on : .off
        }
        pauseItem.state = monitor.isPaused ? .on : .off
        autoPasteItem.title = Paster.isTrusted ? "Auto-Paste Enabled" : "Enable Auto-Paste…"
        autoPasteItem.state = Paster.isTrusted ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    // MARK: - Actions

    @objc private func togglePanel() {
        panelController.toggle()
    }

    @objc private func togglePause() {
        monitor.isPaused.toggle()
    }

    @objc private func grabScreenText() {
        grabber.begin()
    }

    @objc private func showShortcuts() {
        ShortcutsWindowController.shared.show()
    }

    @objc private func setRetention(_ sender: NSMenuItem) {
        guard let option = HistoryStore.Retention(rawValue: sender.tag) else { return }
        store.retention = option
    }

    @objc private func captureFromLogic() {
        logicService?.captureSelection()
    }

    @objc private func clearHistory() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "Pinned items are kept. To remove pinned items too, use “Clear Everything” in the panel’s ⋯ menu."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            store.clearUnpinned()
        }
    }

    @objc private func enableAutoPaste() {
        Paster.requestTrust()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            // Registration only works from a proper .app bundle
            // (run `make install`), not from a bare `swift run` binary.
            NSLog("HotCopyist: launch-at-login toggle failed: \(error)")
        }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
