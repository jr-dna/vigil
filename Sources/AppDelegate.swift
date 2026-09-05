import AppKit

/// Deliberately *not* `@MainActor` at class level: top-level code in
/// main.swift is a nonisolated synchronous context under `-swift-version 5`,
/// so a main-actor-isolated `init()` can't be called from there. The isolation
/// goes on the callbacks instead, which is where it's actually needed —
/// AppKit invokes both of these on the main thread.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var monitor: AssertionMonitor?
    private var statusItem: StatusItemController?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        let monitor = AssertionMonitor()
        self.monitor = monitor
        statusItem = StatusItemController(monitor: monitor)
        monitor.start()
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
    }

    /// Vigil holds no state worth keeping and no windows worth restoring.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
