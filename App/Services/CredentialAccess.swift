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

// Where a saved key is fixed: its service's editor in Settings › Services.
// `allow` also starts Allow access there, for a fix pressed where a task stopped.
struct SavedKeyAnchor: Equatable {
    let service: CredentialAccessService
    let allow: Bool
    var rawValue: String { (allow ? "allow-key-" : "key-") + service.rawValue }
    init(service: CredentialAccessService, allow: Bool) {
        self.service = service
        self.allow = allow
    }
    init?(rawValue: String) {
        let allow = rawValue.hasPrefix("allow-key-")
        guard allow || rawValue.hasPrefix("key-"),
            let service = CredentialAccessService(rawValue: String(rawValue.dropFirst(allow ? 10 : 4)))
        else { return nil }
        self.init(service: service, allow: allow)
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
    // Keys the person allowed through this controller, for as long as they stay the same keys.
    @Published private(set) var allowed: Set<CredentialAccessService> = []
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
    // A macOS prompt can't be withdrawn. Yullo's Cancel stops waiting for it;
    // the prompt's own answer still lands here, and pressing Allow access
    // again waits for the same prompt instead of asking twice.
    private struct Prompt {
        let id = UUID()
        let target: CredentialAccessTarget
        let before: CredentialAccessState
    }
    private var prompt: Prompt?

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
            && targets.contains { $0.account != nil && $0 != prompt?.target }
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
            allowed = allowed.filter { service in
                targets.first { $0.service == service } == next.first { $0.service == service }
            }
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
                && $0 != prompt?.target
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
            if value.state == .requestingAccess, let prompt, prompt.target.service == row.service {
                value.state = prompt.before
            } else if value.state.isWorking {
                value.state = .notChecked
            }
            return value
        }
    }
    func check() {
        guard canCheck else { return }
        beginCheck(targets.filter { $0 != prompt?.target })
    }
    func canCheck(_ service: CredentialAccessService) -> Bool {
        presented && !isWorking
            && targets.contains { $0.service == service && $0.account != nil && $0 != prompt?.target }
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
        guard presented, !isRequestingAccess,
            let state = rows.first(where: { $0.service == service })?.state, state.needsAccess,
            let target = targets.first(where: { $0.service == service }), let account = target.account
        else { return }
        // The person's press wins over a silent check still running.
        if isChecking { cancel() }
        cooldownTask?.cancel()
        cooldownTask = nil
        isCoolingDown = false
        revision = UUID()
        isRequestingAccess = true
        operationServices = [service]
        inspectedTargets[service] = target
        set(.requestingAccess, for: service)
        // The macOS prompt from an earlier press is still up: wait for its answer.
        if prompt?.target == target { return }
        let current = Prompt(target: target, before: state)
        prompt = current
        backend.prepareInteractive(account)
        let backend = backend
        CredentialAccessInteraction.begin()
        // Not `operation`: Cancel must not end the read while macOS still shows its prompt.
        Task { @MainActor [weak self] in
            defer { CredentialAccessInteraction.end() }
            // Canceled before macOS was asked: nothing to wait for.
            guard self?.isWaiting(for: service) == true else {
                self?.answered(current, current.before)
                return
            }
            let answer: CredentialAccessState
            do {
                answer = try await backend.readAvailable(account, true) ? .available : .noSavedKey
            } catch is CancellationError {
                answer = current.before
            } catch { answer = Self.state(for: error) }
            self?.answered(current, answer)
        }
    }
    private func isWaiting(for service: CredentialAccessService) -> Bool {
        presented && isRequestingAccess && operationServices == [service]
    }
    private func answered(_ answered: Prompt, _ answer: CredentialAccessState) {
        guard prompt?.id == answered.id else { return }
        prompt = nil
        let service = answered.target.service
        let waiting = isWaiting(for: service)
        if targets.contains(answered.target) {
            switch answer {
            case .available, .noSavedKey, .needsAccess: set(answer, for: service)
            // Nobody is waiting any more: a prompt that ended without an answer isn't an error to show.
            default: set(waiting ? answer : answered.before, for: service)
            }
        }
        if waiting { finish(revision, completed: false) }
        // Wherever access was allowed, the task that stopped for the key can run again.
        if answer == .available {
            if targets.contains(answered.target) { allowed.insert(service) }
            NotificationCenter.default.post(name: CredentialAccessInteraction.allowed, object: nil)
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
