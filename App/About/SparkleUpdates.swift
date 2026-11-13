import Sparkle

// Sparkle's standard updater: it reads SUFeedURL and SUPublicEDKey from
// Info.plist, shows its own windows, and installs an archive only when its
// EdDSA signature matches and the new app keeps this app's code signature.
extension AppUpdates.Backend {
    @MainActor static func sparkle() -> Self {
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        return Self(
            start: { controller.startUpdater() },
            check: { controller.checkForUpdates(nil) },
            checkInBackground: { controller.updater.checkForUpdatesInBackground() },
            lastCheck: { controller.updater.lastUpdateCheckDate },
            automaticChecks: { controller.updater.automaticallyChecksForUpdates },
            setAutomaticChecks: { controller.updater.automaticallyChecksForUpdates = $0 })
    }
}
