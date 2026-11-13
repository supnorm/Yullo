import Foundation

/// Counts a pause after speech activity, using monotonic time. Audio level alone
/// is never accepted as a speech decision. The capture's classifier supplies it.
@MainActor
final class RecordingSilenceMonitor {
    typealias CancelScheduled = () -> Void
    typealias Schedule = (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> CancelScheduled
    private let now: () -> TimeInterval
    private let schedule: Schedule
    private var cancelScheduled: CancelScheduled?
    private var generation: UInt64 = 0
    private var silenceBegan: TimeInterval?
    private var completion: (() -> Void)?
    private(set) var isRunning = false
    private(set) var autoFinish = true
    private(set) var seconds: TimeInterval = 3
    private(set) var hasSpeech = false
    private(set) var speechIsActive = false
    private(set) var isPaused = false

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }, schedule: Schedule? = nil) {
        self.now = now
        self.schedule =
            schedule ?? { delay, action in
                let timer = Timer(timeInterval: max(0.001, delay), repeats: false) { _ in
                    // Run-loop timers can precede speech already queued on the
                    // main actor. Enqueue the deadline check beside that speech;
                    // its generation guard still rejects cancelled deadlines.
                    Task { @MainActor in action() }
                }
                RunLoop.main.add(timer, forMode: .common)
                return { timer.invalidate() }
            }
    }

    var remainingSeconds: TimeInterval? {
        guard isRunning, !isPaused, autoFinish, hasSpeech, !speechIsActive, let silenceBegan else { return nil }
        return max(0, seconds - max(0, now() - silenceBegan))
    }

    func start(autoFinish: Bool = true, seconds: TimeInterval = 3, onFinish: @escaping () -> Void) {
        stop()
        self.autoFinish = autoFinish
        self.seconds = seconds.isFinite ? min(10, max(1, seconds)) : 3
        completion = onFinish
        isRunning = true
    }

    func observeSpeech(_ active: Bool) {
        guard isRunning else { return }
        if active {
            hasSpeech = true
            speechIsActive = true
            silenceBegan = nil
            clearTimer()
        } else if speechIsActive {
            speechIsActive = false
            silenceBegan = now()
            if autoFinish && !isPaused { arm(after: seconds) }
        }
        // Repeated false frames do not postpone the original pause deadline.
    }

    func stop() {
        clearTimer()
        isRunning = false
        hasSpeech = false
        speechIsActive = false
        silenceBegan = nil
        completion = nil
        isPaused = false
    }

    func pause() {
        guard isRunning, !isPaused else { return }
        isPaused = true
        silenceBegan = nil
        clearTimer()
    }

    // The user's menu interaction is not a speech pause. Start a fresh full
    // deadline after dismissing it, retaining actual speech activity meanwhile.
    func resumeAfterInteraction() {
        guard isRunning, isPaused else { return }
        isPaused = false
        if hasSpeech, !speechIsActive {
            silenceBegan = now()
            if autoFinish { arm(after: seconds) }
        }
    }

    private func clearTimer() {
        generation &+= 1
        cancelScheduled?()
        cancelScheduled = nil
    }

    private func arm(after delay: TimeInterval) {
        clearTimer()
        let expected = generation
        cancelScheduled = schedule(delay) { [weak self] in
            guard let self, self.generation == expected, let remaining = self.remainingSeconds else { return }
            self.cancelScheduled = nil
            if remaining > 0 {
                self.arm(after: remaining)
                return
            }
            let action = self.completion
            self.stop()
            action?()
        }
    }
}
