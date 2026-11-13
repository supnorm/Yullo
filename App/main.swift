import AppKit

if #available(macOS 26.0, *) {
    MainActor.assumeIsolated {
        LegacyDefaultsMigration.run()
        let app = NSApplication.shared
        AppUpdates.shared.backend = .sparkle()
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
} else {
    fputs("Yullo requires macOS 26 or later.\n", stderr)
}
