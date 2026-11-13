import Foundation

enum ProcessingPolicy: String, Codable, CaseIterable, Sendable {
    case standard, onDeviceOnly
}

enum ProcessingPolicyIssue: Error, LocalizedError, Equatable, Sendable {
    case onDeviceOnly, settingsChanged
    var errorDescription: String? {
        switch self {
        case .onDeviceOnly: return L10n.tr("Yullo works on this Mac only. API and CLI services are off.")
        case .settingsChanged: return L10n.tr("Processing settings changed. Start this action again.")
        }
    }
}

// Captured when an action starts, rather than when a queued service eventually
// runs. A later permission change never authorizes an older private action.
struct ProcessingAuthorization: Equatable, Sendable {
    fileprivate let policy: ProcessingPolicy
    fileprivate let restrictionGeneration: UInt64
    // A connection test sends only Yullo's fixed sample, never the person's text.
    fileprivate var fixedSample = false
}

// Settings commits are synchronous. This small lock serializes restriction,
// registration and authorization without an asynchronous update window. Only
// external processing is registered; public model/language downloads are owned
// separately and never receive user text or recordings.
final class ProcessingPolicyController: @unchecked Sendable {
    static let shared = ProcessingPolicyController()
    private let lock = NSLock()
    private var policy: ProcessingPolicy
    private var restrictionGeneration: UInt64 = 0
    private var requests: [UUID: @Sendable () -> Void] = [:]

    init(policy: ProcessingPolicy = .standard) { self.policy = policy }

    func authorization(for requestedPolicy: ProcessingPolicy) -> ProcessingAuthorization {
        lock.lock()
        defer { lock.unlock() }
        // A stale draft can still request standard processing after the live
        // policy became private. Capture the stricter policy so lifting it
        // later never authorizes an action that began while privacy was on.
        let effectivePolicy: ProcessingPolicy =
            requestedPolicy == .onDeviceOnly || policy == .onDeviceOnly ? .onDeviceOnly : .standard
        return .init(policy: effectivePolicy, restrictionGeneration: restrictionGeneration)
    }

    // A test the person starts in Settings sends Yullo's fixed sample once,
    // so it runs while Yullo works on this Mac only without changing the mode.
    func connectionTestAuthorization() -> ProcessingAuthorization {
        lock.lock()
        defer { lock.unlock() }
        return .init(policy: .standard, restrictionGeneration: restrictionGeneration, fixedSample: true)
    }

    func update(_ value: ProcessingPolicy) {
        lock.lock()
        let restrict = value == .onDeviceOnly && policy != .onDeviceOnly
        policy = value
        if restrict { restrictionGeneration &+= 1 }
        let cancellations = restrict ? Array(requests.values) : []
        lock.unlock()
        for cancel in cancellations { cancel() }
    }

    func requireExternal(_ authorization: ProcessingAuthorization) throws {
        lock.lock()
        defer { lock.unlock() }
        try requireExternalWhileLocked(authorization)
    }

    private func requireExternalWhileLocked(_ authorization: ProcessingAuthorization) throws {
        guard authorization.policy == .standard, policy == .standard || authorization.fixedSample else {
            throw ProcessingPolicyIssue.onDeviceOnly
        }
        guard authorization.restrictionGeneration == restrictionGeneration else {
            throw ProcessingPolicyIssue.settingsChanged
        }
    }

    private func register(_ authorization: ProcessingAuthorization, cancel: @escaping @Sendable () -> Void) throws
        -> UUID
    {
        lock.lock()
        defer { lock.unlock() }
        try requireExternalWhileLocked(authorization)
        let id = UUID()
        requests[id] = cancel
        return id
    }
    private func finish(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        requests.removeValue(forKey: id)
    }

    func performExternal<Value: Sendable>(
        authorization: ProcessingAuthorization, onThisMac: Bool = false,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        // A service on this Mac (Ollama on loopback) stays allowed under On-device only.
        if onThisMac { return try await operation() }
        // The worker cannot enter the provider until its cancellation handle is
        // registered. Restriction between registration and release cancels it.
        let start = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let worker = Task {
            for await _ in start.stream { break }
            try Task.checkCancellation()
            try self.requireExternal(authorization)
            let result = try await operation()
            try Task.checkCancellation()
            try self.requireExternal(authorization)
            return result
        }
        let id: UUID
        do { id = try register(authorization, cancel: { worker.cancel() }) } catch {
            worker.cancel()
            start.continuation.finish()
            throw error
        }
        defer { finish(id) }
        start.continuation.yield(())
        start.continuation.finish()
        return try await withTaskCancellationHandler {
            do { return try await worker.value } catch {
                try Task.checkCancellation()
                try requireExternal(authorization)
                throw error
            }
        } onCancel: {
            worker.cancel()
        }
    }

    @MainActor func performExternalAction<Value: Sendable>(
        authorization: ProcessingAuthorization,
        operation: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        try await performExternal(authorization: authorization) { try await operation() }
    }
}
