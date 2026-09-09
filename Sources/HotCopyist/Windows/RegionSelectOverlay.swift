import AppKit

/// The drag-a-rectangle chrome for screen OCR: one borderless, non-activating
/// panel per display, dimming everything and letting the user lasso a region.
///
/// Non-activating means HotCopy never steals focus from the app underneath, so
/// the ⌘V that follows still lands where the user was working.
final class RegionSelectOverlay {

    /// Called with the selected rect in AppKit's global screen coordinates.
    private let onComplete: (NSRect) -> Void
    private let onCancel: () -> Void

    private var panels: [NSPanel] = []
    private var escapeMonitor: Any?
    private var safetyTimer: Timer?
    private var pushedCursor = false
    private var finished = false

    /// The overlay dims every display and swallows clicks, and ⎋ only reaches
    /// it while HotCopy holds key focus — click into another app first and the
    /// key stops working. A plain click still cancels, but this bounds the
    /// worst case rather than relying on the user guessing that.
    private static let safetyTimeout: TimeInterval = 45

    init(onComplete: @escaping (NSRect) -> Void, onCancel: @escaping () -> Void) {
        self.onComplete = onComplete
        self.onCancel = onCancel
    }

    // MARK: - Presenting

    func show() {
        guard panels.isEmpty else { return }

        // The display under the pointer gets the instruction line, and takes
        // key status so ⎋ works before the user has clicked anything.
        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens
        let startIndex = screens.firstIndex { $0.frame.contains(mouse) } ?? 0

        for (index, screen) in screens.enumerated() {
            let panel = SelectionPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.hidesOnDeactivate = false
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.isMovable = false
            panel.isReleasedWhenClosed = false
            panel.acceptsMouseMovedEvents = true
            panel.animationBehavior = .none
            // Set last: some NSPanel properties quietly reset the level as a
            // side effect. Above the menu bar, so the whole display is
            // selectable.
            panel.level = .screenSaver

            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.showsHint = (index == startIndex)
            view.onFinish = { [weak self] rect in self?.complete(rect) }
            view.onCancel = { [weak self] in self?.cancel() }
            panel.contentView = view

            panel.setFrame(screen.frame, display: false)
            panel.orderFrontRegardless()
            panels.append(panel)
        }

        if panels.indices.contains(startIndex) {
            panels[startIndex].makeKeyAndOrderFront(nil)
        }

        NSCursor.crosshair.push()
        pushedCursor = true

        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // ⎋
            self?.cancel()
            return nil
        }

        let timer = Timer(timeInterval: Self.safetyTimeout, repeats: false) { [weak self] _ in
            self?.cancel()
        }
        RunLoop.main.add(timer, forMode: .common)
        safetyTimer = timer
    }

    // MARK: - Dismissing

    /// Tears the overlay down without firing either callback.
    func dismiss() {
        safetyTimer?.invalidate()
        safetyTimer = nil
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        if pushedCursor {
            NSCursor.pop()
            pushedCursor = false
        }
        for panel in panels {
            panel.contentView = nil
            panel.orderOut(nil)
        }
        panels.removeAll()
    }

    private func complete(_ rect: NSRect) {
        guard !finished else { return }
        finished = true
        dismiss()
        onComplete(rect)
    }

    private func cancel() {
        guard !finished else { return }
        finished = true
        dismiss()
        onCancel()
    }
}

// MARK: - Panel

/// Borderless panels refuse key status by default; the overlay needs it for ⎋.
private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Selection view

/// Dims the display, punches the live selection out of the dim, and draws a
/// marching-ants border plus a size readout.
private final class SelectionView: NSView {

    var onFinish: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?
    var showsHint = false

    /// A click that never really moves is a cancel, not a zero-size grab.
    private static let minimumDrag: CGFloat = 6
    private static let dashPattern: [CGFloat] = [5, 4]

    private var anchor: NSPoint?
    private var current: NSPoint?
    private var dashPhase: CGFloat = 0
    private var antsTimer: Timer?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    private var selection: NSRect? {
        guard let anchor, let current else { return nil }
        return NSRect(
            x: min(anchor.x, current.x),
            y: min(anchor.y, current.y),
            width: abs(current.x - anchor.x),
            height: abs(current.y - anchor.y)
        )
    }

    // MARK: Cursor

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        trackingAreas.forEach(removeTrackingArea)
        guard window != nil else {
            stopAnts()
            return
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .cursorUpdate, .mouseMoved],
            owner: self,
            userInfo: nil
        ))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.crosshair.set() }

    // MARK: Marching ants

    /// Only ticks while a selection exists, so an overlay sitting open costs
    /// nothing.
    private func startAnts() {
        guard antsTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            self?.advanceAnts()
        }
        RunLoop.main.add(timer, forMode: .common)
        antsTimer = timer
    }

    private func stopAnts() {
        antsTimer?.invalidate()
        antsTimer = nil
    }

    private func advanceAnts() {
        guard let selection else { return }
        dashPhase = (dashPhase - 1).truncatingRemainder(dividingBy: Self.dashPattern.reduce(0, +))
        setNeedsDisplay(selection.insetBy(dx: -2, dy: -2))
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        current = anchor
        showsHint = false
        startAnts()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard anchor != nil else { return }
        let previous = selection
        current = convert(event.locationInWindow, from: nil)
        if let previous, let now = selection {
            // Repaint the old and new borders (plus the readout beneath them)
            // rather than the whole display on every drag event.
            setNeedsDisplay(previous.union(now).insetBy(dx: -4, dy: -30))
        } else {
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        defer {
            stopAnts()
            anchor = nil
            current = nil
        }
        guard let rect = selection,
              rect.width >= Self.minimumDrag, rect.height >= Self.minimumDrag,
              let window else {
            onCancel?()
            return
        }
        onFinish?(window.convertToScreen(rect))
    }

    override func rightMouseDown(with event: NSEvent) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }   // ⎋ — swallow the rest silently
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.32).setFill()

        guard let selection else {
            bounds.fill()
            if showsHint { drawHint() }
            return
        }

        let dim = NSBezierPath(rect: bounds)
        dim.append(NSBezierPath(rect: selection))
        dim.windingRule = .evenOdd
        dim.fill()

        let border = NSBezierPath(rect: selection)
        border.lineWidth = 1
        var pattern = Self.dashPattern
        NSColor.white.withAlphaComponent(0.95).setStroke()
        border.setLineDash(&pattern, count: pattern.count, phase: dashPhase)
        border.stroke()

        drawReadout(for: selection)
    }

    private func drawHint() {
        draw(
            text: "Drag a box around the text  ·  click or ⎋ to cancel",
            centeredAt: NSPoint(x: bounds.midX, y: bounds.midY),
            fontSize: 13
        )
    }

    private func drawReadout(for selection: NSRect) {
        let label = "\(Int(selection.width.rounded())) × \(Int(selection.height.rounded()))"
        // Sit under the selection, unless it's pinned to the bottom edge.
        let below = selection.minY - 16
        let y = below > bounds.minY + 6 ? below : selection.maxY + 16
        draw(text: label, centeredAt: NSPoint(x: selection.midX, y: y), fontSize: 11)
    }

    private func draw(text: String, centeredAt point: NSPoint, fontSize: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let pill = NSRect(
            x: point.x - size.width / 2 - 8,
            y: point.y - size.height / 2 - 4,
            width: size.width + 16,
            height: size.height + 8
        )
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
        string.draw(at: NSPoint(x: pill.minX + 8, y: pill.minY + 4))
    }
}
