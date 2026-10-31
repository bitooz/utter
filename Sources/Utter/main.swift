import AppKit
import UtterCore

MainActor.assumeIsolated {
    // Before the controller and the windows read the keys: one key per mode (the old main key becomes Auto's).
    Settings.migrateToKeyPerMode()
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
