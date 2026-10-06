import Foundation

/// Sends signals to assertion holders, with the guard rails in front.
///
/// The asymmetry that shapes this file: a Mac that won't sleep is an
/// annoyance, and killing `powerd` or `WindowServer` is a lost afternoon. So
/// the refusal is structural — `terminate` re-checks the rules itself rather
/// than trusting that the UI only enabled the button on killable rows.
///
/// It also re-checks *which process* it's about to signal. The record behind a
/// Stop button comes from the last refresh, and PIDs are recycled: if the
/// process you saw has exited and its number been handed to something new,
/// a naive `kill(pid)` would hit the newcomer — a process you never saw and
/// never chose. So every signal is preceded by confirming the PID still has
/// the start time it had when it was listed.
enum ProcessTerminator {

    enum Outcome: Sendable {
        case terminated(pid: pid_t, name: String, escalated: Bool)
        case refused(pid: pid_t, name: String, reason: String)
        case alreadyGone(pid: pid_t, name: String)
        case failed(pid: pid_t, name: String, errno: Int32)

        var succeeded: Bool {
            switch self {
            case .terminated, .alreadyGone: return true
            case .refused, .failed: return false
            }
        }

        /// Written for the user, not the log: says what happened and, when
        /// something was refused, why.
        var message: String {
            switch self {
            case let .terminated(pid, name, escalated):
                return escalated
                    ? "Force-killed \(name) (\(pid))"
                    : "Stopped \(name) (\(pid))"
            case let .refused(_, name, reason):
                return "\(name) can't be stopped: \(reason)"
            case let .alreadyGone(_, name):
                return "\(name) had already exited"
            case let .failed(pid, name, code):
                return "Couldn't stop \(name) (\(pid)): \(String(cString: strerror(code)))"
            }
        }
    }

    /// Grace period between SIGTERM and SIGKILL. `caffeinate` handles SIGTERM
    /// immediately; two seconds is slack for anything slower.
    private static let gracePeriod: TimeInterval = 2.0
    private static let pollInterval: UInt64 = 100_000_000   // 100 ms, in ns

    /// Async so the grace period suspends instead of blocking. The previous
    /// version slept the main thread for up to two seconds per stubborn
    /// process, freezing the popover — and Stop all ran them one after
    /// another, so several stubborn processes could hang it for a long time.
    static func terminate(_ record: AssertionRecord) async -> Outcome {
        let pid = record.pid
        let name = record.displayName

        guard let listed = record.process else {
            return .refused(pid: pid, name: name,
                            reason: "its owner couldn't be identified")
        }

        // Confirm this is still the process that was listed, then judge it on
        // what's true now rather than what was true at the last refresh.
        guard ProcessInspector.isSameProcess(pid, startedAt: listed.startedAt),
              let current = ProcessInspector.details(for: pid),
              current.startedAt == listed.startedAt
        else {
            return .alreadyGone(pid: pid, name: name)
        }

        guard !current.isRootOwned else {
            return .refused(pid: pid, name: name,
                            reason: "it runs as root")
        }
        guard !current.isSystemPath, !current.isProtectedName else {
            return .refused(pid: pid, name: name,
                            reason: "it's part of macOS")
        }
        guard current.uid == getuid() else {
            return .refused(pid: pid, name: name,
                            reason: "it belongs to another user")
        }
        guard pid > 1 else {
            return .refused(pid: pid, name: name,
                            reason: "it is launchd")
        }
        guard pid != getpid() else {
            return .refused(pid: pid, name: name,
                            reason: "that's Vigil")
        }

        return await signal(pid: pid, name: name, startedAt: listed.startedAt)
    }

    /// SIGTERM, a grace period, then SIGKILL only if the *same* process is
    /// still there.
    ///
    /// The identity check narrows the recycled-PID window from "however long
    /// since the last refresh" to the few microseconds between a check and the
    /// signal that follows it. Closing it entirely would need a process handle
    /// rather than a number, which macOS doesn't offer for signalling.
    private static func signal(pid: pid_t, name: String, startedAt: Date?) async -> Outcome {
        // The policy checks above took a moment; confirm again right before
        // the first signal, as the SIGKILL path does.
        guard ProcessInspector.isSameProcess(pid, startedAt: startedAt) else {
            return .alreadyGone(pid: pid, name: name)
        }
        if kill(pid, SIGTERM) != 0 {
            let code = errno
            if code == ESRCH { return .alreadyGone(pid: pid, name: name) }
            return .failed(pid: pid, name: name, errno: code)
        }

        let deadline = Date().addingTimeInterval(gracePeriod)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: pollInterval)
            // A cancelled sleep returns immediately, which would turn this into
            // a busy loop for the rest of the grace period.
            if Task.isCancelled { break }
            if !ProcessInspector.isSameProcess(pid, startedAt: startedAt) {
                return .terminated(pid: pid, name: name, escalated: false)
            }
        }

        // Still here after the grace period. Re-confirm immediately before the
        // one signal that can't be ignored.
        guard ProcessInspector.isSameProcess(pid, startedAt: startedAt) else {
            return .terminated(pid: pid, name: name, escalated: false)
        }
        if kill(pid, SIGKILL) != 0 {
            let code = errno
            if code == ESRCH { return .terminated(pid: pid, name: name, escalated: false) }
            return .failed(pid: pid, name: name, errno: code)
        }
        return .terminated(pid: pid, name: name, escalated: true)
    }
}
