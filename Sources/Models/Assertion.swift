import Foundation

// MARK: - Dictionary keys

/// Keys used inside the per-assertion dictionaries returned by
/// `IOPMCopyAssertionsByProcess`.
///
/// IOPMLib.h declares these as `CFSTR(...)` macros. C macros of that form do
/// not import into Swift, so the literals are reproduced here. Each field
/// lists every spelling observed across macOS releases; `AssertionRecord`
/// tries them in order and takes the first hit.
///
/// If a field reads back nil on your machine, diff this list against
/// `/usr/include/IOKit/pwr_mgt/IOPMLib.h` (or run
/// `strings /usr/bin/pmset | grep Assert`) and add the missing key.
enum AssertionKey {
    static let type        = ["AssertType"]
    static let name        = ["AssertName"]
    static let createDate  = ["AssertStartWhen", "AssertCreateDate"]
    static let timeout     = ["TimeoutSeconds", "AssertTimeOut"]
    static let processName = ["Process Name", "AssertProcessName"]
    static let details     = ["Details", "AssertDetails"]
    static let globalID    = ["GlobalUniqueID"]
    static let level       = ["AssertLevel"]
}

// MARK: - Assertion kinds

/// The assertion types power management reports. Raw values match the strings
/// `pmset -g assertions` prints in its top block.
enum AssertionKind: String {
    case preventUserIdleDisplaySleep = "PreventUserIdleDisplaySleep"
    case preventUserIdleSystemSleep  = "PreventUserIdleSystemSleep"
    case preventSystemSleep          = "PreventSystemSleep"
    case noDisplaySleep              = "NoDisplaySleepAssertion"   // legacy spelling
    case noIdleSleep                 = "NoIdleSleepAssertion"      // legacy spelling
    case userIsActive                = "UserIsActive"
    case systemIsActive              = "SystemIsActive"
    case backgroundTask              = "BackgroundTask"
    case applePushServiceTask        = "ApplePushServiceTask"
    case networkClientActive         = "NetworkClientActive"
    case externalMedia               = "ExternalMedia"
    case softwareUpdateTask          = "SoftwareUpdateTask"
    case internalPreventDisplaySleep = "InternalPreventDisplaySleep"
    case internalPreventSleep        = "InternalPreventSleep"
    case preventDiskIdle             = "PreventDiskIdle"
    case enableIdleSleep             = "EnableIdleSleep"
    case unknown                     = ""

    init(raw: String) {
        self = AssertionKind(rawValue: raw) ?? .unknown
    }

    /// Whether holding this assertion actually stops the machine idling out.
    var preventsSleep: Bool {
        switch self {
        case .preventUserIdleDisplaySleep, .preventUserIdleSystemSleep,
             .preventSystemSleep, .noDisplaySleep, .noIdleSleep:
            return true
        default:
            return false
        }
    }

    /// What the assertion stops, in the user's terms.
    var effect: String {
        switch self {
        case .preventUserIdleDisplaySleep, .noDisplaySleep:
            return "Display stays on"
        case .preventUserIdleSystemSleep, .noIdleSleep:
            return "System stays awake"
        case .preventSystemSleep:
            return "System cannot sleep at all"
        case .userIsActive:
            return "Recent input"
        case .systemIsActive:
            return "Background work"
        case .backgroundTask, .softwareUpdateTask:
            return "Background task"
        case .applePushServiceTask, .networkClientActive:
            return "Network activity"
        case .externalMedia:
            return "External volume mounted"
        case .internalPreventDisplaySleep:
            return "Display held on internally"
        case .internalPreventSleep:
            return "System held awake internally"
        case .preventDiskIdle:
            return "Disk kept spinning"
        case .enableIdleSleep:
            return "Idle sleep permitted"
        case .unknown:
            return "Unrecognized"
        }
    }
}

// MARK: - Classification

/// How much attention an assertion deserves.
///
/// This is the difference between Vigil and `pmset`. A raw assertion dump is
/// mostly noise: `powerd`'s "Prevent sleep while display is on" exists only
/// *because* something else is holding the display awake, and `WindowServer`'s
/// UserIsActive is the user typing. Neither is worth showing at the top level.
///
/// The line is drawn on ownership, not on whether a timeout exists. A
/// `caffeinate -d -t 600` is blocking sleep for the next ten minutes whether
/// or not it will eventually clean up after itself — if you own it and it
/// stops your Mac sleeping, you should be able to see it and stop it. The
/// timeout shows up as a tag on the row instead.
enum Classification {
    /// Prevents sleep and belongs to the current user. Top level, with a
    /// Stop button.
    case blocking

    /// Owned by the OS, or doesn't prevent sleep at all. Collapsed by
    /// default and never killable.
    case system
}

// MARK: - Record

/// One assertion, joined to what is known about the process holding it.
struct AssertionRecord: Identifiable {
    let id: String
    let pid: pid_t
    let kind: AssertionKind
    let rawType: String
    let name: String
    let details: String?
    let createdAt: Date?
    let timeout: TimeInterval

    /// Filled in by `ProcessInspector`; nil if the process vanished between
    /// the IOKit read and the sysctl call.
    let process: ProcessDetails?

    // MARK: Derived

    var hasTimeout: Bool { timeout > 0 }

    var duration: TimeInterval? {
        guard let createdAt else { return nil }
        return Date().timeIntervalSince(createdAt)
    }

    /// A process reparented to launchd has outlived whatever started it.
    ///
    /// Bundled applications are excluded: every app launched from the Dock or
    /// Finder is a direct child of launchd by design, so without this the flag
    /// would fire on every running app and mean nothing. It's only a signal
    /// for something that ought to have a parent and doesn't — a tool spawned
    /// by a build script whose script has since died, which is exactly the
    /// case this app was written to catch.
    var isOrphaned: Bool {
        guard let process else { return false }
        guard !process.isBundledApp else { return false }
        return process.ppid == 1 && process.uid != 0
    }

    var isSystemOwned: Bool {
        guard let process else { return true }   // unknown owner: assume system
        return process.isSystemOwned
    }

    var classification: Classification {
        guard kind.preventsSleep, !isSystemOwned else { return .system }
        return .blocking
    }

    /// How long before this counts as worth flagging. An hour is generous for
    /// a build or a render and short enough to catch an overnight stray.
    static let staleThreshold: TimeInterval = 60 * 60

    var isStale: Bool {
        classification == .blocking && (duration ?? 0) > Self.staleThreshold
    }

    var displayName: String {
        process?.name ?? name
    }

    /// What this assertion does, in the user's terms — falling back to the raw
    /// type string when the enum has no case for it. An unfamiliar assertion
    /// should tell you its own name rather than just reading "Unrecognized",
    /// which gives you nothing to look up.
    var effectDescription: String {
        kind == .unknown ? rawType : kind.effect
    }

    // MARK: Parsing

    init?(pid: pid_t, index: Int, dictionary: [String: Any], process: ProcessDetails?) {
        func string(_ candidates: [String]) -> String? {
            for key in candidates {
                if let value = dictionary[key] as? String, !value.isEmpty { return value }
            }
            return nil
        }
        func number(_ candidates: [String]) -> NSNumber? {
            for key in candidates {
                if let value = dictionary[key] as? NSNumber { return value }
            }
            return nil
        }
        func date(_ candidates: [String]) -> Date? {
            for key in candidates {
                if let value = dictionary[key] as? Date { return value }
            }
            return nil
        }

        guard let rawType = string(AssertionKey.type) else { return nil }

        self.pid       = pid
        self.rawType   = rawType
        self.kind      = AssertionKind(raw: rawType)
        self.name      = string(AssertionKey.name) ?? rawType
        self.details   = string(AssertionKey.details)
        self.createdAt = date(AssertionKey.createDate)
        self.timeout   = number(AssertionKey.timeout)?.doubleValue ?? 0
        self.process   = process

        // Prefer the assertion's own global ID so SwiftUI keeps row identity
        // across refreshes. The fallback uses the assertion's position within
        // its process rather than its contents: one process routinely holds
        // several assertions of the same type created in the same instant
        // (coreaudiod does it during playback), and a content-derived ID would
        // collide — which makes ForEach silently drop the duplicates.
        if let global = string(AssertionKey.globalID) {
            self.id = global
        } else {
            self.id = "\(pid)-\(index)-\(rawType)"
        }
    }
}

// MARK: - Formatting

extension TimeInterval {
    /// "14h 51m", "2m 12s", "10m", "4s". Trailing zero components are dropped —
    /// a ten-minute timeout should read "10m", not "10m 0s".
    var durationLabel: String {
        let total = Int(self)
        guard total > 0 else { return "0s" }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return seconds > 0 ? "\(minutes)m \(seconds)s" : "\(minutes)m" }
        return "\(seconds)s"
    }
}
