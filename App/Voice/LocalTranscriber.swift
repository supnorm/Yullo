import Foundation
import AVFoundation
import OSLog

// Durations and fixed outcome names only; never paths, model IDs or text.
private let localRecognitionLogger = Logger(subsystem: "me.yullo.app", category: "LocalRecognition")

struct LocalTranscriptionResult: Equatable, Sendable {
    let text: String
    let detectedLanguage: String?
    let vocabularyHintsUnavailable: Bool
    init(text: String, detectedLanguage: String?, vocabularyHintsUnavailable: Bool = false) {
        self.text = text
        self.detectedLanguage = detectedLanguage
        self.vocabularyHintsUnavailable = vocabularyHintsUnavailable
    }
}

enum LocalTranscriptionError: Error, LocalizedError, Equatable {
    case runtimeMissing, invalidAudio, noSpeech, busy, failed, invalidOutput, languageRequired, tooLong,
        senseVoiceTooLong
    var errorDescription: String? { L10n.tr(messageKey) }
    var messageKey: String {
        switch self {
        case .runtimeMissing: return "The local speech runtime is missing. Reinstall Yullo."
        case .invalidAudio: return "Couldn’t read the recording. Try recording again."
        case .noSpeech: return "No speech was recorded. Try again."
        case .busy: return "The previous dictation is still stopping. Try again in a moment."
        case .failed: return "Local transcription failed. Try again or choose another model."
        case .invalidOutput: return "The speech model didn’t return a complete transcription."
        case .languageRequired: return "Choose the spoken language for Cohere in Dictation settings."
        case .tooLong: return "This recording is too long for this model. Choose another model in Dictation settings."
        case .senseVoiceTooLong:
            return
                "For recordings longer than 30 seconds, choose Whisper, Qwen3 ASR or Parakeet in Dictation settings."
        }
    }
}

// A recognizer helper started when recording begins loads its model while the
// user speaks, then waits for the finished WAV's path on stdin. Its arguments,
// hints, deadline and output parsing equal an ordinary transcription; only the
// launch moves earlier. It holds the model lease and a private directory until it
// exits. Cancellation, or end of input without a path, kills or ends it.
final class LocalRecognitionReservation: @unchecked Sendable {
    private struct Outcome {
        var status: Int32?
        var stdout = Data()
        var transcript: Data?
    }
    // The bounded stdout of a transcribe batch helper; Whisper writes a file instead.
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) throws {
            try lock.withLock {
                guard chunk.count <= 512 * 1024 - data.count else { throw LocalTranscriptionError.invalidOutput }
                data.append(chunk)
            }
        }
        var value: Data { lock.withLock { data } }
    }
    private let lock = NSLock()
    private let input = CLISubprocessInput(byteLimit: 8192)
    private let library: ModelLibrary
    private let modelID: String
    private let runtime: LocalASRRuntime
    private let hintsUnavailable: Bool
    private let architecture: String?
    private var task: Task<Outcome, Never>?
    private var claimed = false

    fileprivate init(
        library: ModelLibrary, modelID: String, runtime: LocalASRRuntime, architecture: String?,
        hintsUnavailable: Bool
    ) {
        self.library = library
        self.modelID = modelID
        self.runtime = runtime
        self.architecture = architecture
        self.hintsUnavailable = hintsUnavailable
    }

    fileprivate func launch(executable: URL, model: URL, language: String, hints: String) throws {
        let scope = try CLISubprocess.beginRequest()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "yullo-asr-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            scope.finish()
            throw error
        }
        let transcript = directory.appendingPathComponent("transcript")
        let arguments: [String]
        if runtime == .whisper {
            if !hints.isEmpty { input.send(Data((hints + "\n").utf8)) }
            arguments = LocalTranscriber.arguments(
                audioURL: nil, modelURL: model, language: language, outputURL: transcript, vocabularyHints: hints)
        } else {
            // The helper writes the path it receives as this one-row batch list.
            arguments =
                LocalTranscriber.transcribeArguments(
                    modelURL: model, language: language, batchURL: directory.appendingPathComponent("audio.list"))
                + ["--yullo-wait-audio"]
        }
        let library = library, modelID = modelID, input = input, runtime = runtime, output = Output()
        let worker = Task.detached(priority: .userInitiated) { () -> Outcome in
            var outcome = Outcome()
            // Recording (at most 30 minutes) plus the longest transcription deadline.
            if let result = try? await CLISubprocess.runStreaming(
                executable: executable, arguments: arguments, input: input, directory: directory,
                environment: [
                    "PATH": "/usr/bin:/bin", "TMPDIR": directory.path, "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"
                ], timeout: 2460, stderrLimit: 128 * 1024, stdoutChunk: { try output.append($0) })
            {
                outcome.status = result.status
                outcome.stdout = output.value
                let jsonURL = transcript.appendingPathExtension("json")
                if runtime == .whisper, result.status == 0,
                    let values = try? jsonURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                    values.isRegularFile == true, let size = values.fileSize, size <= 1_048_576
                {
                    outcome.transcript = try? Data(contentsOf: jsonURL)
                }
            }
            try? FileManager.default.removeItem(at: directory)
            await library.releaseModel(id: modelID)
            scope.finish()
            return outcome
        }
        lock.withLock { task = worker }
    }

    func finish(audioURL: URL) async throws -> LocalTranscriptionResult {
        let stopped = ProcessInfo.processInfo.systemUptime
        do {
            try Task.checkCancellation()
            let duration = try LocalTranscriber.validateAudio(audioURL)
            // Same refusal as an ordinary run: never degrade a long recording quietly.
            if architecture == "sensevoice", duration > 30 { throw LocalTranscriptionError.senseVoiceTooLong }
            guard (try? LocalTranscriber.transcribeBatch(audioURL: audioURL)) != nil, audioURL.path.utf8.count <= 4096,
                !audioURL.path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
            else { throw LocalTranscriptionError.invalidAudio }
            guard
                let worker = lock.withLock({ () -> Task<Outcome, Never>? in
                    defer { claimed = true }
                    return claimed ? nil : task
                }), input.send(Data((audioURL.path + "\n").utf8))
            else { throw LocalTranscriptionError.failed }
            input.close()
            let watchdog = Task {
                try await Task.sleep(for: .seconds(max(45, min(600, duration * 3 + 45))))
                worker.cancel()
            }
            defer { watchdog.cancel() }
            let outcome = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            guard let status = outcome.status else { throw LocalTranscriptionError.failed }
            let result: LocalTranscriptionResult
            var load: Double?
            if runtime == .whisper {
                guard status == 0 else { throw LocalTranscriptionError.failed }
                guard let transcript = outcome.transcript else { throw LocalTranscriptionError.invalidOutput }
                result = try LocalTranscriber.parse(transcript)
            } else {
                let parsed = try LocalTranscriber.parseTranscribeBatch(
                    outcome.stdout, audioURL: audioURL, status: status)
                result = LocalTranscriptionResult(
                    text: parsed.0.text, detectedLanguage: parsed.0.detectedLanguage,
                    vocabularyHintsUnavailable: hintsUnavailable)
                load = parsed.loadMilliseconds
            }
            LocalTranscriber.logTiming(
                runtime: runtime, outcome: "completed", audio: duration, began: stopped, prepared: stopped,
                load: load, prestarted: true)
            return result
        } catch {
            await cancel()
            throw error
        }
    }

    func cancel() async {
        input.close()
        let worker = lock.withLock { task }
        worker?.cancel()
        _ = await worker?.value
    }
}

// A short-lived isolated helper owns the heavy runtime. Cancellation kills its
// process group via the shared bounded subprocess runner; no shell or network API
// is available in this adapter. An invocation has no earlier-task context;
// explicitly enabled personal hints use only this request's bounded private pipe.
actor LocalTranscriber {
    private let library: ModelLibrary
    private let helperURL: URL
    private let transcribeHelperURL: URL
    private var running = false
    init(library: ModelLibrary = ModelLibrary(), helperURL: URL? = nil, transcribeHelperURL: URL? = nil) {
        self.library = library
        self.helperURL = helperURL ?? RuntimeHelper.url(.whisper)
        self.transcribeHelperURL =
            transcribeHelperURL ?? RuntimeHelper.url(.transcribe)
    }

    // Runs while recording, ahead of the post-Stop helper launch. Verification is
    // cached by file identity, so a first recognition no longer hashes the whole
    // model after Stop. A sequential read then leaves the file in the page cache
    // for the helper's own read; F_RDADVISE pages are speculative and macOS can
    // reclaim them before Stop. Cancelling the recording's warmup stops both.
    nonisolated func warmModel(id: String) async {
        let began = ProcessInfo.processInfo.systemUptime
        guard let model = try? await library.modelURL(id: id), !Task.isCancelled else { return }
        let verified = ProcessInfo.processInfo.systemUptime
        let completed = await ModelFileReadahead().read(model)
        let ended = ProcessInfo.processInfo.systemUptime
        localRecognitionLogger.notice(
            "Model readahead outcome=\(completed ? "completed" : "stopped", privacy: .public) verify_ms=\(Int(((verified - began) * 1000).rounded()), privacy: .public) read_ms=\(Int(((ended - verified) * 1000).rounded()), privacy: .public)"
        )
    }

    // Starts the recognizer's helper while recording; nil keeps the ordinary
    // path after Stop (a missing helper or model, a Cohere model without a
    // spoken language, or a busy transcriber).
    func reserve(modelID: String, languageHint: String? = nil, vocabularyHints: String = "") async
        -> LocalRecognitionReservation?
    {
        guard !running, let runtime = try? await library.runtime(id: modelID), runtime.task == .dictation else {
            return nil
        }
        let executable = runtime == .whisper ? helperURL : transcribeHelperURL
        guard FileManager.default.isExecutableFile(atPath: executable.path),
            let language = try? Self.validatedLanguage(languageHint, runtime: runtime),
            let model = try? await library.acquireModel(id: modelID)
        else { return nil }
        let architecture = runtime == .transcribe ? try? ModelLibrary.ggufArchitecture(model) : nil
        guard runtime == .whisper || (architecture != nil && !(architecture == "cohere_asr" && language == "auto"))
        else {
            await library.releaseModel(id: modelID)
            return nil
        }
        let reservation = LocalRecognitionReservation(
            library: library, modelID: modelID, runtime: runtime, architecture: architecture,
            hintsUnavailable: runtime != .whisper && !vocabularyHints.isEmpty)
        do {
            try reservation.launch(
                executable: executable, model: model, language: language,
                hints: runtime == .whisper ? Self.validatedVocabularyHints(vocabularyHints) : "")
            return reservation
        } catch {
            await library.releaseModel(id: modelID)
            return nil
        }
    }

    func transcribe(
        audioURL: URL, modelID: String, languageHint: String? = nil, vocabularyHints: String = ""
    ) async throws
        -> LocalTranscriptionResult
    {
        try Task.checkCancellation()
        guard !running else { throw LocalTranscriptionError.busy }
        running = true
        defer { running = false }
        let began = ProcessInfo.processInfo.systemUptime
        let runtime = try await library.runtime(id: modelID)
        guard runtime.task == .dictation else { throw ModelLibraryError.taskMismatch }
        let executable = runtime == .whisper ? helperURL : transcribeHelperURL
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw LocalTranscriptionError.runtimeMissing
        }
        let duration = try Self.validateAudio(audioURL)
        let language = try Self.validatedLanguage(languageHint, runtime: runtime)
        let model = try await library.acquireModel(id: modelID)
        // Preparation includes verification, which hashes a model whose file identity is not yet verified.
        let prepared = ProcessInfo.processInfo.systemUptime
        do {
            if runtime == .transcribe {
                let architecture = try ModelLibrary.ggufArchitecture(model)
                if architecture == "cohere_asr", language == "auto" { throw LocalTranscriptionError.languageRequired }
                // The upstream adapter only warns beyond its training window.
                // Do not quietly turn a long recording into degraded text.
                if architecture == "sensevoice", duration > 30 { throw LocalTranscriptionError.senseVoiceTooLong }
            }
            let (result, loadMilliseconds) = try await run(
                audioURL: audioURL, modelURL: model, language: language, duration: duration,
                runtime: runtime, executable: executable, vocabularyHints: vocabularyHints)
            await library.releaseModel(id: modelID)
            Self.logTiming(
                runtime: runtime, outcome: "completed", audio: duration, began: began, prepared: prepared,
                load: loadMilliseconds)
            return LocalTranscriptionResult(
                text: result.text, detectedLanguage: result.detectedLanguage,
                vocabularyHintsUnavailable: runtime != .whisper && !vocabularyHints.isEmpty)
        } catch {
            await library.releaseModel(id: modelID)
            Self.logTiming(
                runtime: runtime, outcome: error is CancellationError ? "cancelled" : "failed", audio: duration,
                began: began, prepared: prepared, load: nil)
            throw error
        }
    }
    static func logTiming(
        runtime: LocalASRRuntime, outcome: StaticString, audio: Double, began: TimeInterval, prepared: TimeInterval,
        load: Double?, prestarted: Bool = false
    ) {
        let ended = ProcessInfo.processInfo.systemUptime
        func milliseconds(_ seconds: Double) -> Int { Int((seconds * 1000).rounded()) }
        // load_ms is reported only by the transcribe batch helper; -1 means unavailable.
        localRecognitionLogger.notice(
            "Recognition timing runtime=\(runtime.rawValue, privacy: .public) outcome=\(outcome, privacy: .public) audio_ms=\(milliseconds(audio), privacy: .public) prepare_ms=\(milliseconds(prepared - began), privacy: .public) helper_ms=\(milliseconds(ended - prepared), privacy: .public) load_ms=\(load.map { Int($0.rounded()) } ?? -1, privacy: .public) total_ms=\(milliseconds(ended - began), privacy: .public) prestarted=\(prestarted ? 1 : 0, privacy: .public)"
        )
    }

    private func run(
        audioURL: URL, modelURL: URL, language: String, duration: Double,
        runtime: LocalASRRuntime, executable: URL, vocabularyHints: String
    ) async throws -> (LocalTranscriptionResult, loadMilliseconds: Double?) {
        let request = try CLISubprocess.beginRequest()
        defer { request.finish() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "yullo-asr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("transcript")
        let arguments: [String]
        let hints = runtime == .whisper ? Self.validatedVocabularyHints(vocabularyHints) : ""
        if runtime == .whisper {
            arguments = Self.arguments(
                audioURL: audioURL, modelURL: modelURL, language: language, outputURL: output,
                vocabularyHints: hints)
        } else {
            // The upstream single-file CLI writes metadata to stdout. A one-row
            // batch produces a structured result without prompts or prior text.
            let list = directory.appendingPathComponent("audio.list")
            try Self.transcribeBatch(audioURL: audioURL).write(to: list, atomically: true, encoding: .utf8)
            arguments = Self.transcribeArguments(modelURL: modelURL, language: language, batchURL: list)
        }
        let result: CLISubprocessResult
        do {
            result = try await CLISubprocess.run(
                executable: executable, arguments: arguments,
                input: Data(hints.utf8),
                directory: directory,
                environment: [
                    "PATH": "/usr/bin:/bin", "TMPDIR": directory.path,
                    "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"
                ],
                timeout: max(45, min(600, duration * 3 + 45)), stdoutLimit: 512 * 1024, stderrLimit: 128 * 1024)
        } catch is CancellationError { throw CancellationError() } catch {
            if Task.isCancelled { throw CancellationError() }
            throw LocalTranscriptionError.failed
        }
        try Task.checkCancellation()
        if runtime == .transcribe {
            return try Self.parseTranscribeBatch(result.stdout, audioURL: audioURL, status: result.status)
        }
        guard result.status == 0 else { throw LocalTranscriptionError.failed }
        let jsonURL = output.appendingPathExtension("json")
        guard let values = try? jsonURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
            values.isRegularFile == true, let size = values.fileSize, size <= 1_048_576,
            let data = try? Data(contentsOf: jsonURL)
        else { throw LocalTranscriptionError.invalidOutput }
        return (try Self.parse(data), nil)
    }

    static func arguments(
        audioURL: URL?, modelURL: URL, language: String, outputURL: URL, vocabularyHints: String = ""
    ) -> [String] {
        // Without an audio URL the helper reads the finished WAV's path from stdin.
        var arguments = [
            "--model", modelURL.path, "--file", audioURL?.path ?? "-", "--language", language,
            "--output-json", "--output-file", outputURL.path, "--no-prints", "--no-timestamps",
            "--threads", "4", "--max-context", "0", "--temperature", "0", "--no-speech-thold", "0.6",
            "--beam-size", "1", "--best-of", "1"
        ]
        if !validatedVocabularyHints(vocabularyHints).isEmpty { arguments.append("--yullo-hints-stdin") }
        if audioURL == nil { arguments.append("--yullo-wait-audio") }
        return arguments
    }
    static func validatedVocabularyHints(_ text: String) -> String {
        guard !text.isEmpty, text.utf8.count <= 192,
            !text.contains("<|"), !text.contains("|>"),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !text.unicodeScalars.contains(where: {
                [.control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
            })
        else { return "" }
        return text
    }
    static func transcribeArguments(modelURL: URL, language: String, batchURL: URL) -> [String] {
        var arguments = [
            "--model", modelURL.path, "--batch", batchURL.path, "--batch-jsonl", "--quiet",
            "--threads", "4", "--timestamps", "none"
        ]
        // Empty/omitted is auto-detect in transcribe.cpp. Literal "auto" is
        // interpreted as a language hint and is unsupported by several families.
        if language != "auto" { arguments += ["--language", language] }
        return arguments
    }
    static func transcribeBatch(audioURL: URL) throws -> String {
        let path = audioURL.path
        guard audioURL.isFileURL, path.hasPrefix("/"), !path.contains("\n"), !path.contains("\r"),
            !path.contains("\0"), path == path.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw LocalTranscriptionError.invalidAudio
        }
        return path + "\n"
    }
    static func parseTranscribe(_ data: Data, audioURL: URL, status: Int32 = 0) throws -> LocalTranscriptionResult {
        try parseTranscribeBatch(data, audioURL: audioURL, status: status).0
    }
    // Also returns the helper's optional model-load duration for timing diagnostics.
    static func parseTranscribeBatch(_ data: Data, audioURL: URL, status: Int32 = 0) throws
        -> (LocalTranscriptionResult, loadMilliseconds: Double?)
    {
        guard data.count <= 512 * 1024, let value = String(data: data, encoding: .utf8) else {
            throw LocalTranscriptionError.invalidOutput
        }
        let lines = value.split(separator: "\n", omittingEmptySubsequences: true)
        guard (1...2).contains(lines.count), let first = lines.first else {
            throw LocalTranscriptionError.invalidOutput
        }
        var loadMilliseconds: Double?
        if lines.count == 2 {
            guard let header = try? JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any],
                Set(header.keys) == ["type", "load_ms"], header["type"] as? String == "batch_header",
                let load = header["load_ms"] as? NSNumber, CFGetTypeID(load) != CFBooleanGetTypeID(),
                load.doubleValue.isFinite, load.doubleValue >= 0
            else { throw LocalTranscriptionError.invalidOutput }
            loadMilliseconds = load.doubleValue
        }
        let row = lines[lines.count - 1]
        guard let object = try? JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: Any],
            object["file"] as? String == audioURL.path
        else { throw LocalTranscriptionError.invalidOutput }
        if let error = object["error"] as? String,
            error == "input audio too long for model context" || error == "INPUT_TOO_LONG"
        {
            throw LocalTranscriptionError.tooLong
        }
        guard status == 0 else { throw LocalTranscriptionError.failed }
        guard
            object["type"] == nil, object["file"] as? String == audioURL.path, object["error"] == nil,
            let text = object["text"] as? String, text.utf8.count <= 262_144
        else {
            // A truncated/repeating batch can still exit zero. Never insert its
            // partial result or console metadata as a successful transcription.
            throw LocalTranscriptionError.invalidOutput
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalTranscriptionError.noSpeech
        }
        // Upstream text already excludes model control/language tags. Do not
        // rewrite mixed languages, punctuation, whitespace or the user's words.
        return (LocalTranscriptionResult(text: text, detectedLanguage: nil), loadMilliseconds)
    }
    static func validatedLanguage(_ hint: String?, runtime: LocalASRRuntime = .whisper) throws -> String {
        guard let hint, hint != "auto", !hint.isEmpty else { return "auto" }
        let code = runtime == .whisper ? (hint == "fil" ? "tl" : hint == "nb" ? "no" : hint) : hint
        // Trusted language IDs only; callers cannot pass arbitrary helper options.
        guard code.range(of: "^[a-z]{2,3}$", options: .regularExpression) != nil else {
            throw LocalTranscriptionError.invalidAudio
        }
        return code
    }
    static func parse(_ data: Data) throws -> LocalTranscriptionResult {
        guard data.count <= 1_048_576,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let segments = object["transcription"] as? [[String: Any]], !segments.isEmpty,
            segments.count <= 10_000
        else { throw LocalTranscriptionError.invalidOutput }
        var text = ""
        for segment in segments {
            guard let part = segment["text"] as? String else { throw LocalTranscriptionError.invalidOutput }
            text += part
            guard text.utf8.count <= 262_144 else { throw LocalTranscriptionError.invalidOutput }
        }
        // Whitespace supplied by the recognizer is preserved. No filler removal,
        // spelling cleanup, translation or language normalization is performed.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalTranscriptionError.noSpeech
        }
        let detected = (object["result"] as? [String: Any])?["language"] as? String
        return LocalTranscriptionResult(text: text, detectedLanguage: detected)
    }
    static func validateAudio(_ url: URL) throws -> Double {
        guard url.isFileURL, let file = try? AVAudioFile(forReading: url),
            file.processingFormat.channelCount == 1, abs(file.processingFormat.sampleRate - 16000) < 1,
            file.length > 0, file.length <= 16000 * 1800,
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)
        else { throw LocalTranscriptionError.invalidAudio }
        var peak: Float = 0
        while file.framePosition < file.length {
            try Task.checkCancellation()
            do { try file.read(into: buffer) } catch { throw LocalTranscriptionError.invalidAudio }
            guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else {
                throw LocalTranscriptionError.invalidAudio
            }
            for index in 0..<Int(buffer.frameLength) {
                let value = samples[index]
                guard value.isFinite else { throw LocalTranscriptionError.invalidAudio }
                peak = max(peak, abs(value))
            }
        }
        guard peak > 0.00001 else { throw LocalTranscriptionError.noSpeech }
        return Double(file.length) / 16000
    }
}

// Cancellation resumes the caller at once; the utility reader stops after its
// current 1 MiB chunk and owns its descriptor and buffer until then.
final class ModelFileReadahead: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var waiter: CheckedContinuation<Bool, Never>?
    func read(_ url: URL) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let stopped = lock.withLock {
                    waiter = continuation
                    return self.stopped
                }
                if stopped {
                    resume(false)
                } else {
                    DispatchQueue.global(qos: .utility).async { self.resume(self.readSequentially(url)) }
                }
            }
        } onCancel: {
            lock.withLock { stopped = true }
            resume(false)
        }
    }
    private func resume(_ completed: Bool) {
        let continuation = lock.withLock {
            defer { waiter = nil }
            return waiter
        }
        continuation?.resume(returning: completed)
    }
    private func readSequentially(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        // Page in at most a quarter of physical memory ahead of the helper's own load.
        var info = stat()
        guard fstat(descriptor, &info) == 0,
            UInt64(max(0, info.st_size)) <= ProcessInfo.processInfo.physicalMemory / 4
        else { return false }
        let size = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16_384)
        defer { buffer.deallocate() }
        while !lock.withLock({ stopped }) {
            let count = Darwin.read(descriptor, buffer, size)
            if count == 0 { return true }
            if count < 0 && errno != EINTR { return false }
        }
        return false
    }
}
