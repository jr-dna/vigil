import AppKit
import Combine
import SwiftUI

/// Owns the menu bar item and the popover it opens.
@MainActor
final class StatusItemController: NSObject {

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let monitor: AssertionMonitor
    private var cancellable: AnyCancellable?

    /// The three states the icon can be in. Everything Vigil knows has to fit
    /// in an 18-point glyph, so it only distinguishes what changes behaviour:
    /// nothing blocking, something blocking, something blocking for too long.
    ///
    /// Open eye means something is holding sleep off. Closed eye means nothing
    /// is. Deliberately not a moon — that's what Focus uses, and a menu bar
    /// full of crescents tells you nothing.
    private enum IconState {
        case quiet
        case blocking
        case stale

        /// Tried in order; the first name the running OS actually has wins.
        /// SF Symbols adds and renames glyphs between releases, and
        /// `NSImage(systemSymbolName:)` returns nil rather than throwing — so
        /// a name that doesn't exist would leave a blank menu bar with no
        /// error anywhere. The fallback chain makes that impossible.
        var symbolCandidates: [String] {
            switch self {
            case .quiet:
                return ["eye.closed", "eye.slash", "eye"]
            case .blocking:
                return ["eye", "eye.fill"]
            case .stale:
                return ["eye.trianglebadge.exclamationmark",
                        "eye.trianglebadge.exclamationmark.fill",
                        "exclamationmark.triangle.fill"]
            }
        }

        var tint: NSColor? {
            switch self {
            case .quiet, .blocking: return nil   // follows the menu bar
            case .stale:            return .systemOrange
            }
        }

        var description: String {
            switch self {
            case .quiet:    return "Nothing is blocking sleep"
            case .blocking: return "Something is blocking sleep"
            case .stale:    return "Sleep has been blocked for over an hour"
            }
        }
    }

    /// Names already reported, so the log line appears once per symbol rather
    /// than on every refresh.
    private var loggedSymbols = Set<String>()

    private func image(for state: IconState) -> NSImage? {
        for name in state.symbolCandidates {
            guard let image = NSImage(systemSymbolName: name,
                                      accessibilityDescription: state.description)
            else { continue }
            if loggedSymbols.insert(name).inserted {
                NSLog("Vigil: \(state) icon using '\(name)'")
            }
            image.isTemplate = true
            return image
        }
        NSLog("Vigil: no symbol found for \(state); tried \(state.symbolCandidates)")
        return nil
    }

    init(monitor: AssertionMonitor) {
        self.monitor = monitor
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        configureButton()
        configurePopover()

        cancellable = monitor.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                self?.updateIcon(for: snapshot)
            }
    }

    // MARK: Setup

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = image(for: .quiet)
        button.toolTip = IconState.quiet.description
        button.target = self
        button.action = #selector(togglePopover(_:))
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(
            rootView: AssertionListView(monitor: monitor)
        )
    }

    // MARK: Icon

    private func updateIcon(for snapshot: AssertionMonitor.Snapshot) {
        let state: IconState
        if !snapshot.stale.isEmpty {
            state = .stale
        } else if !snapshot.blocking.isEmpty {
            state = .blocking
        } else {
            state = .quiet
        }

        guard let button = statusItem.button else { return }

        button.image = image(for: state)
        button.contentTintColor = state.tint

        // Longest-held blocker in the tooltip, so hovering answers the
        // question without opening anything.
        if let worst = snapshot.blocking.first, let duration = worst.duration {
            button.toolTip = "\(worst.displayName) — \(duration.durationLabel)"
        } else {
            button.toolTip = state.description
        }
    }

    // MARK: Popover

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            guard let button = statusItem.button else { return }
            monitor.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
