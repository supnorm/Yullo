import Foundation
import Combine
import Security

enum CredentialAccessService: String, CaseIterable, Sendable, Identifiable {
    case textAPI, azure, google, elevenLabs, speechAPI
    var id: String { rawValue }
    var titleKey: String {
        switch self {
        case .textAPI: return "API connection"
        case .azure: return "Azure Speech"
        case .google: return "Google Cloud Speech"
        case .elevenLabs: return "ElevenLabs"
        case .speechAPI: return "Speech API"
        }
    }
}

// Exact namespaces are private implementation data, never row labels, endpoint
// diagnostics or an instruction to enumerate the machine's Keychain.
struct CredentialAccessTarget: Equatable, Sendable {
    let service: CredentialAccessService
    fileprivate let account: String?
    fileprivate let invalidConfiguration: Bool
    // The service has a valid saved setup (its account is not shown outside this owner).
    var isConfigured: Bool { account != nil }
    init(service: CredentialAccessService, account: String?, invalidConfiguration: Bool = false) {
        self.service = service
        let valid =
            account.map {
                !$0.isEmpty && $0.utf8.count <= 8192
                    && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            } ?? false
        self.account = !invalidConfiguration && valid ? account : nil
        self.invalidConfiguration = invalidConfiguration || (account != nil && !valid)
    }
}

enum CredentialAccessReason: Equatable, Sendable {
    case permission, authorization, cancelled
}

enum CredentialAccessState: Equatable, Sendable {
    case notConfigured, invalidConfiguration, notChecked, checking, requestingAccess
    case available, noSavedKey, needsAccess(CredentialAccessReason), unavailable, unreadable

    var titleKey: String {
        switch self {
        case .notConfigured: return "Not set up"
        case .invalidConfiguration: return "Needs setup"
        case .notChecked: return "Not checked"
        case .checking: return "Checking…"
        case .requestingAccess: return "Waiting for access…"
        case .available: return "Allowed"
        case .noSavedKey: return "No saved key"
        case .needsAccess(.permission): return "Needs access"
        case .needsAccess(.authorization): return "Access not authorized"
        case .needsAccess(.cancelled): return "Access canceled"
        case .unavailable: return "Keychain unavailable"
        case .unreadable: return "Couldn’t read key"
        }
    }
    var detailKey: String? {
        switch self {
        case .available: return nil
        case .noSavedKey: return nil
        case .invalidConfiguration: return "Check this service’s URL or region."
        case .needsAccess(.permission): return "macOS didn’t allow access to the saved key."
        case .needsAccess(.authorization): return "macOS couldn’t authorize access to this key."
        case .needsAccess(.cancelled): return "The access request was canceled."
        case .unavailable: return "Keychain is busy or unavailable. Try again in a moment."
        case .unreadable: return "Review the saved key in this service’s settings."
        default: return nil
        }
    }
    var needsAccess: Bool {
        if case .needsAccess = self { return true }
        return false
    }
    var isWorking: Bool { self == .checking || self == .requestingAccess }
}

@MainActor
struct CredentialAccessBackend {
    var readAvailable: (String, Bool) async throws -> Bool
    var prepareInteractive: (String) -> Void = { _ in }

    static let system = CredentialAccessBackend(
        readAvailable: { account, interactive in
            !((try await KeyStore.readAsync(account, allowInteraction: interactive)).isEmpty)
        }, prepareInteractive: { KeyStore.retry($0) })
}

// A scoped UI lease spans the asynchronous authorization, including the gap
// before SecurityAgent appears. It does not request or inspect permissions.
@MainActor enum CredentialAccessInteraction {
    static let changed = Notification.Name("YulloCredentialAccessInteractionChanged")
    // Posted once when the person allows access, so the task that stopped for
    // the key can run again where they left it.
    static let allowed = Notification.Name("YulloCredentialAccessAllowed")
    private(set) static var depth = 0
    static var isActive: Bool { depth > 0 }
    static func begin() {
        depth += 1
        NotificationCenter.default.post(name: changed, object: true)
    }
    static func end() {
        depth = max(0, depth - 1)
        NotificationCenter.default.post(name: changed, object: isActive)
    }
}

// This controller observes no window/account history and holds no secret value.
// All physical reads, success caching, cooldowns and IPC deadlines stay in the
// existing serialized SavedKeyAccess owner.
@MainActor
final class CredentialAccessController: ObservableObject {
    private struct CheckResult: Sendable {
        let target: CredentialAccessTarget
        let state: CredentialAccessState
        let cancelled: Bool
    }
    struct Row: Equatable, Identifiable {
        let service: CredentialAccessService
        var state: CredentialAccessState
        var id: CredentialAccessService { service }
    }
    @Published private(set) var rows: [Row] = []
    @Published private(set) var isChecking = false
    @Published private(set) var isRequestingAccess = false
    @Published private(set) var isCoolingDown = false
    @Published private(set) var didCheck = false
    private let backend: CredentialAccessBackend
    private let cooldown: TimeInterval
    private var targets: [CredentialAccessTarget] = []
    private var operation: Task<Void, Never>?
    private var cooldownTask: Task<Void, Never>?
    private var revision = UUID()
    private var presented = false
    private var inspectionScope: Set<CredentialAccessService> = []
    private var inspectedTargets: [CredentialAccessService: CredentialAccessTarget] = [:]
    private var operationServices: Set<CredentialAccessService> = []

    init(backend: CredentialAccessBackend? = nil, cooldown: TimeInterval = 2) {
        self.backend = backend ?? .system
        self.cooldown = cooldown.isFinite ? min(10, max(0, cooldown)) : 2
    }
    deinit {
        operation?.cancel()
        cooldownTask?.cancel()
    }
    var isWorking: Bool { isChecking || isRequestingAccess }
    var canManage: Bool { presented && !isWorking }
    var canCheck: Bool {
        presented && !isWorking && !isCoolingDown
            && targets.contains { $0.account != nil }
    }
    func appear(
        targets: [CredentialAccessTarget], inspecting services: Set<CredentialAccessService> = []
    ) {
        if !presented { inspectedTargets.removeAll() }
        presented = true
        configure(targets, inspecting: services)
    }
    func configure(
        _ requested: [CredentialAccessTarget], inspecting services: Set<CredentialAccessService>? = nil
    ) {
        var seen = Set<CredentialAccessService>()
        let next = requested.filter { seen.insert($0.service).inserted }
        let nextScope = services ?? inspectionScope
        if next != targets {
            let previousTargets = Dictionary(uniqueKeysWithValues: targets.map { ($0.service, $0) })
            let previousStates = Dictionary(uniqueKeysWithValues: rows.map { ($0.service, $0.state) })
            cancel()
            targets = next
            didCheck = false
            rows = next.map { target in
                let previous = previousStates[target.service]
                let state = previousTargets[target.service] == target && previous?.isWorking == false ? previous : nil
                return Row(service: target.service, state: state ?? Self.initialState(target))
            }
        } else if nextScope != inspectionScope, !operationServices.isSubset(of: nextScope) {
            cancel()
        }
        inspectionScope = nextScope
        inspectCurrentServices()
    }
    // The view supplies only selected rows and explicitly expanded optional
    // rows. One inspection per current namespace/presentation prevents render,
    // cancellation and authorization failures from becoming automatic retries.
    func inspectVisibleServices(_ services: Set<CredentialAccessService>) {
        guard presented else { return }
        if services != inspectionScope, !operationServices.isSubset(of: services) { cancel() }
        inspectionScope = services
        inspectCurrentServices()
    }
    @discardableResult private func inspectCurrentServices() -> Bool {
        guard presented, !isWorking else { return false }
        let requested = targets.filter {
            inspectionScope.contains($0.service) && $0.account != nil && inspectedTargets[$0.service] != $0
        }
        guard !requested.isEmpty else { return false }
        beginCheck(requested)
        return true
    }
    func disappear() {
        presented = false
        cancel()
        inspectionScope.removeAll()
    }
    func cancel() {
        for target in targets where inspectionScope.contains(target.service) {
            inspectedTargets[target.service] = target
        }
        operationServices.removeAll()
        revision = UUID()
        operation?.cancel()
        operation = nil
        cooldownTask?.cancel()
        cooldownTask = nil
        isChecking = false
        isRequestingAccess = false
        isCoolingDown = false
        rows = rows.map { row in
            var value = row
            if value.state.isWorking { value.state = .notChecked }
            return value
        }
    }
    func check() {
        guard canCheck else { return }
        beginCheck(targets)
    }
    func canCheck(_ service: CredentialAccessService) -> Bool {
        presented && !isWorking && targets.contains { $0.service == service && $0.account != nil }
    }
    func check(_ service: CredentialAccessService) {
        guard canCheck(service) else { return }
        // The key owner already deduplicates physical reads and caches access.
        // Checking one row must not impose the batch button's cooldown on another.
        cooldownTask?.cancel()
        cooldownTask = nil
        isCoolingDown = false
        beginCheck(targets.filter { $0.service == service })
    }
    private func beginCheck(_ requested: [CredentialAccessTarget]) {
        let ticket = UUID()
        revision = ticket
        operationServices = Set(requested.map(\.service))
        for target in requested {
            inspectedTargets[target.service] = target
            if target.account != nil { set(.checking, for: target.service) }
        }
        isChecking = true
        didCheck = false
        let backend = backend
        operation = Task { @MainActor [weak self] in
            var completed = true
            // At most five known namespaces can enter this group. Their
            // logical deadlines overlap; SavedKeyAccess still owns the one
            // serialized physical Security reader and never permits UI here.
            await withTaskGroup(of: CheckResult.self) { group in
                for target in requested {
                    guard self?.current(ticket) == true else {
                        completed = false
                        group.cancelAll()
                        return
                    }
                    guard let account = target.account else { continue }
                    group.addTask { @MainActor [weak self] in
                        guard self?.current(ticket) == true else {
                            return CheckResult(target: target, state: .notChecked, cancelled: true)
                        }
                        let state: CredentialAccessState
                        do {
                            state = try await backend.readAvailable(account, false) ? .available : .noSavedKey
                        } catch is CancellationError {
                            return CheckResult(target: target, state: .notChecked, cancelled: true)
                        } catch { state = Self.state(for: error) }
                        return CheckResult(
                            target: target, state: Task.isCancelled ? .notChecked : state,
                            cancelled: Task.isCancelled)
                    }
                }
                for await result in group {
                    guard self?.current(ticket) == true, self?.targets.contains(result.target) == true else {
                        completed = false
                        group.cancelAll()
                        return
                    }
                    if result.cancelled { completed = false }
                    self?.set(result.state, for: result.target.service)
                }
            }
            self?.finish(ticket, completed: completed)
        }
    }
    // Only this explicit row action can permit a macOS authentication prompt.
    // It checks one current namespace, never every configured account at once.
    func allowAccess(for service: CredentialAccessService) {
        guard presented, !isWorking,
            rows.first(where: { $0.service == service })?.state.needsAccess == true,
            let target = targets.first(where: { $0.service == service }), let account = target.account
        else { return }
        cooldownTask?.cancel()
        cooldownTask = nil
        isCoolingDown = false
        let ticket = UUID()
        revision = ticket
        isRequestingAccess = true
        operationServices = [service]
        inspectedTargets[service] = target
        set(.requestingAccess, for: service)
        backend.prepareInteractive(account)
        let backend = backend
        CredentialAccessInteraction.begin()
        operation = Task { @MainActor [weak self] in
            defer { CredentialAccessInteraction.end() }
            guard self?.current(ticket) == true else { return }
            let state: CredentialAccessState
            do {
                state = try await backend.readAvailable(account, true) ? .available : .noSavedKey
            } catch is CancellationError {
                self?.finish(ticket, completed: false)
                return
            } catch { state = Self.state(for: error) }
            guard self?.current(ticket) == true, self?.targets.contains(target) == true else {
                self?.finish(ticket, completed: false)
                return
            }
            self?.set(state, for: service)
            self?.finish(ticket, completed: false)
        }
    }
    // An already-observed failure can be shown here without another read. The
    // caller must identify the exact current namespace, not merely a provider.
    func reportFailure(_ status: OSStatus, service: CredentialAccessService, account: String) {
        guard !isWorking,
            let target = targets.first(where: { $0.service == service && $0.account == account })
        else { return }
        inspectedTargets[service] = target
        set(Self.state(for: APIError.keychain(status)), for: service)
    }
    private func current(_ ticket: UUID) -> Bool { presented && revision == ticket && !Task.isCancelled }
    private func finish(_ ticket: UUID, completed: Bool) {
        // Cancellation rejects a result but still finishes its own progress;
        // a superseded namespace/presentation may never finish the newer one.
        guard presented, revision == ticket else { return }
        operation = nil
        operationServices.removeAll()
        isChecking = false
        isRequestingAccess = false
        rows = rows.map { row in
            var value = row
            if value.state.isWorking { value.state = .notChecked }
            return value
        }
        if completed && !Task.isCancelled { didCheck = true }
        if !Task.isCancelled, inspectCurrentServices() { return }
        guard cooldown > 0 else { return }
        isCoolingDown = true
        let delay = cooldown
        cooldownTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard let self, self.current(ticket) else { return }
            self.isCoolingDown = false
            self.cooldownTask = nil
        }
    }
    private func set(_ state: CredentialAccessState, for service: CredentialAccessService) {
        guard let index = rows.firstIndex(where: { $0.service == service }) else { return }
        rows[index].state = state
    }
    private static func initialState(_ target: CredentialAccessTarget) -> CredentialAccessState {
        target.invalidConfiguration ? .invalidConfiguration : target.account == nil ? .notConfigured : .notChecked
    }
    private static func state(for error: Error) -> CredentialAccessState {
        guard case APIError.keychain(let status) = error else { return .unreadable }
        switch status {
        case errSecInteractionNotAllowed, errSecInteractionRequired: return .needsAccess(.permission)
        case errSecAuthFailed: return .needsAccess(.authorization)
        case errSecUserCanceled: return .needsAccess(.cancelled)
        case errSecItemNotFound: return .noSavedKey
        case errSecNotAvailable, errSecInDarkWake: return .unavailable
        default: return .unreadable
        }
    }
}
