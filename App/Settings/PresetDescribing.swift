import Foundation

// Describe-a-preset support shared by the preset editor and Scenario mode. The
// local proposal is deterministic and never leaves this Mac; the service
// proposal and the before/after preview run only after an explicit click, on
// the configured Writing service, with typed or generated text only.
enum PresetDescribing {
    // Proposals update as the person types; build each interface language's names once.
    private final class Names: NSObject {
        let value: [CorePresetLanguageNames]
        init(_ value: [CorePresetLanguageNames]) { self.value = value }
    }
    private static let cache = NSCache<NSString, Names>()
    static func languageNames(locale: Locale = L10n.locale) -> [CorePresetLanguageNames] {
        let key = locale.identifier as NSString
        if let cached = cache.object(forKey: key) { return cached.value }
        let value = makeLanguageNames(locale: locale)
        cache.setObject(Names(value), forKey: key)
        return value
    }
    private static func makeLanguageNames(locale: Locale) -> [CorePresetLanguageNames] {
        let english = Locale(identifier: "en")
        return Language.catalog.map { language in
            let code = language.appleCode ?? language.id
            var names = [language.name, language.subtitle]
            for value in [english, locale, Locale(identifier: code)] {
                if let name = value.localizedString(forIdentifier: code) { names.append(name) }
            }
            // Chinese speakers write a language as -语 or -文 (英语 / 英文).
            names += names.filter { $0.hasSuffix("语") || $0.hasSuffix("語") }.map { String($0.dropLast()) + "文" }
            var seen = Set<String>()
            return CorePresetLanguageNames(id: language.id, names: names.filter { seen.insert($0).inserted })
        }
    }

    static func localProposal(_ description: String) -> CorePresetProposal? {
        guard var proposal = CorePresetDescription.propose(description, languages: languageNames()) else {
            return nil
        }
        if proposal.name.isEmpty { proposal.name = fallbackName(proposal.definition) }
        return proposal
    }

    static func fallbackName(_ definition: CoreDictationPresetDefinition) -> String {
        if definition.mode == "translate", let target = definition.targetLanguage {
            return Language.displayName(for: target, localized: true, locale: L10n.locale)
        }
        if let style = definition.style.flatMap(RewriteStyle.init(rawValue:)) {
            return WritingStylePresentation.title(style)
        }
        let original = definition.mode == "original"
        return L10n.tr(original ? "Original" : "Format")
    }

    // A generated sentence in the interface language; never user content.
    // Letter styles get a spoken greeting and sign-off, so the preview shows
    // the finished message.
    static func previewSample(style: RewriteStyle?) -> String {
        switch style {
        case .email, .polite, .formal:
            L10n.tr(
                "hi Sam um so I wanted to ask if we could maybe move our meeting to Thursday because something came up thanks best Alex"
            )
        default:
            L10n.tr("um so I wanted to ask if we could maybe move our meeting to Thursday because something came up")
        }
    }
}

enum PresetDescriptionIssue: Error, LocalizedError, Equatable {
    case connectionRequired, offline, unreadable, noPreview
    var errorDescription: String? {
        switch self {
        case .connectionRequired: return L10n.tr("Choose an API or CLI connection to refine writing.")
        case .offline: return L10n.tr("Connect to the internet to refine writing with this connection.")
        case .unreadable: return L10n.tr("The writing service’s proposal couldn’t be used. The local proposal is kept.")
        case .noPreview: return L10n.tr("This service can’t preview the format.")
        }
    }
}

struct PresetDescriptionProviders: Sendable {
    var describe: @Sendable (String, [String], TranslationSettings) async throws -> String
    var refine: @Sendable (String, RewriteStyle, TranslationSettings) async throws -> String
    var translate: @Sendable (String, String, TranslationSettings) async throws -> TranslationRoute.Result
    static func system() -> Self {
        .init(
            describe: { description, languageIDs, settings in
                if settings.engine == "cli" {
                    return try await CLIClient.shared.describePreset(
                        description: description, languageIDs: languageIDs, configuration: settings.cli)
                }
                let connection = try APIConnectionSettings(endpoint: settings.endpoint, model: settings.model)
                let key = try await KeyStore.readAsync(connection.endpoint)
                try Task.checkCancellation()
                return try await APIClient().describePreset(
                    endpoint: connection.endpoint, model: connection.model, key: key, description: description,
                    languageIDs: languageIDs)
            },
            refine: { text, style, settings in
                try await RefinementService.shared.refine(text: text, style: style, settings: settings)
            },
            translate: { text, target, settings in
                try await TranslationService.shared.translate(
                    text: text, source: "auto", target: target, settings: settings)
            })
    }
}

actor PresetDescriptionService {
    static let shared = PresetDescriptionService()
    private let providers: PresetDescriptionProviders
    private let processing: ProcessingPolicyController
    init(providers: PresetDescriptionProviders = .system(), processing: ProcessingPolicyController = .shared) {
        self.providers = providers
        self.processing = processing
    }

    // Describe needs an API or CLI connection; a preview runs on any writer.
    private func admit(_ settings: TranslationSettings, offline: Bool, anyWriter: Bool = false) throws {
        try processing.requireExternal(settings.authorization)
        if anyWriter, !["api", "cli"].contains(settings.engine) { return }
        guard ["api", "cli"].contains(settings.engine) else { throw PresetDescriptionIssue.connectionRequired }
        if offline {
            let host = settings.engine == "api" ? try APIClient.endpoint(settings.endpoint).host?.lowercased() : nil
            guard let host, ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) else {
                throw PresetDescriptionIssue.offline
            }
        }
    }

    // `settings` is the Writing service. Only the description is sent.
    func propose(
        description: String, settings: TranslationSettings, offline: Bool = Connectivity.shared.isOffline
    ) async throws -> CorePresetProposal {
        try Task.checkCancellation()
        guard let text = CorePresetInstructions.normalized(description) else {
            throw PresetDescriptionIssue.unreadable
        }
        try admit(settings, offline: offline)
        let ids = Language.catalog.map(\.id)
        let describe = providers.describe
        let output = try await processing.performExternal(authorization: settings.authorization) {
            try await describe(text, ids, settings)
        }
        try Task.checkCancellation()
        guard var proposal = try? CorePresetDescription.proposal(fromServiceOutput: output, languageIDs: Set(ids))
        else { throw PresetDescriptionIssue.unreadable }
        if proposal.name.isEmpty { proposal.name = PresetDescribing.fallbackName(proposal.definition) }
        return proposal
    }

    // Applies a draft to the generated sample through the Writing service.
    func preview(
        _ definition: CoreDictationPresetDefinition, sample: String, settings: TranslationSettings,
        defaultStyle: RewriteStyle, offline: Bool = Connectivity.shared.isOffline
    ) async throws -> String {
        try Task.checkCancellation()
        try admit(settings, offline: offline, anyWriter: true)
        var selected = settings
        selected.presetInstructions = CorePresetInstructions.normalized(definition.instructions)
        switch definition.mode {
        case "translate":
            guard let target = definition.targetLanguage else { throw PresetDescriptionIssue.noPreview }
            let result = try await providers.translate(sample, target, selected)
            guard !result.usedAnyApple else { throw PresetDescriptionIssue.noPreview }
            return result.text
        case "original": throw PresetDescriptionIssue.noPreview
        default:
            selected.preserveTechnicalLiterals = definition.preserveTechnicalLiterals
            let style = definition.style.flatMap(RewriteStyle.init(rawValue:)) ?? defaultStyle
            return try await providers.refine(sample, style, selected)
        }
    }
}
