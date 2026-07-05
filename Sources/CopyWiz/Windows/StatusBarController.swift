import AppKit
import ServiceManagement

final class StatusBarController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let store: HistoryStore
    private let monitor: ClipboardMonitor
    private let panelController: PanelController

    private let toggleItem = NSMenuItem(title: "Show CopyWiz", action: #selector(StatusBarController.togglePanel), keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause Capture", action: #selector(StatusBarController.togglePause), keyEquivalent: "")
    private let autoPasteItem = NSMenuItem(title: "Enable Auto-Paste…", action: #selector(StatusBarController.enableAutoPaste), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(StatusBarController.toggleLaunchAtLogin), keyEquivalent: "")

    init(store: HistoryStore, monitor: ClipboardMonitor, panelController: PanelController) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.store = store
        self.monitor = monitor
        self.panelController = panelController
        super.init()

        statusItem.button?.image = NSImage(
            systemSymbolName: "wand.and.stars",
            accessibilityDescription: "CopyWiz"
        )

        let menu = NSMenu()
        menu.delegate = self

        for item in [toggleItem, pauseItem] {
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let clearItem = NSMenuItem(title: "Clear History…", action: #selector(clearHistory), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        menu.addItem(.separator())

        autoPasteItem.target = self
        menu.addItem(autoPasteItem)
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: "About CopyWiz", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "Quit CopyWiz", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        toggleItem.title = panelController.isVisible ? "Hide CopyWiz  (⌃⌘V)" : "Show CopyWiz  (⌃⌘V)"
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

    @objc private func clearHistory() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "Pinned items are kept. Hold nothing sacred? Use “Clear Everything” inside the panel’s ⋯ menu."
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
            NSLog("CopyWiz: launch-at-login toggle failed: \(error)")
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
