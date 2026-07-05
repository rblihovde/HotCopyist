import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = HistoryStore()
    private(set) lazy var monitor = ClipboardMonitor(store: store)
    private var panelController: PanelController!
    private var statusBar: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        panelController = PanelController(store: store, monitor: monitor)
        statusBar = StatusBarController(store: store, monitor: monitor, panelController: panelController)

        monitor.start()

        HotKeyCenter.shared.action = { [weak self] in
            self?.panelController.toggle()
        }
        HotKeyCenter.shared.register()

        panelController.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow()
    }
}
