import AppKit
import ApplicationServices

/// Captures and re-places music clips for Logic Pro.
///
/// Logic's music clipboard is in-RAM and per-process: ⌘C of regions writes
/// nothing to disk and only a textual track summary to the system pasteboard
/// (verified empirically — see research/ notes). There is no remote API and
/// AppleScript exposes only the Standard Suite. What Logic *does* offer is
/// File ▸ Export ▸ Selection as MIDI File… and File ▸ Import ▸ MIDI File…,
/// both driveable through Accessibility — the same permission HotCopyist
/// already holds for auto-paste. So:
///   capture = drive the export flow into a temp file, keep the MIDI bytes
///   arm     = write the bytes to a temp file, drive the import flow
/// Import places the clip on new tracks at its original bar position and
/// leaves the project's tempo untouched (the "import tempo?" prompt is
/// auto-declined).
final class LogicClipService: ObservableObject {

    /// Representation type for Logic music clips stored in history items.
    static let repType = "com.blihovde.hotcopy.logic.midi-clip"

    static let bundleID = "com.apple.logic10"

    private let store: HistoryStore

    /// All automation runs here so a slow panel never blocks the UI; serial
    /// so two invocations can't interleave keystrokes.
    private let queue = DispatchQueue(label: "com.blihovde.hotcopy.logic-automation")
    private var busy = false

    private let workDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("HotCopy/LogicWork", isDirectory: true)

    init(store: HistoryStore) {
        self.store = store
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    /// True when the pasteboard text looks like the tabular summaries Logic
    /// mirrors on ⌘C: track rows from the Tracks area (" \t  \t 1 1 1 1 \t
    /// hc_test\t 1\t…") and event rows from the Piano Roll / Score / Event
    /// List ("…\t Note\t 1\t C4\t…" alternating with "\t\t\t Rel Vel\t…").
    /// Every such line starts with a space or tab and is tab-delimited;
    /// real user text (track names, lyrics) is not. These summaries carry no
    /// music data, so history skips them.
    static func isTrackSummaryText(_ s: String) -> Bool {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy { line in
            guard let first = line.first, first == " " || first == "\t" else { return false }
            return line.lazy.filter { $0 == "\t" }.count >= 3
        }
    }

    // MARK: - MIDI inspection

    /// Number of notes in a Standard MIDI File. Logic happily exports
    /// audio-only selections as MIDI files containing nothing but tempo/meter
    /// meta events — those must not become clips.
    static func midiNoteCount(_ data: Data) -> Int {
        MidiClipSummary(data: data)?.noteCount ?? 0
    }

    // MARK: - Capture

    /// Exports Logic's current selection as a MIDI file and stores it in
    /// history. Invoked explicitly (hotkey/menu) — never on Logic's own ⌘C,
    /// because the export flow flashes a save panel.
    func captureSelection() {
        guard !busy else { return }
        guard Paster.isTrusted else {
            toast("Logic capture needs Accessibility — enable it in System Settings")
            Paster.requestTrust()
            return
        }
        guard let app = runningLogic() else {
            toast("Logic Pro isn't running")
            return
        }
        busy = true
        toast("Capturing from Logic…")
        let name = "HotCopyClip-\(UInt64(Date().timeIntervalSince1970 * 1000))"
        let outFile = workDir.appendingPathComponent(name + ".mid")
        queue.async { [weak self] in
            guard let self else { return }
            let error = self.runExport(app: app, dir: self.workDir.path, baseName: name, outFile: outFile)
            DispatchQueue.main.async {
                self.busy = false
                if let error {
                    self.toast(error)
                    return
                }
                guard let data = try? Data(contentsOf: outFile) else {
                    self.toast("Logic export produced no file")
                    return
                }
                try? FileManager.default.removeItem(at: outFile)
                // Logic exports audio-only selections as note-less MIDI shells.
                guard Self.midiNoteCount(data) > 0 else {
                    self.toast("No MIDI notes in selection — audio regions can't be captured")
                    return
                }
                let rep = ClipboardItem.Representation(itemIndex: 0, type: Self.repType, data: data)
                self.store.insert(ClipboardItem(reps: [rep],
                                                sourceAppName: "Logic Pro",
                                                sourceBundleID: Self.bundleID))
                self.toast("Captured Logic clip")
            }
        }
    }

    // MARK: - Arming

    /// Places the item's MIDI payload into the frontmost Logic project on new
    /// tracks (via the import flow). Returns false if the item isn't a Logic
    /// clip; placement itself is asynchronous.
    @discardableResult
    func arm(_ item: ClipboardItem) -> Bool {
        guard let data = item.data(for: Self.repType) else { return false }
        guard !busy else { return true }
        guard Paster.isTrusted else {
            toast("Placing in Logic needs Accessibility — enable it in System Settings")
            Paster.requestTrust()
            return true
        }
        guard let app = runningLogic() else {
            toast("Logic Pro isn't running")
            return true
        }
        busy = true
        toast("Placing in Logic…")
        let inFile = workDir.appendingPathComponent("HotCopyPaste-\(UUID().uuidString).mid")
        queue.async { [weak self] in
            guard let self else { return }
            var error: String?
            do {
                try data.write(to: inFile)
                error = self.runImport(app: app, file: inFile.path)
            } catch {
                self.finish(with: "Couldn't stage MIDI file: \(error.localizedDescription)", inFile: inFile)
                return
            }
            self.finish(with: error ?? "", inFile: inFile)
        }
        return true
    }

    private func finish(with error: String, inFile: URL) {
        // Logic reads the file during import; give it a beat before deleting.
        queue.asyncAfter(deadline: .now() + 2) {
            try? FileManager.default.removeItem(at: inFile)
        }
        DispatchQueue.main.async {
            self.busy = false
            self.toast(error.isEmpty ? "Placed in Logic on new tracks" : error)
        }
    }

    // MARK: - Automation flows (run on `queue`)

    private func runExport(app: NSRunningApplication, dir: String, baseName: String, outFile: URL) -> String? {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        app.activate(options: [])
        usleep(400_000)

        guard let mi = menuItem(ax, path: ["File", "Export", "Selection as MIDI File…"]) else {
            return "Couldn't find Logic's Export menu (is a project open?)"
        }
        if !waitForEnabled(mi, ax: ax) {
            return "Select one or more MIDI regions in Logic first"
        }
        press(mi)
        guard let panel = waitForWindow(ax, titled: "Save MIDI File as:", timeout: 5) else {
            return "Logic's export panel never appeared"
        }
        if let err = drivePanel(panel, toPath: dir, saveAs: baseName) {
            cancelPanel(ax); return err
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: outFile.path) { return nil }
            usleep(100_000)
        }
        cancelPanel(ax)
        return "Logic never wrote the MIDI file"
    }

    private func runImport(app: NSRunningApplication, file: String) -> String? {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        app.activate(options: [])
        usleep(400_000)

        guard let mi = menuItem(ax, path: ["File", "Import", "MIDI File…"]) else {
            return "Couldn't find Logic's Import menu (is a project open?)"
        }
        if (attr(mi, kAXEnabledAttribute) as? Bool) != true {
            return "Logic can't import right now (open a project)"
        }
        press(mi)
        guard let panel = waitForWindow(ax, titled: "Import", timeout: 5) else {
            return "Logic's import panel never appeared"
        }
        if let err = drivePanel(panel, toPath: file, saveAs: nil) {
            cancelPanel(ax); return err
        }
        // Auto-decline "Also import tempo information?" if it appears.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let wins = (attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []
            for w in wins where title(w).isEmpty {
                if let no = children(w).first(where: { role($0) == "AXButton" && title($0) == "No" }) {
                    press(no)
                    return nil
                }
            }
            usleep(150_000)
        }
        return nil
    }

    /// Navigates an open NSSave/NSOpenPanel with the Go To Folder sheet, then
    /// confirms. `saveAs` non-nil = save panel (sets the filename field).
    /// Returns an error message, or nil on success.
    private func drivePanel(_ panel: AXUIElement, toPath path: String, saveAs: String?) -> String? {
        usleep(300_000)
        sendKey(5, flags: [.maskCommand, .maskShift])   // ⇧⌘G
        guard pollSheet(on: panel, present: true) else { return "Panel navigation sheet never appeared" }
        usleep(250_000)
        guard let sheet = findSheet(panel),
              let field = firstDescendant(sheet, roles: ["AXTextField", "AXComboBox"]) else {
            return "Panel navigation field not found"
        }
        AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, path as CFString)
        usleep(250_000)
        sendKey(36)                                      // Return — confirm Go To
        guard pollSheet(on: panel, present: false) else { return "Panel navigation never completed" }
        usleep(400_000)

        if let name = saveAs {
            guard let nameField = findNameField(panel) else { return "Save panel filename field not found" }
            AXUIElementSetAttributeValue(nameField, kAXValueAttribute as CFString, name as CFString)
            usleep(200_000)
        }

        var confirm: AXUIElement?
        for t in ["Save", "Import", "Open", "Choose"] {
            if let b = descendantButton(panel, titled: t) { confirm = b; break }
        }
        guard let confirmBtn = confirm else { return "Panel confirm button not found" }
        press(confirmBtn)
        usleep(400_000)

        // "Name already taken" sheet — shouldn't happen with unique names,
        // but never leave it dangling.
        if let sheet = findSheet(panel), let replace = descendantButton(sheet, titled: "Replace") {
            press(replace)
            usleep(300_000)
        }
        return nil
    }

    /// The export item is disabled when key focus sits in a non-editor pane
    /// (Loop Browser, inspector, …) even though the region selection is
    /// intact. Tab cycles Logic's key focus between panes, so nudge focus a
    /// couple of times before concluding there's no selection. Never sends
    /// Tab while a text field is being edited (it would commit the edit).
    private func waitForEnabled(_ mi: AXUIElement, ax: AXUIElement) -> Bool {
        if (attr(mi, kAXEnabledAttribute) as? Bool) == true { return true }
        for _ in 0..<3 {
            if let focused = attr(ax, "AXFocusedUIElement"),
               role(focused as! AXUIElement) == "AXTextField" { return false }
            sendKey(48)                                     // Tab: cycle key focus
            usleep(350_000)
            if (attr(mi, kAXEnabledAttribute) as? Bool) == true { return true }
        }
        return false
    }

    /// Escapes out of whatever panel is left after a failed flow so Logic
    /// isn't stuck behind a modal.
    private func cancelPanel(_ ax: AXUIElement) {
        let wins = (attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        for w in wins where ["Save MIDI File as:", "Import"].contains(title(w)) {
            if let cancel = descendantButton(w, titled: "Cancel") { press(cancel) }
        }
    }

    // MARK: - AX helpers

    private func runningLogic() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first
    }

    private func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        AXUIElementCopyAttributeValue(el, name as CFString, &v)
        return v
    }

    private func children(_ el: AXUIElement) -> [AXUIElement] {
        (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private func title(_ el: AXUIElement) -> String {
        (attr(el, kAXTitleAttribute) as? String) ?? ""
    }

    private func role(_ el: AXUIElement) -> String {
        (attr(el, kAXRoleAttribute) as? String) ?? ""
    }

    private func press(_ el: AXUIElement) {
        AXUIElementPerformAction(el, kAXPressAction as CFString)
    }

    private func menuItem(_ ax: AXUIElement, path: [String]) -> AXUIElement? {
        guard let bar = attr(ax, kAXMenuBarAttribute) else { return nil }
        var cur = bar as! AXUIElement
        for (i, name) in path.enumerated() {
            guard var el = children(cur).first(where: { title($0) == name }) else { return nil }
            if i < path.count - 1 {
                guard let sub = children(el).first(where: { role($0) == "AXMenu" }) else { return nil }
                el = sub
            }
            cur = el
        }
        return cur
    }

    private func waitForWindow(_ ax: AXUIElement, titled t: String, timeout: TimeInterval) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let wins = (attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []
            if let w = wins.first(where: { title($0) == t }) { return w }
            usleep(100_000)
        }
        return nil
    }

    private func findSheet(_ win: AXUIElement) -> AXUIElement? {
        children(win).first { role($0) == "AXSheet" }
    }

    private func pollSheet(on win: AXUIElement, present: Bool, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (findSheet(win) != nil) == present { return true }
            usleep(100_000)
        }
        return false
    }

    private func firstDescendant(_ el: AXUIElement, roles: Set<String>, depth: Int = 0) -> AXUIElement? {
        if depth > 8 { return nil }
        for k in children(el) {
            if roles.contains(role(k)) { return k }
            if let found = firstDescendant(k, roles: roles, depth: depth + 1) { return found }
        }
        return nil
    }

    private func descendantButton(_ el: AXUIElement, titled t: String, depth: Int = 0) -> AXUIElement? {
        if depth > 8 { return nil }
        for k in children(el) {
            if role(k) == "AXButton" && title(k) == t { return k }
            if let found = descendantButton(k, titled: t, depth: depth + 1) { return found }
        }
        return nil
    }

    /// The filename field sits next to the panel's Cancel button; the file
    /// browser and sidebar (scroll areas/outlines) are full of unrelated
    /// text fields, so they're skipped.
    private func findNameField(_ el: AXUIElement, depth: Int = 0) -> AXUIElement? {
        if depth > 8 { return nil }
        let kids = children(el)
        var field: AXUIElement?
        var hasCancel = false
        for k in kids {
            let r = role(k)
            if r == "AXTextField" { field = k }
            if r == "AXButton" && title(k) == "Cancel" { hasCancel = true }
        }
        if hasCancel, let f = field { return f }
        for k in kids {
            let r = role(k)
            if r == "AXScrollArea" || r == "AXOutline" || r == "AXSheet" { continue }
            if let found = findNameField(k, depth: depth + 1) { return found }
        }
        return nil
    }

    private func sendKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
        usleep(50_000)
    }

    private func toast(_ text: String) {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: .hotCopyToast, object: text)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .hotCopyToast, object: text)
            }
        }
    }
}
