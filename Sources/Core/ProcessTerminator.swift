import Foundation

/// Sends signals to assertion holders, with the guard rails in front.
///
/// The asymmetry that shapes this file: a Mac that won't sleep is an
/// annoyance, and killing `powerd` or `WindowServer` is a lost afternoon. So
/// the refusal is structural — `terminate` re-checks the rules itself rather
/// than trusting that the UI only enabled the button on killable rows.
enum ProcessTerminator {

    enum Outcome {
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
    private static let pollInterval: useconds_t = 100_000   // 100 ms

    static func terminate(_ record: AssertionRecord) -> Outcome {
        let pid = record.pid
        let name = record.displayName

        guard let process = record.process else {
            return .refused(pid: pid, name: name,
                            reason: "its owner couldn't be identified")
        }
        guard !process.isRootOwned else {
            return .refused(pid: pid, name: name,
                            reason: "it runs as root")
        }
        guard !process.isProtectedName else {
            return .refused(pid: pid, name: name,
                            reason: "macOS needs it")
        }
        guard process.uid == getuid() else {
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

        return signal(pid: pid, name: name)
    }

    private static func signal(pid: pid_t, name: String) -> Outcome {
        if kill(pid, SIGTERM) != 0 {
            let code = errno
            if code == ESRCH { return .alreadyGone(pid: pid, name: name) }
            return .failed(pid: pid, name: name, errno: code)
        }

        // Wait out the grace period, checking whether it went quietly.
        let deadline = Date().addingTimeInterval(gracePeriod)
        while Date() < deadline {
            usleep(pollInterval)
            if !ProcessInspector.isAlive(pid) {
                return .terminated(pid: pid, name: name, escalated: false)
            }
        }

        // Still here. Escalate.
        if kill(pid, SIGKILL) != 0 {
            let code = errno
            if code == ESRCH { return .terminated(pid: pid, name: name, escalated: false) }
            return .failed(pid: pid, name: name, errno: code)
        }
        return .terminated(pid: pid, name: name, escalated: true)
    }
}
