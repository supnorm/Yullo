import Foundation
import Security
import LocalAuthentication

struct KeyStore {
    private static let interactionLock = NSLock()
    private static var interactions = 0
    private static var interactionEnded = -TimeInterval.infinity
    static var isAuthorizing: Bool {
        interactionLock.lock()
        defer { interactionLock.unlock() }
        return interactions > 0 || ProcessInfo.processInfo.systemUptime - interactionEnded < 0.5
    }
    private static func beginAccess() {
        interactionLock.lock()
        interactions += 1
        interactionLock.unlock()
    }
    private static func endAccess() {
        interactionLock.lock()
        interactions -= 1
        interactionEnded = ProcessInfo.processInfo.systemUptime
        interactionLock.unlock()
    }
    private static let access = SavedKeyAccess(
        read: readSaved, write: writeSaved, remove: removeSaved,
        interactionChanged: { active in if active { beginAccess() } else { endAccess() } })
    private static let legacy = LegacyKeychainRead(
        get: {
            var allowed: DarwinBoolean = false
            let status = YulloGetKeychainInteraction(&allowed)
            guard status == errSecSuccess else { throw APIError.keychain(status) }
            return allowed.boolValue
        },
        set: { allowed in
            let status = YulloSetKeychainInteraction(allowed)
            guard status == errSecSuccess else { throw APIError.keychain(status) }
        })

    static func retry(_ endpoint: String) { access.retry(endpoint) }
    static func query(_ endpoint: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.yullo.api",
            kSecAttrAccount as String: endpoint
        ]
    }
    static func readQuery(_ endpoint: String, allowInteraction: Bool) -> [String: Any] {
        var query = query(endpoint)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // The current SDK replacement for the deprecated authentication-UI
        // constants. This context is never evaluated directly or reused.
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        query[kSecUseAuthenticationContext as String] = context
        return query
    }
    static func readAsync(_ endpoint: String, allowInteraction: Bool = false) async throws -> String {
        try await access.read(endpoint, allowInteraction: allowInteraction)
    }
    static func write(_ key: String, endpoint: String) throws { try access.write(key, account: endpoint) }
    static func remove(_ endpoint: String) throws { try access.remove(endpoint) }
    private static func readSaved(_ endpoint: String, _ allowInteraction: Bool) throws -> String {
        let query = readQuery(endpoint, allowInteraction: allowInteraction)
        defer { (query[kSecUseAuthenticationContext as String] as? LAContext)?.invalidate() }
        return try legacy.perform(
            allowInteraction: allowInteraction,
            read: {
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                if status == errSecItemNotFound { return "" }
                guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8)
                else { throw APIError.keychain(status) }
                return key
            })
    }
    private static func writeSaved(_ key: String, _ endpoint: String) throws {
        try legacy.recover()
        beginAccess()
        defer { endAccess() }
        let query = query(endpoint)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(key.utf8)] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(key.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw APIError.keychain(status) }
    }
    private static func removeSaved(_ endpoint: String) throws {
        try legacy.recover()
        beginAccess()
        defer { endAccess() }
        let status = SecItemDelete(query(endpoint) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw APIError.keychain(status) }
    }
}

// Runs only within the coordinator's one physical read. The process-wide
// legacy UI policy stays disabled until synchronous IPC actually returns, even
// when its logical callers have already cancelled or reached their deadline.
final class LegacyKeychainRead {
    private let get: () throws -> Bool
    private let set: (Bool) throws -> Void
    private var restorationTarget: Bool?
    init(get: @escaping () throws -> Bool, set: @escaping (Bool) throws -> Void) {
        self.get = get
        self.set = set
    }
    // Called only by SavedKeyAccess's serialized physical-read/mutation gate.
    // Keep the intended value after a failed restore; never adopt our leftover
    // disabled policy as a new baseline. Every subsequent effect repairs first.
    func recover() throws {
        guard let target = restorationTarget else { return }
        do {
            try set(target)
            restorationTarget = nil
        } catch { throw APIError.keychain(errSecNotAvailable) }
    }
    func perform(allowInteraction: Bool, read: () throws -> String) throws -> String {
        try recover()
        guard !allowInteraction else { return try read() }
        let previous = try get()
        guard previous else { return try read() }
        restorationTarget = previous
        do { try set(false) } catch {
            try recover()
            throw error
        }
        var restorationError: Error?
        func scopedRead() -> Result<String, Error> {
            defer { do { try recover() } catch { restorationError = error } }
            return Result { try read() }
        }
        let result = scopedRead()
        if let restorationError { throw restorationError }
        return try result.get()
    }
}

// Security IPC cannot be forcibly cancelled. Keep at most one physical reader;
// logical readers have independent cancellation and bounded deadlines. A hung
// OS call cannot consume a new blocked thread on every subsequent retry.
final class SavedKeyAccess: @unchecked Sendable {
    private struct Scope: Hashable {
        let account: String
        let interactive: Bool
    }
    private final class Flight {
        let id = UUID()
        let scope: Scope
        let generation: UInt64
        var waiters: [UUID: CheckedContinuation<String, Error>] = [:]
        var deadline: DispatchWorkItem?
        init(_ scope: Scope, generation: UInt64) {
            self.scope = scope
            self.generation = generation
        }
    }
    private struct Read {
        let id: UUID
        let scope: Scope
        let generation: UInt64
    }
    private struct CachedRead {
        let result: Result<String, Error>
        // Failed and absent reads expire. A saved key stays in memory so normal
        // translation never needs another authorization in this process.
        let retryAt: TimeInterval?
    }
    private typealias Completion = (CheckedContinuation<String, Error>, Result<String, Error>)
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "yullo.saved-key-read", qos: .userInitiated)
    private let readSaved: (String, Bool) throws -> String
    private let writeSaved: (String, String) throws -> Void
    private let removeSaved: (String) throws -> Void
    private let timeout: TimeInterval
    private let interactiveTimeout: TimeInterval
    private let failureCooldown: TimeInterval
    private let now: () -> TimeInterval
    private let interactionChanged: (Bool) -> Void
    private var cached: [String: CachedRead] = [:]
    private var generations: [String: UInt64] = [:]
    private var flights: [UUID: Flight] = [:]
    private var scopes: [Scope: UUID] = [:]
    private var waiterFlights: [UUID: UUID] = [:]
    private var pending: [UUID] = []
    private var active: Read?
    private var mutating = false

    init(
        timeout: TimeInterval = 3, interactiveTimeout: TimeInterval = 30,
        failureCooldown: TimeInterval = 2, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        read: @escaping (String, Bool) throws -> String,
        write: @escaping (String, String) throws -> Void, remove: @escaping (String) throws -> Void,
        interactionChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.timeout = timeout.isFinite ? max(0.01, timeout) : 3
        self.interactiveTimeout = interactiveTimeout.isFinite ? max(0.01, interactiveTimeout) : 30
        self.failureCooldown = failureCooldown.isFinite ? max(0, failureCooldown) : 2
        self.now = now
        readSaved = read
        writeSaved = write
        removeSaved = remove
        self.interactionChanged = interactionChanged
    }
    func read(_ account: String, allowInteraction: Bool = false) async throws -> String {
        try Task.checkCancellation()
        let waiter = UUID(), cancellation = SavedKeyCancellation()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(
                    .init(account: account, interactive: allowInteraction), waiter: waiter,
                    cancellation: cancellation, continuation: continuation)
            }
        } onCancel: {
            cancellation.cancel()
            self.cancel(waiter)
        }
        try Task.checkCancellation()
        return result
    }
    func retry(_ account: String) {
        lock.lock()
        generations[account, default: 0] &+= 1
        if let value = cached[account], value.retryAt != nil { cached.removeValue(forKey: account) }
        let completions = retireAccount(account, result: .failure(CancellationError()))
        let next = nextRead()
        lock.unlock()
        resolve(completions)
        launch(next)
    }
    func write(_ key: String, account: String) throws {
        try mutate(account) {
            try writeSaved(key, account)
            return key
        }
    }
    func remove(_ account: String) throws {
        try mutate(account) {
            try removeSaved(account)
            return ""
        }
    }
    private func mutate(_ account: String, _ body: () throws -> String) throws {
        lock.lock()
        // Never block a native settings commit behind unresolved read IPC or
        // another mutation. The caller retains its unsaved settings draft.
        guard active == nil, !mutating else {
            lock.unlock()
            throw APIError.keychain(errSecNotAvailable)
        }
        let previousSuccess = cached[account].flatMap { value -> CachedRead? in
            if case .success = value.result { return value }
            return nil
        }
        mutating = true
        generations[account, default: 0] &+= 1
        cached.removeValue(forKey: account)
        let generation = generations[account, default: 0]
        let abandoned = retireAccount(account, result: .failure(CancellationError()))
        lock.unlock()
        resolve(abandoned)
        let result = Result { try body() }
        lock.lock()
        mutating = false
        let completions: [Completion]
        if generations[account, default: 0] == generation {
            if case .failure = result, let previousSuccess {
                cached[account] = previousSuccess
                completions = retireAccount(account, result: previousSuccess.result)
            } else {
                cache(result, account: account)
                completions = retireAccount(account, result: result)
            }
        } else {
            completions = []
        }
        let next = nextRead()
        lock.unlock()
        resolve(completions)
        launch(next)
        _ = try result.get()
    }
    private func enqueue(
        _ scope: Scope, waiter: UUID, cancellation: SavedKeyCancellation,
        continuation: CheckedContinuation<String, Error>
    ) {
        lock.lock()
        if cancellation.isCancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        if let value = cached[scope.account] {
            if case .success(let key) = value.result, !key.isEmpty {
                lock.unlock()
                continuation.resume(with: value.result)
                return
            }
            if !scope.interactive, let retryAt = value.retryAt, now() < retryAt {
                lock.unlock()
                continuation.resume(with: value.result)
                return
            }
            cached.removeValue(forKey: scope.account)
        }
        guard waiterFlights.count < 256, flights.count < 64 || scopes[scope] != nil else {
            lock.unlock()
            continuation.resume(throwing: APIError.keychain(errSecNotAvailable))
            return
        }
        let flight: Flight
        if let id = scopes[scope], let existing = flights[id] {
            flight = existing
        } else {
            flight = Flight(scope, generation: generations[scope.account, default: 0])
            flights[flight.id] = flight
            scopes[scope] = flight.id
            pending.append(flight.id)
            if scope.interactive { interactionChanged(true) }
            let id = flight.id
            let deadline = DispatchWorkItem { [weak self] in self?.expire(id) }
            flight.deadline = deadline
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + (scope.interactive ? interactiveTimeout : timeout), execute: deadline)
        }
        flight.waiters[waiter] = continuation
        waiterFlights[waiter] = flight.id
        let next = nextRead()
        lock.unlock()
        launch(next)
    }
    private func cancel(_ waiter: UUID) {
        lock.lock()
        guard let id = waiterFlights.removeValue(forKey: waiter), let flight = flights[id],
            let continuation = flight.waiters.removeValue(forKey: waiter)
        else {
            lock.unlock()
            return
        }
        if flight.waiters.isEmpty { _ = retire(id, result: .failure(CancellationError())) }
        let next = nextRead()
        lock.unlock()
        continuation.resume(throwing: CancellationError())
        launch(next)
    }
    private func expire(_ id: UUID) {
        lock.lock()
        guard let flight = flights[id] else {
            lock.unlock()
            return
        }
        let error = APIError.keychain(errSecNotAvailable)
        if generations[flight.scope.account, default: 0] == flight.generation {
            cache(.failure(error), account: flight.scope.account)
        }
        let completions = retire(id, result: .failure(error))
        let next = nextRead()
        lock.unlock()
        resolve(completions)
        launch(next)
    }
    // Helpers below require the lock. Continuations and OS calls run outside it.
    private func cache(_ result: Result<String, Error>, account: String) {
        switch result {
        case .success(let key):
            cached[account] = CachedRead(result: result, retryAt: key.isEmpty ? now() + failureCooldown : nil)
        case .failure(let error):
            if error is CancellationError { return }
            // A cancelled or failed sibling must not evict a usable saved key.
            if case .success? = cached[account]?.result { return }
            cached[account] = CachedRead(result: result, retryAt: now() + failureCooldown)
        }
    }
    private func retire(_ id: UUID, result: Result<String, Error>) -> [Completion] {
        guard let flight = flights.removeValue(forKey: id) else { return [] }
        flight.deadline?.cancel()
        scopes.removeValue(forKey: flight.scope)
        pending.removeAll { $0 == id }
        if flight.scope.interactive { interactionChanged(false) }
        return flight.waiters.map { waiter, continuation -> Completion in
            waiterFlights.removeValue(forKey: waiter)
            return (continuation, result)
        }
    }
    private func retireAccount(_ account: String, result: Result<String, Error>) -> [Completion] {
        flights.values.filter { $0.scope.account == account }.map(\.id).flatMap { retire($0, result: result) }
    }
    private func nextRead() -> Read? {
        guard active == nil, !mutating else { return nil }
        while !pending.isEmpty {
            guard let flight = flights[pending.removeFirst()] else { continue }
            let next = Read(id: flight.id, scope: flight.scope, generation: flight.generation)
            active = next
            return next
        }
        return nil
    }
    private func launch(_ read: Read?) {
        guard let read else { return }
        worker.async { [self] in
            lock.lock()
            let current = flights[read.id] != nil
            lock.unlock()
            let result: Result<String, Error> =
                current
                ? Result { try readSaved(read.scope.account, read.scope.interactive) } : .failure(CancellationError())
            lock.lock()
            active = nil
            var completions: [Completion] = []
            if generations[read.scope.account, default: 0] == read.generation {
                if case .success = result {
                    // Security may finish after its logical caller timed out or
                    // cancelled. Warm only this unchanged account generation;
                    // retired continuations and UI requests are never revived.
                    cache(result, account: read.scope.account)
                    completions = retireAccount(read.scope.account, result: result)
                } else if flights[read.id] != nil {
                    cache(result, account: read.scope.account)
                    completions = retire(read.id, result: result)
                }
            }
            let next = nextRead()
            lock.unlock()
            resolve(completions)
            launch(next)
        }
    }
    private func resolve(_ completions: [Completion]) {
        for (continuation, result) in completions { continuation.resume(with: result) }
    }
}

private final class SavedKeyCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
