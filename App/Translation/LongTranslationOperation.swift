import Foundation

struct TranslationProgress: Sendable {
    let sequence: UInt64
    let text: String
    let completedJobs: Int
    let totalJobs: Int
}

struct TranslationRemoteOptions: Sendable {
    let useCache: Bool
    let progress: (@Sendable (APITextProgress) -> Void)?
}

// Only the typed local pre-generation admission failure may select a plan
// after an ordinary whole-source call. It must bypass automatic Apple fallback.
struct LongTranslationAdmission: Error, CoreFallbackError {
    var allowsAutomaticFallback: Bool { false }
}

// At most two API primaries can reach this per-operation fallback lane. A
// cancelled queued request waits for owned cleanup, then never enters Apple.
actor LongTranslationAppleLane {
    private var tail: Task<String, Error>?
    private var owner: UUID?
    private var failedJobs: [Int: Error] = [:]

    func run(job: Int, _ operation: @escaping @Sendable () async throws -> String) async throws -> String {
        try Task.checkCancellation()
        if let failure = failedJobs[job] { throw failure }
        let previous = tail
        let id = UUID()
        let work = Task {
            if let previous { _ = try? await previous.value }
            try Task.checkCancellation()
            return try await operation()
        }
        tail = work
        owner = id
        defer {
            if owner == id {
                tail = nil
                owner = nil
            }
        }
        do {
            return try await withTaskCancellationHandler {
                let text = try await work.value
                try Task.checkCancellation()
                return text
            } onCancel: {
                work.cancel()
            }
        } catch {
            // A failed cooldown probe is already this job's Apple outcome;
            // configured fallback must not invoke it a second time.
            failedJobs[job] = error
            throw error
        }
    }
}

// One bounded mailbox/consumer per translation, never a Task per provider
// delta. The caller still guards any queued UI work with its request identity.
final class LongTranslationProgressOwner: @unchecked Sendable {
    struct Ticket: Sendable {
        let job: Int
        let id: UUID
    }
    private struct Partial {
        let ticket: UUID
        var open = true
        var sequence: UInt64 = 0
        var text = ""
    }
    private let lock = NSRecursiveLock()
    private let maximumBytes: Int
    private let totalJobs: Int
    private let callback: @Sendable (TranslationProgress) -> Void
    private let wake: AsyncStream<Void>.Continuation
    private var consumer: Task<Void, Never>?
    private var open = true
    private var prefix = ""
    private var completedJobs = 0
    private var partials: [Int: Partial] = [:]
    private var revision: UInt64 = 0
    private var publishedRevision: UInt64 = 0
    private var sequence: UInt64 = 0

    init(totalJobs: Int, maximumBytes: Int, callback: @escaping @Sendable (TranslationProgress) -> Void) {
        self.totalJobs = totalJobs
        self.maximumBytes = maximumBytes
        self.callback = callback
        let channel = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wake = channel.continuation
        consumer = Task { [weak self] in
            var last: ContinuousClock.Instant?
            for await _ in channel.stream {
                do {
                    if let last {
                        try await Task.sleep(until: last.advanced(by: .milliseconds(100)), clock: .continuous)
                    }
                    try Task.checkCancellation()
                } catch { return }
                if self?.publish() == true { last = .now }
            }
        }
    }

    func begin(job: Int) -> Ticket? {
        lock.lock()
        defer { lock.unlock() }
        guard open, partials.count < 2, partials[job] == nil else { return nil }
        let ticket = Ticket(job: job, id: UUID())
        partials[job] = Partial(ticket: ticket.id)
        return ticket
    }

    func receive(_ value: APITextProgress, ticket: Ticket) {
        lock.lock()
        defer { lock.unlock() }
        guard open, !Task.isCancelled, var partial = partials[ticket.job], partial.open, partial.ticket == ticket.id,
            value.sequence > partial.sequence, value.text.utf8.prefix(maximumBytes + 1).count <= maximumBytes
        else { return }
        partial.sequence = value.sequence
        partial.text = value.text
        partials[ticket.job] = partial
        revision &+= 1
        wake.yield(())
    }

    func end(_ ticket: Ticket, discard: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        guard open, partials[ticket.job]?.ticket == ticket.id else { return }
        if !discard {
            partials[ticket.job]?.open = false
            return
        }
        partials.removeValue(forKey: ticket.job)
        revision &+= 1
        wake.yield(())
    }

    func update(_ value: CoreLongTranslationPlan.Progress, completedJob: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard open else { return }
        if let completedJob { partials.removeValue(forKey: completedJob) }
        prefix = value.text
        completedJobs = value.completedPrefixJobs
        revision &+= 1
        wake.yield(())
    }

    private func publish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard open, !Task.isCancelled, revision != publishedRevision else { return false }
        var text = prefix
        if let partial = partials[completedJobs]?.text, partial.utf8.count <= maximumBytes - prefix.utf8.count {
            text.append(partial)
        }
        publishedRevision = revision
        sequence &+= 1
        callback(.init(sequence: sequence, text: text, completedJobs: completedJobs, totalJobs: totalJobs))
        return true
    }

    func close() {
        lock.lock()
        open = false
        partials.removeAll()
        prefix = ""
        wake.finish()
        consumer?.cancel()
        lock.unlock()
    }

    func finish() async {
        close()
        await consumer?.value
    }

    var bufferedJobs: Int {
        lock.lock()
        defer { lock.unlock() }
        return partials.count
    }
}

// Mechanical long-text checks describe the failed operation, not a broken
// connection. The current source stays available for an explicit retry.
extension CoreLongTranslationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .sourceTooLarge, .tooManyJobs:
            return L10n.tr("This text is too long to translate at once. Use a shorter passage.")
        case .outputTooLarge:
            return L10n.tr("The translation is too long. Use a shorter passage.")
        case .protectedLiteralChanged:
            return L10n.tr("A link or code changed in the translation. Try again.")
        case .emptyTranslation:
            return L10n.tr("The model returned no translated text.")
        default:
            return L10n.tr("Couldn’t finish the translation. Try again.")
        }
    }
}
