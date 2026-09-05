import Foundation

/// Process facts that `pmset` never shows: who owns it, what started it, and
/// the exact command line.
///
/// The parent chain is the single most useful thing here. A `caffeinate`
/// whose parent is `make` is a build in progress and should be left alone. The
/// same `caffeinate` reparented to launchd is debris from a crash and can go.
/// Both look identical in `pmset -g assertions`.
enum ProcessInspector {

    // MARK: Public

    static func details(for pid: pid_t) -> ProcessDetails? {
        guard let info = kinfo(for: pid) else { return nil }

        let ppid = info.kp_eproc.e_ppid
        let uid  = info.kp_eproc.e_ucred.cr_uid
        let (executablePath, arguments) = processArguments(for: pid)

        // p_comm caps at 16 characters, so prefer a path's last component when
        // we have one. argv[0] first, since it's what the user typed; then the
        // exec path; then p_comm as the floor.
        let shortName = withUnsafePointer(to: info.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: info.kp_proc.p_comm)) {
                String(cString: $0)
            }
        }
        let name = [arguments.first, executablePath.isEmpty ? nil : executablePath]
            .compactMap { $0 }
            .first
            .map { ($0 as NSString).lastPathComponent }
            ?? shortName

        return ProcessDetails(
            pid: pid,
            ppid: ppid,
            uid: uid,
            name: name.isEmpty ? "pid \(pid)" : name,
            executablePath: executablePath,
            arguments: arguments,
            startedAt: startDate(from: info),
            ancestors: ancestors(of: pid)
        )
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        // Signal 0 performs the permission and existence check without
        // delivering anything.
        kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: Ancestry

    /// Parent chain, nearest first, terminating at launchd. Capped so a
    /// malformed process table can't spin.
    static func ancestors(of pid: pid_t, limit: Int = 16) -> [ProcessSummary] {
        var chain: [ProcessSummary] = []
        var current = pid
        var visited: Set<pid_t> = [pid]

        while chain.count < limit {
            guard let info = kinfo(for: current) else { break }
            let parent = info.kp_eproc.e_ppid
            guard parent > 0, !visited.contains(parent) else { break }
            visited.insert(parent)

            let name = shortName(of: parent) ?? "pid \(parent)"
            chain.append(ProcessSummary(pid: parent, name: name))

            if parent == 1 { break }   // reached launchd
            current = parent
        }
        return chain
    }

    // MARK: sysctl

    private static func kinfo(for pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]

        let result = mib.withUnsafeMutableBufferPointer { buffer -> Int32 in
            sysctl(buffer.baseAddress, u_int(buffer.count), &info, &size, nil, 0)
        }
        // size == 0 means the PID is gone even though sysctl succeeded.
        guard result == 0, size > 0 else { return nil }
        return info
    }

    private static func shortName(of pid: pid_t) -> String? {
        guard let info = kinfo(for: pid) else { return nil }
        let name = withUnsafePointer(to: info.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: info.kp_proc.p_comm)) {
                String(cString: $0)
            }
        }
        return name.isEmpty ? nil : name
    }

    private static func startDate(from info: kinfo_proc) -> Date? {
        let started = info.kp_proc.p_starttime
        guard started.tv_sec > 0 else { return nil }
        let seconds = TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000
        return Date(timeIntervalSince1970: seconds)
    }

    // MARK: Command line

    /// Reconstructs the executable path and argv the way `ps` does.
    ///
    /// KERN_PROCARGS2 returns a packed buffer:
    ///
    ///     [ Int32 argc ][ exec path \0 ][ \0 padding ][ argv[0] \0 argv[1] \0 ... ][ env ... ]
    ///
    /// The exec path is worth keeping separately: argv[0] is whatever the
    /// caller decided to put there, so a tool run from a shell reports a bare
    /// `caffeinate` while an app launched from the Finder reports a full path.
    /// Only the exec path is dependable.
    ///
    /// Returns empty values for processes the kernel won't describe, which
    /// includes anything owned by another user.
    static func processArguments(for pid: pid_t) -> (executablePath: String, arguments: [String]) {
        var argmax: Int32 = 0
        var argmaxSize = MemoryLayout<Int32>.stride
        var argmaxMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argmaxMIB, 2, &argmax, &argmaxSize, nil, 0) == 0, argmax > 0 else {
            return ("", [])
        }

        var buffer = [CChar](repeating: 0, count: Int(argmax))
        var size = Int(argmax)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]

        let result = mib.withUnsafeMutableBufferPointer { mibBuffer -> Int32 in
            sysctl(mibBuffer.baseAddress, u_int(mibBuffer.count), &buffer, &size, nil, 0)
        }
        guard result == 0, size > MemoryLayout<Int32>.stride else { return ("", []) }

        // argc occupies the first four bytes.
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }

        var offset = MemoryLayout<Int32>.stride

        // The exec path runs from here to the first null.
        let pathStart = offset
        while offset < size, buffer[offset] != 0 { offset += 1 }
        let executablePath = String(
            decoding: buffer[pathStart..<offset].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )

        guard argc > 0 else { return (executablePath, []) }

        // Then any alignment nulls before argv[0].
        while offset < size, buffer[offset] == 0 { offset += 1 }

        var arguments: [String] = []
        var current: [CChar] = []
        while offset < size, arguments.count < Int(argc) {
            let byte = buffer[offset]
            if byte == 0 {
                current.append(0)
                arguments.append(String(cString: current))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(byte)
            }
            offset += 1
        }
        return (executablePath, arguments)
    }
}
