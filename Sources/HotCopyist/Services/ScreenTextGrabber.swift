import AppKit
import Combine
import ScreenCaptureKit
import Vision

/// Screen-region OCR: drag a box over anything on screen — a PDF, a video
/// still, an image of a chord chart — and the text inside it lands on the
/// pasteboard (and in history) as if it had been copied.
///
/// Capture needs the Screen Recording permission; recognition is Vision's,
/// which runs entirely on-device, so nothing leaves the machine.
final class ScreenTextGrabber: ObservableObject {

    /// True while the selection overlay is up, so the toolbar button can show
    /// its active state and a second click dismisses instead of stacking.
    @Published private(set) var isSelecting = false

    /// Handed back keyboard focus after a grab, so the next ⌘V goes to the
    /// user's app rather than to HotCopy's panel.
    weak var panelController: PanelController?

    private let store: HistoryStore
    private let monitor: ClipboardMonitor
    private var overlay: RegionSelectOverlay?

    init(store: HistoryStore, monitor: ClipboardMonitor) {
        self.store = store
        self.monitor = monitor
    }

    // MARK: - Flow

    func begin() {
        if isSelecting {
            finishSelecting()
            return
        }
        guard hasScreenRecordingAccess() else { return }

        let overlay = RegionSelectOverlay(
            onComplete: { [weak self] rect in self?.grab(rect) },
            onCancel: { [weak self] in self?.finishSelecting() }
        )
        self.overlay = overlay
        isSelecting = true
        overlay.show()
    }

    private func finishSelecting() {
        overlay?.dismiss()
        overlay = nil
        isSelecting = false
        panelController?.returnKeyToUser()
    }

    private func grab(_ rect: NSRect) {
        finishSelecting()

        guard let screen = Self.screen(bestMatching: rect) else {
            toast("Couldn’t find that display")
            return
        }
        let region = rect.intersection(screen.frame)
        guard region.width >= 4, region.height >= 4 else {
            toast("Selection too small")
            return
        }

        // The panel is where HotCopy reports back, so a grab started from the
        // menu bar while it was hidden would otherwise land silently.
        panelController?.show()
        toast("Reading screen…")
        Task {
            let outcome = await Self.read(region, on: screen)
            await MainActor.run { [weak self] in self?.settle(outcome) }
        }
    }

    /// Capture and recognition both run off the main thread; only the plain
    /// text (or a message to show) crosses back.
    private enum Outcome {
        case text(String)
        case failure(String)
    }

    private static func read(_ region: NSRect, on screen: NSScreen) async -> Outcome {
        do {
            let image = try await capture(region, on: screen)
            return .text(try recognizeText(in: image))
        } catch {
            return .failure((error as? GrabError)?.message ?? error.localizedDescription)
        }
    }

    private func settle(_ outcome: Outcome) {
        switch outcome {
        case .text(let text): deliver(text)
        case .failure(let message): toast(message)
        }
    }

    /// Puts the recognized text on the pasteboard and records it in history so
    /// it behaves like any other clip (nameable, pinnable, droppable on a slot).
    private func deliver(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            toast("No text found in that region")
            return
        }

        let rep = ClipboardItem.Representation(
            itemIndex: 0,
            type: "public.utf8-plain-text",
            data: Data(trimmed.utf8)
        )
        let item = ClipboardItem(reps: [rep], sourceAppName: "Screen OCR", sourceBundleID: nil)
        store.insert(item)
        monitor.arm(item)

        let words = trimmed.split(whereSeparator: \.isWhitespace).count
        toast("Read \(words) word\(words == 1 ? "" : "s") — press ⌘V")
    }

    private func toast(_ text: String) {
        NotificationCenter.default.post(name: .hotCopyToast, object: text)
    }

    // MARK: - Permission

    /// Screen capture is gated by TCC, not by a sandbox entitlement. The first
    /// call to `CGRequestScreenCaptureAccess` shows the system prompt; after
    /// that macOS only ever answers from the recorded decision, so a denial
    /// has to be walked to System Settings by hand.
    private func hasScreenRecordingAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if CGRequestScreenCaptureAccess() { return true }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "HotCopy needs permission to read the screen"
        alert.informativeText = """
            Turn on Screen & System Audio Recording for HotCopy in System \
            Settings → Privacy & Security, then try again. The screen is only \
            read when you drag a selection, and the text is recognized on this \
            Mac — nothing is sent anywhere.
            """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Not Now")
        alert.alertStyle = .informational

        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    // MARK: - Capture

    private enum GrabError: Error {
        case noDisplay
        case emptyRegion

        var message: String {
            switch self {
            case .noDisplay: return "Couldn’t capture that display"
            case .emptyRegion: return "Nothing to read there"
            }
        }
    }

    /// The display holding most of the selection — a drag that starts near an
    /// edge can spill onto a neighbor.
    private static func screen(bestMatching rect: NSRect) -> NSScreen? {
        NSScreen.screens.max { a, b in
            let areaA = a.frame.intersection(rect).area
            let areaB = b.frame.intersection(rect).area
            return areaA < areaB
        }
    }

    private static func capture(_ region: NSRect, on screen: NSScreen) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let displayID = screen.displayID,
              let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw GrabError.noDisplay
        }

        // Never read HotCopy's own panel (or the selection overlay) back into
        // the capture — the content behind them shows through instead.
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)

        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * screen.backingScaleFactor)
        config.height = Int(CGFloat(display.height) * screen.backingScaleFactor)
        config.captureResolution = .best
        config.scalesToFit = false
        config.showsCursor = false

        let full = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        )

        // Crop from the full display rather than using `sourceRect`, and take
        // the scale from the image actually returned instead of assuming the
        // requested size was honored.
        let scaleX = CGFloat(full.width) / CGFloat(display.width)
        let scaleY = CGFloat(full.height) / CGFloat(display.height)
        let local = region.inDisplaySpace(of: screen.frame)
        let pixels = CGRect(
            x: local.minX * scaleX,
            y: local.minY * scaleY,
            width: local.width * scaleX,
            height: local.height * scaleY
        )
        .integral
        .intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))

        guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1,
              let cropped = full.cropping(to: pixels) else {
            throw GrabError.emptyRegion
        }

        // `cropping(to:)` keeps the whole display's pixel buffer alive behind
        // the crop, so everything outside the selection — other windows, other
        // clients' data — would stay in memory for the length of recognition.
        // Copying into a fresh bitmap lets the full screenshot go now.
        return detached(cropped) ?? cropped
    }

    /// An independent copy of an image, sharing nothing with its source.
    private static func detached(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    // MARK: - Recognition

    private static func recognizeText(in image: CGImage) throws -> String {
        let source = upscaledIfTiny(image)

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        // `minimumTextHeight` is relative to the image, so a large selection of
        // small type falls under the default floor and gets skipped. Aim for
        // roughly 8px-tall text instead, without going so low that noise reads
        // as words.
        request.minimumTextHeight = Float(min(0.03125, max(0.006, 8.0 / Double(source.height))))

        try VNImageRequestHandler(cgImage: source, options: [:]).perform([request])
        return assemble(request.results ?? [])
    }

    /// Vision loses accuracy on very small crops (a single word lifted out of a
    /// UI label), so those get scaled up before recognition.
    private static func upscaledIfTiny(_ image: CGImage) -> CGImage {
        let minSide = min(image.width, image.height)
        guard minSide > 0, minSide < 260 else { return image }

        let factor = min(4, max(2, Int(ceil(260.0 / Double(minSide)))))
        let width = image.width * factor
        let height = image.height * factor
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return image }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// Vision hands back one observation per text run, in no guaranteed order.
    /// Runs sharing a baseline (a label and its value, side-by-side columns)
    /// are rejoined into one line so the pasted text keeps the layout's shape.
    private static func assemble(_ observations: [VNRecognizedTextObservation]) -> String {
        let runs: [(box: CGRect, text: String)] = observations.compactMap { observation in
            guard let best = observation.topCandidates(1).first else { return nil }
            return (observation.boundingBox, best.string)
        }
        guard !runs.isEmpty else { return "" }

        let averageHeight = runs.reduce(0) { $0 + $1.box.height } / CGFloat(runs.count)
        let tolerance = max(averageHeight * 0.6, 0.004)

        // Normalized boxes are bottom-left origin, so top of the page is high y.
        var lines: [[(box: CGRect, text: String)]] = []
        for run in runs.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let last = lines.last, let reference = last.first,
               abs(reference.box.midY - run.box.midY) < tolerance {
                lines[lines.count - 1].append(run)
            } else {
                lines.append([run])
            }
        }

        return lines
            .map { line in
                line.sorted { $0.box.minX < $1.box.minX }
                    .map(\.text)
                    .joined(separator: " ")
            }
            .joined(separator: "\n")
    }
}

// MARK: - Geometry helpers

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

private extension NSRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }

    /// AppKit's global screen space is bottom-left origin and spans every
    /// display; CoreGraphics captures are top-left origin and display-local.
    func inDisplaySpace(of screenFrame: NSRect) -> CGRect {
        CGRect(
            x: minX - screenFrame.minX,
            y: screenFrame.maxY - maxY,
            width: width,
            height: height
        )
    }
}
