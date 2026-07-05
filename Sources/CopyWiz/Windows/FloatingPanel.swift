import AppKit
import SwiftUI

/// A non-activating panel that floats above every window on every Space.
/// Clicking it never yanks focus away from the app you're working in, which is
/// what makes "click an item, then just hit ⌘V" possible.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that responds to the first click even while the panel isn't
/// key, and avoids pulling key status for plain clicks (palette behavior).
final class PanelHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
}

extension Notification.Name {
    static let copyWizPanelDidShow = Notification.Name("org.copywiz.panelDidShow")
    /// Posted with a String object to flash a toast in the panel.
    static let copyWizToast = Notification.Name("org.copywiz.toast")
}

final class PanelController {

    let panel: FloatingPanel

    private static let frameAutosaveName = "CopyWizPanel"
    private static let defaultSize = NSSize(width: 400, height: 620)

    init(store: HistoryStore, monitor: ClipboardMonitor) {
        panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 340, height: 400)
        panel.animationBehavior = .utilityWindow

        for buttonType: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(buttonType)?.isHidden = true
        }

        let root = PanelRootView(controller: self)
            .environmentObject(store)
            .environmentObject(monitor)
        panel.contentView = PanelHostingView(rootView: AnyView(root))

        panel.setFrameAutosaveName(Self.frameAutosaveName)
        if !panel.setFrameUsingName(Self.frameAutosaveName) {
            positionAtDefaultLocation()
        }
    }

    private func positionAtDefaultLocation() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = Self.defaultSize
        let origin = NSPoint(
            x: visible.maxX - size.width - 24,
            y: visible.maxY - size.height - 24
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        panel.orderFrontRegardless()
        NotificationCenter.default.post(name: .copyWizPanelDidShow, object: nil)
    }

    func hide() {
        panel.orderOut(nil)
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    /// If an interaction (typing in search, clicking a control) made the panel
    /// the key window, hand keyboard focus back to whatever app the user was
    /// in — so their very next ⌘V lands where they expect. The panel stays
    /// visible; a same-tick orderOut/orderFront releases key status.
    func returnKeyToUser() {
        guard panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }
}
