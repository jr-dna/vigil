import AppKit
import SwiftUI

struct AssertionListView: View {
    @ObservedObject var monitor: AssertionMonitor

    @State private var showBackground = false
    @State private var lastMessage: String?
    @State private var messageTask: Task<Void, Never>?
    @State private var confirmingKillAll = false

    private var snapshot: AssertionMonitor.Snapshot { monitor.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if snapshot.isQuiet {
                        quietState
                    } else {
                        ForEach(snapshot.blocking) { record in
                            AssertionRow(record: record) { kill(record) }
                            Divider()
                        }
                    }

                    if !snapshot.system.isEmpty {
                        Divider()
                        backgroundSection
                    }
                }
            }
            .frame(maxHeight: 400)

            // Pinned outside the ScrollView. Two blocking rows are already
            // enough to overflow the cap, and the one control that must never
            // scroll out of reach is the one that stops everything.
            if !snapshot.isQuiet {
                Divider()
                killAllControl
            }

            if let lastMessage {
                Divider()
                Text(lastMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .frame(width: 380)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            statusLine(
                label: "Display sleep",
                blocked: snapshot.displaySleepBlocked
            )
            statusLine(
                label: "System sleep",
                blocked: snapshot.systemSleepBlocked
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func statusLine(label: String, blocked: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(blocked ? Color.orange : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 12))
            Spacer()
            Text(blocked ? "blocked" : "allowed")
                .font(.system(size: 12, weight: blocked ? .medium : .regular))
                .foregroundStyle(blocked ? Color.primary : Color.secondary)
        }
    }

    // MARK: States

    private var quietState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nothing is holding your Mac awake.")
                .font(.system(size: 12))
            if snapshot.systemSleepBlocked {
                Text("System sleep shows as blocked because the display is on. That clears on its own when the screen idles out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private var killAllControl: some View {
        HStack {
            if confirmingKillAll {
                Text("Stop \(uniqueBlockingCount) process\(uniqueBlockingCount == 1 ? "" : "es")?")
                    .font(.system(size: 12))
                Spacer()
                Button("Cancel") { confirmingKillAll = false }
                    .controlSize(.small)
                Button("Stop all") { killAll() }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Stop all (\(uniqueBlockingCount))") {
                    confirmingKillAll = true
                }
                .controlSize(.small)
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var uniqueBlockingCount: Int {
        Set(snapshot.blocking.map(\.pid)).count
    }

    // MARK: Background section

    private var backgroundSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { showBackground.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showBackground ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Background (\(snapshot.system.count))")
                        .font(.system(size: 12))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if showBackground {
                ForEach(snapshot.system) { record in
                    BackgroundRow(record: record)
                }
                .padding(.bottom, 6)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Refresh") { monitor.refresh() }
                .controlSize(.small)
            settingsMenu
            Spacer()
            Button("Quit Vigil") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var settingsMenu: some View {
        Menu {
            Picker("Check for changes", selection: $monitor.refreshInterval) {
                ForEach(RefreshInterval.allCases) { interval in
                    Text(interval.label).tag(interval)
                }
            }
            .pickerStyle(.inline)

            Divider()
            Text(updateNote)

            Divider()
            Button("Uninstall Vigil…") { Uninstaller.run() }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("How often Vigil checks for changes")
    }

    /// The interval means different things depending on whether the system is
    /// pushing changes at us, so say which case we're in rather than leaving
    /// the setting to be interpreted in a vacuum.
    private var updateNote: String {
        if monitor.liveUpdatesActive {
            return "Changes arrive as they happen. The schedule above is a fallback."
        }
        if monitor.refreshInterval == .manual {
            return "Live updates are unavailable and checking is off — the menu bar icon won't change until you open this."
        }
        return "Live updates are unavailable, so the schedule above is how changes get noticed."
    }

    // MARK: Actions

    /// Status lines expire. A line reading "Stopped caffeinate (48198)" while a
    /// different caffeinate is running describes the past as if it were the
    /// present, which is worse than showing nothing.
    private func show(_ message: String) {
        lastMessage = message
        messageTask?.cancel()
        messageTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8 * NSEC_PER_SEC)
            guard !Task.isCancelled else { return }
            lastMessage = nil
        }
    }

    private func kill(_ record: AssertionRecord) {
        show(monitor.kill(record).message)
    }

    private func killAll() {
        confirmingKillAll = false
        let outcomes = monitor.killAllBlocking()
        let stopped = outcomes.filter(\.succeeded).count
        let refused = outcomes.count - stopped
        if refused == 0 {
            show("Stopped \(stopped) process\(stopped == 1 ? "" : "es")")
        } else {
            show("Stopped \(stopped), skipped \(refused)")
        }
    }
}

// MARK: - Blocking row

private struct AssertionRow: View {
    let record: AssertionRecord
    let onKill: () -> Void

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if record.isStale {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
                Text(record.displayName)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                if let duration = record.duration {
                    Text(duration.durationLabel)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(record.isStale ? Color.orange : Color.secondary)
                }
            }

            Text(record.effectDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Tag(record.hasTimeout ? "expires in \(record.timeout.durationLabel)" : "no timeout")
                if record.isOrphaned { Tag("orphaned", tint: .orange) }
                Tag("pid \(record.pid)")
                Spacer()
                Button("Stop", action: onKill)
                    .controlSize(.small)
                    .disabled(!(record.process?.isKillable ?? false))
            }

            Button {
                withAnimation(.easeOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text(record.process?.commandLine ?? record.name)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            if expanded { ancestry }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// The parent chain, indented. This is the line that separates "a build is
    /// running" from "this is debris from a crash three days ago".
    private var ancestry: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array((record.process?.ancestors ?? []).enumerated()), id: \.element.id) { index, ancestor in
                HStack(spacing: 4) {
                    Text(String(repeating: "  ", count: index) + "└─")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(verbatim: "\(ancestor.name) (\(ancestor.pid))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if ancestor.isLaunchd && record.isOrphaned {
                        Text("— nothing owns this any more")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                }
            }
            if (record.process?.ancestors ?? []).isEmpty {
                Text("Parent chain unavailable")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 12)
        .padding(.top, 2)
    }
}

// MARK: - Background row

private struct BackgroundRow: View {
    let record: AssertionRecord

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(record.displayName)
                .font(.system(size: 11))
            Text(record.effectDescription)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer()
            if record.hasTimeout {
                Text("expires")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else if let duration = record.duration {
                Text(duration.durationLabel)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
    }
}

// MARK: - Tag

private struct Tag: View {
    let text: String
    var tint: Color = .secondary

    init(_ text: String, tint: Color = .secondary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(tint.opacity(0.12))
            )
    }
}
