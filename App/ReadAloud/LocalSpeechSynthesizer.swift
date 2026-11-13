import Foundation
import AVFoundation
import NaturalLanguage

enum LocalSpeechError: Error, LocalizedError, Equatable {
    case model, runtime, language, voice, input, tooLong, reference, failed, audio
    var errorDescription: String? {
        switch self {
        case .model: return L10n.tr("Choose a downloaded local speech model.")
        case .runtime: return L10n.tr("The local speech runtime is missing. Reinstall Yullo.")
        case .language: return L10n.tr("This speech model doesn’t support this language.")
        case .voice: return L10n.tr("Choose an available voice for this speech model.")
        case .input: return L10n.tr("Enter some text to read aloud.")
        case .tooLong: return L10n.tr("This passage is too long for the local speech model. Try a shorter passage.")
        case .reference:
            return L10n.tr("Choose a clear voice sample between 0.5 and 30 seconds in Read aloud settings.")
        case .failed: return L10n.tr("Local speech generation failed. Try another voice or model.")
        case .audio: return L10n.tr("The speech model returned no playable audio.")
        }
    }
}

// One isolated native helper keeps the verified model loaded and receives one
// private JSON request at a time. It has no account, credential, editor or
// conversation context, and cannot download model weights. A warm helper is
// reused only for the same model file, and is released after a minute unused,
// under memory pressure, after a failure or cancellation, and at app exit.
actor LocalSpeechSynthesizer {
    static let shared = LocalSpeechSynthesizer(library: .shared)
    private let library: ModelLibrary
    private let helperURL: URL
    private let sampleVoiceURL: URL
    private let pronunciationDataURL: URL
    nonisolated static let sampleVoiceText =
        "A clear voice makes every word easy to follow. Take a moment, and listen at a comfortable pace."
    private let idleSeconds: TimeInterval
    private var operation: Task<Data, Error>?
    private var requestID = UUID()
    private var helper: CLIServeHelper?
    private var helperUse = UUID()
    private var memoryPressure: DispatchSourceMemoryPressure?

    init(
        library: ModelLibrary, helperURL: URL? = nil, sampleVoiceURL: URL? = nil, pronunciationDataURL: URL? = nil,
        idleSeconds: TimeInterval = 60
    ) {
        self.library = library
        self.idleSeconds = idleSeconds.isFinite ? min(600, max(0, idleSeconds)) : 60
        self.helperURL = helperURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/yullo-speech")
        self.sampleVoiceURL =
            sampleVoiceURL
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Audio/YulloSampleVoice.wav")
        self.pronunciationDataURL =
            pronunciationDataURL
            ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/LocalSpeech/espeak-ng-data.bin")
    }

    nonisolated static func requiresReferenceAudio(modelID: String) -> Bool { modelID == "cosyvoice3-q8" }
    nonisolated static func voices(modelID: String, language: String) -> [SpeechVoice] {
        LocalSpeechVoiceCatalog.voiceIDs(modelID: modelID, language: language).map {
            let details = LocalSpeechVoiceCatalog.details(for: $0, modelID: modelID)
            return SpeechVoice(
                id: $0, name: LocalSpeechVoiceCatalog.name(for: $0, modelID: modelID), languageCodes: [language],
                gender: details?.gender.rawValue,
                accent: details.map { LocalSpeechVoiceCatalog.varietyName($0.variety) })
        }
    }
    // Longer passages start with their first sentences so playback can begin
    // while the warm helper generates the rest. Short passages stay whole: they
    // would gain little from a second request.
    nonisolated static func leadingSegment(_ text: String) -> (first: String, rest: String?) {
        guard text.count >= 160 else { return (text, nil) }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var end = text.startIndex
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            end = range.upperBound
            return text.distance(from: text.startIndex, to: end) < 40
        }
        let rest = String(text[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard end < text.endIndex, text.distance(from: text.startIndex, to: end) <= 240, !rest.isEmpty
        else { return (text, nil) }
        return (String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines), rest)
    }
    nonisolated static func playbackRate(modelID: String, rate: Double) -> Float {
        modelID == "kokoro-82m-q8" ? 1 : Float(rate.isFinite ? min(2, max(0.5, rate)) : 1)
    }

    func synthesize(
        text: String, language: String, modelID: String, voiceID: String, rate: Double,
        referenceAudioURL: URL? = nil
    ) async throws -> Data {
        try Task.checkCancellation()
        let id = UUID()
        requestID = id
        let previous = operation
        previous?.cancel()
        if let previous { _ = try? await previous.value }
        try Task.checkCancellation()
        guard requestID == id else { throw CancellationError() }
        let work = Task {
            try await self.generate(
                text: text, language: language, modelID: modelID,
                voiceID: voiceID, rate: rate, referenceAudioURL: referenceAudioURL)
        }
        operation = work
        defer { if requestID == id { operation = nil } }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func generate(
        text: String, language: String, modelID: String, voiceID: String, rate: Double,
        referenceAudioURL: URL?
    ) async throws -> Data {
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !text.contains("\0") else {
            throw LocalSpeechError.input
        }
        guard text.utf8.count <= 32_768 else { throw LocalSpeechError.tooLong }
        let family = try Self.family(modelID)
        let code = Self.normalizedLanguage(language)
        let available = Self.voices(modelID: modelID, language: language)
        let voice: String
        if family == "cosyvoice3" {
            guard ["zh", "en", "ja", "ko", "de", "es", "fr", "it", "ru", "yue"].contains(code) else {
                throw LocalSpeechError.language
            }
            voice = ""
        } else {
            guard !available.isEmpty else { throw LocalSpeechError.language }
            let selected = voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = selected.isEmpty ? available.first : available.first(where: { $0.id == selected }) else {
                throw LocalSpeechError.voice
            }
            voice = value.id
        }
        guard try await library.task(id: modelID) == .readAloud,
            try await library.runtime(id: modelID) == .audioSpeech
        else { throw LocalSpeechError.model }
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else { throw LocalSpeechError.runtime }
        if family == "kokoro_tts" {
            guard pronunciationDataURL.isFileURL,
                let data = try? pronunciationDataURL.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
                ]),
                data.isRegularFile == true, data.isSymbolicLink != true, let size = data.fileSize,
                size > 0, size <= 64 * 1_024 * 1_024
            else { throw LocalSpeechError.runtime }
        }
        let model = try await library.acquireModel(id: modelID)
        do {
            let audio = try await run(
                text: text, language: LocalSpeechVoiceCatalog.requestLanguage(code, voiceID: voice, modelID: modelID),
                family: family, model: model, voice: voice,
                rate: rate, referenceAudioURL: referenceAudioURL)
            await library.releaseModel(id: modelID)
            return audio
        } catch {
            await library.releaseModel(id: modelID)
            throw error
        }
    }

    // Test and diagnostic visibility only; returns whether a helper is warm.
    var hasWarmHelper: Bool { helper?.isRunning == true }

    func retireHelper() async {
        helperUse = UUID()
        let current = helper
        helper = nil
        await current?.stopAndWait()
    }

    private func warmHelper(identity: String, family: String, model: URL) async throws -> CLIServeHelper {
        // At most one helper process exists: a different or stopped one has
        // fully exited, and its private directory is gone, before a replacement.
        while let current = helper, current.identity != identity || !current.isRunning { await retireHelper() }
        if let helper { return helper }
        // eSpeak 1.52 has a 160-byte data-path buffer. macOS user temp roots
        // plus its nested data directories exceed that limit, so retain the
        // full random private helper ID under the short system temp anchor.
        let launched = CLIServeHelper(
            identity: identity,
            directory: URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                .appendingPathComponent("yullo-speech-\(UUID().uuidString)", isDirectory: true),
            inputLimit: 16_384)
        var environment = [
            "PATH": "/usr/bin:/bin", "TMPDIR": launched.directory.path,
            "XDG_CACHE_HOME": launched.directory.appendingPathComponent("cache").path, "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8"
        ]
        // The data package is a signed bundle resource, not executable code.
        // Kokoro's upstream G2P accepts this exact explicit override.
        if family == "kokoro_tts" { environment["AUDIOCPP_ESPEAK_DATA"] = pronunciationDataURL.path }
        try launched.launch(
            executable: helperURL, arguments: Self.arguments(family: family, model: model), environment: environment)
        helper = launched
        observeMemoryPressure()
        return launched
    }

    private func scheduleRetirement() {
        let use = UUID()
        helperUse = use
        let delay = idleSeconds
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.retireIfIdle(use)
        }
    }

    private func retireIfIdle(_ use: UUID? = nil) async {
        guard use == nil || helperUse == use, operation == nil, helper != nil else { return }
        await retireHelper()
    }

    // A warm speech model holds about a gigabyte; give it back under pressure.
    private func observeMemoryPressure() {
        guard memoryPressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
        source.setEventHandler { [weak self] in
            Task { await self?.retireIfIdle() }
        }
        source.resume()
        memoryPressure = source
    }

    private func run(
        text: String, language: String, family: String, model: URL, voice: String, rate: Double,
        referenceAudioURL: URL?
    ) async throws -> Data {
        guard let identity = CLIServeHelper.fileIdentity(model) else { throw LocalSpeechError.model }
        helperUse = UUID()
        let helper: CLIServeHelper
        do {
            helper = try await warmHelper(identity: family + "\n" + identity, family: family, model: model)
        } catch is CancellationError { throw CancellationError() } catch { throw LocalSpeechError.failed }
        // Every exit that keeps this helper restarts its idle countdown.
        defer { if self.helper === helper { scheduleRetirement() } }
        // Each passage has its own private request directory inside the helper's.
        let directory = helper.directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            // The helper exited and removed its directory since it was checked.
            await retireHelper()
            throw LocalSpeechError.failed
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        let reference: URL?
        let referencePrompt: String?
        if family == "cosyvoice3" {
            let target = directory.appendingPathComponent("reference.wav")
            try Self.prepareReference(referenceAudioURL ?? sampleVoiceURL, destination: target)
            reference = target
            referencePrompt = referenceAudioURL == nil ? Self.sampleVoiceText : nil
        } else {
            reference = nil
            referencePrompt = nil
        }
        let input = directory.appendingPathComponent("request.json"),
            output = directory.appendingPathComponent("speech.wav")
        let data = try Self.request(
            text: text, language: language, family: family, voice: voice, rate: rate,
            reference: reference, referencePrompt: referencePrompt)
        try data.write(to: input, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
        // The line names only private files; the passage stays in request.json.
        let line = try JSONSerialization.data(
            withJSONObject: ["request": input.path, "out": output.path], options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let answer: Data
        do {
            answer = try await helper.request(line, timeout: min(600, max(60, Double(text.count) * 0.3 + 45)))
        } catch {
            await retireHelper()
            try Task.checkCancellation()
            throw LocalSpeechError.failed
        }
        guard Self.completed(answer) else {
            await retireHelper()
            try Task.checkCancellation()
            throw LocalSpeechError.failed
        }
        try Task.checkCancellation()
        return try Self.readAudio(output)
    }

    nonisolated static func completed(_ answer: Data) -> Bool {
        guard let value = try? JSONSerialization.jsonObject(with: answer) as? [String: Any],
            Set(value.keys) == ["complete"], let complete = value["complete"] as? NSNumber,
            CFGetTypeID(complete) == CFBooleanGetTypeID()
        else { return false }
        return complete.boolValue
    }

    // Every family uses Metal. A warm Kokoro passage measured 2–3.5 times
    // faster than on four CPU threads, with matching loudness and spectra.
    // Two, four or six threads made no measurable difference on Metal.
    nonisolated static func arguments(family: String, model: URL) -> [String] {
        ["--family", family, "--model", model.path, "--backend", "metal", "--threads", "4", "--serve"]
    }
    nonisolated static func request(
        text: String, language: String, family: String, voice: String,
        rate: Double, reference: URL?, referencePrompt: String? = nil
    ) throws -> Data {
        var value: [String: Any] = ["id": "utterance", "text": text]
        if family != "cosyvoice3" { value["language"] = language }
        // Keep native per-family chunking: Kokoro uses smaller CJK chunks to
        // stay inside its phoneme context, while other families own their caps.
        var options: [String: Any] = [:]
        if !voice.isEmpty { value["voice_id"] = voice }
        if family == "kokoro_tts" { options["speed"] = rate.isFinite ? min(2, max(0.5, rate)) : 1 }
        if family == "cosyvoice3" {
            guard let reference else { throw LocalSpeechError.reference }
            value["voice_ref"] = reference.path
            if language == "yue" {
                options["template_name"] = "instruct"
                options["instruct"] = "请用粤语朗读。"
            } else if let referencePrompt {
                options["template_name"] = "zero_shot"
                options["reference_text"] = referencePrompt
            } else {
                options["template_name"] = "cross_lingual"
            }
        }
        value["options"] = options
        return try JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys])
    }
    nonisolated private static func family(_ model: String) throws -> String {
        switch model {
        case "kokoro-82m-q8": return "kokoro_tts"
        case "qwen3-tts-customvoice-q8": return "qwen3_tts"
        case "cosyvoice3-q8": return "cosyvoice3"
        default: throw LocalSpeechError.model
        }
    }
    nonisolated private static func normalizedLanguage(_ language: String) -> String {
        let code = Language.speechCode(language)
        return code == "zh-Hant" ? "zh" : code
    }
    nonisolated static func readAudio(_ url: URL) throws -> Data {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
            values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
            size > 44, size <= 32 * 1_024 * 1_024,
            let audio = try? AVAudioFile(forReading: url), audio.length > 0,
            audio.processingFormat.channelCount == 1, audio.processingFormat.sampleRate.isFinite,
            audio.processingFormat.sampleRate >= 16_000, audio.processingFormat.sampleRate <= 48_000,
            Double(audio.length) / audio.processingFormat.sampleRate <= 600,
            let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 4096)
        else { throw LocalSpeechError.audio }
        var peak: Float = 0
        while audio.framePosition < audio.length {
            try Task.checkCancellation()
            try audio.read(into: buffer)
            guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else {
                throw LocalSpeechError.audio
            }
            for index in 0..<Int(buffer.frameLength) {
                guard samples[index].isFinite else { throw LocalSpeechError.audio }
                peak = max(peak, abs(samples[index]))
            }
        }
        guard peak > 0.00001 else { throw LocalSpeechError.audio }
        return try Data(contentsOf: url)
    }
    nonisolated private static func prepareReference(_ source: URL, destination: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard source.isFileURL,
            let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
            values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize,
            size <= 64 * 1_024 * 1_024,
            let file = try? AVAudioFile(forReading: source), file.processingFormat.sampleRate > 0,
            file.processingFormat.sampleRate <= 192_000, file.processingFormat.channelCount <= 2,
            Double(file.length) / file.processingFormat.sampleRate >= 0.5,
            Double(file.length) / file.processingFormat.sampleRate <= 30,
            let input = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: file.processingFormat, to: format),
            let output = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(
                    ceil(Double(file.length) * 24_000 / file.processingFormat.sampleRate) + 32))
        else { throw LocalSpeechError.reference }
        do {
            try file.read(into: input)
            var supplied = false, error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                if supplied {
                    state.pointee = .endOfStream
                    return nil
                }
                supplied = true
                state.pointee = .haveData
                return input
            }
            guard status != .error, error == nil, output.frameLength > 0, let samples = output.floatChannelData?[0]
            else { throw LocalSpeechError.reference }
            var peak: Float = 0
            for index in 0..<Int(output.frameLength) {
                guard samples[index].isFinite else { throw LocalSpeechError.reference }
                peak = max(peak, abs(samples[index]))
            }
            guard peak > 0.00001 else { throw LocalSpeechError.reference }
            let target = try AVAudioFile(
                forWriting: destination,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
                ], commonFormat: .pcmFormatFloat32, interleaved: false)
            try target.write(from: output)
        } catch is CancellationError { throw CancellationError() } catch { throw LocalSpeechError.reference }
    }
}
