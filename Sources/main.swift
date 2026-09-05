import AppKit

// Explicit entry point rather than @main: a top-level main.swift lets the
// activation policy be set before the app finishes launching, which avoids a
// Dock icon flickering in on startup.
let application = NSApplication.shared
let delegate = AppDelegate()

application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
