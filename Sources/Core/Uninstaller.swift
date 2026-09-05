import AppKit

/// Removes Vigil and the small amount of state it created.
///
/// A separate uninstaller *application* is a Windows convention that reads as
/// amateurish on macOS, where the expectation is to drag an app to the Trash.
/// But dragging leaves the preferences plist behind, and the app is the thing
/// that knows what it wrote — so the cleanup belongs here, in the gear menu,
/// rather than in a second binary the user has to find.
@MainActor
enum Uninstaller {

    static func run() {
        let bundleURL = Bundle.main.bundleURL

        let alert = NSAlert()
        alert.messageText = "Uninstall Vigil?"
        alert.informativeText = """
        Vigil will move itself to the Trash and delete its saved settings.

        \(bundleURL.path)
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")

        // The popover has no window of its own to attach a sheet to, and an
        // accessory app isn't frontmost by default, so the alert would open
        // behind whatever the user is looking at.
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if let bundleID = Bundle.main.bundleIdentifier {
            // removePersistentDomain also clears cfprefsd's in-memory copy.
            // Deleting the plist alone lets the settings come back.
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }

        // If launch-at-login ever lands, unregister it here — before the
        // bundle moves — or the user is left with a login item pointing at
        // something in the Trash:
        //     try? SMAppService.mainApp.unregister()

        // Trashing a running app is safe: the process keeps its open file
        // handles, and macOS only reclaims the bundle once it exits.
        NSWorkspace.shared.recycle([bundleURL]) { _, error in
            if let error {
                NSLog("Vigil: couldn't move the bundle to the Trash: \(error.localizedDescription)")
            }
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}
