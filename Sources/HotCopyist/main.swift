import AppKit

// HotCopyist — a retro-future clipboard scope for macOS.
// Runs as a menu bar accessory app with a floating, always-on-top panel.

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
