import AppKit
import Combine

/// Mirrors Finale's *internal* music clipboard into HotCopyist history and
/// writes history items back so Finale pastes them.
///
/// Finale never puts copied music on the system pasteboard. Instead its
/// clipboard engine (SYSCLIP) spills every ⌘C to a small "ENIGMA BINARY FILE"
/// under ~/Library/Caches/com.makemusic.Finale27/Finale Temp Files <session>/
/// EnigmaTemp<n>, and re-reads that file when pasting. Overwriting the file
/// while Finale runs changes what the next ⌘V pastes (verified empirically —
/// see research/ notes), which makes capture and restore pure file I/O.
final class FinaleClipService: ObservableObject {

    /// Representation type for Finale music clips stored in history items.
    static let repType = "com.blihovde.hotcopy.finale.enigma-clip"

    /// Type written by pre-rename builds; still present in persisted history,
    /// so it must stay readable forever.
    static let legacyRepType = "org.copywiz.finale.enigma-clip"

    private static let headerMagic = Data("ENIGMA BINARY FILE".utf8)
    private static let bundleID = "com.makemusic.Finale27"

    /// Auto-save also writes ENIGMA-header library mirrors next to the clip
    /// file; changes this close to auto-save activity are not treated as
    /// user copies.
    private static let autosaveWindow: TimeInterval = 3.0

    private let store: HistoryStore
    private var timer: Timer?
    private var fileStates: [String: (mtime: Date, size: Int)] = [:]
    private var didBaseline = false

    /// The file Finale most recently wrote a music clip to — the one to
    /// overwrite when arming an item. Nil until Finale copies once.
    private(set) var clipFilePath: String?

    /// Hash of data this service just wrote itself, so the resulting file
    /// change isn't re-captured as a fresh copy.
    private var suppressedHash: String?

    private let cachesRoot = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.makemusic.Finale27", isDirectory: true)

    init(store: HistoryStore) {
        self.store = store
    }

    func start() {
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Capture

    /// Finale keeps one "Finale Temp Files <n>" folder per running session;
    /// the folder id changes across launches, so track the newest.
    private func sessionDir() -> URL? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: cachesRoot.path) else { return nil }
        var newest: (url: URL, mtime: Date)?
        for name in names where name.hasPrefix("Finale Temp Files") {
            let url = cachesRoot.appendingPathComponent(name, isDirectory: true)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            if newest == nil || mtime > newest!.mtime {
                newest = (url, mtime)
            }
        }
        return newest?.url
    }

    private func poll() {
        guard let dir = sessionDir() else { return }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }

        var autosaveActive = false
        var changed: [String] = []

        for name in names {
            let path = dir.appendingPathComponent(name).path
            if name.hasPrefix("NfTemp") {
                if let attrs = try? fm.attributesOfItem(atPath: path),
                   let mtime = attrs[.modificationDate] as? Date,
                   Date().timeIntervalSince(mtime) < Self.autosaveWindow {
                    autosaveActive = true
                }
                continue
            }
            // Clip candidates: extensionless EnigmaTemp files (skips .dragclip).
            guard name.hasPrefix("EnigmaTemp"), !name.contains(".") else { continue }
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date,
                  let size = (attrs[.size] as? NSNumber)?.intValue else { continue }
            let previous = fileStates[path]
            fileStates[path] = (mtime, size)
            guard didBaseline else { continue }
            if previous == nil || previous!.mtime != mtime || previous!.size != size {
                changed.append(path)
            }
        }
        didBaseline = true

        for path in changed {
            captureChange(at: path, autosaveActive: autosaveActive)
        }
    }

    private func captureChange(at path: String, autosaveActive: Bool) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              data.starts(with: Self.headerMagic),
              data.count <= ClipboardMonitor.maxRepresentationBytes else { return }
        guard !autosaveActive else { return }

        clipFilePath = path

        let rep = ClipboardItem.Representation(itemIndex: 0, type: Self.repType, data: data)
        if ClipboardItem.hash(of: [rep]) == suppressedHash {
            suppressedHash = nil
            return
        }
        store.insert(ClipboardItem(reps: [rep],
                                   sourceAppName: "Finale",
                                   sourceBundleID: Self.bundleID))
    }

    // MARK: - Arming

    /// Writes the item's Enigma payload into Finale's live clip file so the
    /// next ⌘V in Finale pastes it. Returns false if the item isn't a Finale
    /// clip or no clip file exists yet this session.
    @discardableResult
    func arm(_ item: ClipboardItem) -> Bool {
        guard let data = item.data(for: Self.repType) ?? item.data(for: Self.legacyRepType) else { return false }
        guard let path = clipFilePath ?? locateClipFile() else {
            toast("Copy once in Finale first, then HotCopyist can re-arm clips")
            return false
        }
        clipFilePath = path
        let rep = ClipboardItem.Representation(itemIndex: 0, type: Self.repType, data: data)
        suppressedHash = ClipboardItem.hash(of: [rep])
        do {
            // Non-atomic on purpose: keep the same inode Finale re-reads.
            try data.write(to: URL(fileURLWithPath: path), options: [])
            return true
        } catch {
            suppressedHash = nil
            toast("Couldn't write Finale clip: \(error.localizedDescription)")
            return false
        }
    }

    /// Fallback when nothing has been captured yet this app-session: the
    /// most recently modified ENIGMA-header clip candidate.
    private func locateClipFile() -> String? {
        guard let dir = sessionDir() else { return nil }
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return nil }
        var best: (path: String, mtime: Date)?
        for name in names where name.hasPrefix("EnigmaTemp") && !name.contains(".") {
            let path = dir.appendingPathComponent(name).path
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date,
                  let handle = FileHandle(forReadingAtPath: path),
                  let head = try? handle.read(upToCount: Self.headerMagic.count),
                  head == Self.headerMagic else { continue }
            try? handle.close()
            if best == nil || mtime > best!.mtime {
                best = (path, mtime)
            }
        }
        return best?.path
    }

    private func toast(_ text: String) {
        NotificationCenter.default.post(name: .hotCopyToast, object: text)
    }
}
