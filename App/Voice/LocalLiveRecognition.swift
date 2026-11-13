import AVFoundation
import Foundation

struct LocalLiveRecognitionProvider: Sendable {
    let library: ModelLibrary
    let helperURL: URL
    let host: LocalLiveRecognitionHost
    init(library: ModelLibrary = .shared, helperURL: URL? = nil, host: LocalLiveRecognitionHost? = nil) {
        self.library = library
        self.helperURL = helperURL ?? RuntimeHelper.url(.liveTranscribe)
        self.host = host ?? LocalLiveRecognitionHost()
    }
    // Waits until the helper has loaded the model and accepted this recording.
    func start(
        settings: VoiceRecognitionSettings, onTranscript: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) async throws -> any VoiceLiveRecognizing {
        let session = try await begin(settings: settings, onTranscript: onTranscript, onFailure: onFailure)
        do {
            try await session.waitUntilReady()
            try Task.checkCancellation()
            return session
        } catch {
            await session.cancel()
            throw error
        }
    }
    // Starts one recording on a warm or newly launched helper without waiting
    // for the model. `finish` waits for readiness itself. A nil transcript
    // callback recognizes only the finished WAV, with no preview text.
    func begin(
        settings: VoiceRecognitionSettings, onTranscript: (@Sendable (String) -> Void)?,
        onFailure: @escaping @Sendable (Error) -> Void
    ) async throws -> LocalLiveRecognitionSession {
        try Task.checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw LiveRecognitionIssue.unavailable
        }
        guard try await library.runtime(id: settings.modelID) == .transcribe else {
            throw LiveRecognitionIssue.unsupported
        }
        let model = try await library.acquireModel(id: settings.modelID)
        do {
            try Task.checkCancellation()
            let language = try Self.language(model: model, settings: settings)
            guard let identity = Self.identity(model: model, language: language) else {
                throw LiveRecognitionIssue.unavailable
            }
            let helper = try await host.checkout(identity: identity) {
                try LocalLiveRecognitionHelper.launch(
                    identity: identity, executable: helperURL, model: model, language: language)
            }
            let session = LocalLiveRecognitionSession(
                helper: helper, host: host, library: library, modelID: settings.modelID,
                onTranscript: onTranscript, onFailure: onFailure)
            session.begin()
            return session
        } catch {
            await library.releaseModel(id: settings.modelID)
            throw error
        }
    }
    // Final recognition without preview on the warm helper; nil keeps the
    // one-shot route (another runtime, a natively streaming model, no helper).
    func reserve(modelID: String, languageHint: String?, vocabularyHints: String) async
        -> LocalLiveRecognitionReservation?
    {
        guard LiveRecognitionSupport.mode(modelID: modelID) != .nativeStream,
            let session = try? await begin(
                settings: .init(
                    modelID: modelID, useAppleFallback: false, appleLocale: "en_US", languageHint: languageHint),
                onTranscript: nil, onFailure: { _ in })
        else { return nil }
        // Like the one-shot transcribe helper, this runtime takes no vocabulary hints.
        return LocalLiveRecognitionReservation(session: session, hintsUnavailable: !vocabularyHints.isEmpty)
    }
    // Loads the selected model ahead of a likely recording. No audio is sent;
    // an idle helper holds no model lease and retires after its idle interval.
    func prepare(settings: VoiceRecognitionSettings) async {
        guard !settings.isApplePrimary, FileManager.default.isExecutableFile(atPath: helperURL.path),
            (try? await library.runtime(id: settings.modelID)) == .transcribe,
            let model = try? await library.acquireModel(id: settings.modelID)
        else { return }
        if let language = try? Self.language(model: model, settings: settings),
            let identity = Self.identity(model: model, language: language)
        {
            await host.prepare(identity: identity) {
                try LocalLiveRecognitionHelper.launch(
                    identity: identity, executable: helperURL, model: model, language: language)
            }
        }
        await library.releaseModel(id: settings.modelID)
    }
    private static func language(model: URL, settings: VoiceRecognitionSettings) throws -> String {
        let architecture = try ModelLibrary.ggufArchitecture(model)
        guard ["qwen3_asr", "parakeet", "sensevoice", "cohere_asr"].contains(architecture) else {
            throw LiveRecognitionIssue.unsupported
        }
        guard architecture == "cohere_asr" else { return "auto" }
        guard let hint = settings.languageHint, VoiceRecognitionSettings.cohereLanguageIDs.contains(hint) else {
            throw LocalTranscriptionError.languageRequired
        }
        return hint
    }
    // A warm helper is reused only for the same model file and spoken language.
    private static func identity(model: URL, language: String) -> String? {
        CLIServeHelper.fileIdentity(model).map { $0 + "\n" + language }
    }
}

// A ready helper's stdin channel and native stream buffer each hold about 2 s
// of PCM, and neither drains while a buffered startup prefix is replayed in one
// burst. Stop adopts a still-loading helper only for a prefix within both.
enum LocalLiveRecognitionInput {
    static let byteLimit = 131_072
    static let pendingSamples = 32_000  // kPending in yullo-live-transcribe.cpp
    static func admitsBurst(samples: Int, frames: Int) -> Bool {
        samples <= pendingSamples && 5 * frames + 4 * samples <= byteLimit
    }
}

// Owns at most one live helper process. It is reused only for the same model
// identity, and retired after an idle interval, under memory pressure, after
// any failure, and when another model is needed. An idle helper holds no model
// lease and receives no audio; each recording takes the lease again.
actor LocalLiveRecognitionHost {
    private let idleSeconds: TimeInterval
    private var helper: LocalLiveRecognitionHelper?
    private var busy = false
    // The helper a recording holds; only its checkin frees the pool.
    private var checkedOut: LocalLiveRecognitionHelper?
    private var claim = UUID()
    // A replaced helper still stopping; nothing launches until it has exited.
    private var retiring: Task<Void, Never>?
    private var use = UUID()
    private var memoryPressure: DispatchSourceMemoryPressure?
    init(idleSeconds: TimeInterval = 60) {
        self.idleSeconds = idleSeconds.isFinite ? min(600, max(0, idleSeconds)) : 60
    }
    func checkout(identity: String, launch: () throws -> LocalLiveRecognitionHelper) async throws
        -> LocalLiveRecognitionHelper
    {
        // A previous recording is still releasing its helper; never run two models.
        guard !busy else { throw LiveRecognitionIssue.unavailable }
        // Claimed before any wait, so a prewarm arriving meanwhile launches nothing.
        busy = true
        checkedOut = nil
        let mark = UUID()
        claim = mark
        use = UUID()
        await settle(identity: identity)
        // Retired meanwhile (a failure, a settings change): this start no longer owns the pool.
        guard claim == mark else { throw LiveRecognitionIssue.unavailable }
        // No suspension from here to the claim: the state checked is the state used.
        use = UUID()
        let value: LocalLiveRecognitionHelper
        if let helper {
            value = helper
        } else {
            do {
                value = try launch()
            } catch {
                busy = false
                throw error
            }
            helper = value
            observeMemoryPressure()
        }
        checkedOut = value
        return value
    }
    func prepare(identity: String, launch: () throws -> LocalLiveRecognitionHelper) async {
        guard !busy else { return }
        await settle(identity: identity)
        // A recording may have started while the old helper stopped; it owns the pool now.
        guard !busy else { return }
        if helper != nil {
            scheduleRetirement()
            return
        }
        guard let value = try? launch() else { return }
        helper = value
        observeMemoryPressure()
        scheduleRetirement()
    }
    func checkin(_ value: LocalLiveRecognitionHelper, reusable: Bool) async {
        if checkedOut === value {
            checkedOut = nil
            busy = false
        }
        guard value === helper else {
            await value.stopAndWait()
            return
        }
        if reusable && value.isRunning && !busy { scheduleRetirement() } else if !busy { await retire() }
    }
    func retire() async {
        use = UUID()
        busy = false
        checkedOut = nil
        claim = UUID()
        await drop()
    }
    // Until no other model's helper runs or is still stopping: one model at a
    // time, and every wait is followed by a fresh look.
    private func settle(identity: String) async {
        while true {
            if let current = helper, current.identity != identity || !current.isRunning {
                await drop()
                continue
            }
            guard let pending = retiring else { return }
            await pending.value
            if retiring == pending { retiring = nil }
        }
    }
    private func drop() async {
        if let current = helper {
            helper = nil
            let previous = retiring
            retiring = Task {
                await previous?.value
                await current.stopAndWait()
            }
        }
        await retiring?.value
    }
    // Test and diagnostic visibility only.
    var hasWarmHelper: Bool { helper?.isRunning == true && !busy }
    private func scheduleRetirement() {
        let mark = UUID()
        use = mark
        let delay = idleSeconds
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.retireIfIdle(mark)
        }
    }
    private func retireIfIdle(_ mark: UUID? = nil) async {
        guard mark == nil || use == mark, !busy, helper != nil else { return }
        await retire()
    }
    private func observeMemoryPressure() {
        guard memoryPressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
        source.setEventHandler { [weak self] in
            Task { await self?.retireIfIdle() }
        }
        source.resume()
        memoryPressure = source
    }
}

// One helper process: a private working directory and stdin/stdout pipes, no
// ports. It loads one model, then serves one recording at a time; each line of
// output goes to the recording that is currently attached.
final class LocalLiveRecognitionHelper: @unchecked Sendable {
    let identity: String
    let input = CLISubprocessInput(byteLimit: LocalLiveRecognitionInput.byteLimit)
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var consumer: LocalLiveRecognitionSession?
    private var bytes = Data()
    private var stopped = false
    private init(identity: String) { self.identity = identity }
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
    var isRunning: Bool { locked { !stopped } }

    static func launch(identity: String, executable: URL, model: URL, language: String) throws
        -> LocalLiveRecognitionHelper
    {
        let helper = LocalLiveRecognitionHelper(identity: identity)
        let scope = try CLISubprocess.beginRequest()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "yullo-live-recognition-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            scope.finish()
            throw error
        }
        let worker = Task.detached(priority: .userInitiated) { [helper] in
            _ = try? await CLISubprocess.runStreaming(
                executable: executable,
                arguments: ["--model", model.path, "--language", language, "--serve"], input: helper.input,
                directory: directory,
                environment: [
                    "PATH": "/usr/bin:/bin", "TMPDIR": directory.path, "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"
                ], timeout: 86_400, stderrLimit: 131_072, stdoutChunk: { data in try helper.receive(data) })
            try? FileManager.default.removeItem(at: directory)
            scope.finish()
            let session = helper.locked { () -> LocalLiveRecognitionSession? in
                helper.stopped = true
                defer { helper.consumer = nil }
                return helper.consumer
            }
            session?.helperStopped()
        }
        helper.locked { helper.task = worker }
        return helper
    }
    func attach(_ session: LocalLiveRecognitionSession) -> Bool {
        locked {
            guard !stopped, consumer == nil else { return false }
            consumer = session
            return true
        }
    }
    func detach(_ session: LocalLiveRecognitionSession) {
        locked { if consumer === session { consumer = nil } }
    }
    private func receive(_ data: Data) throws {
        let lines = locked { () -> [Data]? in
            guard data.count <= 1_048_576 - bytes.count else { return nil }
            bytes.append(data)
            var lines: [Data] = []
            while let newline = bytes.firstIndex(of: 10) {
                lines.append(Data(bytes[bytes.startIndex..<newline]))
                bytes.removeSubrange(bytes.startIndex...newline)
            }
            return lines
        }
        guard let lines else { throw LiveRecognitionIssue.invalidOutput }
        for line in lines {
            guard let session = locked({ consumer }) else {
                // Only a load failure may arrive while no recording is attached;
                // the helper then exits by itself.
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                    object["type"] as? String == "error", object["session"] as? String == ""
                else { throw LiveRecognitionIssue.invalidOutput }
                continue
            }
            try session.receive(line)
        }
    }
    func stop() {
        input.close()
        locked { task }?.cancel()
    }
    func stopAndWait() async {
        stop()
        await locked { task }?.value
    }
}

final class LocalLiveRecognitionSession: VoiceLiveRecognizing, @unchecked Sendable {
    private enum Phase { case preparing, listening, finishing, finished, cancelled, failed }
    private struct Event: Decodable {
        let session: String
        let type: String
        let version: Int?
        let mode: String?
        let revision: Int64?
        let text: String?
        let code: String?
    }
    private let lock = NSLock()
    private let publicationQueue = DispatchQueue(label: "yullo.live-recognition.publication", qos: .userInitiated)
    private let helper: LocalLiveRecognitionHelper
    private let host: LocalLiveRecognitionHost
    private let library: ModelLibrary
    private let modelID: String
    private let identifier = UUID().uuidString.lowercased()
    private let onTranscript: (@Sendable (String) -> Void)?
    private let onFailure: @Sendable (Error) -> Void
    private var phase = Phase.preparing
    private var terminalError: Error?
    private var finalText: String?
    private var recoverableText: VoiceRecognitionRecoverySnapshot?
    private var ready = false, acknowledged = false, released = false
    private var nativeStream = false, receivedAudio = false
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var doneWaiters: [CheckedContinuation<Void, Never>] = []
    private var readyTimeout: Task<Void, Never>?
    private var pendingText: String?
    private var publicationScheduled = false
    private var lastPublished: TimeInterval = 0
    // Only the helper's stdout consumer touches this value.
    private var revision: Int64 = 0

    fileprivate init(
        helper: LocalLiveRecognitionHelper, host: LocalLiveRecognitionHost, library: ModelLibrary, modelID: String,
        onTranscript: (@Sendable (String) -> Void)?, onFailure: @escaping @Sendable (Error) -> Void
    ) {
        self.helper = helper
        self.host = host
        self.library = library
        self.modelID = modelID
        self.onTranscript = onTranscript
        self.onFailure = onFailure
    }
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
    fileprivate func begin() {
        guard helper.attach(self), helper.input.send(Self.frame(type: 3, payload: Data(identifier.utf8))) else {
            fail(LiveRecognitionIssue.unavailable)
            return
        }
        // A cold helper loads its model first; a warm one is ready at once.
        let watchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard let self, self.locked({ !self.ready }) else { return }
            self.fail(LiveRecognitionIssue.unavailable)
        }
        let settled = locked {
            readyTimeout = watchdog
            return ready || terminalError != nil
        }
        if settled { watchdog.cancel() }
    }
    func waitUntilReady() async throws {
        try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    let state = locked { () -> (Bool, Error?) in
                        if !ready && terminalError == nil { readyWaiters.append(continuation) }
                        return (ready, terminalError)
                    }
                    if let error = state.1 {
                        continuation.resume(throwing: error)
                    } else if state.0 {
                        continuation.resume()
                    }
                }
            },
            onCancel: { [self] in fail(CancellationError()) })
        if let error = locked({ terminalError }) { throw error }
        guard locked({ ready }) else { throw LiveRecognitionIssue.unavailable }
    }
    func accept(_ samples: [Float]) -> Bool {
        if samples.isEmpty { return locked { phase == .listening } }
        guard samples.count <= 16_384, samples.allSatisfy({ $0.isFinite && $0 >= -1 && $0 <= 1 }) else {
            fail(LocalTranscriptionError.invalidAudio)
            return false
        }
        let payload = samples.withUnsafeBytes { Data($0) }
        let accepted = locked {
            guard phase == .listening && helper.input.send(Self.frame(type: 1, payload: payload)) else { return false }
            receivedAudio = true
            return true
        }
        if !accepted, locked({ phase == .listening }) { fail(LiveRecognitionIssue.overloaded) }
        return accepted
    }
    func finish(audioURL: URL) async throws -> LocalTranscriptionResult {
        do { return try await finishRecording(audioURL: audioURL) } catch {
            await cleanup(preservingRecovery: true)
            throw error
        }
    }
    private func finishRecording(audioURL: URL) async throws -> LocalTranscriptionResult {
        try Task.checkCancellation()
        let duration = try LocalTranscriber.validateAudio(audioURL)
        guard !audioURL.path.contains("\n"), !audioURL.path.contains("\r"), !audioURL.path.contains("\0"),
            audioURL.path.utf8.count <= 4096
        else { throw LocalTranscriptionError.invalidAudio }
        // A recording reserved without preview may still be loading at Stop.
        try await waitUntilReady()
        let allowed = locked { () -> Bool in
            guard phase == .listening && terminalError == nil else { return false }
            phase = .finishing
            pendingText = nil
            return true
        }
        guard allowed else { throw locked { terminalError } ?? LiveRecognitionIssue.failed }
        // A native stream finalizes the PCM it received; it never reads the WAV.
        if locked({ nativeStream && !receivedAudio }) {
            fail(LiveRecognitionIssue.unsupported)
            throw LiveRecognitionIssue.unsupported
        }
        let message = Self.frame(type: 2, payload: Data(audioURL.path.utf8))
        let admissionDeadline = ProcessInfo.processInfo.systemUptime + 2
        while !helper.input.send(message) {
            if let error = locked({ terminalError }) { throw error }
            guard ProcessInfo.processInfo.systemUptime < admissionDeadline else {
                fail(LiveRecognitionIssue.overloaded)
                throw LiveRecognitionIssue.overloaded
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let watchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(45, min(600, duration * 3 + 45)))) } catch { return }
            self?.fail(LiveRecognitionIssue.failed)
        }
        defer { watchdog.cancel() }
        await withTaskCancellationHandler(
            operation: { await waitUntilDone() },
            onCancel: { [self] in fail(CancellationError()) })
        await drainPublications()
        try Task.checkCancellation()
        if let error = locked({ terminalError }) { throw error }
        guard let text = locked({ finalText }), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalTranscriptionError.noSpeech
        }
        locked { recoverableText = nil }
        await release(reusable: true)
        return LocalTranscriptionResult(text: text, detectedLanguage: nil)
    }
    func recoverySnapshot() async -> VoiceRecognitionRecoverySnapshot? { locked { recoverableText } }
    func cancel() async { await cleanup(preservingRecovery: false) }
    private func cleanup(preservingRecovery: Bool) async {
        let wasReady = locked { () -> Bool in
            if phase != .finished {
                phase = .cancelled
                terminalError = terminalError ?? CancellationError()
            }
            pendingText = nil
            if !preservingRecovery { recoverableText = nil }
            return ready && !released && finalText == nil
        }
        resumeReadyWaiters(throwing: CancellationError())
        var reusable = false
        if wasReady, helper.isRunning, helper.input.send(Self.frame(type: 4, payload: Data())) {
            // The helper stops this recording's decoding and stays loaded for the next.
            let deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.resumeDone()
            }
            await waitUntilDone()
            deadline.cancel()
            reusable = locked { acknowledged }
        }
        await drainPublications()
        await release(reusable: reusable)
    }
    // Returns the helper to its host and the model lease to the library once.
    private func release(reusable: Bool) async {
        guard
            locked({ () -> Bool in
                defer { released = true }
                return !released
            })
        else { return }
        locked { readyTimeout }?.cancel()
        helper.detach(self)
        if !reusable { await helper.stopAndWait() }
        await host.checkin(helper, reusable: reusable)
        await library.releaseModel(id: modelID)
    }
    fileprivate func helperStopped() {
        fail(locked { ready } ? LiveRecognitionIssue.failed : LiveRecognitionIssue.unavailable)
        resumeDone()
    }
    private func waitUntilDone() async {
        await withCheckedContinuation { continuation in
            let done = locked { () -> Bool in
                let value =
                    finalText != nil || acknowledged || !helper.isRunning
                    || (terminalError != nil && !(terminalError is CancellationError && ready))
                if !value { doneWaiters.append(continuation) }
                return value
            }
            if done { continuation.resume() }
        }
    }
    private func resumeDone() {
        let waiters = locked { () -> [CheckedContinuation<Void, Never>] in
            defer { doneWaiters.removeAll() }
            return doneWaiters
        }
        for waiter in waiters { waiter.resume() }
    }
    private func resumeReadyWaiters(throwing error: Error) {
        let waiters = locked { () -> [CheckedContinuation<Void, Error>] in
            defer { readyWaiters.removeAll() }
            return readyWaiters
        }
        for waiter in waiters { waiter.resume(throwing: error) }
    }
    private func drainPublications() async {
        await withCheckedContinuation { continuation in publicationQueue.async { continuation.resume() } }
    }
    private func fail(_ error: Error) {
        let first = locked { () -> Bool in
            guard terminalError == nil && phase != .finished && phase != .cancelled else { return false }
            terminalError = error
            phase = .failed
            pendingText = nil
            return true
        }
        guard first else { return }
        resumeReadyWaiters(throwing: error)
        resumeDone()
        // A failed recording never returns its helper for reuse.
        helper.stop()
        onFailure(error)
    }
    fileprivate func receive(_ line: Data) throws {
        guard !line.isEmpty, let event = try? JSONDecoder().decode(Event.self, from: line),
            event.session == identifier || (event.session.isEmpty && event.type == "error"),
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { throw LiveRecognitionIssue.invalidOutput }
        let keys: Set<String>
        switch event.type {
        case "ready": keys = ["session", "type", "version", "mode"]
        case "partial": keys = ["session", "type", "revision", "text"]
        case "final": keys = ["session", "type", "text"]
        case "error": keys = ["session", "type", "code"]
        case "cancelled": keys = ["session", "type"]
        default: throw LiveRecognitionIssue.invalidOutput
        }
        guard Set(object.keys) == keys else { throw LiveRecognitionIssue.invalidOutput }
        switch event.type {
        case "ready":
            guard event.version == 2, event.mode == "stream" || event.mode == "window" else {
                throw LiveRecognitionIssue.invalidOutput
            }
            let admitted = locked { () -> Bool in
                guard phase == .preparing && !ready else { return false }
                ready = true
                nativeStream = event.mode == "stream"
                phase = .listening
                return true
            }
            guard admitted else {
                // A late ready after cancellation belongs to an abandoned recording.
                if locked({ phase == .cancelled && !ready }) {
                    locked { ready = true }
                    return
                }
                throw LiveRecognitionIssue.invalidOutput
            }
            locked { readyTimeout }?.cancel()
            let waiters = locked { () -> [CheckedContinuation<Void, Error>] in
                defer { readyWaiters.removeAll() }
                return readyWaiters
            }
            for waiter in waiters { waiter.resume() }
        case "partial":
            guard let number = event.revision, number > revision, let text = event.text, text.utf8.count <= 8192
            else { throw LiveRecognitionIssue.invalidOutput }
            revision = number
            let recovery = VoiceRecognitionRecoverySnapshot(text: text, coverage: .latestWords)
            let current = locked { () -> Bool? in
                guard ready && finalText == nil else { return nil }
                guard phase == .listening || phase == .finishing else { return false }
                recoverableText = recovery
                return true
            }
            guard let current else { throw LiveRecognitionIssue.invalidOutput }
            if current { publish(text) }
        case "final":
            guard let text = event.text, text.utf8.count <= 262_144,
                locked({ phase == .finishing && finalText == nil && ready })
            else { throw LiveRecognitionIssue.invalidOutput }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LocalTranscriptionError.noSpeech
            }
            locked {
                finalText = text
                phase = .finished
            }
            resumeDone()
        case "cancelled":
            guard locked({ phase == .cancelled && ready && !acknowledged }) else {
                throw LiveRecognitionIssue.invalidOutput
            }
            locked { acknowledged = true }
            resumeDone()
        case "error":
            let error: Error
            switch event.code {
            case "unsupported": error = LiveRecognitionIssue.unsupported
            case "overloaded": error = LiveRecognitionIssue.overloaded
            case "languageRequired": error = LocalTranscriptionError.languageRequired
            case "tooLong": error = LocalTranscriptionError.tooLong
            case "senseVoiceTooLong": error = LocalTranscriptionError.senseVoiceTooLong
            case "invalidAudio": error = LocalTranscriptionError.invalidAudio
            case "noSpeech": error = LocalTranscriptionError.noSpeech
            case "invalidOutput": error = LiveRecognitionIssue.invalidOutput
            default: error = LiveRecognitionIssue.failed
            }
            fail(error)
            throw error
        default: throw LiveRecognitionIssue.invalidOutput
        }
    }
    private func publish(_ text: String) {
        guard let onTranscript else { return }
        let delay = locked { () -> TimeInterval? in
            guard phase == .listening else { return nil }
            pendingText = text
            guard !publicationScheduled else { return nil }
            publicationScheduled = true
            return max(0, 0.15 - (ProcessInfo.processInfo.systemUptime - lastPublished))
        }
        guard let delay else { return }
        // Take the latest value only when the serial consumer can publish it.
        // A slow callback must not let an older captured value overtake it.
        publicationQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            let pending = self.locked { () -> String? in
                self.publicationScheduled = false
                guard self.phase == .listening else { return nil }
                let text = self.pendingText
                self.pendingText = nil
                self.lastPublished = ProcessInfo.processInfo.systemUptime
                return text
            }
            if let pending { onTranscript(pending) }
        }
    }
    private static func frame(type: UInt8, payload: Data) -> Data {
        var count = UInt32(payload.count + 1).littleEndian
        var data = Data(bytes: &count, count: 4)
        data.append(type)
        data.append(payload)
        return data
    }
}

// Final recognition without preview on the same warm helper: it receives no
// PCM and recognizes the finished WAV once. Helper failures become ordinary
// local failures, so the caller can still take the fresh-helper route.
final class LocalLiveRecognitionReservation: VoiceRecognitionReserving, @unchecked Sendable {
    private let session: LocalLiveRecognitionSession
    private let hintsUnavailable: Bool
    init(session: LocalLiveRecognitionSession, hintsUnavailable: Bool) {
        self.session = session
        self.hintsUnavailable = hintsUnavailable
    }
    func finish(audioURL: URL) async throws -> LocalTranscriptionResult {
        let stopped = ProcessInfo.processInfo.systemUptime
        do {
            let result = try await session.finish(audioURL: audioURL)
            let duration = (try? AVAudioFile(forReading: audioURL)).map { Double($0.length) / 16000 } ?? 0
            LocalTranscriber.logTiming(
                runtime: .transcribe, outcome: "completed", audio: duration, began: stopped, prepared: stopped,
                load: nil, prestarted: true)
            return LocalTranscriptionResult(
                text: result.text, detectedLanguage: nil, vocabularyHintsUnavailable: hintsUnavailable)
        } catch is LiveRecognitionIssue {
            try Task.checkCancellation()
            throw LocalTranscriptionError.failed
        }
    }
    func cancel() async { await session.cancel() }
}
