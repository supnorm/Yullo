import Foundation

// One step per task, each ending in a Try: languages, then translation and
// writing set up in place, then the permissions dictation needs and its trial,
// then the shortcuts. Every step can be skipped.
enum GuidedSetupStep: Int, CaseIterable {
    case choices, translation, writing, permissions, trial, more
}

// Only an explicit forward action owns an automatic continuation. Navigation
// and edits revoke it before an asynchronous result can move the guide.
struct GuidedSetupProgress {
    private(set) var step: GuidedSetupStep
    private(set) var visit = UUID()
    private(set) var forward: UUID?

    init(step: GuidedSetupStep = .choices) { self.step = step }

    mutating func beginForward() -> UUID {
        let ticket = UUID()
        forward = ticket
        return ticket
    }

    func accepts(_ ticket: UUID, at step: GuidedSetupStep) -> Bool {
        self.step == step && forward == ticket
    }

    mutating func invalidate() { forward = nil }

    mutating func move(to step: GuidedSetupStep) {
        invalidate()
        self.step = step
        visit = UUID()
    }
}

// Whether a guide task can run now, and if not, the one step that fixes it.
// A key that cannot be read, or a service never set up, is fixed in place.
enum GuidedEngineReadiness: Equatable {
    case ready, needsSetup(anchor: String), needsKeyAccess

    // The engine as the guide will apply it; the saved key's state comes from
    // the noninteractive check Quick setup's Saved keys uses.
    static func resolve(engine: String, preferences: Preferences, keyState: CredentialAccessState?) -> Self {
        switch engine {
        case "apple", "local": return .ready
        case "ollama": return preferences.ollamaModel.isEmpty ? .needsSetup(anchor: "ollama") : .ready
        case "cli": return CLIClient.hasConfiguredMetadata(preferences.cli) ? .ready : .needsSetup(anchor: "cli")
        case "api":
            guard (try? APIConnectionSettings(endpoint: preferences.endpoint, model: preferences.model)) != nil else {
                return .needsSetup(anchor: "api")
            }
            switch keyState {
            case .some(let state) where state.needsAccess: return .needsKeyAccess
            case .some(.noSavedKey), .some(.notConfigured), .some(.invalidConfiguration):
                return .needsSetup(anchor: "api")
            default: return .ready
            }
        default: return .needsSetup(anchor: "text-services")
        }
    }
}

enum GuidedModelVerification: Equatable {
    case checking, verified, failed(String)
}

// These edits belong to a reviewed setup, not to the experience preference.
// Unedited fields are applied from the latest configuration, never a snapshot.
struct GuidedSetupPlan: Equatable {
    var targetLanguage: String
    // Translate with, the same shared translator Translation and Dictation use.
    var translationEngine: String
    // The local translation model, when Translate with is one on this Mac.
    var translationModelID: String
    // Write with, the same shared writer Refine and Dictation use.
    var writingEngine: String
    // The command-line tool both can use, when one is chosen here by name.
    var cli: CLIConfiguration
    // A writer set up in the guide brings its connection: the API's address and
    // model, or the Ollama model.
    var endpoint: String
    var apiModel: String
    var ollamaModel: String
    var recognitionModelID: String
    var recognitionLanguage: String
    var appleLocale: String
    var previewFirst: Bool
    var voicePlacement: String
    // Your languages: the first is the one the person speaks; the rest are the others they use.
    private(set) var languages: [String]
    private let initialTarget: String
    private let initialEngine: String
    private let initialTranslationModel: String
    private let initialWriting: String
    private let initialCLI: CLIConfiguration
    private let initialEndpoint: String
    private let initialAPIModel: String
    private let initialOllamaModel: String
    private let initialRecognition: String
    private let initialRecognitionLanguage: String
    private let initialAppleLocale: String
    private let initialPreview: Bool
    private let initialPlacement: String
    private let initialLanguages: [String]

    init(preferences: Preferences, targetLanguage: String) {
        self.targetLanguage = targetLanguage
        translationEngine = preferences.engine
        initialEngine = preferences.engine
        translationModelID = preferences.localTranslationModelID
        initialTranslationModel = preferences.localTranslationModelID
        writingEngine = preferences.voiceRefinementEngine
        initialWriting = preferences.voiceRefinementEngine
        cli = preferences.cli
        initialCLI = preferences.cli
        endpoint = preferences.endpoint
        initialEndpoint = preferences.endpoint
        apiModel = preferences.model
        initialAPIModel = preferences.model
        ollamaModel = preferences.ollamaModel
        initialOllamaModel = preferences.ollamaModel
        recognitionModelID = preferences.voiceModelID
        recognitionLanguage = preferences.voiceRecognitionLanguage
        appleLocale = preferences.voiceAppleLocale
        previewFirst = preferences.voicePreviewFirst
        voicePlacement = preferences.voicePlacement
        initialTarget = targetLanguage
        initialRecognition = preferences.voiceModelID
        initialRecognitionLanguage = preferences.voiceRecognitionLanguage
        initialAppleLocale = preferences.voiceAppleLocale
        initialPreview = preferences.voicePreviewFirst
        initialPlacement = preferences.voicePlacement
        languages = Language.enabled(preferences.enabledLanguages).map(\.id)
        initialLanguages = languages
    }
    // Write with and Translate with as the guide's pop-ups set them; a command-line
    // tool chosen by name brings its path and model along.
    mutating func stageTranslator(_ preferences: Preferences) {
        translationEngine = preferences.engine
        translationModelID = preferences.localTranslationModelID
        cli = preferences.cli
    }
    mutating func stageWriter(_ preferences: Preferences) {
        writingEngine = preferences.voiceRefinementEngine
        cli = preferences.cli
        endpoint = preferences.endpoint
        apiModel = preferences.model
        ollamaModel = preferences.ollamaModel
    }
    var spokenLanguage: String { languages[0] }
    var otherLanguages: [String] { Array(languages.dropFirst()) }

    // I speak: the language moves to the front; the one it replaces stays among the others.
    // A model that needs a language hint, and Apple Speech, follow it.
    mutating func speak(_ id: String, systemLocale: String = Locale.current.identifier) {
        guard let language = Language.enabled([id]).first, language.id != spokenLanguage else { return }
        languages.removeAll { $0 == language.id }
        languages.insert(language.id, at: 0)
        if recognitionLanguage != "auto" { recognitionLanguage = language.id }
        appleLocale = Language.canonicalCode(systemLocale) == language.id ? "system" : language.locale
        if targetLanguage == language.id { targetLanguage = otherLanguages.first ?? language.id }
    }
    // I also use: checking adds a language after the others; unchecking removes it, and
    // a target that was removed moves to the next other language.
    mutating func toggleOther(_ id: String) {
        let id = Language.canonicalCode(id)
        guard id != spokenLanguage, Language.catalog.contains(where: { $0.id == id }) else { return }
        if languages.contains(id) {
            languages.removeAll { $0 == id }
            if targetLanguage == id { targetLanguage = otherLanguages.first ?? spokenLanguage }
        } else {
            languages.append(id)
            if targetLanguage == spokenLanguage { targetLanguage = id }
        }
    }

    // Newer settings arrived while the guide is open: the list staged here stays.
    mutating func keepLanguages(_ ids: [String]) { languages = Language.enabled(ids).map(\.id) }

    func patch(useBuiltInMacSetup: Bool = false) -> GuidedSetupPatch {
        GuidedSetupPatch(
            targetLanguage: targetLanguage == initialTarget ? nil : targetLanguage,
            recognitionModelID: recognitionModelID == initialRecognition ? nil : recognitionModelID,
            recognitionLanguage: recognitionLanguage == initialRecognitionLanguage ? nil : recognitionLanguage,
            appleLocale: useBuiltInMacSetup || appleLocale != initialAppleLocale ? appleLocale : nil,
            previewFirst: previewFirst == initialPreview ? nil : previewFirst,
            voicePlacement: voicePlacement == initialPlacement ? nil : voicePlacement,
            usesBuiltInMacSetup: useBuiltInMacSetup,
            translationEngine: translationEngine == initialEngine ? nil : translationEngine,
            translationModelID: translationModelID == initialTranslationModel ? nil : translationModelID,
            writingEngine: writingEngine == initialWriting ? nil : writingEngine,
            cli: cli == initialCLI ? nil : cli,
            endpoint: endpoint == initialEndpoint ? nil : endpoint,
            apiModel: apiModel == initialAPIModel ? nil : apiModel,
            ollamaModel: ollamaModel == initialOllamaModel ? nil : ollamaModel,
            languages: languages == initialLanguages ? nil : languages)
    }
}

struct GuidedSetupPatch: Equatable {
    let targetLanguage: String?
    let recognitionModelID: String?
    let recognitionLanguage: String?
    let appleLocale: String?
    let previewFirst: Bool?
    let voicePlacement: String?
    let usesBuiltInMacSetup: Bool
    // Explore's explicit Add for the mail app: one What dictation writes row, Email in the
    // spoken language. Nothing else changes.
    var emailRule: MailApplication? = nil
    // Explore's explicit Turn on for that app's paused row.
    var enablesEmailRule: MailApplication? = nil
    // One "Made to fit you" switch: its kind's rules are added or removed. Nothing else changes.
    var suggestion: OutputSuggestionGroup? = nil
    var suggestionOn = false
    var translationEngine: String? = nil
    var translationModelID: String? = nil
    var writingEngine: String? = nil
    var cli: CLIConfiguration? = nil
    var endpoint: String? = nil
    var apiModel: String? = nil
    var ollamaModel: String? = nil
    var languages: [String]? = nil

    func applying(to current: Preferences) -> Preferences {
        var updated = current
        if let emailRule,
            !updated.outputs.rules.contains(where: {
                $0.applicationBundleID.caseInsensitiveCompare(emailRule.bundleID) == .orderedSame
            })
        {
            updated.outputs.rules.append(
                .init(
                    applicationBundleID: emailRule.bundleID, applicationName: emailRule.name,
                    output: .init(format: RewriteStyle.email.rawValue)))
        }
        if let enablesEmailRule,
            let index = updated.outputs.rules.firstIndex(where: {
                $0.applicationBundleID.caseInsensitiveCompare(enablesEmailRule.bundleID) == .orderedSame
            })
        {
            updated.outputs.rules[index].enabled = true
        }
        if let suggestion {
            updated.outputs = updated.outputs.setting(suggestion, on: suggestionOn)
        }
        if let translationEngine { updated.engine = translationEngine }
        if let translationModelID { updated.localTranslationModelID = translationModelID }
        if let writingEngine { updated.voiceRefinementEngine = writingEngine }
        if let cli { updated.cli = cli }
        if let endpoint { updated.endpoint = endpoint }
        if let apiModel { updated.model = apiModel }
        if let ollamaModel { updated.ollamaModel = ollamaModel }
        if let languages, !languages.isEmpty {
            updated.enabledLanguages = languages
            if !languages.contains(updated.voiceTarget) {
                updated.voiceTarget = languages.dropFirst().first ?? languages[0]
            }
        }
        if let recognitionModelID { updated.voiceModelID = recognitionModelID }
        if let recognitionLanguage { updated.voiceRecognitionLanguage = recognitionLanguage }
        if let appleLocale { updated.voiceAppleLocale = appleLocale }
        if let previewFirst { updated.voicePreviewFirst = previewFirst }
        if let voicePlacement, VoiceOverlayPlacement(rawValue: voicePlacement) != nil {
            updated.voicePlacement = voicePlacement
        }
        if usesBuiltInMacSetup {
            updated.engine = "apple"
            updated.voiceModelID = VoiceRecognitionSettings.appleModelID
            updated.speechEngine = SpeechProvider.macOS.rawValue
            // The review lists What I say for dictation everywhere else. App rows,
            // shortcuts and Refine rows keep their own outputs.
            updated.outputs.everywhere = .spoken
            updated.voiceTranslateEnabled = false
        }
        return updated
    }
}

enum GuidedRecognitionReadiness: Equatable {
    case checking, ready, appleFallback, missingModel, languageRequired
    case needsAppleDownload, appleDownloading, unsupportedApple, unavailableApple

    var canTry: Bool { self == .ready || self == .appleFallback }

    static func needsAppleSpeech(preferences: Preferences, installed: [InstalledLocalModel]) -> Bool {
        preferences.voiceModelID == VoiceRecognitionSettings.appleModelID
            || (preferences.voiceAppleFallback && recognitionModel(preferences, installed: installed) == nil)
    }

    static func resolve(
        preferences: Preferences, installed: [InstalledLocalModel], apple: AppleSpeechAvailability?
    ) -> GuidedRecognitionReadiness {
        let applePrimary = preferences.voiceModelID == VoiceRecognitionSettings.appleModelID
        if !applePrimary, let selected = recognitionModel(preferences, installed: installed) {
            if VoiceRecognitionSettings.requiresLanguageHint(modelID: selected.id, architecture: selected.architecture),
                !VoiceRecognitionSettings.cohereLanguageIDs.contains(preferences.voiceRecognitionLanguage)
            {
                return .languageRequired
            }
            return .ready
        }
        guard applePrimary || preferences.voiceAppleFallback else { return .missingModel }
        guard let apple else { return .checking }
        switch apple.state {
        case .ready: return applePrimary ? .ready : .appleFallback
        case .needsDownload: return .needsAppleDownload
        case .downloading: return .appleDownloading
        case .unsupportedLocale: return .unsupportedApple
        case .unavailableDevice: return .unavailableApple
        }
    }

    private static func recognitionModel(_ preferences: Preferences, installed: [InstalledLocalModel])
        -> InstalledLocalModel?
    {
        installed.first { $0.id == preferences.voiceModelID && $0.task == .dictation && $0.runtime.task == .dictation }
    }
}

// Where a Try on the guide's sample shows its windows, in AppKit screen coordinates.
enum GuideTryPlacement {
    // The Sample card as reported, or, before it reports, its place in the guide:
    // under the title, across the working column.
    static func card(reported: CGRect?, guide: CGRect) -> CGRect {
        if let reported, !reported.isNull, !reported.isEmpty, guide.intersects(reported) { return reported }
        return CGRect(x: guide.minX + 200, y: guide.maxY - 250, width: max(guide.width - 230, 120), height: 100)
    }
}

// The translation model the guide offers: the reviewed model for these languages that
// fits this Mac's memory. Free space is judged on its own, so a full disk shows its
// reason beside the model rather than hiding it.
enum GuidedTranslationOffer {
    static func model(languages: [String], hardware: ModelHardwareProfile?) -> LocalModelDescriptor? {
        let catalog = ModelLibrary.catalog.filter { $0.task == .translation }
        var id = Preferences().localTranslationModelID
        if let hardware {
            let anyDisk = ModelHardwareProfile(
                physicalMemoryBytes: hardware.physicalMemoryBytes, availableDiskBytes: nil,
                architecture: hardware.architecture, availableRuntimes: hardware.availableRuntimes,
                liveRecognitionAvailable: hardware.liveRecognitionAvailable,
                unavailableModelIDs: hardware.unavailableModelIDs)
            if let pick = HardwareModelRecommendation.recommend(
                needs: .init(task: .translation, languageIDs: languages), profile: anyDisk,
                candidates: ModelDiscoveryCatalog.hardwareCatalog)?.modelID
            {
                id = pick
            }
        }
        return catalog.first { $0.id == id } ?? catalog.first
    }
    // The download is staged beside its final copy, with room to spare: the library's own rule.
    static func hasRoom(_ model: LocalModelDescriptor, hardware: ModelHardwareProfile?) -> Bool {
        guard let disk = hardware?.availableDiskBytes else { return true }
        let (staging, overflow) = UInt64(max(0, model.sizeBytes)).multipliedReportingOverflow(by: 2)
        return !overflow && staging + 256 * 1_048_576 <= disk
    }
}

// The writer the guide recommends on this Mac: Apple's model where it runs here, else, where
// Yullo may work online, a command-line tool installed and not known to be signed out. Nil: the
// guide leads with the service that fits Where Yullo works (Ollama on this Mac only, else an API).
enum GuidedWriterRecommendation: Equatable {
    case apple, cli(CLIConfiguration)

    static func make(
        apple: CoreAppleWriterAvailability, installed: [CLIConfiguration], signedIn: [CLIProvider: Bool] = [:],
        onDeviceOnly: Bool = false
    ) -> Self? {
        if apple == .available { return .apple }
        guard !onDeviceOnly else { return nil }
        return installed.first { signedIn[$0.provider] != false }.map(Self.cli)
    }
    var title: String {
        switch self {
        case .apple: return L10n.tr("Apple Foundation Model")
        case .cli(let setup): return setup.provider.displayName
        }
    }
    var caption: String {
        switch self {
        case .apple: return L10n.tr("Runs on this Mac")
        case .cli: return L10n.tr("Command-line tool")
        }
    }
}
