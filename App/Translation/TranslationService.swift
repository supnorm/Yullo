import Foundation
import CryptoKit
import NaturalLanguage

struct TranslationSettings: Equatable, Sendable {
    private(set) var engine: String
    let endpoint: String
    let model: String
    let apiStreamingEnabled: Bool
    let cli: CLIConfiguration
    let appleFallback: Bool
    let localTranslationModelID: String
    let authorization: ProcessingAuthorization
    let personalVocabulary: CoreVocabularyConfiguration
    var vocabularyTerms: [CoreVocabularyTranslationTerm] = []
    var jsonValueContext: [String]? = nil
    var protectsJSONStructure = false
    var preserveTechnicalLiterals = false
    var writingRequirements = CoreWritingRequirements.standard
    // An applied preset's own instructions; prompt-based routes (API, CLI) only.
    var presetInstructions: String? = nil
    let signOffName: String
    let ollamaHost: String
    let ollamaModel: String
    let appleWriterFallback: String
    var ollamaOnThisMac: Bool { engine == "ollama" && CoreOllama.isOnThisMac(host: ollamaHost) }
    init(_ preferences: Preferences, engine: String? = nil, processing: ProcessingPolicyController = .shared) {
        self.engine = engine ?? preferences.engine
        endpoint = preferences.endpoint
        model = preferences.model
        apiStreamingEnabled = preferences.apiStreamsTranslations
        cli = preferences.cli
        appleFallback = preferences.appleFallback
        localTranslationModelID = preferences.localTranslationModelID
        authorization = processing.authorization(for: preferences.processingPolicy)
        personalVocabulary = preferences.personalVocabulary
        signOffName = preferences.signOffName
        ollamaHost = preferences.ollamaHost
        ollamaModel = preferences.ollamaModel
        appleWriterFallback = preferences.appleWriterFallback
    }
    // The same settings, writing with another writer.
    func writing(with engine: String) -> Self {
        var value = self
        value.engine = engine
        return value
    }
}

// The macOS composition boundary. Tests and future hosts inject providers;
// credential lookup/storage, subprocesses and Apple frameworks stay in adapters.
// The backup writer's own name, as Write with lists it, so the note names what wrote.
enum BackupWriterNotice {
    static func text(_ settings: TranslationSettings) -> String {
        let name: String
        switch settings.engine {
        case "cli": name = settings.cli.provider.displayName
        case "ollama": name = settings.ollamaModel.isEmpty ? "Ollama" : "Ollama · " + settings.ollamaModel
        default: name = settings.model.isEmpty ? L10n.tr("Online service (API)") : settings.model
        }
        return L10n.format("Written with %@. Apple’s model couldn’t write this.", StandInName.unbroken(name))
    }
}
struct TranslationProviders: Sendable {
    var remote: @Sendable (String, String, String, TranslationSettings) async throws -> String
    var local: @Sendable (String, String, String) async throws -> String
    var model: (@Sendable (String, String, String, String) async throws -> String)? = nil
    var modelWithTerms:
        (@Sendable (String, String, String, String, [CoreVocabularyTranslationTerm]) async throws -> String)? = nil
    var remoteProgress:
        (@Sendable (String, String, String, TranslationSettings, TranslationRemoteOptions) async throws -> String)? =
            nil
    var remoteBatch:
        (@Sendable (CoreJSONTranslationBatch.Batch, String, String, TranslationSettings) async throws -> String)? = nil
    var localBatch: (@Sendable (CoreJSONTranslationBatch.Batch, String, String) async throws -> String)? = nil
    var ollama: (@Sendable (String, String, String, TranslationSettings) async throws -> String)? = nil
    static func system() -> TranslationProviders {
        var providers = systemRemote()
        providers.ollama = { text, from, to, settings in
            try await OllamaClient.shared.translate(
                text: text, from: from, to: to, instructions: settings.presetInstructions,
                target: .init(host: settings.ollamaHost, model: settings.ollamaModel))
        }
        return providers
    }
    private static func systemRemote() -> TranslationProviders {
        let cli = CLIClient.shared
        return TranslationProviders(
            remote: { text, source, target, settings in
                if settings.engine == "cli" {
                    return try await cli.translate(
                        text: text, source: source, target: target, configuration: settings.cli,
                        terms: settings.vocabularyTerms, context: settings.jsonValueContext,
                        instructions: settings.presetInstructions)
                }
                guard settings.engine == "api" else { throw APIError.invalidEndpoint }
                let connection = try APIConnectionSettings(endpoint: settings.endpoint, model: settings.model)
                let key = try await KeyStore.readAsync(connection.endpoint)
                try Task.checkCancellation()
                return try await APIClient().translate(
                    endpoint: connection.endpoint, model: connection.model, key: key,
                    text: text, source: source, target: target, terms: settings.vocabularyTerms,
                    context: settings.jsonValueContext, instructions: settings.presetInstructions)
            },
            local: { text, source, target in
                try await AppleTranslator.translate(text: text, source: source, target: target)
            },
            model: { text, source, target, modelID in
                try await LocalTranslationProvider.shared.translate(
                    text: text, source: source, target: target, modelID: modelID)
            },
            modelWithTerms: { text, source, target, modelID, terms in
                try await LocalTranslationProvider.shared.translate(
                    text: text, source: source, target: target, modelID: modelID, terms: terms)
            },
            remoteProgress: { text, source, target, settings, options in
                guard settings.engine == "api" else { throw APIError.invalidEndpoint }
                let connection = try APIConnectionSettings(endpoint: settings.endpoint, model: settings.model)
                let key = try await KeyStore.readAsync(connection.endpoint)
                try Task.checkCancellation()
                return try await APIClient().translate(
                    endpoint: connection.endpoint, model: connection.model, key: key,
                    text: text, source: source, target: target, useCache: options.useCache,
                    terms: settings.vocabularyTerms, context: settings.jsonValueContext,
                    instructions: settings.presetInstructions,
                    progress: settings.apiStreamingEnabled ? options.progress : nil)
            },
            remoteBatch: { batch, source, target, settings in
                if settings.engine == "cli" {
                    return try await cli.translateJSONBatch(
                        batch, source: source, target: target, configuration: settings.cli)
                }
                guard settings.engine == "api" else { throw APIError.invalidEndpoint }
                let connection = try APIConnectionSettings(endpoint: settings.endpoint, model: settings.model)
                let key = try await KeyStore.readAsync(connection.endpoint)
                try Task.checkCancellation()
                return try await APIClient().translateJSONBatch(
                    endpoint: connection.endpoint, model: connection.model, key: key,
                    batch: batch, source: source, target: target)
            },
            localBatch: { batch, source, target in
                try await AppleTranslator.translateJSONBatch(batch, source: source, target: target)
            })
    }
}

enum StructuredJSONIssue: LocalizedError {
    case tooLarge, incomplete
    init(_ issue: CoreJSONTranslationPlan.Issue) {
        switch issue {
        case .tooComplex, .outputTooLong: self = .tooLarge
        case .incomplete: self = .incomplete
        }
    }
    var errorDescription: String? {
        switch self {
        case .tooLarge: return L10n.tr("This JSON document is too large to translate.")
        case .incomplete: return L10n.tr("Couldn’t translate every JSON value. Try again.")
        }
    }
}

// Text and voice share the same request contract, never the visible editor or a
// conversation. Each call receives only its current source and frozen settings.
actor TranslationService {
    static let shared = TranslationService()
    private let providers: TranslationProviders
    private let processing: ProcessingPolicyController
    private struct ConnectionState {
        let attempt: UUID
        var retryAfter: TimeInterval?
        var touched: TimeInterval
    }
    private var connectionStates: [Data: ConnectionState] = [:]
    private let clock: @Sendable () -> TimeInterval
    private let singleRequestBytes: Int
    private let longLimits: CoreLongTranslationPlan.Limits
    init(
        providers: TranslationProviders = .system(), processing: ProcessingPolicyController = .shared,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        singleRequestBytes: Int = 131_072, longLimits: CoreLongTranslationPlan.Limits = .init()
    ) {
        self.providers = providers
        self.processing = processing
        self.clock = clock
        self.singleRequestBytes = min(131_072, max(1, singleRequestBytes))
        self.longLimits = longLimits
    }
    func translate(
        text: String, source: String, target: String, settings: TranslationSettings,
        offline: Bool = Connectivity.shared.isOffline, retryPreferredProvider: Bool = false,
        translateAnyway: Bool = false, progress: (@Sendable (TranslationProgress) -> Void)? = nil
    ) async throws -> TranslationRoute.Result {
        try Task.checkCancellation()
        if !translateAnyway, InputLanguageAnalysis.isAlready(in: target, text: text) {
            var unchanged = TranslationRoute.Result(text: text, usedApple: false)
            unchanged.alreadyInTarget = true
            return unchanged
        }
        let vocabulary = try CoreVocabularyProcessor.shared.snapshot(for: settings.personalVocabulary)
        if ["local", "api", "cli", "apple"].contains(settings.engine) {
            do {
                if let plan = try CoreJSONTranslationPlan.make(source: text) {
                    if settings.engine != "local" {
                        return try await translateBatchedJSON(
                            plan, source: source, target: target, settings: settings, vocabulary: vocabulary,
                            offline: offline, retryPreferredProvider: retryPreferredProvider)
                    }
                    return try await translateJSON(
                        plan, source: source, target: target, settings: settings, vocabulary: vocabulary,
                        offline: offline, retryPreferredProvider: retryPreferredProvider)
                }
            } catch let error as CoreJSONTranslationPlan.Issue {
                if settings.engine != "local" { throw StructuredJSONIssue(error) }
                switch error {
                case .tooComplex, .outputTooLong: throw LocalTranslationIssue.inputTooLong
                case .incomplete: throw LocalTranslationIssue.invalidOutput
                }
            }
        }
        let first = try await translateContent(
            text: text, source: source, target: target, settings: settings, vocabulary: vocabulary,
            offline: offline, retryPreferredProvider: retryPreferredProvider, progress: progress)
        // Part of the source came back as it was: ask once more, past any saved
        // answer. A second miss is shown as unfinished, never as a translation.
        guard TranslationLeftover.untranslated(source: text, output: first.text, target: target) else { return first }
        var second: TranslationRoute.Result
        do {
            second = try await translateContent(
                text: text, source: source, target: target, settings: settings, vocabulary: vocabulary,
                offline: offline, retryPreferredProvider: retryPreferredProvider, progress: progress, fresh: true)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            second = first
        }
        second.incomplete = TranslationLeftover.untranslated(source: text, output: second.text, target: target)
        return second
    }

    private func translateBatchedJSON(
        _ document: CoreJSONTranslationPlan, source: String, target: String, settings: TranslationSettings,
        vocabulary: CoreVocabularySnapshot, offline: Bool, retryPreferredProvider: Bool
    ) async throws -> TranslationRoute.Result {
        // Apple needs an explicit pair for structured values; guessing short
        // labels can select unrelated languages and assets. Literal-only JSON
        // requires no provider or source choice.
        if settings.engine == "apple", source == "auto", !document.leaves.isEmpty {
            throw AppleTranslationIssue.unidentified
        }
        var structuredSettings = settings
        structuredSettings.protectsJSONStructure = true
        // API/CLI keep Auto rather than a guessed document-dominant language.
        let from = source
        let plan = try CoreJSONTranslationBatch.make(
            document, maximumInputBytes: 48 * 1024 - 512, maximumJobs: longLimits.maximumJobs)
        var jobs: [(CoreJSONTranslationBatch.Job, [CoreVocabularyTranslationTerm], Bool)] = []
        var plannedRequests = 0
        for job in plan.jobs {
            try Task.checkCancellation()
            switch job {
            case .batch(let batch):
                var terms: [CoreVocabularyTranslationTerm] = []
                var seen: Set<Data> = []
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                for entry in batch.entries {
                    for term in vocabulary.translationTerms(in: entry.text, targetLanguage: target) {
                        let key = try encoder.encode(term)
                        if seen.insert(key).inserted, terms.count < 16,
                            try encoder.encode(terms + [term]).count <= 512
                        {
                            terms.append(term)
                        }
                    }
                }
                jobs.append((.batch(try batch.addingTerms(terms)), terms, false))
                plannedRequests += 1
            case .single(let entry):
                let forceLong = try jsonSingleNeedsLongPath(
                    entry, source: source, target: target, settings: settings, vocabulary: vocabulary)
                if forceLong {
                    let ranges = try vocabulary.translationSourceRanges(
                        in: entry.text, targetLanguage: target, maximumTextBytes: longLimits.sourceBytes)
                    plannedRequests += try CoreLongTranslationPlan.make(
                        source: entry.text, limits: longLimits, protectedRanges: ranges
                    ).jobs.count
                } else {
                    plannedRequests += 1
                }
                jobs.append((job, [], forceLong))
            }
            guard plannedRequests <= longLimits.maximumJobs else { throw CoreJSONTranslationPlan.Issue.tooComplex }
        }
        var accumulator = document.makeAccumulator()
        var apples = 0, completed = 0
        var mixed = false, terminologyUnavailable = false, deferred = false
        var recovery: TranslationRoute.Recovery?
        for (job, terms, forceLong) in jobs {
            try Task.checkCancellation()
            let result: TranslationRoute.Result
            switch job {
            case .batch(let batch):
                result = try await translateOne(
                    text: String(decoding: batch.input, as: UTF8.self), source: from, target: target,
                    settings: structuredSettings, terms: terms, offline: offline,
                    retryPreferredProvider: retryPreferredProvider && completed == 0,
                    admissionCanSegment: false, segmented: false, job: completed, progress: nil, appleLane: nil,
                    batch: batch)
                let values = try batch.decode(Data(result.text.utf8))
                for entry in batch.entries {
                    guard let value = values[entry.id] else { throw CoreJSONTranslationPlan.Issue.incomplete }
                    for id in entry.leafIDs { try accumulator.accept(id: id, text: value) }
                }
            case .single(let entry):
                var contextual = structuredSettings
                contextual.jsonValueContext = entry.context
                if forceLong {
                    result = try await translateLong(
                        text: entry.text, source: from, target: target, settings: contextual, vocabulary: vocabulary,
                        offline: offline, retryPreferredProvider: retryPreferredProvider && completed == 0,
                        progress: nil)
                } else {
                    result = try await translateContent(
                        text: entry.text, source: from, target: target, settings: contextual, vocabulary: vocabulary,
                        offline: offline, retryPreferredProvider: retryPreferredProvider && completed == 0,
                        progress: nil)
                }
                for id in entry.leafIDs { try accumulator.accept(id: id, text: result.text) }
            }
            try Task.checkCancellation()
            completed += 1
            if result.usedApple { apples += 1 }
            mixed = mixed || result.usedMixedProviders
            terminologyUnavailable = terminologyUnavailable || result.terminologyUnavailable
            deferred = deferred || result.preferredProviderDeferred
            recovery = recovery ?? result.recovery
        }
        return .init(
            text: try accumulator.assemble(), usedApple: completed > 0 && apples == completed && !mixed,
            terminologyUnavailable: terminologyUnavailable, preferredProviderDeferred: deferred,
            usedMixedProviders: mixed || (apples > 0 && apples < completed), recovery: recovery)
    }

    // Only structured single values need this extra admission: escaping the
    // value and its field context can exceed the transport budget before the
    // decoded text reaches the ordinary single-request threshold.
    private func jsonSingleNeedsLongPath(
        _ entry: CoreJSONTranslationBatch.Entry, source: String, target: String,
        settings: TranslationSettings, vocabulary: CoreVocabularySnapshot
    ) throws -> Bool {
        guard settings.engine != "apple" else { return false }
        if entry.text.utf8.count > singleRequestBytes { return true }
        let terms = vocabulary.translationTerms(in: entry.text, targetLanguage: target)
        if settings.engine == "api" {
            // Invalid connection/request configuration still belongs to the
            // normal route, including its already-permitted Apple fallback.
            guard let connection = try? APIConnectionSettings(endpoint: settings.endpoint, model: settings.model),
                let request = try? APIClient.request(
                    endpoint: connection.endpoint, model: connection.model, key: "", text: entry.text,
                    source: source, target: target, terms: terms, context: entry.context)
            else { return false }
            return (request.httpBody?.count ?? 0) > 131_072
        }
        guard CLIClient.hasConfiguredMetadata(settings.cli) else { return false }
        let value = try VocabularyPromptData.make(text: entry.text, terms: terms, context: entry.context)
        let input =
            value.instructionSuffix.isEmpty
            ? try JSONSerialization.data(
                withJSONObject: ["source_text": entry.text], options: [.sortedKeys, .withoutEscapingSlashes])
            : Data(value.text.utf8)
        return input.count > 131_072
    }

    // The document owns structure, including serialized child documents.
    // Models see only final decoded text values through the ordinary/long path.
    private func translateJSON(
        _ plan: CoreJSONTranslationPlan, source: String, target: String, settings: TranslationSettings,
        vocabulary: CoreVocabularySnapshot, offline: Bool, retryPreferredProvider: Bool
    ) async throws -> TranslationRoute.Result {
        var accumulator = plan.makeAccumulator()
        var appleLeaves = 0
        var mixed = false
        var terminologyUnavailable = false
        var preferredDeferred = false
        var recovery: TranslationRoute.Recovery?
        let frozenSource: String
        if source == "auto", !plan.leaves.isEmpty {
            // Resolve once from current value text, not English-looking keys.
            // Isolated names/IDs then share the document's established source.
            let languages = InputLanguageAnalysis.detectLanguages(inValues: plan.leaves.map(\.source))
            frozenSource = languages.count == 1 ? languages[0] : source
        } else {
            frozenSource = source
        }
        // Reuse only byte-identical final values within this document. Keep
        // every occurrence in source detection and structural assembly.
        var repeatedValues: Set<Data> = []
        if plan.leaves.count > 1 {
            var seen: Set<Data> = []
            for leaf in plan.leaves {
                try Task.checkCancellation()
                let key = Data(leaf.source.utf8)
                if !seen.insert(key).inserted { repeatedValues.insert(key) }
            }
        }
        var completedValues: [Data: TranslationRoute.Result] = [:]
        try Task.checkCancellation()
        for leaf in plan.leaves {
            try Task.checkCancellation()
            let key = repeatedValues.isEmpty ? nil : Data(leaf.source.utf8)
            let repeatedKey = key.flatMap { repeatedValues.contains($0) ? $0 : nil }
            let result: TranslationRoute.Result
            if let repeatedKey, let completed = completedValues[repeatedKey] {
                result = completed
            } else {
                result = try await translateContent(
                    text: leaf.source, source: frozenSource, target: target, settings: settings, vocabulary: vocabulary,
                    offline: offline, retryPreferredProvider: retryPreferredProvider && leaf.id == 0, progress: nil)
            }
            try Task.checkCancellation()
            try accumulator.accept(id: leaf.id, text: result.text)
            // An Apple fallback must not suppress a later selected-model try.
            // Accept first so incomplete/over-budget output is never retained.
            if let repeatedKey, !result.usedAnyApple { completedValues[repeatedKey] = result }
            if result.usedApple { appleLeaves += 1 }
            mixed = mixed || result.usedMixedProviders
            terminologyUnavailable = terminologyUnavailable || result.terminologyUnavailable
            preferredDeferred = preferredDeferred || result.preferredProviderDeferred
            recovery = recovery ?? result.recovery
        }
        try Task.checkCancellation()
        let text = try accumulator.assemble()
        return .init(
            text: text, usedApple: !plan.leaves.isEmpty && appleLeaves == plan.leaves.count && !mixed,
            terminologyUnavailable: terminologyUnavailable, preferredProviderDeferred: preferredDeferred,
            usedMixedProviders: mixed || (appleLeaves > 0 && appleLeaves < plan.leaves.count), recovery: recovery)
    }

    private func translateContent(
        text: String, source: String, target: String, settings: TranslationSettings,
        vocabulary: CoreVocabularySnapshot, offline: Bool, retryPreferredProvider: Bool,
        progress: (@Sendable (TranslationProgress) -> Void)?, fresh: Bool = false
    ) async throws -> TranslationRoute.Result {
        try Task.checkCancellation()
        if ["api", "cli", "local"].contains(settings.engine), text.utf8.count > singleRequestBytes {
            return try await translateLong(
                text: text, source: source, target: target, settings: settings, vocabulary: vocabulary,
                offline: offline, retryPreferredProvider: retryPreferredProvider, progress: progress)
        }
        let owner =
            settings.engine == "api" && settings.apiStreamingEnabled && providers.remoteProgress != nil
            ? progress.map {
                LongTranslationProgressOwner(totalJobs: 1, maximumBytes: longLimits.outputBytes, callback: $0)
            }
            : nil
        do {
            let result = try await withTaskCancellationHandler {
                try await translateOne(
                    text: text, source: source, target: target, settings: settings,
                    terms: vocabulary.translationTerms(in: text, targetLanguage: target), offline: offline,
                    retryPreferredProvider: retryPreferredProvider, admissionCanSegment: settings.engine == "local",
                    segmented: false, job: 0, progress: owner, appleLane: nil, fresh: fresh)
            } onCancel: {
                owner?.close()
            }
            await owner?.finish()
            try Task.checkCancellation()
            return result
        } catch is LongTranslationAdmission {
            await owner?.finish()
            try Task.checkCancellation()
            return try await translateLong(
                text: text, source: source, target: target, settings: settings, vocabulary: vocabulary,
                offline: offline, retryPreferredProvider: retryPreferredProvider, progress: progress)
        } catch {
            await owner?.finish()
            throw error
        }
    }

    private func translateLong(
        text: String, source: String, target: String, settings: TranslationSettings, vocabulary: CoreVocabularySnapshot,
        offline: Bool, retryPreferredProvider: Bool, progress: (@Sendable (TranslationProgress) -> Void)?
    ) async throws -> TranslationRoute.Result {
        var limits = longLimits
        if settings.engine == "local" { limits.jobBytes = min(limits.jobBytes, 2_048) }
        guard (1...1_048_576).contains(limits.sourceBytes) else {
            throw CoreLongTranslationError.invalidLimits
        }
        guard text.utf8.prefix(limits.sourceBytes + 1).count <= limits.sourceBytes else {
            throw CoreLongTranslationError.sourceTooLarge
        }
        let ranges = try vocabulary.translationSourceRanges(
            in: text, targetLanguage: target, maximumTextBytes: limits.sourceBytes)
        let plan = try CoreLongTranslationPlan.make(source: text, limits: limits, protectedRanges: ranges)
        var accumulator = try plan.makeProgressAccumulator()
        let owner = progress.map {
            LongTranslationProgressOwner(totalJobs: plan.jobs.count, maximumBytes: limits.outputBytes, callback: $0)
        }
        owner?.update(accumulator.progress)
        let lane = LongTranslationAppleLane()
        do {
            let result = try await withTaskCancellationHandler {
                var appleJobs = 0
                var terminologyUnavailable = false
                var preferredDeferred = false
                var recovery: TranslationRoute.Recovery?
                try await withThrowingTaskGroup(of: (Int, TranslationRoute.Result).self) { group in
                    var next = 0
                    let width = settings.engine == "api" ? 2 : 1
                    func add(_ job: CoreLongTranslationPlan.Job) {
                        group.addTask {
                            let output = try await self.translateOne(
                                text: job.text, source: source, target: target, settings: settings,
                                terms: vocabulary.translationTerms(in: job.text, targetLanguage: target),
                                offline: offline,
                                retryPreferredProvider: retryPreferredProvider && job.id == 0,
                                admissionCanSegment: false,
                                segmented: true, job: job.id, progress: owner, appleLane: lane)
                            return (job.id, output)
                        }
                    }
                    while next < min(width, plan.jobs.count) {
                        add(plan.jobs[next])
                        next += 1
                    }
                    do {
                        while let (id, output) = try await group.next() {
                            try Task.checkCancellation()
                            try accumulator.accept(.init(id: id, text: output.text))
                            owner?.update(accumulator.progress, completedJob: id)
                            if output.usedApple { appleJobs += 1 }
                            terminologyUnavailable = terminologyUnavailable || output.terminologyUnavailable
                            preferredDeferred = preferredDeferred || output.preferredProviderDeferred
                            recovery = recovery ?? output.recovery
                            if next < plan.jobs.count {
                                add(plan.jobs[next])
                                next += 1
                            }
                        }
                    } catch {
                        owner?.close()
                        group.cancelAll()
                        throw error
                    }
                }
                try Task.checkCancellation()
                return TranslationRoute.Result(
                    text: try accumulator.assemble(), usedApple: appleJobs > 0 && appleJobs == plan.jobs.count,
                    terminologyUnavailable: terminologyUnavailable, preferredProviderDeferred: preferredDeferred,
                    usedMixedProviders: appleJobs > 0 && appleJobs < plan.jobs.count, recovery: recovery)
            } onCancel: {
                owner?.close()
            }
            await owner?.finish()
            try Task.checkCancellation()
            return result
        } catch {
            await owner?.finish()
            throw error
        }
    }

    private func translateOne(
        text: String, source: String, target: String, settings: TranslationSettings,
        terms: [CoreVocabularyTranslationTerm], offline: Bool, retryPreferredProvider: Bool,
        admissionCanSegment: Bool, segmented: Bool, job: Int, progress: LongTranslationProgressOwner?,
        appleLane: LongTranslationAppleLane?, batch: CoreJSONTranslationBatch.Batch? = nil, fresh: Bool = false
    ) async throws -> TranslationRoute.Result {
        try Task.checkCancellation()
        var requestSettings = settings
        requestSettings.vocabularyTerms = terms
        let selectedSettings = requestSettings
        let apple: @Sendable () async throws -> String = {
            if settings.protectsJSONStructure, source == "auto" { throw AppleTranslationIssue.unidentified }
            if let batch {
                guard let local = self.providers.localBatch else { throw AppleTranslationIssue.unsupported }
                let output = try await local(batch, source, target)
                _ = try batch.decode(Data(output.utf8))
                return output
            }
            if let appleLane {
                return try await appleLane.run(job: job) { try await self.providers.local(text, source, target) }
            }
            return try await self.providers.local(text, source, target)
        }
        if ["api", "cli"].contains(settings.engine) || (settings.engine == "ollama" && !settings.ollamaOnThisMac) {
            do { try processing.requireExternal(settings.authorization) } catch ProcessingPolicyIssue.onDeviceOnly
                where settings.appleFallback
            {
                let text = try await apple()
                try Task.checkCancellation()
                return .init(text: text, usedApple: true, terminologyUnavailable: !terms.isEmpty)
            }
        }
        let from =
            source == "auto"
            ? "automatically detected language(s), including mixed-language text"
            : Language.catalog.first(where: { $0.id == source })?.subtitle ?? source
        let to = Language.catalog.first(where: { $0.id == target })?.subtitle ?? target
        // Internet connectivity does not determine whether a local API server
        // is reachable. Use the same validated loopback hosts as speech/refine.
        var useOfflineRoute = offline && settings.engine != "local"
        if offline, settings.engine == "api", let endpoint = try? APIClient.endpoint(settings.endpoint),
            let host = endpoint.host?.lowercased(), ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        {
            useOfflineRoute = false
        }
        if settings.ollamaOnThisMac { useOfflineRoute = false }
        let connection = connectionFingerprint(settings)
        if !retryPreferredProvider, !useOfflineRoute, settings.appleFallback, let connection,
            let retryAfter = connectionStates[connection]?.retryAfter, clock() < retryAfter
        {
            // A short, text-free memory avoids repeating an already failed
            // network wait. If this pair is unavailable locally, still try the
            // preferred service; a different language must not become a dead end.
            do {
                let output = try await apple()
                try Task.checkCancellation()
                return .init(
                    text: output, usedApple: true, terminologyUnavailable: !terms.isEmpty,
                    preferredProviderDeferred: true)
            } catch {
                try Task.checkCancellation()
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            }
        }
        // The chosen model isn't on this Mac: Apple may stand in, and the result says so.
        var localModelMissing = false
        let result = try await TranslationRoute.run(
            appleOnly: settings.engine == "apple", offline: useOfflineRoute,
            fallback: settings.appleFallback,
            api: {
                if settings.engine == "local" {
                    do {
                        if !terms.isEmpty, let model = self.providers.modelWithTerms {
                            return try await model(text, source, target, settings.localTranslationModelID, terms)
                        }
                        guard let model = self.providers.model else { throw LocalTranslationIssue.unavailable }
                        return try await model(text, source, target, settings.localTranslationModelID)
                    } catch LocalTranslationIssue.inputTooLong where admissionCanSegment {
                        throw LongTranslationAdmission()
                    } catch let issue as ModelLibraryError where issue == .unavailable || issue == .unknownModel {
                        localModelMissing = true
                        throw issue
                    }
                }
                if settings.engine == "ollama" {
                    guard let ollama = self.providers.ollama else { throw OllamaIssue.notRunning }
                    if settings.ollamaOnThisMac { return try await ollama(text, from, to, selectedSettings) }
                    return try await self.processing.performExternal(authorization: settings.authorization) {
                        try await ollama(text, from, to, selectedSettings)
                    }
                }
                let attempt = connection.map { self.beginAttempt($0) }
                let ticket = settings.engine == "api" ? progress?.begin(job: job) : nil
                var completed = false
                defer { if let ticket { progress?.end(ticket, discard: !completed) } }
                let observer: (@Sendable (APITextProgress) -> Void)?
                if settings.apiStreamingEnabled, let ticket {
                    observer = { value in
                        guard (try? self.processing.requireExternal(settings.authorization)) != nil else { return }
                        progress?.receive(value, ticket: ticket)
                    }
                } else {
                    observer = nil
                }
                do {
                    let output = try await self.processing.performExternal(authorization: settings.authorization) {
                        if let batch {
                            guard let remote = self.providers.remoteBatch else { throw APIError.invalidResponse }
                            let output = try await remote(batch, from, to, selectedSettings)
                            _ = try batch.decode(Data(output.utf8))
                            return output
                        }
                        if settings.engine == "api", let remote = self.providers.remoteProgress,
                            segmented || observer != nil || fresh
                        {
                            return try await remote(
                                text, from, to, selectedSettings,
                                .init(useCache: !segmented && !fresh, progress: observer))
                        }
                        return try await self.providers.remote(text, from, to, selectedSettings)
                    }
                    try Task.checkCancellation()
                    if let connection, let attempt { self.finishAttempt(connection, attempt: attempt, error: nil) }
                    completed = true
                    return output
                } catch {
                    var reported = error
                    if batch != nil, let issue = error as? CoreJSONTranslationPlan.Issue {
                        reported = StructuredJSONIssue(issue)
                    }
                    if let connection, let attempt { self.finishAttempt(connection, attempt: attempt, error: reported) }
                    throw reported
                }
            },
            apple: apple)
        // A model's translation loses escaped breaks, wrapping quotes and a
        // lead-in label; Apple's translator and structured batches are exact.
        let tidied =
            batch == nil && !result.usedApple && settings.engine != "apple"
            ? CoreWriterOutput.tidy(result.text, input: text) : result.text
        var translated = TranslationRoute.Result(
            text: tidied, usedApple: result.usedApple,
            terminologyUnavailable: !terms.isEmpty
                && (result.usedApple || (settings.engine == "local" && providers.modelWithTerms == nil)),
            recovery: result.recovery)
        if localModelMissing, result.usedApple {
            translated.appleStoodInFor =
                ModelLibrary.catalog.first { $0.id == settings.localTranslationModelID }?.name
                ?? settings.localTranslationModelID
        }
        return translated
    }
    private func connectionFingerprint(_ settings: TranslationSettings) -> Data? {
        guard settings.engine == "api", let endpoint = try? APIClient.endpoint(settings.endpoint) else { return nil }
        // No source, result, key, app identity or credential state is retained.
        return Data(SHA256.hash(data: Data((endpoint.absoluteString + "\n" + settings.model).utf8)))
    }
    private func beginAttempt(_ key: Data) -> UUID {
        let now = clock(), attempt = UUID()
        let retryAfter = connectionStates[key]?.retryAfter
        if connectionStates[key] == nil, connectionStates.count >= 16,
            let oldest = connectionStates.min(by: { $0.value.touched < $1.value.touched })?.key
        {
            connectionStates.removeValue(forKey: oldest)
        }
        connectionStates[key] = .init(attempt: attempt, retryAfter: retryAfter, touched: now)
        return attempt
    }
    private func finishAttempt(_ key: Data, attempt: UUID, error: Error?) {
        guard connectionStates[key]?.attempt == attempt else { return }
        let now = clock()
        if error is CancellationError || (error as? URLError)?.code == .cancelled || error is ProcessingPolicyIssue {
            connectionStates[key]?.touched = now
            return
        }
        let transient: Bool
        if let issue = error as? APIError, case .http(let status) = issue {
            transient = [408, 429, 500, 502, 503, 504].contains(status)
        } else if let issue = error as? URLError {
            transient = [
                .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                .dnsLookupFailed, .notConnectedToInternet
            ].contains(issue.code)
        } else {
            transient = false
        }
        connectionStates[key] = .init(attempt: attempt, retryAfter: transient ? now + 10 : nil, touched: now)
    }
}

// For results that are used without a window to show them in (dictation,
// Refine in place): an unfinished translation is a failure, never output.
struct TranslationIncomplete: LocalizedError {
    var errorDescription: String? { L10n.tr("Part of this wasn’t translated.") }
}
extension TranslationRoute.Result {
    func finished() throws -> String {
        if incomplete { throw TranslationIncomplete() }
        return text
    }
}

// A translation that hands back a long stretch of the source as it was, in a
// language other than the one asked for, is unfinished ("Bleibt auf dem Mac,
// außer you choose otherwise"). Names, titles, code and text already in the
// target language are kept as they are on purpose and don't count.
enum TranslationLeftover {
    static func untranslated(source: String, output: String, target: String) -> Bool {
        guard source.utf16.count <= 32_768, output.utf16.count <= 32_768 else { return false }
        let original = words(source), translated = words(output)
        guard original.count >= 5, translated.count >= 5 else { return false }
        // A quotation is kept as it was on purpose: a quoted sentence, an error message, a block quote.
        let quoted = quotations(in: source)
        var starts: [String: [Int]] = [:]
        for index in 0..<(original.count - 1) {
            starts[original[index].text + " " + original[index + 1].text, default: []].append(index)
        }
        var position = 0
        while position < translated.count - 1 {
            let key = translated[position].text + " " + translated[position + 1].text
            var longest = 0, from = 0
            for start in starts[key]?.prefix(32) ?? [] {
                var length = 0
                while start + length < original.count, position + length < translated.count,
                    original[start + length].text == translated[position + length].text
                {
                    length += 1
                }
                if length > longest { (longest, from) = (length, start) }
            }
            if longest >= 8 || (longest >= 5 && longest * 5 >= original.count * 2),
                !quoted.contains(where: {
                    $0.contains(original[from].range.lowerBound)
                        && $0.contains(original[from + longest - 1].range.lowerBound)
                }),
                untranslatedRun(
                    String(source[original[from].range.lowerBound..<original[from + longest - 1].range.upperBound]),
                    words: original[from..<(from + longest)].map(\.text), target: target)
            {
                return true
            }
            position += max(1, longest)
        }
        return false
    }

    // Spans inside paired quotation marks of any script, and lines quoted with ">".
    static func quotations(in text: String) -> [Range<String.Index>] {
        let pairs: [Character: Character] = [
            "“": "”", "„": "“", "«": "»", "»": "«", "‹": "›", "「": "」", "『": "』", "\"": "\"", "”": "”"
        ]
        var spans: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            if let close = pairs[text[index]] {
                let start = text.index(after: index)
                if let end = text[start...].firstIndex(of: close) {
                    spans.append(start..<end)
                    index = text.index(after: end)
                    continue
                }
            }
            index = text.index(after: index)
        }
        var line = text.startIndex
        while line < text.endIndex {
            let end = text[line...].firstIndex(of: "\n") ?? text.endIndex
            if text[line..<end].drop(while: { $0 == " " }).first == ">" { spans.append(line..<end) }
            line = end < text.endIndex ? text.index(after: end) : end
        }
        return spans
    }

    private static func untranslatedRun(_ run: String, words: [String], target: String) -> Bool {
        // Code, addresses and handles stay as written.
        guard run.rangeOfCharacter(from: CharacterSet(charactersIn: "{}<>=;_`$\\|@")) == nil, !run.contains("://")
        else { return false }
        // A run of names and title words isn't prose: it needs a few ordinary words.
        let ordinary = words.filter { word in
            guard let first = word.first else { return false }
            return first.isLowercase || String(first).lowercased() == String(first).uppercased()
        }
        guard ordinary.count >= 2 else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(run)
        var inTarget = 0.0, elsewhere = 0.0
        for (language, value) in recognizer.languageHypotheses(withMaximum: 3) {
            if CoreSameLanguageGate.same(Language.canonicalCode(language.rawValue), target) {
                inTarget += value
            } else {
                elsewhere = max(elsewhere, value)
            }
        }
        return inTarget < 0.2 && elsewhere >= 0.5
    }

    private static func words(_ text: String) -> [(text: String, range: Range<String.Index>)] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var found: [(text: String, range: Range<String.Index>)] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            found.append((String(text[range]), range))
            return found.count < 8_000
        }
        return found
    }
}
