import Foundation

/// What Vigil knows about a process holding an assertion.
struct ProcessDetails {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
    let name: String

    /// The real path to the binary, from KERN_PROCARGS2 rather than argv[0].
    /// Empty if the kernel wouldn't describe the process.
    let executablePath: String

    /// Full command line, reconstructed from KERN_PROCARGS2. Empty if the
    /// kernel refused (which happens for processes you don't own).
    let arguments: [String]

    let startedAt: Date?

    /// Parent chain from the immediate parent up to launchd, nearest first.
    let ancestors: [ProcessSummary]

    var commandLine: String {
        if !arguments.isEmpty { return arguments.joined(separator: " ") }
        return executablePath.isEmpty ? name : executablePath
    }

    /// Whether this is a normal application launched from the Dock or Finder.
    ///
    /// Matters because every such app is a direct child of launchd, so the
    /// "orphaned" heuristic — no parent left — is meaningless for them and
    /// would fire on every running app. It's only informative for something
    /// that ought to have a parent, like a tool spawned by a build script.
    var isBundledApp: Bool {
        executablePath.contains(".app/Contents/") || executablePath.contains(".appex/")
    }

    /// Root-owned processes are off limits. `powerd` is PID 338 on the machine
    /// this was written for; killing it would be a very bad afternoon.
    var isRootOwned: Bool { uid == 0 }

    /// Names that hold legitimate assertions as part of normal operation and
    /// must never be offered as killable, even when running as the user.
    /// Most are consequences of some other assertion rather than causes.
    static let protectedNames: Set<String> = [
        "powerd",           // "Prevent sleep while display is on" — a symptom
        "WindowServer",     // UserIsActive from keyboard and trackpad input
        "loginwindow",
        "sharingd",         // Handoff
        "useractivityd",    // Continuity BTLE advertising
        "cloudd",           // iCloud sync sessions, self-expiring
        "bird",
        "coreaudiod",       // holds assertions during playback
        "bluetoothd",
        "mediaremoted",
        "backupd",          // Time Machine
        "softwareupdated",
        "mds", "mds_stores", "mdworker",
        "launchd",
    ]

    var isProtectedName: Bool { Self.protectedNames.contains(name) }

    var isSystemOwned: Bool { isRootOwned || isProtectedName }

    /// The current user can signal it, and nothing above says not to.
    var isKillable: Bool {
        !isSystemOwned && uid == getuid()
    }
}

/// A link in the parent chain. Deliberately thinner than ProcessDetails —
/// walking the chain shouldn't cost a KERN_PROCARGS2 call per ancestor.
struct ProcessSummary: Identifiable {
    let pid: pid_t
    let name: String
    var id: pid_t { pid }

    var isLaunchd: Bool { pid == 1 }
}
