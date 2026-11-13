import Foundation

// First-use acknowledgement only. This owner neither reads functional
// Preferences nor chooses presentation, models, shortcuts or permissions.
@MainActor final class WelcomeStateStore {
    static let key = "yullo.welcome.v1"
    static let legacyModeKey = "yullo.settingsMode.v1"
    let isNewInstallation: Bool
    private(set) var isPending: Bool
    private let defaults: UserDefaults?

    init(defaults: UserDefaults, persisted: [String: Any], legacyPersisted: [String: Any] = [:]) {
        self.defaults = defaults
        // Capture before this owner or Model writes any migration markers.
        isNewInstallation = persisted.isEmpty && legacyPersisted.isEmpty
        if let value = persisted[Self.key] {
            // Preserve unknown newer/damaged values as existing-installation
            // evidence instead of overwriting them or reapplying fresh defaults.
            isPending = (value as? String) == "pending"
            return
        }
        let legacy = persisted[Self.legacyModeKey] ?? legacyPersisted[Self.legacyModeKey]
        isPending = (legacy as? String) == "pending" || isNewInstallation
        // Legacy mode values, aliases and every functional byte stay untouched.
        defaults.set(isPending ? "pending" : "completed", forKey: Self.key)
    }

    private init(isPending: Bool) {
        defaults = nil
        isNewInstallation = false
        self.isPending = isPending
    }

    static func application() -> WelcomeStateStore {
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier ?? "me.yullo.app"
        return WelcomeStateStore(
            defaults: defaults, persisted: defaults.persistentDomain(forName: domain) ?? [:],
            legacyPersisted: defaults.persistentDomain(forName: "local.glasstranslate.prototype") ?? [:])
    }

    static func inMemory(isPending: Bool = false) -> WelcomeStateStore { WelcomeStateStore(isPending: isPending) }

    func complete() {
        defaults?.set("completed", forKey: Self.key)
        isPending = false
    }
}

// One current welcome visit; closing deliberately defers only this process.
@MainActor final class WelcomeStartupCoordinator {
    let welcome: WelcomeStateStore
    private(set) var welcomeID: UUID?
    private(set) var deferredForRun = false
    var isPresenting: Bool { welcomeID != nil }
    var shouldOfferWelcome: Bool { welcome.isPending && !deferredForRun }

    init(welcome: WelcomeStateStore) { self.welcome = welcome }

    func beginWelcome(launchedAtLogin: Bool = false) -> UUID? {
        guard !launchedAtLogin, shouldOfferWelcome, welcomeID == nil else { return nil }
        let id = UUID()
        welcomeID = id
        return id
    }

    @discardableResult func completeWelcome(id: UUID) -> Bool {
        guard welcomeID == id, welcome.isPending else { return false }
        welcome.complete()
        welcomeID = nil
        return true
    }

    @discardableResult func deferWelcome(id: UUID) -> Bool {
        guard welcomeID == id, welcome.isPending else { return false }
        welcomeID = nil
        deferredForRun = true
        return true
    }

    func cancelWelcome(id: UUID? = nil) {
        guard id == nil || id == welcomeID else { return }
        welcomeID = nil
    }
}
