import Foundation
import Speech
import AVFoundation
import CoreMedia

struct AppleLiveTranscriptSegment: Sendable {
    let start: Double
    let duration: Double
    let text: String
    var isFinal = false
}

// The analyzer consumes on a worker task. Admission never waits on that task,
// conversion, a model or a full queue on the recording writer's callback.
final class AppleLivePCMQueue: @unchecked Sendable {
    enum Admission { case accepted, closed, overloaded, invalid }
    struct Chunk: Sendable {
        let samples: [Float]
        let startFrame: Int64
    }
    private let lock = NSLock()
    private var chunks: [[Float]] = []
    private var headOffset = 0
    private var sampleCount = 0
    private var consumedFrames: Int64 = 0
    private var closed = false
    let maximumSamples: Int
    let signals: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    init(maximumSamples: Int = 16_000) {
        self.maximumSamples = maximumSamples
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        signals = pair.stream
        continuation = pair.continuation
    }
    func admit(_ samples: [Float]) -> Admission {
        guard samples.count <= maximumSamples, samples.allSatisfy(\.isFinite) else { return .invalid }
        guard lock.try() else { return .overloaded }
        guard !closed else {
            lock.unlock()
            return .closed
        }
        guard samples.count <= maximumSamples - sampleCount else {
            lock.unlock()
            return .overloaded
        }
        if !samples.isEmpty {
            chunks.append(samples)
            sampleCount += samples.count
        }
        lock.unlock()
        if !samples.isEmpty { continuation.yield(()) }
        return .accepted
    }
    func pop(maximumCount: Int = 2_560) -> Chunk? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, sampleCount > 0 else { return nil }
        let start = consumedFrames
        var output: [Float] = []
        output.reserveCapacity(min(maximumCount, sampleCount))
        while output.count < maximumCount, !chunks.isEmpty {
            let take = min(maximumCount - output.count, chunks[0].count - headOffset)
            output.append(contentsOf: chunks[0][headOffset..<headOffset + take])
            headOffset += take
            sampleCount -= take
            consumedFrames += Int64(take)
            if headOffset == chunks[0].count {
                chunks.removeFirst()
                headOffset = 0
            }
        }
        return Chunk(samples: output, startFrame: start)
    }
    func close() {
        lock.lock()
        closed = true
        chunks.removeAll()
        headOffset = 0
        sampleCount = 0
        lock.unlock()
        continuation.finish()
    }
    #if YULLO_TESTING
        var bufferedSamples: Int {
            lock.lock()
            defer { lock.unlock() }
            return sampleCount
        }
    #endif
}

protocol AppleLiveAnalyzing: Sendable {
    var results: AsyncThrowingStream<AppleLiveTranscriptSegment, Error> { get }
    func send(_ chunk: AppleLivePCMQueue.Chunk) async throws
    func stop() async
}

struct AppleLiveTranscriptTail {
    private var segments: [AppleLiveTranscriptSegment] = []
    mutating func accept(_ value: AppleLiveTranscriptSegment) throws -> String {
        guard value.start.isFinite, value.duration.isFinite, value.start >= 0, value.duration >= 0,
            value.text.utf8.count <= 16_384
        else { throw LiveRecognitionIssue.invalidOutput }
        let end = value.start + value.duration
        guard end.isFinite else { throw LiveRecognitionIssue.invalidOutput }
        segments.removeAll { item in
            item.start == value.start || (item.start < end && value.start < item.start + item.duration)
        }
        segments.append(
            .init(
                start: value.start, duration: value.duration,
                text: VoiceLiveTextBuffer.suffix(value.text)))
        segments.sort { $0.start < $1.start }
        // Keep a bounded amount of actual provider context, not a guessed
        // concatenation of overlapping rolling-window results.
        if segments.count > 256 { segments.removeFirst(segments.count - 256) }
        var bytes = segments.reduce(0) { $0 + $1.text.utf8.count }
        while segments.count > 1 && bytes > VoiceLiveTextBuffer.maximumBytes {
            bytes -= segments.removeFirst().text.utf8.count
        }
        return VoiceLiveTextBuffer.suffix(segments.map(\.text).joined())
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum AppleLiveRecognitionProvider {
    typealias Finalizer = @Sendable (URL, String) async throws -> LocalTranscriptionResult
    static func start(
        settings: VoiceRecognitionSettings, onTranscript: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) async throws -> any VoiceLiveRecognizing {
        try await startInstalled(
            settings: settings, onTranscript: onTranscript, onFailure: onFailure,
            finalizer: { try await VoiceResources.appleSpeech.transcribe(audioURL: $0, localeID: $1) })
    }
    // Loads Apple's recognizer for the selected language once and releases it.
    // No audio is sent; missing assets are left for a recording to report.
    static func prewarm(settings: VoiceRecognitionSettings) async {
        guard settings.isApplePrimary,
            let resolved = try? await VoiceResources.appleSpeech.requireAvailable(localeID: settings.appleLocale),
            let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: resolved)),
            let engine = try? await AppleSpeechLiveEngine.start(locale: locale)
        else { return }
        await engine.stop()
    }
    private static func startInstalled(
        settings: VoiceRecognitionSettings, onTranscript: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void, finalizer: @escaping Finalizer
    ) async throws -> any VoiceLiveRecognizing {
        guard settings.isApplePrimary else { throw LiveRecognitionIssue.unsupported }
        let resolved = try await VoiceResources.appleSpeech.requireAvailable(localeID: settings.appleLocale)
        try Task.checkCancellation()
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: resolved)) else {
            throw AppleSpeechError.unsupportedLocale
        }
        let engine = try await AppleSpeechLiveEngine.start(locale: locale)
        do {
            try Task.checkCancellation()
            let session = await make(
                localeID: locale.identifier, engine: engine, onTranscript: onTranscript, onFailure: onFailure,
                finalizer: finalizer)
            if Task.isCancelled {
                await session.cancel()
                throw CancellationError()
            }
            return session
        } catch {
            await engine.stop()
            throw error
        }
    }
    private static func make(
        localeID: String, engine: any AppleLiveAnalyzing,
        onTranscript: @escaping @Sendable (String) -> Void, onFailure: @escaping @Sendable (Error) -> Void,
        finalizer: @escaping Finalizer
    ) async -> any VoiceLiveRecognizing {
        let session = AppleLiveRecognitionSession(
            engine: engine, localeID: localeID,
            onTranscript: onTranscript, onFailure: onFailure, finalizer: finalizer)
        await session.start()
        return session
    }
    #if YULLO_TESTING
        static func startInstalledForTesting(
            settings: VoiceRecognitionSettings,
            onTranscript: @escaping @Sendable (String) -> Void, onFailure: @escaping @Sendable (Error) -> Void,
            finalizer: @escaping Finalizer
        ) async throws -> any VoiceLiveRecognizing {
            try await startInstalled(
                settings: settings, onTranscript: onTranscript, onFailure: onFailure, finalizer: finalizer)
        }
        static func startForTesting(
            settings: VoiceRecognitionSettings, engine: any AppleLiveAnalyzing,
            onTranscript: @escaping @Sendable (String) -> Void, onFailure: @escaping @Sendable (Error) -> Void,
            finalizer: @escaping Finalizer
        ) async throws -> any VoiceLiveRecognizing {
            guard settings.isApplePrimary else { throw LiveRecognitionIssue.unsupported }
            return await make(
                localeID: settings.appleLocale, engine: engine, onTranscript: onTranscript, onFailure: onFailure,
                finalizer: finalizer)
        }
    #endif
}

private actor AppleLiveRecognitionSession: VoiceLiveRecognizing {
    private enum Phase { case active, failed, finishing, finished, cancelled }
    nonisolated private let queue = AppleLivePCMQueue()
    private let engine: any AppleLiveAnalyzing
    private let localeID: String
    private let onTranscript: @Sendable (String) -> Void
    private let onFailure: @Sendable (Error) -> Void
    private let finalizer: AppleLiveRecognitionProvider.Finalizer
    private var phase = Phase.active
    private var feeder: Task<Void, Never>?
    private var collector: Task<Void, Never>?
    private var stopping: Task<Void, Never>?
    private var finalization: Task<LocalTranscriptionResult, Error>?
    private var latestText = ""
    private var finalizedRecovery = ""
    private var finalizedEnd = 0.0
    private var finalizedRecoveryBytes = 0
    private var hasFinalizedRecoveryRange = false
    private var recoveryTruncated = false
    private var latestRecovery: VoiceRecognitionRecoverySnapshot?
    init(
        engine: any AppleLiveAnalyzing, localeID: String,
        onTranscript: @escaping @Sendable (String) -> Void, onFailure: @escaping @Sendable (Error) -> Void,
        finalizer: @escaping AppleLiveRecognitionProvider.Finalizer
    ) {
        self.engine = engine
        self.localeID = localeID
        self.onTranscript = onTranscript
        self.onFailure = onFailure
        self.finalizer = finalizer
    }
    func start() {
        let queue = queue, engine = engine
        feeder = Task { [weak self] in
            do {
                for await _ in queue.signals {
                    while let chunk = queue.pop() {
                        try Task.checkCancellation()
                        try await engine.send(chunk)
                    }
                }
            } catch {
                if !Task.isCancelled { Task { await self?.fail(error) } }
            }
        }
        collector = Task { [weak self] in
            do {
                var tail = AppleLiveTranscriptTail()
                for try await result in engine.results {
                    try Task.checkCancellation()
                    let text = try tail.accept(result)
                    await self?.publish(text, segment: result)
                }
                if !Task.isCancelled { Task { await self?.fail(LiveRecognitionIssue.unavailable) } }
            } catch {
                if !Task.isCancelled { Task { await self?.fail(error) } }
            }
        }
    }
    nonisolated func accept(_ samples: [Float]) -> Bool {
        switch queue.admit(samples) {
        case .accepted: return true
        case .closed: return false
        case .overloaded:
            Task { await fail(LiveRecognitionIssue.overloaded) }
            return false
        case .invalid:
            Task { await fail(LiveRecognitionIssue.invalidOutput) }
            return false
        }
    }
    private func publish(_ text: String, segment: AppleLiveTranscriptSegment) {
        guard phase == .active else { return }
        if segment.isFinal, !recoveryTruncated,
            !hasFinalizedRecoveryRange
                || (segment.start >= finalizedEnd && segment.start + segment.duration > finalizedEnd)
        {
            let bytes = segment.text.utf8.count
            if bytes <= VoiceRecognitionRecoverySnapshot.maximumBytes - finalizedRecoveryBytes {
                finalizedRecovery.append(segment.text)
                finalizedRecoveryBytes += bytes
            } else if let bounded = VoiceRecognitionRecoverySnapshot(
                text: finalizedRecovery + segment.text, coverage: .finalizedSpans)
            {
                finalizedRecovery = bounded.text
                finalizedRecoveryBytes = bounded.text.utf8.count
                recoveryTruncated = true
            }
            finalizedEnd = segment.start + segment.duration
            hasFinalizedRecoveryRange = true
        }
        latestRecovery = VoiceRecognitionRecoverySnapshot(text: text, coverage: .latestWords)
        guard text != latestText else { return }
        latestText = text
        onTranscript(text)
    }
    private func fail(_ error: Error) async {
        guard phase == .active else { return }
        phase = .failed
        onFailure(error)
        await stopLive()
    }
    private func stopLive() async {
        if let stopping {
            await stopping.value
            return
        }
        queue.close()
        feeder?.cancel()
        collector?.cancel()
        let engine = engine, feeder = feeder, collector = collector
        let task = Task {
            await engine.stop()
            await feeder?.value
            await collector?.value
        }
        stopping = task
        await task.value
        self.feeder = nil
        self.collector = nil
        latestText = ""
    }
    func finish(audioURL: URL) async throws -> LocalTranscriptionResult {
        guard phase == .active || phase == .failed else { throw CancellationError() }
        phase = .finishing
        return try await withTaskCancellationHandler {
            await stopLive()
            try Task.checkCancellation()
            guard phase == .finishing else { throw CancellationError() }
            let finalizer = finalizer, localeID = localeID
            let task = Task { try await finalizer(audioURL, localeID) }
            finalization = task
            do {
                let result = try await task.value
                try Task.checkCancellation()
                guard phase == .finishing else { throw CancellationError() }
                phase = .finished
                clearRecovery()
                finalization = nil
                return result
            } catch {
                finalization = nil
                throw error
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }
    func recoverySnapshot() async -> VoiceRecognitionRecoverySnapshot? {
        guard phase != .cancelled, phase != .finished else { return nil }
        return VoiceRecognitionRecoverySnapshot(
            text: finalizedRecovery, coverage: .finalizedSpans, truncated: recoveryTruncated) ?? latestRecovery
    }
    private func clearRecovery() {
        finalizedRecovery = ""
        latestRecovery = nil
        recoveryTruncated = false
        finalizedEnd = 0
        finalizedRecoveryBytes = 0
        hasFinalizedRecoveryRange = false
    }
    func cancel() async {
        phase = .cancelled
        clearRecovery()
        finalization?.cancel()
        await stopLive()
        _ = try? await finalization?.value
        finalization = nil
    }
}

private actor AppleSpeechLiveEngine: AppleLiveAnalyzing {
    nonisolated let results: AsyncThrowingStream<AppleLiveTranscriptSegment, Error>
    private let resultContinuation: AsyncThrowingStream<AppleLiveTranscriptSegment, Error>.Continuation
    private let locale: Locale
    private let module: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let inputStream: AsyncStream<AnalyzerInput>
    private let sourceFormat: AVAudioFormat
    private let analyzerFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let reservations: AppleSpeechAssetReservations
    private var reservation: AppleSpeechAssetReservations.Ticket?
    private var reader: Task<Void, Never>?
    private var stopping: Task<Void, Never>?
    private var stopped = false
    private init(
        locale: Locale, module: SpeechTranscriber, analyzer: SpeechAnalyzer,
        sourceFormat: AVAudioFormat, analyzerFormat: AVAudioFormat, reservations: AppleSpeechAssetReservations
    ) throws {
        self.locale = locale
        self.module = module
        self.analyzer = analyzer
        self.sourceFormat = sourceFormat
        self.analyzerFormat = analyzerFormat
        self.reservations = reservations
        if sourceFormat == analyzerFormat {
            converter = nil
        } else {
            guard let conversion = AVAudioConverter(from: sourceFormat, to: analyzerFormat) else {
                throw LiveRecognitionIssue.unavailable
            }
            converter = conversion
        }
        let input = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(4))
        inputStream = input.stream
        inputContinuation = input.continuation
        let output = AsyncThrowingStream<AppleLiveTranscriptSegment, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(8))
        results = output.stream
        resultContinuation = output.continuation
    }
    static func start(
        locale: Locale, reservations: AppleSpeechAssetReservations = .shared
    ) async throws -> AppleSpeechLiveEngine {
        let module = SpeechTranscriber(
            locale: locale, transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [module])
        guard
            let source = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: source)
        else {
            throw LiveRecognitionIssue.unavailable
        }
        let engine = try AppleSpeechLiveEngine(
            locale: locale, module: module, analyzer: analyzer, sourceFormat: source, analyzerFormat: format,
            reservations: reservations)
        do {
            try await withTaskCancellationHandler {
                try await engine.prepare()
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
            return engine
        } catch {
            await engine.stop()
            throw error
        }
    }
    private func prepare() async throws {
        reservation = try await reservations.acquire(locale: locale)
        try Task.checkCancellation()
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        try Task.checkCancellation()
        let continuation = resultContinuation, module = module
        reader = Task {
            do {
                for try await result in module.results {
                    try Task.checkCancellation()
                    let value = AppleLiveTranscriptSegment(
                        start: result.range.start.seconds, duration: result.range.duration.seconds,
                        text: String(result.text.characters), isFinal: result.isFinal)
                    if case .dropped = continuation.yield(value) { throw LiveRecognitionIssue.overloaded }
                }
                continuation.finish()
            } catch {
                if Task.isCancelled { continuation.finish() } else { continuation.finish(throwing: error) }
            }
        }
        try await analyzer.start(inputSequence: inputStream)
        try Task.checkCancellation()
    }
    func send(_ chunk: AppleLivePCMQueue.Chunk) async throws {
        guard !stopped, !chunk.samples.isEmpty else { throw CancellationError() }
        try Task.checkCancellation()
        guard
            let source = AVAudioPCMBuffer(
                pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(chunk.samples.count)),
            let channel = source.floatChannelData?[0]
        else { throw LiveRecognitionIssue.failed }
        source.frameLength = AVAudioFrameCount(chunk.samples.count)
        chunk.samples.withUnsafeBufferPointer {
            if let base = $0.baseAddress { channel.update(from: base, count: $0.count) }
        }
        let output: AVAudioPCMBuffer
        if let converter {
            let capacity = AVAudioFrameCount(
                ceil(Double(chunk.samples.count) * analyzerFormat.sampleRate / 16_000) + 32)
            guard let converted = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else {
                throw LiveRecognitionIssue.failed
            }
            var supplied = false, error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, state in
                if supplied {
                    state.pointee = .noDataNow
                    return nil
                }
                supplied = true
                state.pointee = .haveData
                return source
            }
            if let error { throw error }
            guard status != .error else { throw LiveRecognitionIssue.failed }
            output = converted
        } else {
            output = source
        }
        guard output.frameLength > 0 else { return }
        let input = AnalyzerInput(buffer: output, bufferStartTime: CMTime(value: chunk.startFrame, timescale: 16_000))
        switch inputContinuation.yield(input) {
        case .enqueued: break
        case .dropped: throw LiveRecognitionIssue.overloaded
        case .terminated: throw CancellationError()
        @unknown default: throw LiveRecognitionIssue.failed
        }
    }
    func stop() async {
        if let stopping {
            await stopping.value
            return
        }
        stopped = true
        inputContinuation.finish()
        reader?.cancel()
        let analyzer = analyzer, reader = reader, reservations = reservations, ticket = reservation
        reservation = nil
        let continuation = resultContinuation
        let task = Task {
            await analyzer.cancelAndFinishNow()
            await reader?.value
            continuation.finish()
            if let ticket { await reservations.release(ticket) }
        }
        stopping = task
        await task.value
        self.reader = nil
    }
}
