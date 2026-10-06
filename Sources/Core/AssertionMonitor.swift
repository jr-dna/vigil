import Foundation
import IOKit.pwr_mgt

/// How often Vigil re-reads the assertion list on its own.
///
/// This is a fallback, not the primary update path. When the Darwin
/// notification registers successfully, changes arrive as they happen and this
/// timer only keeps durations ticking in an already-open popover. The popover
/// also refreshes on open, so the list you actually read is current whatever
/// this is set to — the interval mostly governs how fast the menu bar icon
/// reacts while you aren't looking.
enum RefreshInterval: Int, CaseIterable, Identifiable {
    case manual         = 0
    case twoSeconds     = 2
    case fiveSeconds    = 5
    case fifteenSeconds = 15
    case thirtySeconds  = 30
    case oneMinute      = 60
    case fiveMinutes    = 300

    var id: Int { rawValue }

    /// nil means no timer at all.
    var seconds: TimeInterval? {
        rawValue > 0 ? TimeInterval(rawValue) : nil
    }

    var label: String {
        switch self {
        case .manual:         return "Only when opened"
        case .twoSeconds:     return "Every 2 seconds"
        case .fiveSeconds:    return "Every 5 seconds"
        case .fifteenSeconds: return "Every 15 seconds"
        case .thirtySeconds:  return "Every 30 seconds"
        case .oneMinute:      return "Every minute"
        case .fiveMinutes:    return "Every 5 minutes"
        }
    }
}

/// Reads power-management assertions and publishes them, classified.
@MainActor
final class AssertionMonitor: ObservableObject {

    struct Snapshot {
        var blocking: [AssertionRecord] = []
        var system: [AssertionRecord] = []
        var displaySleepBlocked = false
        var systemSleepBlocked = false
        var capturedAt = Date()

        var all: [AssertionRecord] { blocking + system }
        var isQuiet: Bool { blocking.isEmpty }

        /// Anything blocking that has been up past the stale threshold.
        var stale: [AssertionRecord] { blocking.filter(\.isStale) }
    }

    @Published private(set) var snapshot = Snapshot()

    /// Persisted across launches. Setting it restarts the timer immediately.
    @Published var refreshInterval: RefreshInterval {
        didSet {
            guard oldValue != refreshInterval else { return }
            UserDefaults.standard.set(refreshInterval.rawValue, forKey: Self.intervalKey)
            restartTimer()
        }
    }

    /// Whether the Darwin notification registered. When true, the timer is
    /// belt-and-braces; when false, it's the only thing keeping the icon
    /// honest — which is what makes "Only when opened" worth warning about.
    @Published private(set) var liveUpdatesActive = false

    private static let intervalKey = "refreshInterval"

    init() {
        let stored = UserDefaults.standard.object(forKey: Self.intervalKey) as? Int
        refreshInterval = stored.flatMap(RefreshInterval.init(rawValue:)) ?? .fiveSeconds
    }

    /// `notify.h` spells these as preprocessor macros, which don't survive the
    /// Swift importer. Both values are stable ABI.
    private static let invalidToken: Int32 = -1     // NOTIFY_TOKEN_INVALID
    private static let notifyStatusOK: UInt32 = 0   // NOTIFY_STATUS_OK

    private var notifyToken: Int32 = AssertionMonitor.invalidToken
    private var timer: Timer?

    /// Darwin notification posted when the assertion set changes.
    ///
    /// This constant lives in IOPMLibPrivate.h and is not part of the public
    /// SDK, so it is spelled out rather than imported. It is only an
    /// optimisation — if the name is wrong the registration fails silently and
    /// the polling timer below keeps the UI correct, just less promptly.
    /// Verify with: `notifyutil -w com.apple.system.powermanagement.assertions`
    private static let assertionsChangedNotification =
        "com.apple.system.powermanagement.assertions"

    // MARK: Lifecycle

    func start() {
        refresh()
        subscribeToChanges()
        restartTimer()
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = nil

        guard let seconds = refreshInterval.seconds else { return }
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if notifyToken != Self.invalidToken {
            notify_cancel(notifyToken)
            notifyToken = Self.invalidToken
        }
    }

    private func subscribeToChanges() {
        // notify_register_dispatch and notify_cancel come from <notify.h>, which
        // reaches Swift only through Sources/Bridging/Vigil-Bridging-Header.h.
        let status = notify_register_dispatch(
            Self.assertionsChangedNotification,
            &notifyToken,
            DispatchQueue.main
        ) { [weak self] (_: Int32) in
            Task { @MainActor in self?.refresh() }
        }
        if status != Self.notifyStatusOK {
            notifyToken = Self.invalidToken
            liveUpdatesActive = false
            NSLog("Vigil: assertion change notification unavailable (status \(status)); polling only")
        } else {
            liveUpdatesActive = true
        }
    }

    // MARK: Reading

    func refresh() {
        let raw = Self.copyAssertionsByProcess()
        let levels = Self.copyAssertionLevels()

        var records: [AssertionRecord] = []
        for (pid, dictionaries) in raw {
            // One sysctl round trip per process, not per assertion — a single
            // process can hold several (cloudd routinely holds four).
            let details = ProcessInspector.details(for: pid)
            for (index, dictionary) in dictionaries.enumerated() {
                if let record = AssertionRecord(pid: pid, index: index,
                                                dictionary: dictionary, process: details) {
                    records.append(record)
                }
            }
        }

        // Longest-held first: the thing that has been up for 14 hours is the
        // thing you came here to find.
        let byAge: (AssertionRecord, AssertionRecord) -> Bool = {
            ($0.duration ?? 0) > ($1.duration ?? 0)
        }

        var next = Snapshot()
        next.blocking = records.filter { $0.classification == .blocking }.sorted(by: byAge)
        next.system   = records.filter { $0.classification == .system   }.sorted(by: byAge)
        next.displaySleepBlocked =
            (levels[AssertionKind.preventUserIdleDisplaySleep.rawValue] ?? 0) > 0
        next.systemSleepBlocked =
            (levels[AssertionKind.preventUserIdleSystemSleep.rawValue] ?? 0) > 0
            || (levels[AssertionKind.preventSystemSleep.rawValue] ?? 0) > 0
        next.capturedAt = Date()

        snapshot = next
    }

    /// Mirrors the "Listed by owning process" block of `pmset -g assertions`.
    private static func copyAssertionsByProcess() -> [pid_t: [[String: Any]]] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let dictionary = unmanaged?.takeRetainedValue() as? [NSNumber: Any]
        else { return [:] }

        var result: [pid_t: [[String: Any]]] = [:]
        for (key, value) in dictionary {
            guard let entries = value as? [[String: Any]] else { continue }
            result[pid_t(truncating: key)] = entries
        }
        return result
    }

    /// Mirrors the "Assertion status system-wide" block.
    private static func copyAssertionLevels() -> [String: Int] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&unmanaged) == kIOReturnSuccess,
              let dictionary = unmanaged?.takeRetainedValue() as? [String: NSNumber]
        else { return [:] }
        return dictionary.mapValues { $0.intValue }
    }

    // MARK: Actions

    @discardableResult
    func kill(_ record: AssertionRecord) async -> ProcessTerminator.Outcome {
        let outcome = await ProcessTerminator.terminate(record)
        refresh()
        return outcome
    }

    /// Kills every blocking assertion holder — everything the current user owns
    /// that is stopping the machine sleeping, including ones with a timeout.
    /// Never touches anything in the system bucket.
    ///
    /// Targets are the rows the user was looking at when they confirmed, not a
    /// fresh read: Stop all should mean "the ones I saw". Each is re-verified
    /// by the terminator before it's signalled, so anything that has exited
    /// since is skipped rather than mistaken for its successor.
    ///
    /// The stops run concurrently, so the worst case is one grace period in
    /// total rather than one per stubborn process.
    @discardableResult
    func killAllBlocking() async -> [ProcessTerminator.Outcome] {
        // Deduplicate by PID: one process holding three assertions is one kill.
        var seen = Set<pid_t>()
        let targets = snapshot.blocking.filter { seen.insert($0.pid).inserted }

        let outcomes = await withTaskGroup(of: ProcessTerminator.Outcome.self) { group in
            for target in targets {
                group.addTask { await ProcessTerminator.terminate(target) }
            }
            var collected: [ProcessTerminator.Outcome] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }

        refresh()
        return outcomes
    }
}
