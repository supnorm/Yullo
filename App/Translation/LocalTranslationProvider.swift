import Foundation
import CoreFoundation

enum LocalTranslationIssue: Error, LocalizedError, Equatable {
    case unavailable, runtimeMissing, busy, inputTooLong, sourceRequired, unsupportedLanguage, failed, invalidOutput
    var errorDescription: String? {
        let key: String
        switch self {
        case .unavailable: key = "Download or import a local translation model first."
        case .runtimeMissing: key = "The local translation runtime is missing. Reinstall Yullo."
        case .busy: key = "Local translation is still stopping. Try again in a moment."
        case .inputTooLong: key = "This text is too long for the local model. Try a shorter passage."
        case .sourceRequired: key = "Choose one source language for this local model."
        case .unsupportedLanguage: key = "This local model doesn’t support that language."
        case .failed: key = "Local translation failed. Try another model."
        case .invalidOutput: key = "The local model didn’t return a complete translation."
        }
        return L10n.tr(key)
    }
}

// One isolated helper owns each model; a warm helper is reused only for the same
// model file identity. Only the current literal text and trusted task/language
// metadata enter stdin; no UI, history, credentials or CLI configuration is
// visible to the local runtime, and no request state carries over.
actor LocalTranslationProvider {
    static let shared = LocalTranslationProvider()
    private let library: ModelLibrary
    private let helperURL: URL
    private let timeout: TimeInterval
    private let idleSeconds: TimeInterval
    private var operation: Task<String, Error>?
    private var requestID = UUID()
    private var helper: CLIServeHelper?
    private var helperUse = UUID()
    private var memoryPressure: DispatchSourceMemoryPressure?
    // Publisher-listed Hy-MT2 coverage. Filipino uses the app's canonical fil
    // identifier; the publisher lists it as tl. Keep scripts and Cantonese
    // distinct, and do not infer support from the full app language catalog.
    private static let hyMTLanguages: Set<String> = [
        "zh", "en", "fr", "pt", "es", "ja", "tr", "ru", "ar", "ko", "th", "it", "de", "vi", "ms", "id", "fil", "hi",
        "zh-Hant", "pl", "cs", "nl", "km", "my", "fa", "gu", "ur", "te", "mr", "he", "bn", "ta", "uk", "bo", "kk", "mn",
        "ug", "yue"
    ]
    init(
        library: ModelLibrary = .shared, helperURL: URL? = nil, timeout: TimeInterval = 180,
        idleSeconds: TimeInterval = 60
    ) {
        self.library = library
        self.helperURL = helperURL ?? RuntimeHelper.url(.llama)
        self.timeout = timeout.isFinite ? min(600, max(1, timeout)) : 180
        self.idleSeconds = idleSeconds.isFinite ? min(600, max(0, idleSeconds)) : 60
    }

    // Loads the selected model in the background before a request arrives, for
    // example while the user is still typing. No text is sent.
    func prepare(modelID: String) async {
        guard operation == nil, FileManager.default.isExecutableFile(atPath: helperURL.path),
            (try? await library.task(id: modelID)) == .translation,
            (try? await library.runtime(id: modelID)) == .llama,
            let model = try? await library.acquireModel(id: modelID)
        else { return }
        if operation == nil, let identity = CLIServeHelper.fileIdentity(model),
            (try? await warmHelper(identity: identity, model: model)) != nil
        {
            scheduleRetirement()
        }
        await library.releaseModel(id: modelID)
    }

    // Test and diagnostic visibility only; returns whether a helper is warm.
    var hasWarmHelper: Bool { helper?.isRunning == true }

    func retireHelper() async {
        helperUse = UUID()
        let current = helper
        helper = nil
        await current?.stopAndWait()
    }

    private func warmHelper(identity: String, model: URL) async throws -> CLIServeHelper {
        // At most one helper process exists: a different or stopped one has
        // fully exited before a replacement launches.
        while let current = helper, current.identity != identity || !current.isRunning { await retireHelper() }
        if let helper { return helper }
        let launched = CLIServeHelper(
            identity: identity,
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(
                "yullo-local-translation-\(UUID().uuidString)", isDirectory: true))
        try launched.launch(
            executable: helperURL, arguments: ["--model", model.path, "--serve"],
            environment: [
                "PATH": "/usr/bin:/bin", "TMPDIR": launched.directory.path + "/", "LANG": "en_US.UTF-8",
                "LC_ALL": "en_US.UTF-8"
            ])
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

    // A warm model can hold more than a gigabyte; give it back under pressure.
    private func observeMemoryPressure() {
        guard memoryPressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
        source.setEventHandler { [weak self] in
            Task { await self?.retireIfIdle() }
        }
        source.resume()
        memoryPressure = source
    }

    func translate(
        text: String, source: String, target: String, modelID: String,
        terms: [CoreVocabularyTranslationTerm] = []
    ) async throws -> String {
        try Task.checkCancellation()
        let previous = operation
        guard previous == nil || previous?.isCancelled == true else { throw LocalTranslationIssue.busy }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw APIError.empty }
        guard text.utf8.count <= 131_072 else { throw LocalTranslationIssue.inputTooLong }
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw LocalTranslationIssue.runtimeMissing
        }
        let id = UUID()
        requestID = id
        defer { if requestID == id { operation = nil } }
        // Cancellation must finish process, request-directory and model-lease
        // cleanup before a replacement starts another local helper.
        if let previous { _ = try? await previous.value }
        try Task.checkCancellation()
        guard requestID == id else { throw CancellationError() }
        let work = Task {
            try await self.generate(text: text, source: source, target: target, modelID: modelID, terms: terms)
        }
        operation = work
        return try await withTaskCancellationHandler {
            let result = try await work.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            work.cancel()
        }
    }

    private func generate(
        text: String, source: String, target: String, modelID: String, terms: [CoreVocabularyTranslationTerm]
    ) async throws -> String {
        try Task.checkCancellation()
        guard try await library.task(id: modelID) == .translation else { throw LocalTranslationIssue.unavailable }
        guard try await library.runtime(id: modelID) == .llama else { throw LocalTranslationIssue.unavailable }
        let model = try await library.acquireModel(id: modelID)
        do {
            let result = try await run(text: text, source: source, target: target, modelURL: model, terms: terms)
            await library.releaseModel(id: modelID)
            return result
        } catch {
            await library.releaseModel(id: modelID)
            throw error
        }
    }

    private func run(
        text: String, source: String, target: String, modelURL: URL, terms: [CoreVocabularyTranslationTerm]
    ) async throws -> String {
        let started = ProcessInfo.processInfo.systemUptime
        let family = try ModelLibrary.ggufArchitecture(modelURL)
        let profile: String
        switch family {
        case "hunyuan-dense": profile = "hymt"
        case "qwen3": profile = "qwen"
        case "gemma3": profile = "gemma"
        default: throw LocalTranslationIssue.unavailable
        }
        let protection: CoreTermProtection?
        do {
            protection =
                profile == "gemma" && !terms.isEmpty
                ? try CoreTermProtection.make(source: text, terms: terms) : nil
        } catch CoreTermProtectionError.inputTooLong, CoreTermProtectionError.tooManyOccurrences {
            throw LocalTranslationIssue.inputTooLong
        }
        var requestSource = source
        if protection?.active == true, source == "auto" {
            // Source provenance belongs to the original task, before generated markup.
            let languages = InputLanguageAnalysis.detectLanguages(text)
            guard languages.count == 1, let original = languages.first else {
                throw LocalTranslationIssue.sourceRequired
            }
            requestSource = original
        }
        let input = try Self.request(
            text: protection?.text ?? text, source: requestSource, target: target,
            profile: profile, terms: terms, protectionTagName: protection?.active == true ? protection?.tagName : nil)
        func invoke(_ data: Data) async throws -> String {
            try Task.checkCancellation()
            let remaining = timeout - (ProcessInfo.processInfo.systemUptime - started)
            guard remaining > 0 else { throw LocalTranslationIssue.failed }
            guard let identity = CLIServeHelper.fileIdentity(modelURL) else { throw LocalTranslationIssue.unavailable }
            helperUse = UUID()
            let line: Data
            do {
                line = try await warmHelper(identity: identity, model: modelURL).request(data, timeout: remaining)
            } catch {
                await retireHelper()
                try Task.checkCancellation()
                throw LocalTranslationIssue.failed
            }
            try Task.checkCancellation()
            do {
                let text = try Self.parse(line, status: 0)
                scheduleRetirement()
                return text
            } catch LocalTranslationIssue.inputTooLong {
                // A length refusal precedes generation; the long-text planner
                // sends its segments to this same loaded model.
                scheduleRetirement()
                throw LocalTranslationIssue.inputTooLong
            } catch {
                await retireHelper()
                throw error
            }
        }
        let parsed = try await invoke(input)
        guard let protection, protection.active else { return parsed }
        do {
            let restored = try protection.restore(parsed)
            guard !restored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CoreTermProtectionError.invalidMarkers
            }
            try Task.checkCancellation()
            return restored
        } catch CoreTermProtectionError.invalidMarkers {
            guard protection.occurrences.allSatisfy({ $0.source != $0.target }) else {
                throw LocalTranslationIssue.invalidOutput
            }
            try Task.checkCancellation()
            let ordinary = try Self.request(
                text: text, source: requestSource, target: target, profile: profile, terms: terms)
            let result = try await invoke(ordinary)
            try Task.checkCancellation()
            return result
        }
    }

    static func request(
        text: String, source: String, target: String, profile: String,
        terms: [CoreVocabularyTranslationTerm] = [], protectionTagName: String? = nil
    ) throws -> Data {
        guard ["hymt", "qwen", "gemma"].contains(profile) else { throw LocalTranslationIssue.unavailable }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw APIError.empty }
        guard text.utf8.count <= 131_072 else { throw LocalTranslationIssue.inputTooLong }
        var sourceID = source
        if profile == "gemma", sourceID == "auto" {
            let languages = InputLanguageAnalysis.detectLanguages(text)
            guard languages.count == 1, let detected = languages.first else {
                throw LocalTranslationIssue.sourceRequired
            }
            sourceID = detected
        }
        guard profile != "gemma" || (sourceID != "yue" && target != "yue") else {
            throw LocalTranslationIssue.unsupportedLanguage
        }
        var instruction = try TranslationPrompt.instruction(source: sourceID, target: target)
        guard let destination = Language.catalog.first(where: { $0.id == target }),
            sourceID == "auto" || Language.catalog.contains(where: { $0.id == sourceID })
        else { throw APIError.invalidLanguage }
        if profile == "hymt" {
            let sources = sourceID == "auto" ? InputLanguageAnalysis.detectLanguages(text) : [sourceID]
            guard Self.hyMTLanguages.contains(target), sources.allSatisfy(Self.hyMTLanguages.contains) else {
                throw LocalTranslationIssue.unsupportedLanguage
            }
        }
        if profile == "hymt", target == "zh" {
            // Hy-MT2 follows its publisher-style target task more reliably for
            // Traditional-to-Simplified text. Keep the shared source rules and
            // native literal token boundary unchanged.
            instruction =
                "Translate the following text into Simplified Chinese. Note that you should only output the translated result without any additional explanation. "
                + CoreTranslationPrompt.literalSourceRules + " Use simplified Chinese characters."
        }
        // Apply only after every profile-specific instruction is finalized.
        // Values stay in literal task data, including for model role tokens.
        let value = try VocabularyPromptData.make(text: text, terms: terms)
        guard value.text.utf8.count <= 131_072 else { throw LocalTranslationIssue.inputTooLong }
        let sourceName =
            Language.catalog.first(where: { $0.id == sourceID })?.subtitle ?? "automatically detected languages"
        if (profile == "hymt" || profile == "gemma"), !value.instructionSuffix.isEmpty {
            let targetName = target == "zh" ? "Simplified Chinese" : destination.subtitle
            instruction =
                "Translate the source text from \(sourceName) into \(targetName). "
                + CoreTranslationPrompt.glossarySourceRules
            if target == "zh" { instruction += " Use simplified Chinese characters." }
            if target == "zh-Hant" { instruction += " Use traditional Chinese characters." }
            if target == "yue" { instruction += " Use natural written Cantonese in traditional Chinese characters." }
        } else {
            instruction += value.instructionSuffix
        }
        if let protectionTagName {
            guard protectionTagName.first == "x", protectionTagName.utf8.count <= 8,
                protectionTagName.dropFirst().utf8.allSatisfy({ (48...57).contains($0) })
            else { throw LocalTranslationIssue.invalidOutput }
            instruction +=
                " Preserve each paired \(protectionTagName) tag and its id exactly once at the translated name's position. Do not add tag lists."
        }
        func code(_ value: String) -> String { profile == "gemma" && value == "fil" ? "tl" : value }
        var payload: [String: Any] = [
            "text": value.text, "instruction": instruction, "profile": profile,
            "source_name": sourceName, "source_code": code(sourceID), "target_name": destination.subtitle,
            "target_code": code(target)
        ]
        if !value.instructionSuffix.isEmpty { payload["task_data"] = true }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        guard data.count <= 196_608 else { throw LocalTranslationIssue.inputTooLong }
        return data
    }

    static func parse(_ data: Data, status: Int32) throws -> String {
        guard data.count <= 1_048_576,
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw LocalTranslationIssue.invalidOutput }
        if let error = value["error"] as? String {
            switch error {
            case "input_too_long": throw LocalTranslationIssue.inputTooLong
            case "truncated": throw APIError.truncated
            case "unsupported_model": throw LocalTranslationIssue.unavailable
            default: throw LocalTranslationIssue.failed
            }
        }
        guard status == 0, Set(value.keys) == ["text", "complete"],
            let complete = value["complete"] as? NSNumber, CFGetTypeID(complete) == CFBooleanGetTypeID(),
            complete.boolValue,
            let text = value["text"] as? String, text.utf8.count <= 262_144,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw LocalTranslationIssue.invalidOutput }
        return text
    }
}
