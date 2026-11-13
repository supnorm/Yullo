import Foundation

// A finalized result is retained only after an explicit settings opt-in. This
// owner never stores audio, destinations, credentials or processing settings.
@MainActor
final class RecentVoiceResultStore {
    enum Output: Equatable, Sendable {
        case original
        case translation(languageID: String)
        case refinement(style: RewriteStyle)
        case voiceEdit
    }

    enum DeliveryOutcome: Equatable, Sendable { case inserted, notInserted, uncertain }
    // Presentation metadata only; no saved connection, credentials or write authority.
    enum Recovery: Equatable, Sendable { case appleForAPIKeyAccess, partlyAppleForAPIKeyAccess }

    struct Snapshot: Equatable, Sendable {
        let id: UUID
        let originalTranscript: String
        let finalText: String
        let output: Output
        let deliveryOutcome: DeliveryOutcome
        let processingTranscript: String?
        let recovery: Recovery?

        init(
            id: UUID, originalTranscript: String, finalText: String, output: Output,
            deliveryOutcome: DeliveryOutcome, processingTranscript: String? = nil, recovery: Recovery? = nil
        ) {
            self.id = id
            self.originalTranscript = originalTranscript
            self.finalText = finalText
            self.output = output
            self.deliveryOutcome = deliveryOutcome
            self.processingTranscript = processingTranscript
            self.recovery = recovery
        }
    }

    struct Value: Equatable, Sendable {
        let snapshot: Snapshot
        // Presentation only. A wall-clock adjustment cannot change retention.
        let retainedAt: Date
    }

    // Settings can describe the retained result without obtaining its text.
    // Remaining lifetime is sampled from the same continuous clock as expiry.
    struct Metadata: Equatable, Sendable {
        let retainedAt: Date
        let remainingSeconds: TimeInterval
        let output: Output
        let deliveryOutcome: DeliveryOutcome
    }

    typealias CancelScheduled = () -> Void
    typealias Schedule = (_ deadline: Duration, _ action: @escaping @MainActor () -> Void) -> CancelScheduled

    static let maximumTextBytes = 262_144
    var onChange: (() -> Void)?

    private struct Entry {
        let value: Value
        let created: Duration
        let expires: Duration
    }

    private let now: () -> Duration
    private let wallNow: () -> Date
    private let schedule: Schedule
    private var enabled = false
    private var durationSeconds: TimeInterval = 300
    private var entry: Entry?
    private var cancelScheduled: CancelScheduled?
    private var expirationGeneration = UUID()

    convenience init() {
        let clock = ContinuousClock()
        let origin = clock.now
        self.init(
            now: { origin.duration(to: clock.now) },
            schedule: { deadline, action in
                let task = Task { @MainActor in
                    do {
                        try await clock.sleep(until: origin.advanced(by: deadline), tolerance: .zero)
                    } catch { return }
                    guard !Task.isCancelled else { return }
                    action()
                }
                return { task.cancel() }
            })
    }

    init(
        now: @escaping () -> Duration, schedule: @escaping Schedule,
        wallNow: @escaping () -> Date = Date.init
    ) {
        self.now = now
        self.schedule = schedule
        self.wallNow = wallNow
    }

    deinit { cancelScheduled?() }

    var hasValue: Bool {
        expireIfNeeded()
        return entry != nil
    }

    // Longer settings apply to future results. A current result can only keep
    // or shorten its original deadline, never gain lifetime from reconfiguration.
    func configure(enabled requested: Bool, durationSeconds requestedSeconds: TimeInterval) {
        let nextEnabled = requested && requestedSeconds.isFinite
        let nextSeconds = Self.normalizedDuration(requestedSeconds)
        let settingsChanged = enabled != nextEnabled || durationSeconds != nextSeconds
        enabled = nextEnabled
        durationSeconds = nextSeconds
        var changed = settingsChanged
        if !enabled {
            changed = discardEntry() || changed
        } else if let current = entry {
            let deadline = min(current.expires, current.created + .seconds(nextSeconds))
            if now() >= deadline {
                changed = discardEntry() || changed
            } else if deadline != current.expires {
                entry = Entry(value: current.value, created: current.created, expires: deadline)
                armExpiration()
                changed = true
            }
        }
        if changed { onChange?() }
    }

    // The caller must supply a current, accepted FINAL result, never live words.
    // Repeated delivery receipts use updateDeliveryOutcome so a late receipt
    // cannot recreate text after clear, expiry or replacement by another result.
    @discardableResult
    func remember(_ snapshot: Snapshot) -> Bool {
        expireIfNeeded()
        guard enabled, Self.valid(snapshot) else { return false }
        if let current = entry, current.value.snapshot.id == snapshot.id {
            let previous = current.value.snapshot
            guard previous.originalTranscript.utf16.elementsEqual(snapshot.originalTranscript.utf16),
                previous.finalText.utf16.elementsEqual(snapshot.finalText.utf16), previous.output == snapshot.output,
                previous.recovery == snapshot.recovery,
                (previous.processingTranscript ?? previous.originalTranscript).utf16.elementsEqual(
                    (snapshot.processingTranscript ?? snapshot.originalTranscript).utf16)
            else { return false }
            return updateDeliveryOutcome(snapshot.deliveryOutcome, for: snapshot.id)
        }
        let created = now()
        entry = Entry(
            value: Value(snapshot: snapshot, retainedAt: wallNow()), created: created,
            expires: created + .seconds(durationSeconds))
        armExpiration()
        onChange?()
        return true
    }

    // Reading does not consume or extend the result. Restoring this value grants
    // no authority to transform it or write it to any external destination.
    func read() -> Value? {
        expireIfNeeded()
        return entry?.value
    }

    func metadata() -> Metadata? {
        let instant = now()
        guard let current = entry else { return nil }
        guard instant < current.expires else {
            clear()
            return nil
        }
        let remaining = (current.expires - instant).components
        let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
        return Metadata(
            retainedAt: current.value.retainedAt, remainingSeconds: max(0, seconds),
            output: current.value.snapshot.output, deliveryOutcome: current.value.snapshot.deliveryOutcome)
    }

    @discardableResult
    func updateDeliveryOutcome(_ outcome: DeliveryOutcome, for id: UUID) -> Bool {
        expireIfNeeded()
        guard let current = entry, current.value.snapshot.id == id else { return false }
        let previous = current.value.snapshot
        guard outcome != previous.deliveryOutcome else { return true }
        let snapshot = Snapshot(
            id: previous.id, originalTranscript: previous.originalTranscript, finalText: previous.finalText,
            output: previous.output, deliveryOutcome: outcome, processingTranscript: previous.processingTranscript,
            recovery: previous.recovery)
        entry = Entry(
            value: Value(snapshot: snapshot, retainedAt: current.value.retainedAt), created: current.created,
            expires: current.expires)
        onChange?()
        return true
    }

    // Quit uses the same operation. Clearing releases this owner's references;
    // it is not a promise of physical RAM erasure or removal of caller copies.
    func clear() {
        if discardEntry() { onChange?() }
    }

    private func expireIfNeeded() {
        if let current = entry, now() >= current.expires { clear() }
    }

    private func discardEntry() -> Bool {
        expirationGeneration = UUID()
        cancelScheduled?()
        cancelScheduled = nil
        let hadValue = entry != nil
        entry = nil
        return hadValue
    }

    private func armExpiration() {
        cancelScheduled?()
        cancelScheduled = nil
        expirationGeneration = UUID()
        guard let current = entry else { return }
        let id = current.value.snapshot.id
        let generation = expirationGeneration
        // The timer owns only identities and a weak store, never the transcript.
        cancelScheduled = schedule(current.expires) { [weak self] in
            guard let self, self.expirationGeneration == generation, self.entry?.value.snapshot.id == id else {
                return
            }
            self.cancelScheduled = nil
            if let current = self.entry, self.now() < current.expires {
                self.armExpiration()
            } else {
                self.clear()
            }
        }
    }

    private static func normalizedDuration(_ value: TimeInterval) -> TimeInterval {
        value.isFinite ? min(86_400, max(60, value)) : 300
    }

    private static func valid(_ snapshot: Snapshot) -> Bool {
        if snapshot.recovery != nil {
            guard case .translation = snapshot.output else { return false }
        }
        for text in [snapshot.originalTranscript, snapshot.finalText]
            + [snapshot.processingTranscript].compactMap({ $0 })
        {
            guard text.utf8.count <= maximumTextBytes,
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return false }
        }
        if case .translation(let languageID) = snapshot.output {
            guard languageID.utf8.count <= 63 else { return false }
            let parts = languageID.split(separator: "-", omittingEmptySubsequences: false)
            guard let first = parts.first, (2...8).contains(first.utf8.count),
                first.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
                parts.dropFirst().allSatisfy({ part in
                    (1...8).contains(part.utf8.count)
                        && part.utf8.allSatisfy {
                            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                        }
                })
            else { return false }
        }
        return true
    }
}
