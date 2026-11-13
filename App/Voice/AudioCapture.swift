import Foundation
import AVFoundation
import CoreAudio
import SoundAnalysis
import CoreMedia
import Darwin

/// The file is created inside a private per-session directory. It is never sent
/// anywhere by capture; the caller owns it only until recognition completes.
final class CapturedAudio: @unchecked Sendable {
    let url: URL
    var fileURL: URL { url }
    let sampleCount: Int64
    let sampleRate: Double = 16_000
    var duration: TimeInterval { Double(sampleCount) / sampleRate }
    private let directory: URL
    fileprivate init(url: URL, directory: URL, sampleCount: Int64) {
        self.url = url
        self.directory = directory
        self.sampleCount = sampleCount
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    deinit { cleanup() }
}

enum AudioCaptureError: Error, LocalizedError {
    case permissionDenied, alreadyRecording, unavailable, deviceChanged
    case conversionFailed, recordingFailed, processingOverloaded, speechDetectionUnavailable, emptyRecording,
        recordingTooLong
    var messageKey: String {
        switch self {
        case .permissionDenied: return "Allow microphone access in System Settings to start dictation."
        case .alreadyRecording: return "A recording is already in progress."
        case .unavailable: return "No microphone is available. Check your audio input in System Settings."
        case .deviceChanged: return "The microphone changed. Start recording again."
        case .conversionFailed: return "Couldn’t prepare the microphone audio for recognition."
        case .recordingFailed: return "Couldn’t save the recording. Try again."
        case .processingOverloaded: return "Audio processing couldn’t keep up. Try recording again."
        case .speechDetectionUnavailable:
            return
                "Automatic stopping is unavailable. In Dictation settings, select Press Return and deselect After a pause."
        case .emptyRecording: return "No audio was recorded. Try again."
        case .recordingTooLong: return "This recording reached the time limit. Try a shorter recording."
        }
    }
    var errorDescription: String? { L10n.tr(messageKey) }
}

/// Confidence comes from SoundAnalysis's real on-device speech classifier.
/// Hysteresis prevents a borderline classification from repeatedly toggling VAD.
struct SpeechActivityGate {
    private(set) var active = false
    mutating func observe(confidence: Double) -> Bool {
        let confidence = confidence.isFinite ? min(1, max(0, confidence)) : 0
        active = confidence >= (active ? 0.30 : 0.55)
        return active
    }
}

// A segment lease also guards work already queued to the main actor. Stopping
// an engine tap alone does not drain its callback or classifier publications.
private final class CaptureActivityLease: @unchecked Sendable {
    private let lock = NSLock()
    private var current: UUID?
    func open() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let id = UUID()
        current = id
        return id
    }
    func close() {
        lock.lock()
        current = nil
        lock.unlock()
    }
    func ticket() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
    func owns(_ ticket: UUID?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ticket != nil && current == ticket
    }
}

@MainActor
final class AudioCapture {
    typealias SamplesHandler = @Sendable ([Float]) -> Void
    typealias LevelHandler = @MainActor (Float) -> Void
    typealias SpeechHandler = @MainActor (Bool) -> Void
    typealias SpeechUnavailableHandler = @MainActor () -> Void
    typealias ErrorHandler = @MainActor (Error) -> Void
    private var token: UUID?
    private var engine: AVAudioEngine?
    private var run: CaptureRun?
    private var format: AVAudioFormat?
    private var tapInstalled = false
    private var configurationObserver: NSObjectProtocol?
    private let activity = CaptureActivityLease()
    private var speechHandler: SpeechHandler?
    private var unavailableHandler: SpeechUnavailableHandler?
    private var errorHandler: ErrorHandler?
    private(set) var isPaused = false
    #if YULLO_TESTING
        private var generated = false
    #endif

    /// Loads the audio stack and reads the default input device's description
    /// once allowed, so the first recording does not pay for it. It creates no
    /// input node, starts no input and never asks for permission.
    nonisolated static func prewarmAudioStack() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        loadAudioStack()
    }
    nonisolated static func loadAudioStack() {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
                == noErr, device != kAudioObjectUnknown
        else { return }
        var rate = Float64(0)
        size = UInt32(MemoryLayout<Float64>.size)
        address.mSelector = kAudioDevicePropertyNominalSampleRate
        _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        _ = AVAudioEngine()
    }

    /// Only an explicit recording action requests microphone permission. Model
    /// preparation belongs to the caller and need not delay microphone startup.
    func start(
        requiresSpeechActivity: Bool = true, onSamples: SamplesHandler? = nil, onLevel: @escaping LevelHandler,
        onSpeechActivity: @escaping SpeechHandler,
        onSpeechActivityUnavailable: SpeechUnavailableHandler? = nil,
        onError: @escaping ErrorHandler
    ) async throws {
        guard token == nil else { throw AudioCaptureError.alreadyRecording }
        try Task.checkCancellation()
        let expected = UUID()
        token = expected
        do {
            let allowed: Bool
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: allowed = true
            case .notDetermined:
                allowed = await withCheckedContinuation { continuation in
                    AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
                }
            default: allowed = false
            }
            try Task.checkCancellation()
            guard token == expected else { throw CancellationError() }
            guard allowed else { throw AudioCaptureError.permissionDenied }
            let audioEngine = AVAudioEngine()
            let inputFormat = audioEngine.inputNode.outputFormat(forBus: 0)
            guard inputFormat.sampleRate.isFinite, inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
                throw AudioCaptureError.unavailable
            }
            speechHandler = onSpeechActivity
            unavailableHandler = onSpeechActivityUnavailable
            errorHandler = onError
            let segment = activity.open()
            let lease = activity
            let captureRun = try CaptureRun(
                format: inputFormat, requiresSpeechActivity: requiresSpeechActivity, onSamples: onSamples,
                onLevel: { [weak self] value in
                    let ticket = lease.ticket()
                    Task { @MainActor in
                        guard self?.token == expected, lease.owns(ticket) else { return }
                        onLevel(value)
                    }
                },
                onSpeech: speechCallback(for: expected, segment: segment),
                onSpeechActivityUnavailable: speechUnavailableHandler(for: expected, segment: segment),
                onError: failureHandler(for: expected, deliver: onError))
            run = captureRun
            engine = audioEngine
            format = inputFormat
            isPaused = false
            try installAndStart(audioEngine, captureRun: captureRun, format: inputFormat)
            try Task.checkCancellation()
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main
            ) { [weak self] _ in
                let ticket = lease.ticket()
                Task { @MainActor in
                    await self?.configurationChanged(for: expected, ticket: ticket, deliver: onError)
                }
            }
        } catch {
            if token == expected { await cancel() }
            throw error
        }
    }

    func pause() async throws {
        guard let captureRun = run, !isPaused else { return }
        // Revoke admission before the OS tap is touched. A callback that was
        // already copied may finish; the serial barrier drains it before return.
        captureRun.pauseAdmission()
        activity.close()
        isPaused = true
        stopEngine(releasing: false)
        try await captureRun.drainPaused()
    }

    func resume() async throws {
        guard let captureRun = run, let expected = token, isPaused else { return }
        try Task.checkCancellation()
        if let engine, let format {
            guard engine.inputNode.outputFormat(forBus: 0).isEqual(format) else {
                throw AudioCaptureError.deviceChanged
            }
        } else {
            #if YULLO_TESTING
                guard generated else { throw AudioCaptureError.unavailable }
            #else
                throw AudioCaptureError.unavailable
            #endif
        }
        let segment = activity.open()
        do {
            try await captureRun.resumeSpeechActivity(
                onSpeech: speechCallback(for: expected, segment: segment),
                onUnavailable: speechUnavailableHandler(for: expected, segment: segment))
            try Task.checkCancellation()
            guard token == expected, run === captureRun else { throw CancellationError() }
            try captureRun.resumeAdmission()
            if let engine, let format { try installAndStart(engine, captureRun: captureRun, format: format) }
            isPaused = false
        } catch {
            activity.close()
            captureRun.pauseAdmission()
            stopEngine(releasing: false)
            try? await captureRun.drainPaused()
            throw error
        }
    }

    func finish() async throws -> CapturedAudio {
        if Task.isCancelled {
            await cancel()
            throw CancellationError()
        }
        guard let captureRun = run else { throw AudioCaptureError.emptyRecording }
        activity.close()
        stopEngine()
        run = nil
        token = nil
        isPaused = false
        do {
            let audio = try await captureRun.finish()
            if Task.isCancelled {
                audio.cleanup()
                throw CancellationError()
            }
            return audio
        } catch {
            await captureRun.cancel()
            throw error
        }
    }

    func cancel() async {
        let captureRun = run
        activity.close()
        captureRun?.setSamplesHandler(nil)
        stopEngine()
        run = nil
        token = nil
        isPaused = false
        speechHandler = nil
        unavailableHandler = nil
        errorHandler = nil
        await captureRun?.cancel()
    }
    func setSamplesHandler(_ handler: SamplesHandler?) { run?.setSamplesHandler(handler) }

    private func speechCallback(for expected: UUID, segment: UUID) -> (Bool) -> Void {
        let lease = activity
        return { [weak self] active in
            Task { @MainActor in
                guard let self, self.token == expected, lease.owns(segment) else { return }
                self.speechHandler?(active)
            }
        }
    }
    private func speechUnavailableHandler(for expected: UUID, segment: UUID) -> () -> Void {
        let lease = activity
        return { [weak self] in
            Task { @MainActor in
                guard let self, self.token == expected, lease.owns(segment) else { return }
                if let deliver = self.unavailableHandler {
                    deliver()
                } else if let onError = self.errorHandler {
                    await self.cancel()
                    onError(AudioCaptureError.speechDetectionUnavailable)
                }
            }
        }
    }
    private func configurationChanged(for expected: UUID, ticket: UUID?, deliver: @escaping ErrorHandler) async {
        guard token == expected, activity.owns(ticket), !isPaused else { return }
        await cancel()
        deliver(AudioCaptureError.deviceChanged)
    }
    private func failureHandler(for expected: UUID, deliver: @escaping ErrorHandler) -> (Error) -> Void {
        { [weak self] error in
            Task { @MainActor in
                guard let self, self.token == expected else { return }
                await self.cancel()
                deliver(error)
            }
        }
    }
    private func installAndStart(_ engine: AVAudioEngine, captureRun: CaptureRun, format: AVAudioFormat) throws {
        let generation = captureRun.inputGeneration
        let input = engine.inputNode
        if #available(macOS 27.0, *) {
            do {
                try input.__installTap(onBus: 0, bufferSize: 4096, format: format, error: ()) { buffer, _ in
                    captureRun.receive(buffer, generation: generation)
                }
            } catch { throw AudioCaptureError.unavailable }
        } else {
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
                captureRun.receive(buffer, generation: generation)
            }
        }
        tapInstalled = true
        engine.prepare()
        do { try engine.start() } catch { throw AudioCaptureError.unavailable }
    }
    #if YULLO_TESTING
        // Snapshot the notification's segment before its main-actor publication.
        // Tests can replay that publication after a pause/resume without a device.
        func pendingGeneratedConfigurationChange() -> @MainActor () async -> Void {
            guard let expected = token, let deliver = errorHandler else { return {} }
            let ticket = activity.ticket()
            return { [weak self] in
                guard let self else { return }
                await self.configurationChanged(for: expected, ticket: ticket, deliver: deliver)
            }
        }
        // Real writer/callback owners, with no engine, microphone or permission.
        func startGenerated(
            onSpeechActivityUnavailable: SpeechUnavailableHandler? = nil,
            onError: @escaping ErrorHandler
        ) throws -> (run: CaptureRun, speechUnavailable: () -> Void, failure: (Error) -> Void) {
            guard token == nil else { throw AudioCaptureError.alreadyRecording }
            try Task.checkCancellation()
            let expected = UUID()
            token = expected
            generated = true
            isPaused = false
            unavailableHandler = onSpeechActivityUnavailable
            errorHandler = onError
            let segment = activity.open()
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
            let generated = try CaptureRun(generatedFormat: format)
            run = generated
            return (
                generated, speechUnavailableHandler(for: expected, segment: segment),
                failureHandler(for: expected, deliver: onError)
            )
        }
    #endif
    private func stopEngine(releasing: Bool = true) {
        if releasing {
            if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
            configurationObserver = nil
        }
        if let engine {
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.stop()
        }
        tapInstalled = false
        if releasing {
            engine = nil
            format = nil
        }
    }
}

/// Copies a tap buffer before returning it to AVAudioEngine, then converts and
/// writes on one serial worker. At most eight input buffers can be queued.
final class CaptureRun: @unchecked Sendable {
    private let queue = DispatchQueue(label: "yullo.audio.capture", qos: .userInitiated)
    private let slots = DispatchSemaphore(value: 8)
    private let lock = NSLock()
    private var accepting = true
    private var generation: UInt64 = 0
    var inputGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }
    private var cancelled = false
    private var failure: Error?
    private let worker: AudioCaptureWriter
    private let onError: (Error) -> Void
    #if YULLO_TESTING
        var beforeEnqueue: (() -> Void)?
        var generatedFileURL: URL { worker.fileURL }
        init(
            generatedFormat: AVAudioFormat, onSamples: AudioCapture.SamplesHandler? = nil,
            onError: @escaping (Error) -> Void = { _ in }
        ) throws {
            self.onError = onError
            worker = try AudioCaptureWriter(format: generatedFormat, classifySpeech: false, onSamples: onSamples)
        }
    #endif

    init(
        format: AVAudioFormat, requiresSpeechActivity: Bool, onSamples: AudioCapture.SamplesHandler? = nil,
        onLevel: @escaping (Float) -> Void,
        onSpeech: @escaping (Bool) -> Void, onSpeechActivityUnavailable: (() -> Void)? = nil,
        onError: @escaping (Error) -> Void
    ) throws {
        self.onError = onError
        worker = try AudioCaptureWriter(
            format: format, classifySpeech: requiresSpeechActivity, onSamples: onSamples,
            onLevel: onLevel, onSpeech: onSpeech, onSpeechActivityUnavailable: onSpeechActivityUnavailable,
            onError: onError)
    }
    func setSamplesHandler(_ handler: AudioCapture.SamplesHandler?) { worker.setSamplesHandler(handler) }
    func receive(_ buffer: AVAudioPCMBuffer, generation expected: UInt64? = nil) {
        guard buffer.frameLength > 0 else { return }
        // Keep reservation, copying and enqueue ordered with closeInput().
        // Removing an engine tap does not promise that a tap callback has drained.
        lock.lock()
        guard accepting && !cancelled && failure == nil, expected == nil || expected == generation else {
            lock.unlock()
            return
        }
        guard slots.wait(timeout: .now()) == .success else {
            failWhileLocked(AudioCaptureError.processingOverloaded)
            return
        }
        guard let owned = Self.copy(buffer) else {
            slots.signal()
            failWhileLocked(AudioCaptureError.conversionFailed)
            return
        }
        #if YULLO_TESTING
            beforeEnqueue?()
        #endif
        queue.async { [self] in
            defer { slots.signal() }
            lock.lock()
            let shouldProcess = !cancelled && failure == nil
            lock.unlock()
            guard shouldProcess else { return }
            do { try worker.append(owned) } catch { fail(error) }
        }
        lock.unlock()
    }
    func pauseAdmission() {
        lock.lock()
        accepting = false
        generation &+= 1
        lock.unlock()
    }
    func drainPaused() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                worker.pauseSpeechActivity()
                lock.lock()
                let issue = failure
                let stopped = cancelled
                lock.unlock()
                if let issue {
                    continuation.resume(throwing: issue)
                } else if stopped {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
    func resumeSpeechActivity(onSpeech: @escaping (Bool) -> Void, onUnavailable: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                lock.lock()
                let issue = failure
                let stopped = cancelled
                lock.unlock()
                if let issue {
                    continuation.resume(throwing: issue)
                } else if stopped {
                    continuation.resume(throwing: CancellationError())
                } else {
                    worker.resumeSpeechActivity(onSpeech: onSpeech, onUnavailable: onUnavailable)
                    continuation.resume(returning: ())
                }
            }
        }
    }
    func resumeAdmission() throws {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
        if cancelled { throw CancellationError() }
        generation &+= 1
        accepting = true
    }
    func finish() async throws -> CapturedAudio {
        closeInput(cancel: false)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                lock.lock()
                let error = failure
                let wasCancelled = cancelled
                lock.unlock()
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if wasCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                continuation.resume(with: Result { try worker.finish() })
            }
        }
    }
    func cancel() async {
        closeInput(cancel: true)
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                worker.cancel()
                continuation.resume()
            }
        }
    }
    private func closeInput(cancel: Bool) {
        lock.lock()
        accepting = false
        if cancel { cancelled = true }
        lock.unlock()
    }
    private func fail(_ error: Error) {
        lock.lock()
        failWhileLocked(error)
    }
    // Called with the lock held so a concurrent finish cannot export success
    // between detecting a rejected buffer and recording that failure.
    private func failWhileLocked(_ error: Error) {
        let notify = !cancelled && failure == nil
        if notify {
            failure = error
            accepting = false
        }
        lock.unlock()
        if notify { onError(error) }
    }
    private static func copy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard source.frameLength > 0,
            let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength)
        else { return nil }
        copy.frameLength = source.frameLength
        let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let output = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard input.count == output.count else { return nil }
        for index in input.indices {
            guard let from = input[index].mData, let to = output[index].mData,
                input[index].mDataByteSize <= output[index].mDataByteSize
            else { return nil }
            memcpy(to, from, Int(input[index].mDataByteSize))
            output[index].mDataByteSize = input[index].mDataByteSize
        }
        return copy
    }
}

// Changed from the main actor; sampled only on the serial conversion worker.
// Each recording owns its sink, so draining an old writer cannot feed a new one.
private final class AudioSamplesSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: AudioCapture.SamplesHandler?
    init(_ handler: AudioCapture.SamplesHandler?) { self.handler = handler }
    func set(_ value: AudioCapture.SamplesHandler?) {
        lock.lock()
        handler = value
        lock.unlock()
    }
    func send(_ values: UnsafePointer<Float>, count: Int) {
        lock.lock()
        let callback = handler
        lock.unlock()
        guard let callback else { return }
        callback(Array(UnsafeBufferPointer(start: values, count: count)))
    }
}

/// Internal test seam consumes generated PCM; it cannot open a microphone.
final class AudioCaptureWriter {
    static let sampleRate = 16_000.0
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private var file: AVAudioFile?
    private let directory: URL
    private let url: URL
    private let onLevel: (Float) -> Void
    private var classifier: SpeechClassifier?
    private let classifySpeech: Bool
    private let samplesSink: AudioSamplesSink
    private var frames: Int64 = 0
    private var classifierOrigin: Int64 = 0
    private var exported = false
    private var ended = false
    var fileURL: URL { url }
    #if YULLO_TESTING
        var speechActivityEnabled: Bool { classifier != nil }
    #endif
    // PCM16 disk storage is bounded to 30 minutes (57.6 MB); RAM stays bounded.
    private let maximumFrames: Int64

    init(
        format: AVAudioFormat, maximumDuration: TimeInterval = 1800, classifySpeech: Bool = true,
        onSamples: AudioCapture.SamplesHandler? = nil,
        onLevel: @escaping (Float) -> Void = { _ in }, onSpeech: @escaping (Bool) -> Void = { _ in },
        onSpeechActivityUnavailable: (() -> Void)? = nil,
        onError: @escaping (Error) -> Void = { _ in }
    ) throws {
        guard format.sampleRate > 0, format.channelCount > 0,
            let output = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: format, to: output)
        else { throw AudioCaptureError.conversionFailed }
        self.converter = converter
        self.classifySpeech = classifySpeech
        outputFormat = output
        self.onLevel = onLevel
        samplesSink = AudioSamplesSink(onSamples)
        maximumFrames = Int64(
            (maximumDuration.isFinite ? max(0.001, min(1800, maximumDuration)) : 1800) * Self.sampleRate)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "yullo-recording-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent("speech.wav")
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: Self.sampleRate, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
                ], commonFormat: .pcmFormatFloat32, interleaved: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw AudioCaptureError.recordingFailed
        }
        classifier =
            classifySpeech
            ? SpeechClassifier(
                format: output, onSpeech: onSpeech,
                onUnavailable: onSpeechActivityUnavailable ?? { onError(AudioCaptureError.speechDetectionUnavailable) })
            : nil
    }
    func setSamplesHandler(_ handler: AudioCapture.SamplesHandler?) { samplesSink.set(handler) }
    func pauseSpeechActivity() {
        classifier?.stop()
        classifier = nil
    }
    func resumeSpeechActivity(onSpeech: @escaping (Bool) -> Void, onUnavailable: @escaping () -> Void) {
        guard !ended, classifySpeech else { return }
        classifierOrigin = frames
        classifier = SpeechClassifier(format: outputFormat, onSpeech: onSpeech, onUnavailable: onUnavailable)
    }
    func append(_ input: AVAudioPCMBuffer) throws {
        guard !ended else { throw AudioCaptureError.recordingFailed }
        guard input.frameLength > 0 else { return }
        let capacity = AVAudioFrameCount(
            ceil(Double(input.frameLength) * Self.sampleRate / input.format.sampleRate) + 32)
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: max(32, capacity)) else {
            throw AudioCaptureError.conversionFailed
        }
        var supplied = false, error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, state in
            if supplied {
                state.pointee = .noDataNow
                return nil
            }
            supplied = true
            state.pointee = .haveData
            return input
        }
        guard status != .error, error == nil else { throw AudioCaptureError.conversionFailed }
        try store(converted)
    }
    func finish() throws -> CapturedAudio {
        guard !ended else { throw AudioCaptureError.recordingFailed }
        // Drain the sample-rate converter's small tail without retaining input.
        for _ in 0..<8 {
            guard let tail = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 1024) else {
                throw AudioCaptureError.conversionFailed
            }
            var error: NSError?
            let status = converter.convert(to: tail, error: &error) { _, state in
                state.pointee = .endOfStream
                return nil
            }
            guard status != .error, error == nil else { throw AudioCaptureError.conversionFailed }
            try store(tail)
            if status == .endOfStream || tail.frameLength == 0 { break }
        }
        ended = true
        classifier?.stop()
        file = nil
        guard frames > 0 else { throw AudioCaptureError.emptyRecording }
        exported = true
        return CapturedAudio(url: url, directory: directory, sampleCount: frames)
    }
    func cancel() {
        samplesSink.set(nil)
        ended = true
        classifier?.stop()
        file = nil
        try? FileManager.default.removeItem(at: directory)
    }
    private func store(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.frameLength > 0 else { return }
        guard frames + Int64(buffer.frameLength) <= maximumFrames else { throw AudioCaptureError.recordingTooLong }
        guard let values = buffer.floatChannelData?[0] else { throw AudioCaptureError.conversionFailed }
        var sum: Double = 0
        for i in 0..<Int(buffer.frameLength) {
            let value = values[i].isFinite ? min(1, max(-1, values[i])) : 0
            values[i] = value
            sum += Double(value * value)
        }
        do { try file?.write(from: buffer) } catch { throw AudioCaptureError.recordingFailed }
        samplesSink.send(values, count: Int(buffer.frameLength))
        classifier?.append(buffer, position: frames - classifierOrigin)
        frames += Int64(buffer.frameLength)
        // RMS is used only for the decorative volume meter, never for VAD.
        let rms = sqrt(sum / Double(buffer.frameLength))
        let level = rms > 0 ? Float(min(1, max(0, (20 * log10(rms) + 55) / 45))) : 0
        onLevel(level)
    }
    deinit {
        classifier?.stop()
        if !exported {
            file = nil
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

/// Apple's built-in sound classifier is local and language-independent. Its
/// 0.5-second window (50% overlap) has about 250 ms inference cadence; this is
/// classified speech activity, not a sample-exact endpoint or transcription.
private final class SpeechClassifier: NSObject, SNResultsObserving, @unchecked Sendable {
    private let queue = DispatchQueue(label: "yullo.audio.speech-activity", qos: .userInitiated)
    private let slots = DispatchSemaphore(value: 32)
    private let lock = NSLock()
    private var active = true
    private var analyzer: SNAudioStreamAnalyzer?
    private var labels = Set<String>()
    private var gate = SpeechActivityGate()
    private let onSpeech: (Bool) -> Void
    private let onUnavailable: () -> Void
    private static let speechLabels: Set<String> = [
        "speech", "conversation", "narration", "whispering", "shout", "yell"
    ]

    init(format: AVAudioFormat, onSpeech: @escaping (Bool) -> Void, onUnavailable: @escaping () -> Void) {
        self.onSpeech = onSpeech
        self.onUnavailable = onUnavailable
        super.init()
        queue.async { [self] in
            guard isActive else { return }
            do {
                let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
                labels = Set(request.knownClassifications).intersection(Self.speechLabels)
                guard !labels.isEmpty else { throw AudioCaptureError.speechDetectionUnavailable }
                request.windowDuration = CMTime(seconds: 0.5, preferredTimescale: 48_000)
                request.overlapFactor = 0.5
                let stream = SNAudioStreamAnalyzer(format: format)
                try stream.add(request, withObserver: self)
                analyzer = stream
            } catch { reportFailure() }
        }
    }
    private var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }
    func append(_ buffer: AVAudioPCMBuffer, position: Int64) {
        guard isActive else { return }
        guard slots.wait(timeout: .now()) == .success else {
            reportFailure()
            return
        }
        queue.async { [self] in
            defer { slots.signal() }
            guard isActive else { return }
            analyzer?.analyze(buffer, atAudioFramePosition: position)
        }
    }
    func stop() {
        lock.lock()
        active = false
        lock.unlock()
        queue.async { [self] in
            analyzer?.removeAllRequests()
            analyzer = nil
        }
    }
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        lock.lock()
        guard active else {
            lock.unlock()
            return
        }
        let confidence = result.classifications.filter { labels.contains($0.identifier) }.map(\.confidence).max() ?? 0
        let speech = gate.observe(confidence: confidence)
        lock.unlock()
        onSpeech(speech)
    }
    func request(_ request: SNRequest, didFailWithError error: Error) { reportFailure() }
    private func reportFailure() {
        lock.lock()
        let notify = active
        active = false
        lock.unlock()
        if notify {
            // Release the failed analyzer promptly even while the healthy WAV
            // continues recording until an explicit finish action.
            stop()
            onUnavailable()
        }
    }
}

// Private working folders left by a crash or force quit: recordings, recognition
// and speech helpers, and command-line tasks. Removed at launch, before any
// recording, once they are old enough that no running task can own them.
enum TemporaryLeftovers {
    static let prefixes = [
        "yullo-recording-", "yullo-live-recognition-", "yullo-asr-", "yullo-speech-", "yullo-cli-",
        "yullo-local-translation-"
    ]
    @discardableResult static func sweep(
        in directory: URL = FileManager.default.temporaryDirectory, olderThan age: TimeInterval = 3_600,
        now: Date = Date()
    ) -> Int {
        let manager = FileManager.default
        guard
            let entries = try? manager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey])
        else { return 0 }
        var removed = 0
        for entry in entries where prefixes.contains(where: entry.lastPathComponent.hasPrefix) {
            guard let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .isSymbolicLinkKey]),
                values.isSymbolicLink != true, let modified = values.contentModificationDate,
                now.timeIntervalSince(modified) > age
            else { continue }
            if (try? manager.removeItem(at: entry)) != nil { removed += 1 }
        }
        return removed
    }
}
