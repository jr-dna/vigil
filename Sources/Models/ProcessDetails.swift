import Foundation

/// What Vigil knows about a process holding an assertion.
struct ProcessDetails: Sendable {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
    let name: String

    /// The real path to the binary — from KERN_PROCARGS2, falling back to
    /// `proc_pidpath` — rather than argv[0]. Empty only if both refused.
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

    /// Locations only macOS itself installs into. System Integrity Protection
    /// keeps everything else out, so a binary living here is part of the OS
    /// whatever it happens to be called.
    ///
    /// This is the real protection; `protectedNames` is the backstop. A name
    /// list only covers the processes that happened to be running on the Mac
    /// it was written on, and macOS ships plenty of user-owned background
    /// agents that aren't on it — some of which take sleep assertions while
    /// they work. Without this they'd land at the top of the list, tagged
    /// orphaned (launchd starts them, and they aren't apps), and be swept up
    /// by Stop all.
    ///
    /// /usr/bin is deliberately absent: that's where `caffeinate` lives, and
    /// a forgotten `caffeinate` is the whole reason Vigil exists.
    static let systemPathPrefixes = [
        "/System/",
        "/usr/libexec/",
        "/usr/sbin/",
        "/sbin/",
        "/Library/Apple/",
    ]

    /// One carve-out: the ordinary apps Apple ships in /System/Applications —
    /// QuickTime Player, Music, TV, Podcasts — and Safari, whose real binary
    /// lives under a cryptex path that also contains /System/Applications/.
    /// They're apps you open and quit like any other, and a movie left playing
    /// in QuickTime is a perfectly reasonable thing to want to stop.
    /// /System/Library/CoreServices stays protected: Finder, Dock and
    /// loginwindow live there.
    var isSystemPath: Bool {
        guard Self.systemPathPrefixes.contains(where: { executablePath.hasPrefix($0) }) else {
            return false
        }
        let isUserFacingApp = isBundledApp && executablePath.contains("/System/Applications/")
        return !isUserFacingApp
    }

    var isSystemOwned: Bool { isRootOwned || isSystemPath || isProtectedName }

    /// The current user can signal it, and nothing above says not to.
    var isKillable: Bool {
        !isSystemOwned && uid == getuid()
    }
}

/// A link in the parent chain. Deliberately thinner than ProcessDetails —
/// walking the chain shouldn't cost a KERN_PROCARGS2 call per ancestor.
struct ProcessSummary: Identifiable, Sendable {
    let pid: pid_t
    let name: String
    var id: pid_t { pid }

    var isLaunchd: Bool { pid == 1 }
}
