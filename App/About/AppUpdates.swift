import Combine
import Foundation

// In-app updates. The app's Sparkle updater (SparkleUpdates.swift, built into
// the app only) installs itself here before launch; everything else sees just
// these operations, so test builds run without the framework.
@MainActor final class AppUpdates: ObservableObject {
    struct Backend {
        var start: () -> Void
        var check: () -> Void
        var checkInBackground: () -> Void
        var lastCheck: () -> Date?
        var automaticChecks: () -> Bool
        var setAutomaticChecks: (Bool) -> Void
    }
    // A relaunch within this time of the last check does not check again.
    static let launchCheckSpacing: TimeInterval = 60 * 60
    static let shared = AppUpdates()
    var backend: Backend?
    @Published private(set) var automaticChecks = false

    init(backend: Backend? = nil) { self.backend = backend }

    // With automatic checks on, each launch also checks once in the background
    // (shown only when an update exists); the daily schedule stays as it is.
    // The first launch, before Welcome is done, leaves it to that schedule.
    func start(now: Date = Date(), quiet: Bool = false) {
        guard let backend else { return }
        backend.start()
        automaticChecks = backend.automaticChecks()
        guard automaticChecks, !quiet else { return }
        if let last = backend.lastCheck(), now.timeIntervalSince(last) < Self.launchCheckSpacing { return }
        backend.checkInBackground()
    }
    func check() { backend?.check() }
    func setAutomaticChecks(_ enabled: Bool) {
        backend?.setAutomaticChecks(enabled)
        automaticChecks = backend?.automaticChecks() ?? enabled
    }
}
