import Foundation

enum RefinementIssue: Error, LocalizedError, Equatable, Sendable {
    case connectionRequired, offline, emptyInput, inputTooLarge, refused, truncated, emptyResult, technicalTextChanged
    var errorDescription: String? {
        switch self {
        case .connectionRequired: return L10n.tr("Choose an API or CLI connection to refine writing.")
        case .offline: return L10n.tr("Connect to the internet to refine writing with this connection.")
        case .emptyInput: return L10n.tr("Enter some text to refine.")
        case .inputTooLarge: return L10n.tr("This text is too long to refine in one request.")
        case .refused: return L10n.tr("The model declined to refine this text.")
        case .truncated: return L10n.tr("The refined text was cut off. Try a shorter passage.")
        case .emptyResult: return L10n.tr("The model returned no refined text.")
        case .technicalTextChanged: return L10n.tr("Technical text wasn’t preserved.")
        }
    }
}

struct RefinementProviders: Sendable {
    var api: @Sendable (String, RewriteStyle, TranslationSettings) async throws -> String
    var cli: @Sendable (String, RewriteStyle, TranslationSettings) async throws -> String
    var ollama: @Sendable (String, RewriteStyle, TranslationSettings) async throws -> String = {
        text, style, settings in
        try await OllamaClient.shared.write(
            text: text, style: style, requirements: settings.writingRequirements,
            instructions: settings.presetInstructions,
            target: .init(host: settings.ollamaHost, model: settings.ollamaModel))
    }
    var apple: @Sendable (String, RewriteStyle, TranslationSettings) async throws -> String = {
        text, style, settings in
        try await AppleWriter.write(
            text: text, style: style, requirements: settings.writingRequirements,
            instructions: settings.presetInstructions)
    }
    var apiProgress:
        (
            @Sendable (
                String, RewriteStyle, TranslationSettings, @escaping @Sendable (APITextProgress) -> Void
            ) async throws -> String
        )? = nil
    static func system() -> RefinementProviders {
        let cli = CLIClient.shared
        return RefinementProviders(
            api: { text, style, settings in
                let connection = try APIConnectionSettings(endpoint: settings.endpoint, model: settings.model)
                let key = try await KeyStore.readAsync(connection.endpoint)
                try Task.checkCancellation()
                return try await APIClient().refine(
                    endpoint: connection.endpoint, model: connection.model, key: key, text: text, style: style,
                    useCache: settings.writingRequirements.allowsCaching,
                    terms: settings.vocabularyTerms, requirements: settings.writingRequirements,
                    instructions: settings.presetInstructions)
            },
            cli: { text, style, settings in
                try await cli.refine(
                    text: text, style: style, configuration: settings.cli, terms: settings.vocabularyTerms,
                    requirements: settings.writingRequirements, instructions: settings.presetInstructions)
            },
            apiProgress: { text, style, settings, progress in
                let connection = try APIConnectionSettings(endpoint: settings.endpoint, model: settings.model)
                let key = try await KeyStore.readAsync(connection.endpoint)
                try Task.checkCancellation()
                return try await APIClient().refine(
                    endpoint: connection.endpoint, model: connection.model, key: key,
                    text: text, style: style, useCache: settings.writingRequirements.allowsCaching,
                    terms: settings.vocabularyTerms, requirements: settings.writingRequirements,
                    instructions: settings.presetInstructions, progress: progress)
            })
    }
}

struct RefinementVocabularyContext: Sendable {
    let originalSource: String
    let targetLanguage: String
}

// Refinement is an explicit writing task on the selected connection. Apple
// translation is neither a writing model nor a substitute provider here.
actor RefinementService {
    static let shared = RefinementService()
    private let providers: RefinementProviders
    private let processing: ProcessingPolicyController
    init(providers: RefinementProviders = .system(), processing: ProcessingPolicyController = .shared) {
        self.providers = providers
        self.processing = processing
    }
    func refine(
        text: String, style: RewriteStyle, settings: TranslationSettings,
        offline: Bool = Connectivity.shared.isOffline, vocabularyContext: RefinementVocabularyContext? = nil,
        progress: (@Sendable (APITextProgress) -> Void)? = nil
    ) async throws -> String {
        do {
            return try await refineOnce(
                text: text, style: style, settings: settings, offline: offline,
                vocabularyContext: vocabularyContext, progress: progress)
        } catch let issue as AppleWriterIssue {
            // The writer the person chose for when Apple's model can't; none says why.
            let fallback = settings.appleWriterFallback
            guard settings.engine == "apple", ["ollama", "api", "cli"].contains(fallback) else { throw issue }
            return try await refineOnce(
                text: text, style: style, settings: settings.writing(with: fallback), offline: offline,
                vocabularyContext: vocabularyContext, progress: progress)
        }
    }
    private func refineOnce(
        text: String, style: RewriteStyle, settings: TranslationSettings, offline: Bool,
        vocabularyContext: RefinementVocabularyContext?, progress: (@Sendable (APITextProgress) -> Void)?
    ) async throws -> String {
        try Task.checkCancellation()
        // Apple's model and Ollama on this Mac never leave it.
        let onThisMac = settings.ollamaOnThisMac || settings.engine == "apple"
        if !onThisMac { try processing.requireExternal(settings.authorization) }
        guard ["api", "cli", "ollama", "apple"].contains(settings.engine) else {
            throw RefinementIssue.connectionRequired
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RefinementIssue.emptyInput }
        guard text.utf8.count <= 131_072 else { throw RefinementIssue.inputTooLarge }
        do {
            let vocabulary = try CoreVocabularyProcessor.shared.snapshot(for: settings.personalVocabulary)
            let plan = try CoreTechnicalTextPlan.make(source: text, enabled: settings.preserveTechnicalLiterals)
            if let plan, !plan.requiresTransformation { return text }
            let terms: [CoreVocabularyTranslationTerm]
            if let plan {
                terms =
                    vocabularyContext.map {
                        plan.translatedRefinementTerms(
                            using: vocabulary, originalSource: $0.originalSource, targetLanguage: $0.targetLanguage)
                    } ?? plan.refinementTerms(using: vocabulary)
            } else {
                terms =
                    vocabularyContext.map {
                        vocabulary.translatedRefinementTerms(
                            in: $0.originalSource, targetLanguage: $0.targetLanguage, translatedText: text)
                    } ?? vocabulary.refinementTerms(in: text)
            }
            try Task.checkCancellation()
            var requestSettings = settings
            requestSettings.vocabularyTerms = terms
            requestSettings.writingRequirements = (plan?.writingRequirements ?? .standard)
                .signingOff(as: settings.signOffName).writing(in: settings.writingRequirements.outputLanguage)
            // The written language's own conventions: register, typography, letters.
            requestSettings.writingRequirements = requestSettings.writingRequirements.conventions(
                for: AppleWriter.outputLanguage(requirements: requestSettings.writingRequirements, text: text)?.id)
            let selectedSettings = requestSettings
            let providerText = plan?.text ?? text
            let selectedProgress: (@Sendable (APITextProgress) -> Void)?
            if let progress {
                // Consume an already selected stream, but publish only the
                // restored final result. Marker-bearing drafts have no UI lease.
                selectedProgress = plan == nil ? progress : { @Sendable _ in }
            } else {
                selectedProgress = nil
            }
            if offline, !onThisMac {
                let host = settings.engine == "api" ? try APIClient.endpoint(settings.endpoint).host?.lowercased() : nil
                guard let host, ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) else {
                    throw RefinementIssue.offline
                }
            }
            let provider: @Sendable (String, RewriteStyle, TranslationSettings) async throws -> String
            switch settings.engine {
            case "api": provider = providers.api
            case "ollama": provider = providers.ollama
            case "apple": provider = providers.apple
            default: provider = providers.cli
            }
            let progressProvider = providers.apiProgress
            let result = try await processing.performExternal(
                authorization: settings.authorization, onThisMac: onThisMac
            ) {
                if settings.engine == "api", settings.apiStreamingEnabled, let progress = selectedProgress,
                    let streamed = progressProvider
                {
                    return try await streamed(providerText, style, selectedSettings, progress)
                }
                return try await provider(providerText, style, selectedSettings)
            }
            try Task.checkCancellation()
            // Every writer's answer loses escaped breaks, wrapping quotes and a lead-in label.
            var output = CoreWriterOutput.tidy(result, input: providerText)
            // Nothing invented around what was said: no header, placeholder, or unspoken
            // greeting or closing. A translation's greeting is the source's, so it stays.
            // Output set to the speech's own language is no translation: the guard applies as without one.
            let requirements = selectedSettings.writingRequirements
            let translated =
                requirements.outputLanguage != nil
                && AppleWriter.outputLanguage(requirements: requirements, text: providerText)?.id
                    != AppleWriter.textLanguage(providerText)
            if !translated {
                // Only letters (Email, Formal letter) sign with the "Sign letters as" name.
                let signs = [RewriteStyle.email, .formal].contains(style)
                output = CoreLetterScaffold.removingInvented(
                    output, input: providerText,
                    signOffName: signs ? selectedSettings.writingRequirements.signOffName : nil,
                    unsigned: signs ? nil : selectedSettings.writingRequirements.signOffName)
                // A letter's spoken greeting and closing on their own lines.
                output = CoreLetterScaffold.laidOut(
                    output, input: providerText, style: style,
                    languageID: selectedSettings.writingRequirements.languageID)
            }
            guard !output.isEmpty else { throw RefinementIssue.emptyResult }
            // Preserve original code indentation/newlines restored by the plan.
            return try plan?.restore(output) ?? output
        } catch {
            try Task.checkCancellation()
            if let issue = error as? CoreTechnicalTextPlan.Issue {
                switch issue {
                case .invalidMarkers: throw RefinementIssue.technicalTextChanged
                case .inputTooLong, .tooManyLiterals, .outputTooLong: throw RefinementIssue.inputTooLarge
                }
            }
            if let issue = error as? APIError {
                switch issue {
                case .refused: throw RefinementIssue.refused
                case .truncated: throw RefinementIssue.truncated
                case .empty: throw RefinementIssue.emptyResult
                default: break
                }
            }
            if (error as? CLIError) == .emptyResponse { throw RefinementIssue.emptyResult }
            throw error
        }
    }
}
