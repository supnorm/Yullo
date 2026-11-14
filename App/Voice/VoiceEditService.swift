import Foundation

enum VoiceEditIssue: Error, LocalizedError, Equatable, Sendable {
    case connectionRequired, offline, validation(CoreVoiceEditValidationError), refused, truncated
    var errorDescription: String? {
        let key: String
        switch self {
        case .connectionRequired: key = "Needs a writing service."
        case .offline: key = "Connect to the internet to edit text with this connection."
        case .validation(.emptySource): key = "Select text first, then say how to change it."
        case .validation(.sourceTooLong): key = "The selected text is too long to edit in one request."
        case .validation(.emptyInstruction): key = "No editing instruction was recognized. Try again."
        case .validation(.instructionTooLong):
            key = "Your instruction is too long. Try a shorter one."
        case .validation(.invalidTerms): key = "Couldn’t apply your personal vocabulary to this request."
        case .validation(.emptyResult): key = "The model returned no edited text."
        case .validation(.resultTooLong): key = "The edited text is too long. Try a shorter selection."
        case .validation(.instructionEcho): key = "The model returned the editing instruction instead of edited text."
        case .refused: key = "The model declined to edit this text."
        case .truncated: key = "The edited text was cut off. Try a shorter selection."
        }
        return L10n.tr(key)
    }
}

struct VoiceEditProviders: Sendable {
    var api: @Sendable (String, String, TranslationSettings) async throws -> String
    var cli: @Sendable (String, String, TranslationSettings) async throws -> String
    var ollama: @Sendable (String, String, TranslationSettings) async throws -> String = {
        source, instruction, settings in
        try await OllamaClient.shared.voiceEdit(
            source: source, instruction: instruction, terms: settings.vocabularyTerms,
            target: .init(host: settings.ollamaHost, model: settings.ollamaModel))
    }
    var apple: @Sendable (String, String, TranslationSettings) async throws -> String = {
        source, instruction, settings in
        try await AppleWriter.voiceEdit(source: source, instruction: instruction, terms: settings.vocabularyTerms)
    }
    static func system() -> Self {
        let cli = CLIClient.shared
        return .init(
            api: { source, instruction, settings in
                let connection = try APIConnectionSettings(endpoint: settings.endpoint, model: settings.model)
                let key = try await KeyStore.readAsync(connection.endpoint)
                try Task.checkCancellation()
                return try await APIClient().voiceEdit(
                    endpoint: connection.endpoint, model: connection.model, key: key,
                    source: source, instruction: instruction, terms: settings.vocabularyTerms)
            },
            cli: { source, instruction, settings in
                try await cli.voiceEdit(
                    source: source, instruction: instruction, configuration: settings.cli,
                    terms: settings.vocabularyTerms)
            })
    }
}

// No selection, editor, destination or app context is available here. The UI
// owns revision checks and an explicit reviewed replacement of its source.
actor VoiceEditService {
    static let shared = VoiceEditService()
    // Every writer edits with voice; checked before the instruction is
    // recorded, so nobody speaks into a request that can't run. Apple's model
    // and Ollama on this Mac also work on this Mac only.
    nonisolated static func isConfigured(_ preferences: Preferences) -> Bool {
        switch preferences.voiceRefinementEngine {
        case "apple": return true
        case "ollama":
            return !preferences.ollamaModel.isEmpty
                && (preferences.processingPolicy == .standard || CoreOllama.isOnThisMac(host: preferences.ollamaHost))
        default: break
        }
        guard preferences.processingPolicy == .standard else { return false }
        switch preferences.voiceRefinementEngine {
        case "api": return (try? APIConnectionSettings(endpoint: preferences.endpoint, model: preferences.model)) != nil
        case "cli": return CLIClient.hasConfiguredMetadata(preferences.cli)
        default: return false
        }
    }
    private let providers: VoiceEditProviders
    private let processing: ProcessingPolicyController
    init(providers: VoiceEditProviders = .system(), processing: ProcessingPolicyController = .shared) {
        self.providers = providers
        self.processing = processing
    }
    func edit(
        source: String, instruction: String, settings: TranslationSettings,
        offline: Bool = Connectivity.shared.isOffline
    ) async throws -> String {
        try await editNoted(source: source, instruction: instruction, settings: settings, offline: offline).text
    }
    // The edit, and when the backup writer made it instead of Apple's model, the words that say so.
    func editNoted(
        source: String, instruction: String, settings: TranslationSettings,
        offline: Bool = Connectivity.shared.isOffline
    ) async throws -> (text: String, note: String?) {
        do {
            return (
                try await editOnce(source: source, instruction: instruction, settings: settings, offline: offline), nil
            )
        } catch let issue as AppleWriterIssue {
            // What Apple's model can't do, the writer chosen for that case does, and says so.
            let fallback = settings.appleWriterFallback
            guard settings.engine == "apple", ["ollama", "api", "cli"].contains(fallback) else { throw issue }
            let text = try await editOnce(
                source: source, instruction: instruction, settings: settings.writing(with: fallback), offline: offline)
            return (text, BackupWriterNotice.text(settings.writing(with: fallback)))
        }
    }
    private func editOnce(
        source: String, instruction: String, settings: TranslationSettings, offline: Bool
    ) async throws -> String {
        try Task.checkCancellation()
        // Apple's model and Ollama on this Mac never leave it.
        let onThisMac = settings.ollamaOnThisMac || settings.engine == "apple"
        if !onThisMac { try processing.requireExternal(settings.authorization) }
        guard ["api", "cli", "ollama", "apple"].contains(settings.engine) else {
            throw VoiceEditIssue.connectionRequired
        }
        do {
            try CoreVoiceEditPrompt.validateInputs(source: source, instruction: instruction)
            // "Never mind", filler or thanks: the text stays as it was, and no writer is asked.
            if CoreVoiceEditPrompt.intent(of: instruction) == .dismissal { return source }
            // An exact swap of words found once in the text needs no writer.
            if let swapped = CoreVoiceEditPrompt.directReplacement(source: source, instruction: instruction) {
                return swapped
            }
            let terms = try CoreVocabularyProcessor.shared.snapshot(for: settings.personalVocabulary)
                .refinementTerms(in: source)
            try Task.checkCancellation()
            var selected = settings
            selected.vocabularyTerms = terms
            if offline, !onThisMac {
                let host = settings.engine == "api" ? try APIClient.endpoint(settings.endpoint).host?.lowercased() : nil
                guard let host, ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) else {
                    throw VoiceEditIssue.offline
                }
            }
            let provider: @Sendable (String, String, TranslationSettings) async throws -> String
            switch settings.engine {
            case "api": provider = providers.api
            case "ollama": provider = providers.ollama
            case "apple": provider = providers.apple
            default: provider = providers.cli
            }
            let frozen = selected
            let result = try await processing.performExternal(
                authorization: settings.authorization, onThisMac: onThisMac
            ) {
                try await provider(source, instruction, frozen)
            }
            try Task.checkCancellation()
            // Quotation marks around the whole text and the request glued to it
            // are removed; a request still inside the text is refused.
            let cleaned = CoreVoiceEditPrompt.cleanedResult(source: source, instruction: instruction, result: result)
            try CoreVoiceEditPrompt.validateResult(source: source, instruction: instruction, result: cleaned)
            return cleaned
        } catch {
            try Task.checkCancellation()
            if let issue = error as? CoreVoiceEditValidationError { throw VoiceEditIssue.validation(issue) }
            if let issue = error as? APIError {
                switch issue {
                case .refused: throw VoiceEditIssue.refused
                case .truncated: throw VoiceEditIssue.truncated
                case .empty: throw VoiceEditIssue.validation(.emptyResult)
                default: break
                }
            }
            if (error as? CLIError) == .emptyResponse { throw VoiceEditIssue.validation(.emptyResult) }
            throw error
        }
    }
}
