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
    static let hotCopyPanelDidShow = Notification.Name("com.blihovde.hotcopy.panelDidShow")
    /// Posted with a String object to flash a toast in the panel.
    static let hotCopyToast = Notification.Name("com.blihovde.hotcopy.toast")
}

final class PanelController: ObservableObject {

    let panel: FloatingPanel

    private static let frameAutosaveName = "HotCopyPanel"
    private static let defaultSize = NSSize(width: 400, height: 620)
    private static let miniHeight: CGFloat = 66
    private static let alwaysOnTopKey = "com.blihovde.hotcopy.alwaysOnTop"
    private static let collapsedKey = "com.blihovde.hotcopy.collapsed"
    private static let expandedHeightKey = "com.blihovde.hotcopy.expandedHeight"

    /// Whether the panel floats above every other window (on) or behaves like
    /// a regular window that other apps can cover (off).
    @Published var alwaysOnTop: Bool {
        didSet {
            panel.level = alwaysOnTop ? .floating : .normal
            UserDefaults.standard.set(alwaysOnTop, forKey: Self.alwaysOnTopKey)
        }
    }

    /// Mini mode: the panel shrinks to a slim bar showing only the hot slots.
    @Published var collapsed: Bool {
        didSet {
            guard collapsed != oldValue else { return }
            applyCollapsed(animate: true)
            UserDefaults.standard.set(collapsed, forKey: Self.collapsedKey)
        }
    }

    init(store: HistoryStore, monitor: ClipboardMonitor, grabber: ScreenTextGrabber) {
        let defaults = UserDefaults.standard
        alwaysOnTop = defaults.object(forKey: Self.alwaysOnTopKey) as? Bool ?? true
        collapsed = defaults.bool(forKey: Self.collapsedKey)
        panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        // Off, so dragging a history row (to drop it on a hot slot) doesn't
        // start a window move. The header provides an explicit drag region.
        panel.isMovableByWindowBackground = false
        panel.isMovable = true
        panel.level = alwaysOnTop ? .floating : .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
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
            .environmentObject(grabber)
        panel.contentView = PanelHostingView(rootView: AnyView(root))

        panel.setFrameAutosaveName(Self.frameAutosaveName)
        if !panel.setFrameUsingName(Self.frameAutosaveName) {
            positionAtDefaultLocation()
        }
        if collapsed {
            applyCollapsed(animate: false)
        }
    }

    /// Resizes the panel for mini mode (hot slots only) or restores the full
    /// layout, keeping the top edge anchored so the slot strip doesn't jump.
    private func applyCollapsed(animate: Bool) {
        let defaults = UserDefaults.standard
        var frame = panel.frame
        let top = frame.maxY

        if collapsed {
            if frame.height > Self.miniHeight {
                defaults.set(Double(frame.height), forKey: Self.expandedHeightKey)
            }
            frame.size.height = Self.miniHeight
            panel.minSize = NSSize(width: 340, height: Self.miniHeight)
            panel.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: Self.miniHeight)
        } else {
            panel.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                   height: CGFloat.greatestFiniteMagnitude)
            panel.minSize = NSSize(width: 340, height: 400)
            let saved = defaults.double(forKey: Self.expandedHeightKey)
            frame.size.height = saved > Self.miniHeight ? CGFloat(saved) : Self.defaultSize.height
        }

        frame.origin.y = top - frame.height
        panel.setFrame(frame, display: true, animate: animate)
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
        NotificationCenter.default.post(name: .hotCopyPanelDidShow, object: nil)
    }

    func hide() {
        panel.orderOut(nil)
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    /// Makes the panel key so an inline text field can receive typing
    /// (used by the naming prompt). Does not activate the owning app.
    func makeKeyForInput() {
        panel.makeKeyAndOrderFront(nil)
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
