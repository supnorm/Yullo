import AppKit
import Combine
import ServiceManagement

// Service Management owns the setting. Keeping a second preference would drift
// when the user changes Login Items directly in System Settings.
protocol LoginItemBackend {
    func status() async -> SMAppService.Status
    func register() async throws
    func unregister() async throws
    @MainActor func openSettings()
}

private actor SystemLoginItem: LoginItemBackend {
    private let service = SMAppService.mainApp
    func status() -> SMAppService.Status { service.status }
    func register() throws { try service.register() }
    func unregister() async throws { try await service.unregister() }
    @MainActor func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var status: SMAppService.Status?
    @Published private(set) var isUpdating = false
    @Published private(set) var failure: String?
    private let backend: any LoginItemBackend
    private var revision: UInt64 = 0

    init(backend: any LoginItemBackend = SystemLoginItem()) { self.backend = backend }

    // Pending approval is registered, but the inline status makes clear that it
    // cannot launch yet. Switching it off still unregisters that pending item.
    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    // A service the system has never seen can report .notFound on first use.
    // Let an explicit enable request register it; registration provides the
    // actionable error if the bundle really cannot be registered.
    var canChange: Bool { status != nil && !isUpdating }

    func refresh() async {
        guard !isUpdating else { return }
        revision &+= 1
        let currentRevision = revision
        let current = await backend.status()
        guard currentRevision == revision, !isUpdating else { return }
        if status != current {
            status = current
            failure = nil
        }
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isUpdating else { return }
        revision &+= 1
        isUpdating = true
        failure = nil
        defer { isUpdating = false }
        let current = await backend.status()
        status = current
        let registered = current == .enabled || current == .requiresApproval
        guard enabled != registered else { return }
        do {
            if enabled { try await backend.register() } else { try await backend.unregister() }
            status = await backend.status()
        } catch {
            // Registration may report denied approval even though the item was
            // registered. Present the actionable pending state in that case.
            status = await backend.status()
            if enabled != isEnabled {
                failure = error.localizedDescription
            }
        }
    }

    func openSettings() { backend.openSettings() }
}

enum LoginLaunchPolicy {
    static func shouldStartQuietly(event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventClass == kCoreEventClass,
            event.eventID == kAEOpenApplication
        else { return false }
        // Documented launch Apple Event property; ordinary Finder/Dock launches
        // do not carry the login-item property and retain normal behavior.
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
