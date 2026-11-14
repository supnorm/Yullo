import CryptoKit
import Foundation
import Carbon

struct Shortcut: Codable, Equatable {
    var key: UInt32
    var modifiers: UInt32
    var label: String
    static let unassigned = Shortcut(key: UInt32.max, modifiers: 0, label: "")
    var isAssigned: Bool { key != UInt32.max }
    static let copy = Shortcut(key: 36, modifiers: UInt32(cmdKey), label: "⌘↩")
    static let replace = Shortcut(key: 36, modifiers: UInt32(cmdKey | shiftKey), label: "⇧⌘↩")
    static let close = Shortcut(key: 53, modifiers: 0, label: "Esc")
    static let open = Shortcut(key: 17, modifiers: UInt32(cmdKey | optionKey), label: "⌥⌘T")
    static let selection = Shortcut(key: 14, modifiers: UInt32(cmdKey | shiftKey), label: "⇧⌘E")
    static let dictation = Shortcut(key: 49, modifiers: UInt32(controlKey | shiftKey), label: "⌃⇧Space")
    static let voiceTranslation = Shortcut(key: 49, modifiers: UInt32(controlKey | optionKey), label: "⌃⌥Space")
    // Refine selected text: R, on the same Control-Shift prefix as Dictate.
    static let refineSelection = Shortcut(key: 15, modifiers: UInt32(controlKey | shiftKey), label: "⌃⇧R")
    // Refine in Yullo window: E, on the same Control-Shift prefix. ⌃⇧R now
    // refines in place (the first Refine in place row).
    static let refineWindow = Shortcut(key: 14, modifiers: UInt32(controlKey | shiftKey), label: "⌃⇧E")
    // Edit with voice in place: S, for say, on the same Control-Shift prefix.
    // It is kept with the row keys under its own ID.
    static let editWithVoice = Shortcut(key: 1, modifiers: UInt32(controlKey | shiftKey), label: "⌃⇧S")
    static let editWithVoiceID = "edit-with-voice"
    // Edit with text: the same edit with a typed request. W, for write.
    static let editWithText = Shortcut(key: 13, modifiers: UInt32(controlKey | shiftKey), label: "⌃⇧W")
    static let editWithTextID = "edit-with-text"
    // Keys with a default that, once removed, stay removed.
    static let rememberedIDs: Set<String> = [editWithVoiceID, editWithTextID]
    // The first builds with Refine selected text saved this as its default.
    static let previousRefineSelection = Shortcut(
        key: 14, modifiers: UInt32(cmdKey | shiftKey | optionKey), label: "⌥⇧⌘E")
    var isValidVoiceResultCopy: Bool {
        !isAssigned
            || (key <= 127 && modifiers != 0 && key != 53
                && !(key == 8 && modifiers == UInt32(cmdKey)))
    }
    func conflicts(_ other: Shortcut) -> Bool {
        isAssigned && other.isAssigned && key == other.key && modifiers == other.modifiers
    }
}

// A profile is a proposal until the Preferences/Settings owner explicitly
// adopts it. Legacy Shortcut constants and saved physical keys stay unchanged.
struct ShortcutProfile: Equatable {
    let open: Shortcut
    let selection: Shortcut
    let dictation: Shortcut
    let voiceTranslation: Shortcut
    let copy: Shortcut
    let replace: Shortcut
    let close: Shortcut
    static let localTranslate = Shortcut(key: 36, modifiers: UInt32(cmdKey), label: "")
    static let localCancel = Shortcut(key: 47, modifiers: UInt32(cmdKey), label: "")
    static let localCloseWindow = Shortcut(key: 13, modifiers: UInt32(cmdKey), label: "")

    // Physical US positions provide deterministic factory data. Explicit
    // adoption resolves each letter in its own modifier/layout context.
    static let recommended = ShortcutProfile(
        open: .init(key: 16, modifiers: UInt32(controlKey | shiftKey), label: ""),
        selection: .init(key: 17, modifiers: UInt32(controlKey | shiftKey), label: ""),
        dictation: .init(key: 9, modifiers: UInt32(controlKey | shiftKey), label: ""),
        voiceTranslation: .unassigned,
        copy: .init(key: 8, modifiers: UInt32(shiftKey | cmdKey), label: ""),
        replace: .replace, close: .close)

    static func recommended(using keyForCharacter: (String, UInt32) -> UInt32?) -> ShortcutProfile? {
        let prefix = UInt32(controlKey | shiftKey)
        let copyModifiers = UInt32(shiftKey | cmdKey)
        guard let y = keyForCharacter("y", prefix), let t = keyForCharacter("t", prefix),
            let v = keyForCharacter("v", prefix), let c = keyForCharacter("c", copyModifiers),
            [y, t, v, c].allSatisfy({ $0 <= 127 })
        else { return nil }
        let profile = ShortcutProfile(
            open: .init(key: y, modifiers: prefix, label: ""),
            selection: .init(key: t, modifiers: prefix, label: ""),
            dictation: .init(key: v, modifiers: prefix, label: ""), voiceTranslation: .unassigned,
            copy: .init(key: c, modifiers: copyModifiers, label: ""), replace: .replace, close: .close)
        guard !profile.hasConflicts, profile.permitsLocalCommand(localTranslate) else { return nil }
        return profile
    }

    var globalBindings: [(id: UInt32, shortcut: Shortcut)] {
        [(1, open), (2, selection), (3, dictation), (4, voiceTranslation)].filter { $0.1.isAssigned }
    }
    var configurableBindings: [Shortcut] { [open, selection, dictation, voiceTranslation, copy, replace, close] }
    var hasConflicts: Bool { Self.hasConflicts(configurableBindings) }
    static func hasConflicts(_ bindings: [Shortcut]) -> Bool {
        for (index, binding) in bindings.enumerated() where binding.isAssigned {
            if bindings.prefix(index).contains(where: { $0.isAssigned && $0.conflicts(binding) }) { return true }
        }
        return false
    }
    // A fixed local addition never steals a saved custom combination.
    func permitsLocalCommand(_ command: Shortcut) -> Bool {
        command.isAssigned && !configurableBindings.contains { $0.isAssigned && $0.conflicts(command) }
    }
}

struct VoiceShortcutFinishPolicy: Equatable {
    let finishOnReturn: Bool
    let finishOnShortcut: Bool
    let finishAfterPause: Bool
    let usesReturnFallback: Bool
}

enum SpeechProvider: String, CaseIterable, Codable, Sendable {
    case macOS = "macos", local, azure, google, elevenlabs, speechAPI = "speech-api"
}

struct SpeechAPIConfiguration: Codable, Equatable, Sendable {
    var endpoint: String
    var model: String
    var voice: String
    var voiceIDsByLanguage: [String: String]
    var responseFormat: String
    init(
        endpoint: String = "", model: String = "", voice: String = "", voiceIDsByLanguage: [String: String] = [:],
        responseFormat: String = "mp3"
    ) {
        self.endpoint = endpoint
        self.model = model
        self.voice = voice
        self.voiceIDsByLanguage = voiceIDsByLanguage
        self.responseFormat = responseFormat
    }
    static let google = SpeechAPIConfiguration(endpoint: "https://texttospeech.googleapis.com")
    static let elevenLabs = SpeechAPIConfiguration(
        endpoint: "https://api.elevenlabs.io", model: "eleven_multilingual_v2")
    func voice(for language: String) -> String {
        let family = Language.speechCode(language)
        let override = voiceIDsByLanguage[family]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return override.isEmpty ? voice : override
    }
    private enum CodingKeys: String, CodingKey { case endpoint, model, voice, voiceIDsByLanguage, responseFormat }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try values.decodeIfPresent(String.self, forKey: .endpoint) ?? ""
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ""
        voice = try values.decodeIfPresent(String.self, forKey: .voice) ?? ""
        voiceIDsByLanguage = try values.decodeIfPresent([String: String].self, forKey: .voiceIDsByLanguage) ?? [:]
        responseFormat = try values.decodeIfPresent(String.self, forKey: .responseFormat) ?? "mp3"
    }
}

enum ProcessingTask: String, CaseIterable, Sendable {
    case translation, writing, readAloud
    var title: String {
        switch self {
        case .translation: return L10n.tr("Translation")
        case .writing: return L10n.tr("Writing")
        case .readAloud: return L10n.tr("Read aloud")
        }
    }
}

struct PausedOnlineChoice: Codable, Equatable, Sendable {
    var online: String
    var onDevice: String
}

struct Preferences: Codable, Equatable {
    var processingPolicy = ProcessingPolicy.standard
    // Online choices set aside by On this Mac only, by task, with the
    // on-device service used meanwhile.
    var pausedOnlineChoices: [String: PausedOnlineChoice] = [:]
    var showInDock = false
    var showInMenuBar = true
    var hideWhenClickingOutside = true
    // Opening Yullo shows the translator; off opens Settings instead.
    var openYulloAtLaunch = true
    var engine = "apple"
    var appleFallback = true
    var endpoint = ""
    var model = ""
    var apiStreamingEnabled = false
    // The API connection (a hash of its endpoint and model) that
    // rejected streaming ("" when none); translations from it arrive complete. Changing either clears it.
    var apiStreamingUnsupported = ""
    var localTranslationModelID = "hy-mt2-18b-q4"
    var cli = CLIConfiguration()
    // Other command-line tools set up before, each with the path and model last used,
    // so switching back restores them.
    var rememberedCLIs: [CLIConfiguration] = []
    var defaultTarget = "en"
    var enabledLanguages = Language.fallbackIDs
    var showLocalizedLanguageNames = true
    var resultHistoryEnabled = false
    var translationResultComparisonEnabled = true
    var restoreTranslationOnQuickReturn = false
    // No longer read: the Refine button is always in the Yullo window. Kept for earlier builds.
    var showTranslationRefinement = false
    var resultHistoryRetention = "week"
    var languageDefaultsVersion = 3
    var interfaceLanguage = "en"
    var mainWindowPosition = "center"
    var appearance = "system"
    // "glass" (Liquid Glass) or "solid" (the same layout, opaque).
    var windowStyle = "glass"
    static let solidWindowStyle = "solid"
    // An earlier build stored Solid as "classic".
    static func isSolidWindowStyle(_ value: String) -> Bool { value == solidWindowStyle || value == "classic" }
    var textSize = 21.0
    var textBold = false
    // Email and Formal letter close with this name when none is spoken; empty adds none.
    var signOffName = ""
    var voiceResultCopyShortcut = Shortcut(key: 8, modifiers: UInt32(shiftKey | cmdKey), label: "")
    var copyShortcut = Shortcut.copy
    var localTranslateShortcut = Shortcut.unassigned
    var replaceShortcut = Shortcut.replace
    var closeShortcut = Shortcut.close
    var speechRate = 1.0
    var speechEngine = "macos"
    var localSpeechModelID = "kokoro-82m-q8"
    var localSpeechVoicesByModel: [String: [String: String]] = [:]
    var localSpeechReferencePath = ""
    var azureRegion = ""
    var azureVoiceIDsByLanguage: [String: String] = [:]
    var speechAPI = SpeechAPIConfiguration()
    var googleSpeech = SpeechAPIConfiguration.google
    var elevenLabsSpeech = SpeechAPIConfiguration.elevenLabs
    // Hashes of non-secret settings for connected services that have worked;
    // see ConnectedService.
    var workingServices: [String: String] = [:]
    var autoTranslate = true
    var learnTranslationDirections = true
    var translateSelection = true
    var selectedTextStartsEditable = false
    var voiceIDs: [String: String] = [:]
    var dictationShortcut = Shortcut.dictation
    // ⌃⌥Space switches input sources on macOS; new installs add a dictation shortcut row instead.
    var voiceTranslationShortcut = Shortcut.unassigned
    // Starts or ends Scenario mode; unassigned until the person chooses one.
    var scenarioShortcut = Shortcut.unassigned
    var refineSelectionShortcut = Shortcut.refineWindow
    var refineShortcutVersion = 2
    var voiceModelID = "whisper-turbo-q5"
    var voiceRecognitionLanguage = "auto"
    var voiceAppleFallback = true
    var voiceAppleLocale = "system"
    var voicePlacement = "bottom"
    var voiceTranslateEnabled = false
    var voiceOutputMode = "original"
    var voiceRefinementStyle = "professional"
    var voiceRefinementEngine = "api"
    var voiceDictationTarget = "original"
    var voiceTarget = "en"
    var voicePreviewFirst = false
    var voiceLivePreview = false
    var voiceLivePreviewSize = "compact"
    // The recording window's language switch: off by default, cycling through
    // up to three languages and Same as I speak for that recording only.
    var voiceLanguageSwitch = false
    var voiceLanguageSwitchLanguages: [String] = []
    var personalVocabulary = CoreVocabularyConfiguration()
    var appPreferences = CoreAppPreferencesConfiguration()
    // Apps whose suggested app preference the person answered with Not now.
    var dismissedAppPreferenceSuggestions: [String] = []
    var dictationPresets = CoreDictationPresetsConfiguration()
    // What dictation and Refine in place write (see CoreOutputs). Older
    // settings migrate once to outputs with the same results; their fields stay
    // readable so an earlier build still finds them.
    var outputs = CoreOutputSettings()
    var outputShortcutKeys: [String: Shortcut] = [
        "refine-1": .refineSelection, Shortcut.editWithVoiceID: .editWithVoice,
        Shortcut.editWithTextID: .editWithText
    ]
    var outputsVersion = CoreOutputSettings.currentVersion
    // Ollama on this Mac (or an address the person set); one model writes and translates.
    var ollamaHost = CoreOllama.defaultHost
    var ollamaModel = ""
    // Write with Apple · on device: the writer that writes instead when Apple's
    // model can't ("" writes nothing and says why). Never chosen automatically.
    var appleWriterFallback = ""
    // Session only: the language a resolved format writes in. Never saved as a default.
    var voiceWritingLanguage: String?
    var voiceResultComparisonEnabled = true
    // Edit with voice shows its result to accept first; off, it replaces in place.
    var voiceEditReview = true
    var voiceKeepRecentResult = false
    var voiceRecentResultSeconds = 300.0
    var voiceFinishOnReturn = true
    var voiceFinishOnShortcut = true
    var voiceAutoFinish = true
    var voiceSilenceSeconds = 3.0
    // Keep only edits made against this Settings baseline. Unchanged fields
    // follow the current owner, so an unrelated staged edit cannot replay an
    // older configuration. Nested configurations move as complete values.
    func mergingEdits(since baseline: Preferences, onto latest: Preferences) -> Preferences {
        var merged = latest
        func keep<Value: Equatable>(_ field: WritableKeyPath<Preferences, Value>) {
            if self[keyPath: field] != baseline[keyPath: field] {
                merged[keyPath: field] = self[keyPath: field]
            }
        }
        keep(\.processingPolicy)
        keep(\.pausedOnlineChoices)
        keep(\.showInDock)
        keep(\.showInMenuBar)
        keep(\.hideWhenClickingOutside)
        keep(\.openYulloAtLaunch)
        keep(\.engine)
        keep(\.appleFallback)
        keep(\.endpoint)
        keep(\.model)
        keep(\.apiStreamingEnabled)
        keep(\.apiStreamingUnsupported)
        keep(\.localTranslationModelID)
        // Connection identity stays atomic; the response preference is independent.
        var connectionEdit = cli
        connectionEdit.preferLowEffort = baseline.cli.preferLowEffort
        if connectionEdit != baseline.cli {
            merged.cli.provider = cli.provider
            merged.cli.executablePath = cli.executablePath
            merged.cli.model = cli.model
        }
        if cli.preferLowEffort != baseline.cli.preferLowEffort {
            merged.cli.preferLowEffort = cli.preferLowEffort
        }
        keep(\.defaultTarget)
        keep(\.enabledLanguages)
        keep(\.showLocalizedLanguageNames)
        keep(\.resultHistoryEnabled)
        keep(\.translationResultComparisonEnabled)
        keep(\.restoreTranslationOnQuickReturn)
        keep(\.showTranslationRefinement)
        keep(\.resultHistoryRetention)
        keep(\.languageDefaultsVersion)
        keep(\.interfaceLanguage)
        keep(\.mainWindowPosition)
        keep(\.appearance)
        keep(\.windowStyle)
        keep(\.signOffName)
        keep(\.textSize)
        keep(\.textBold)
        keep(\.voiceResultCopyShortcut)
        keep(\.copyShortcut)
        keep(\.localTranslateShortcut)
        keep(\.replaceShortcut)
        keep(\.closeShortcut)
        keep(\.speechRate)
        keep(\.speechEngine)
        keep(\.localSpeechModelID)
        keep(\.localSpeechVoicesByModel)
        keep(\.localSpeechReferencePath)
        keep(\.workingServices)
        keep(\.azureRegion)
        keep(\.azureVoiceIDsByLanguage)
        keep(\.speechAPI)
        keep(\.googleSpeech)
        keep(\.elevenLabsSpeech)
        keep(\.autoTranslate)
        keep(\.learnTranslationDirections)
        keep(\.translateSelection)
        keep(\.selectedTextStartsEditable)
        keep(\.voiceIDs)
        keep(\.dictationShortcut)
        keep(\.voiceTranslationShortcut)
        keep(\.scenarioShortcut)
        keep(\.refineSelectionShortcut)
        keep(\.refineShortcutVersion)
        keep(\.voiceModelID)
        keep(\.voiceRecognitionLanguage)
        keep(\.voiceAppleFallback)
        keep(\.voiceAppleLocale)
        keep(\.voicePlacement)
        keep(\.voiceTranslateEnabled)
        keep(\.voiceOutputMode)
        keep(\.voiceRefinementStyle)
        keep(\.voiceRefinementEngine)
        keep(\.voiceDictationTarget)
        keep(\.voiceTarget)
        keep(\.voicePreviewFirst)
        keep(\.voiceLivePreview)
        keep(\.voiceLivePreviewSize)
        keep(\.voiceLanguageSwitch)
        keep(\.voiceLanguageSwitchLanguages)
        keep(\.personalVocabulary)
        keep(\.appPreferences)
        keep(\.dismissedAppPreferenceSuggestions)
        keep(\.dictationPresets)
        keep(\.outputs)
        keep(\.outputShortcutKeys)
        keep(\.outputsVersion)
        keep(\.ollamaHost)
        keep(\.rememberedCLIs)
        keep(\.ollamaModel)
        keep(\.appleWriterFallback)
        keep(\.voiceResultComparisonEnabled)
        keep(\.voiceEditReview)
        keep(\.voiceKeepRecentResult)
        keep(\.voiceRecentResultSeconds)
        keep(\.voiceFinishOnReturn)
        keep(\.voiceFinishOnShortcut)
        keep(\.voiceAutoFinish)
        keep(\.voiceSilenceSeconds)
        return merged
    }
    // Bundle identifiers only, each once, newest kept within a small bound.
    static func normalizedDismissedSuggestions(_ values: [String]) -> [String] {
        var seen = Set<String>()
        let valid = values.reversed().filter { value in
            !value.isEmpty && value.utf8.count <= 255
                && value.utf8.allSatisfy {
                    (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
                        || $0 == 46
                } && seen.insert(value).inserted
        }
        return Array(valid.prefix(32).reversed())
    }
    static func normalizedTextSize(_ value: Double) -> Double {
        value.isFinite ? min(28, max(16, value)) : 21
    }
    static func normalizedSpeechRate(_ value: Double) -> Double {
        value.isFinite ? min(1.2, max(0.6, value)) : 1
    }
    static func normalizedVoiceSilenceSeconds(_ value: Double) -> Double {
        value.isFinite ? min(10, max(1, value)) : 3
    }
    static func normalizedVoiceRecentResultSeconds(_ value: Double) -> Double {
        value.isFinite ? min(86_400, max(60, value)) : 300
    }
    func localSpeechVoices(forModel modelID: String) -> [String: String] {
        localSpeechVoicesByModel[modelID] ?? [:]
    }
    mutating func setLocalSpeechVoices(_ voices: [String: String], forModel modelID: String) {
        guard !modelID.isEmpty else { return }
        localSpeechVoicesByModel[modelID] = voices
    }
    // Model suggestions follow Your languages, top first.
    var modelSuggestionLanguageIDs: [String] { Language.enabled(enabledLanguages).map(\.id) }
    // A task whose chosen service is online: an API, a command-line tool,
    // Ollama elsewhere, or a cloud voice.
    func usesOnlineService(_ task: ProcessingTask) -> Bool {
        func online(_ engine: String) -> Bool {
            engine == "api" || engine == "cli" || (engine == "ollama" && !CoreOllama.isOnThisMac(host: ollamaHost))
        }
        switch task {
        case .translation: return online(engine)
        case .writing: return online(voiceRefinementEngine)
        case .readAloud: return !["macos", "local"].contains(speechEngine)
        }
    }
    // On this Mac only, the tasks that wait for online to be allowed.
    // Translation with Apple as its fallback keeps working.
    var pausedTasks: [ProcessingTask] {
        guard processingPolicy == .onDeviceOnly else { return [] }
        return ProcessingTask.allCases.filter { usesOnlineService($0) && !($0 == .translation && appleFallback) }
    }
    // On this Mac only, the tasks moved to an on-device service.
    var switchedTasks: [ProcessingTask] {
        processingPolicy == .onDeviceOnly
            ? ProcessingTask.allCases.filter { pausedOnlineChoices[$0.rawValue] != nil } : []
    }
    // Where Yullo works. On this Mac only moves each task on an online service
    // to its on-device alternative (when one exists) and remembers the online
    // choice; allowing online again restores each one not changed since.
    func switchingProcessing(
        to policy: ProcessingPolicy, onDevice alternative: (ProcessingTask, Preferences) -> String?
    ) -> Preferences {
        var value = self
        guard policy != processingPolicy else { return value }
        value.processingPolicy = policy
        if policy == .standard {
            for task in ProcessingTask.allCases {
                if let paused = pausedOnlineChoices[task.rawValue], value[engineOf: task] == paused.onDevice {
                    value[engineOf: task] = paused.online
                }
            }
            value.pausedOnlineChoices = [:]
            return value
        }
        for task in ProcessingTask.allCases where usesOnlineService(task) {
            guard let local = alternative(task, self) else { continue }
            value.pausedOnlineChoices[task.rawValue] = .init(online: value[engineOf: task], onDevice: local)
            value[engineOf: task] = local
        }
        return value
    }
    // The owner's rule for every online choice: choosing an online service for
    // a task on this Mac only is deliberate, so it allows online and keeps the
    // choice. Other tasks stay where they are. Returns the task that asked.
    func allowingOnline(after previous: Preferences) -> (Preferences, ProcessingTask)? {
        guard processingPolicy == .onDeviceOnly, previous.processingPolicy == .onDeviceOnly,
            let task = ProcessingTask.allCases.first(where: {
                usesOnlineService($0) && self[engineOf: $0] != previous[engineOf: $0]
            })
        else { return nil }
        var value = self
        value.processingPolicy = .standard
        value.pausedOnlineChoices = [:]
        return (value, task)
    }
    // After a switch, whether a service still needs choosing: online with no
    // task on an online service yet, or on this Mac only with a task paused.
    var needsServiceChoice: Bool {
        processingPolicy == .standard
            ? !ProcessingTask.allCases.contains(where: usesOnlineService) : !pausedTasks.isEmpty
    }
    subscript(engineOf task: ProcessingTask) -> String {
        get {
            switch task {
            case .translation: return engine
            case .writing: return voiceRefinementEngine
            case .readAloud: return speechEngine
            }
        }
        set {
            switch task {
            case .translation: engine = newValue
            case .writing: voiceRefinementEngine = newValue
            case .readAloud: speechEngine = newValue
            }
        }
    }
    // Every binding stored here, plus the separately stored global keys.
    func savedBindings(_ global: [Shortcut]) -> [Shortcut] {
        global + [
            copyShortcut, localTranslateShortcut, replaceShortcut, closeShortcut, voiceResultCopyShortcut,
            dictationShortcut, voiceTranslationShortcut, scenarioShortcut
        ]
    }
    // A new installation starts from the Mac's languages: the first is the one the
    // person speaks, the next is where translation goes. One language translates nowhere yet.
    mutating func adoptSystemLanguages(_ ids: [String]) {
        let languages = Language.enabled(ids).map(\.id)
        enabledLanguages = languages
        let target = languages.dropFirst().first ?? languages[0]
        defaultTarget = target
        voiceTarget = target
    }
    @discardableResult mutating func applyRecommendedShortcuts(_ profile: ShortcutProfile = .recommended) -> Bool {
        guard !profile.hasConflicts, profile.permitsLocalCommand(ShortcutProfile.localTranslate) else { return false }
        copyShortcut = profile.copy
        replaceShortcut = profile.replace
        closeShortcut = profile.close
        dictationShortcut = profile.dictation
        voiceTranslationShortcut = profile.voiceTranslation
        localTranslateShortcut = ShortcutProfile.localTranslate
        return true
    }
    func effectiveVoiceFinishPolicy(forVoiceTranslation: Bool, shortcutAvailable: Bool = true)
        -> VoiceShortcutFinishPolicy
    {
        let binding = forVoiceTranslation ? voiceTranslationShortcut : dictationShortcut
        let shortcut = voiceFinishOnShortcut && binding.isAssigned && shortcutAvailable
        let fallback = !voiceFinishOnReturn && !shortcut && !voiceAutoFinish
        return .init(
            finishOnReturn: voiceFinishOnReturn || fallback, finishOnShortcut: shortcut,
            finishAfterPause: voiceAutoFinish, usesReturnFallback: fallback)
    }
    mutating func normalizeVoiceFinishMethods() {
        if !voiceFinishOnReturn && !voiceFinishOnShortcut && !voiceAutoFinish { voiceFinishOnReturn = true }
    }
    private static func globalShortcuts(_ defaults: UserDefaults) -> [Shortcut] {
        ["openShortcut", "selectionShortcut"].compactMap { name in
            defaults.data(forKey: name).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
        }
    }
    // A new or unreadable store starts from the defaults; their keys give way
    // to global keys already saved, as on a normal load.
    private static func fresh(_ defaults: UserDefaults) -> Preferences {
        var value = Preferences()
        // A new install speaks the Mac's language; settings saved before keep theirs.
        value.interfaceLanguage = "system"
        let taken = value.savedBindings(globalShortcuts(defaults))
        if taken.contains(where: { $0.conflicts(value.refineSelectionShortcut) }) {
            value.refineSelectionShortcut = .unassigned
        }
        for (id, key) in value.outputShortcutKeys where taken.contains(where: { $0.conflicts(key) }) {
            value.outputShortcutKeys[id] = .unassigned
        }
        return value
    }
    static func load(defaults: UserDefaults = .standard) -> Preferences {
        guard let data = defaults.data(forKey: "yullo.preferences"),
            var stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return fresh(defaults) }
        // Settings saved before the language list existed keep the list those versions used.
        let needsLegacyLanguages = !stored.isEmpty && stored["enabledLanguages"] == nil
        let needsReplacementShortcut = stored["replaceShortcut"] == nil
        let needsRefineShortcut = stored["refineSelectionShortcut"] == nil
        // Only the first builds saved ⌥⇧⌘E without a version; a later explicit
        // choice of the same keys is kept.
        let refineFromFirstBuilds =
            (stored["refineShortcutVersion"] as? Int ?? 0) < 2
            && (stored["refineSelectionShortcut"] as? [String: Any]).flatMap {
                try? JSONDecoder().decode(
                    Shortcut.self, from: JSONSerialization.data(withJSONObject: $0))
            }?.conflicts(.previousRefineSelection) == true
        let needsDictationTranslationMigration = stored["voiceTranslateEnabled"] == nil
        let needsVoiceOutputMode = stored["voiceOutputMode"] == nil
        let needsWritingEngine = stored["voiceRefinementEngine"] == nil
        // An empty store is a new install; only saved older settings migrate.
        let needsOutputs =
            !stored.isEmpty && (stored["outputsVersion"] as? Int ?? 0) < CoreOutputSettings.currentVersion
        // Older versions kept one voice map for all local model families. Its
        // only known owner is the model ID saved beside it, never a new default.
        if let legacy = stored["localSpeechVoicesByLanguage"] as? [String: String],
            let modelID = stored["localSpeechModelID"] as? String, !modelID.isEmpty
        {
            let valid = LocalSpeechVoiceCatalog.validLegacySelections(legacy, modelID: modelID)
            if var scoped = stored["localSpeechVoicesByModel"] as? [String: [String: String]] {
                if scoped[modelID] == nil {
                    scoped[modelID] = valid
                    stored["localSpeechVoicesByModel"] = scoped
                }
            } else if stored["localSpeechVoicesByModel"] == nil {
                stored["localSpeechVoicesByModel"] = [modelID: valid]
            }
        }
        stored.removeValue(forKey: "localSpeechVoicesByLanguage")
        if (stored["languageDefaultsVersion"] as? Int ?? 0) < 3 {
            // Only known untouched defaults migrate. Preserve custom membership
            // and user-defined order, including a reordered six-language list.
            let priorDefaults = [
                ["de", "en", "es", "fr", "it", "zh"],
                ["de", "en", "es", "fr", "it", "zh", "yue"]
            ]
            if let ids = stored["enabledLanguages"] as? [String], priorDefaults.contains(ids) {
                stored["enabledLanguages"] = Language.legacyDefaultIDs
            }
            stored["languageDefaultsVersion"] = 3
        }
        if needsLegacyLanguages { stored["enabledLanguages"] = Language.legacyDefaultIDs }
        // Earlier versions kept a second list, Languages you use, for suggestions.
        // Its languages now lead the one list, in their order; none is dropped.
        if let personal = stored.removeValue(forKey: "personalLanguageIDs") {
            let current = stored["enabledLanguages"] as? [String] ?? Language.fallbackIDs
            stored["enabledLanguages"] = Language.leading(personal as? [String] ?? [], in: current)
        }
        // Fill missing fields individually so an older schema never discards a
        // user's endpoint, model or voice choices when a new option is added.
        var baseline: [String: Any] = [:]
        if let data = try? JSONEncoder().encode(Preferences()),
            let encodedDefaults = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        {
            baseline = encodedDefaults
            stored = encodedDefaults.merging(stored) { _, saved in saved }
        }
        guard let migrated = try? JSONSerialization.data(withJSONObject: stored) else { return fresh(defaults) }
        var value: Preferences
        var rejected = Set<String>()
        if let decoded = try? JSONDecoder().decode(Preferences.self, from: migrated) {
            value = decoded
        } else if let recovered = recoverFields(stored, baseline: baseline) {
            value = recovered.0
            rejected = recovered.1
        } else {
            return fresh(defaults)
        }
        // Damaged connection metadata must require setup, not select another
        // provider, executable or saved credential namespace during recovery.
        if rejected.contains("cli") {
            value.cli.executablePath = ""
            value.cli.model = ""
        }
        if rejected.contains("speechAPI") { value.speechAPI = SpeechAPIConfiguration() }
        if rejected.contains("googleSpeech") { value.googleSpeech = SpeechAPIConfiguration() }
        if rejected.contains("elevenLabsSpeech") { value.elevenLabsSpeech = SpeechAPIConfiguration() }
        if rejected.contains("engine") { value.engine = "" }
        if rejected.contains("speechEngine") { value.speechEngine = "" }
        if rejected.contains("voiceRefinementEngine") { value.voiceRefinementEngine = "" }
        if rejected.contains("processingPolicy") { value.processingPolicy = .onDeviceOnly }
        if rejected.contains("voiceResultComparisonEnabled") { value.voiceResultComparisonEnabled = false }
        value.voiceLanguageSwitchLanguages = Language.switchIDs(value.voiceLanguageSwitchLanguages)
        if CoreHistoryRetention(rawValue: value.resultHistoryRetention) == nil {
            value.resultHistoryRetention = "week"
        }
        if (try? value.personalVocabulary.validated()) == nil { value.personalVocabulary.enabled = false }
        if (try? value.appPreferences.validated()) == nil { value.appPreferences.enabled = false }
        value.dismissedAppPreferenceSuggestions = normalizedDismissedSuggestions(
            value.dismissedAppPreferenceSuggestions)
        if rejected.contains("voiceKeepRecentResult") || rejected.contains("voiceRecentResultSeconds") {
            value.voiceKeepRecentResult = false
        }
        if needsReplacementShortcut || rejected.contains("replaceShortcut") {
            let global = ["openShortcut", "selectionShortcut"].compactMap { name in
                defaults.data(forKey: name).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
            }
            let reserved = [value.copyShortcut, value.closeShortcut] + global
            let alternatives = [
                Shortcut.replace,
                Shortcut(key: 36, modifiers: UInt32(cmdKey | optionKey), label: "⌥⌘↩"),
                Shortcut(key: 36, modifiers: UInt32(cmdKey | controlKey), label: "⌃⌘↩"),
                Shortcut(key: 36, modifiers: UInt32(cmdKey | optionKey | controlKey), label: "⌃⌥⌘↩"),
                Shortcut(key: 36, modifiers: UInt32(cmdKey | shiftKey | controlKey), label: "⌃⇧⌘↩")
            ]
            value.replaceShortcut =
                alternatives.first { candidate in !reserved.contains { candidate.conflicts($0) } } ?? .replace
        }
        // An older domain gains the refine default only where no saved binding
        // already uses that combination; otherwise it starts unassigned.
        // A ⌥⇧⌘E saved by the first builds moves to the current default under
        // the same rule.
        if needsRefineShortcut || rejected.contains("refineSelectionShortcut") || refineFromFirstBuilds {
            let global = ["openShortcut", "selectionShortcut"].compactMap { name in
                defaults.data(forKey: name).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
            }
            // An older store's Refine key becomes Refine in place below; a new one starts on the window key.
            let refineDefault = needsOutputs ? Shortcut.refineSelection : .refineWindow
            value.refineSelectionShortcut =
                value.savedBindings(global).contains { $0.conflicts(refineDefault) } ? .unassigned : refineDefault
        }
        value.textSize = normalizedTextSize(value.textSize)
        value.speechRate = normalizedSpeechRate(value.speechRate)
        value.voiceSilenceSeconds = normalizedVoiceSilenceSeconds(value.voiceSilenceSeconds)
        value.voiceRecentResultSeconds = normalizedVoiceRecentResultSeconds(value.voiceRecentResultSeconds)
        value.normalizeVoiceFinishMethods()
        if value.voiceModelID.isEmpty { value.voiceModelID = "whisper-turbo-q5" }
        if value.voiceAppleLocale.isEmpty { value.voiceAppleLocale = "system" }
        if value.voiceDictationTarget != "original" {
            let target = Language.canonicalCode(value.voiceDictationTarget)
            value.voiceDictationTarget =
                Language.enabled(value.enabledLanguages).contains(where: { $0.id == target }) ? target : "original"
        }
        if needsDictationTranslationMigration { value.voiceTranslateEnabled = value.voiceDictationTarget != "original" }
        if needsVoiceOutputMode {
            value.voiceOutputMode = value.voiceDictationTarget == "original" ? "original" : "translate"
        }
        if needsWritingEngine {
            value.voiceRefinementEngine = ["api", "cli"].contains(value.engine) ? value.engine : "api"
        }
        if !["original", "translate", "refine"].contains(value.voiceOutputMode) { value.voiceOutputMode = "original" }
        if !["", "ollama", "api", "cli"].contains(value.appleWriterFallback) { value.appleWriterFallback = "" }
        if RewriteStyle(rawValue: value.voiceRefinementStyle) == nil {
            value.voiceRefinementStyle = "professional"
        }
        if value.voiceOutputMode == "translate", value.voiceDictationTarget == "original" {
            value.voiceDictationTarget = Language.enabled(value.enabledLanguages).first?.id ?? "en"
        }
        let languageIDs = Language.enabled(value.enabledLanguages).map(\.id)
        if needsOutputs || rejected.contains("outputs") {
            let migrated = CoreOutputMigration.migrate(
                .init(
                    translationAndRefinementEnabled: value.voiceTranslateEnabled, outputMode: value.voiceOutputMode,
                    dictationTarget: value.voiceDictationTarget, refinementStyle: value.voiceRefinementStyle,
                    voiceTranslationTarget: value.voiceTarget,
                    voiceTranslationKeyAssigned: value.voiceTranslationShortcut.isAssigned,
                    selectedTextRefinementStyle: value.voiceRefinementStyle,
                    presets: value.dictationPresets, appPreferences: value.appPreferences, languages: languageIDs))
            value.outputs = migrated.settings
            // Only a folded "(edited)" record is added; the old selection stays for an earlier build.
            value.dictationPresets.records = migrated.presets.records
            // Every saved key keeps its keys: voice translation keeps its own
            // key, which its dictation shortcut row shows, and Refine selected
            // text moves to Refine in place. The Refine window gets ⌃⇧E only
            // where nothing saved uses it.
            value.outputShortcutKeys = [:]
            if value.refineSelectionShortcut.isAssigned {
                value.outputShortcutKeys[value.outputs.refineInPlace[0].id] = value.refineSelectionShortcut
            }
            let taken = value.savedBindings(globalShortcuts(defaults)) + Array(value.outputShortcutKeys.values)
            value.refineSelectionShortcut = taken.contains { $0.conflicts(.refineWindow) } ? .unassigned : .refineWindow
            value.outputsVersion = CoreOutputSettings.currentVersion
        } else {
            // Any catalog language stays: More languages… sets a row without adding to your languages.
            value.outputs = value.outputs.validated(languages: Set(Language.catalog.map(\.id)))
        }
        // The voice translation row's key is voiceTranslationShortcut alone; a
        // copy here, saved by an earlier migration, would count it twice.
        value.outputShortcutKeys.removeValue(forKey: CoreOutputSettings.voiceTranslationShortcutID)
        // A voice translation row without a key was added automatically by earlier
        // builds; only rows with a key stay.
        if !value.voiceTranslationShortcut.isAssigned {
            value.outputs.dictationShortcuts.removeAll { $0.id == CoreOutputSettings.voiceTranslationShortcutID }
        }
        (value.outputs, value.dictationPresets) = CoreOutputMigration.formatLanguages(
            value.outputs, value.dictationPresets, fallbackLanguage: languageIDs.first ?? "en")
        // Edit with voice gets ⌃⇧S and Edit with text ⌃⇧W once, each only where no
        // saved key uses it. A removed key is saved as unassigned, so it never comes back.
        for (id, key) in [(Shortcut.editWithVoiceID, Shortcut.editWithVoice), (Shortcut.editWithTextID, .editWithText)]
        where value.outputShortcutKeys[id] == nil {
            let global = ["openShortcut", "selectionShortcut"].compactMap { name in
                defaults.data(forKey: name).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
            }
            let taken =
                global + Array(value.outputShortcutKeys.values) + [
                    value.dictationShortcut, value.voiceTranslationShortcut, value.scenarioShortcut,
                    value.refineSelectionShortcut, value.voiceResultCopyShortcut, value.copyShortcut,
                    value.replaceShortcut, value.localTranslateShortcut, value.closeShortcut
                ]
            value.outputShortcutKeys[id] = taken.contains { $0.conflicts(key) } ? .unassigned : key
        }
        return value
    }
    // The normal load path decodes once. Only a malformed known field takes
    // this bounded fallback; unrelated valid choices remain independent. Values
    // are never logged, persisted here or used to probe a service or credential.
    private static func recoverFields(_ stored: [String: Any], baseline: [String: Any]) -> (Preferences, Set<String>)? {
        guard !baseline.isEmpty else { return nil }
        var accepted = baseline
        var rejected = Set<String>()
        for key in baseline.keys.sorted() {
            guard let saved = stored[key] else { continue }
            var candidate = accepted
            candidate[key] = saved
            if let data = try? JSONSerialization.data(withJSONObject: candidate),
                (try? JSONDecoder().decode(Preferences.self, from: data)) != nil
            {
                accepted = candidate
            } else {
                rejected.insert(key)
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: accepted),
            let value = try? JSONDecoder().decode(Preferences.self, from: data)
        else { return nil }
        return (value, rejected)
    }
    func persist(defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: "yullo.preferences")
    }

    var appPreferenceDefaultTarget: String {
        let available = Set(Language.catalog.map(\.id))
        if available.contains(voiceDictationTarget) { return voiceDictationTarget }
        if available.contains(defaultTarget) { return defaultTarget }
        return Language.enabled(enabledLanguages).first?.id ?? "en"
    }
    // Settings describe configured output, even while processing is paused.
    // Inherited preset fields stay nil: the next target app can supply its rule.
    var configuredDictationPresetDefinition: CoreDictationPresetDefinition {
        if let id = dictationPresets.selectedID, let record = dictationPresets.record(for: id), record.enabled {
            return record.definition.applying(dictationPresets.currentOverrides)
        }
        return .init(
            mode: voiceOutputMode,
            targetLanguage: voiceOutputMode == "translate" ? appPreferenceDefaultTarget : nil,
            style: voiceOutputMode == "refine" ? voiceRefinementStyle : nil)
    }
    var globalVoiceOutputChoice: CoreAppOutputChoice {
        guard voiceTranslateEnabled else { return .original }
        switch voiceOutputMode {
        case "translate": return .translation(appPreferenceDefaultTarget)
        case "refine": return .refinement(RewriteStyle(rawValue: voiceRefinementStyle) ?? .professional)
        default: return .original
        }
    }
    // The output for one recording, as a private session value: a choice made
    // while recording, then the shortcut that started it, then the rule for the
    // app in front, then Everywhere else (see CoreOutputs).
    // A website is the front browser page's host, used for this resolution only.
    func resolvingOutput(
        applicationBundleID: String?, website: String? = nil, shortcutID: String? = nil,
        recordingChoice: CoreOutput? = nil, presets: CoreDictationPresetsConfiguration? = nil
    ) -> (preferences: Preferences, output: CoreAppPreferenceResolution, format: String) {
        let resolution = outputs.resolve(
            applicationBundleID: applicationBundleID, website: website, shortcutID: shortcutID,
            recordingChoice: recordingChoice)
        let plan = CoreOutputPlan.make(
            for: resolution.output, presets: presets ?? dictationPresets,
            defaultStyle: RewriteStyle(rawValue: voiceRefinementStyle) ?? .professional,
            fallbackLanguage: Language.enabled(enabledLanguages).first?.id ?? "en")
        var value = self
        value.voiceTranslateEnabled = true
        value.voiceWritingLanguage = nil
        let choice: CoreAppOutputChoice
        switch plan.task {
        case .asSpoken:
            value.voiceOutputMode = "original"
            choice = .original
        case .translate(let target):
            value.voiceOutputMode = "translate"
            value.voiceDictationTarget = target
            value.voiceTarget = target
            if !value.enabledLanguages.contains(target) { value.enabledLanguages.append(target) }
            choice = .translation(target)
        case .write(let style, let language):
            value.voiceOutputMode = "refine"
            value.voiceRefinementStyle = style.rawValue
            value.voiceWritingLanguage = language
            choice = .refinement(style)
        }
        var ruleID: UUID?
        if case .application(let id) = resolution.source { ruleID = id }
        return (
            value,
            .init(
                choice: choice, appliedRuleID: ruleID, appliedPresetID: plan.presetID,
                preserveTechnicalLiterals: plan.preserveTechnicalLiterals, presetInstructions: plan.instructions),
            resolution.output.format
        )
    }
    // Assemble a private session value once. App rules never persist model,
    // credential, policy or favorite-language changes, and never own a target.
    func applyingAppPreferences(
        applicationBundleID: String?, context: CoreAppPreferenceContext,
        sessionChoice: CoreAppOutputChoice? = nil
    ) -> Preferences {
        resolvingVoicePreferences(
            applicationBundleID: applicationBundleID, context: context, sessionChoice: sessionChoice
        ).preferences
    }
    // The caller owns this one resolved snapshot. It must inspect any issue
    // before starting, and never persist the materialized session as defaults.
    func resolvingVoicePreferences(
        applicationBundleID: String?, context: CoreAppPreferenceContext,
        sessionChoice: CoreAppOutputChoice? = nil, presets: CoreDictationPresetsConfiguration? = nil
    ) -> (preferences: Preferences, output: CoreAppPreferenceResolution) {
        switch context {
        case .sourceEditor, .trial, .recentResult, .voiceEdit:
            return (self, .init(choice: globalVoiceOutputChoice))
        case .dictation, .voiceTranslation: break
        }
        let resolution = appPreferences.resolve(
            applicationBundleID: applicationBundleID, context: context,
            outputModesEnabled: voiceTranslateEnabled, globalChoice: globalVoiceOutputChoice,
            voiceTranslationTarget: voiceTarget, defaultDictationTarget: appPreferenceDefaultTarget,
            defaultRefinementStyle: RewriteStyle(rawValue: voiceRefinementStyle) ?? .professional,
            availableTargetLanguageIDs: Set(Language.catalog.map(\.id)), sessionChoice: sessionChoice,
            presets: presets, presetLibrary: dictationPresets)
        guard voiceTranslateEnabled, resolution.presetIssue == nil,
            resolution.appliedRuleID != nil || resolution.appliedPresetID != nil || sessionChoice != nil
        else { return (self, resolution) }
        var value = self
        switch resolution.choice {
        case .original:
            if context == .dictation { value.voiceOutputMode = "original" }
        case .translation(let target):
            guard Language.catalog.contains(where: { $0.id == target }) else { return (self, resolution) }
            if context == .voiceTranslation {
                value.voiceTarget = target
            } else {
                value.voiceOutputMode = "translate"
                value.voiceDictationTarget = target
            }
            if !value.enabledLanguages.contains(target) { value.enabledLanguages.append(target) }
        case .refinement(let style):
            guard context == .dictation else { return (self, resolution) }
            value.voiceOutputMode = "refine"
            value.voiceRefinementStyle = style.rawValue
        }
        return (value, resolution)
    }
}

// Yullo's bundle identifier moved from local.yullo.app to me.yullo.app. The
// first launch under the new identifier copies the old settings domain once,
// only while the new one is still empty; the old domain is left in place.
// How the edit review shows a result: clean, or with what changed in place. One value,
// shared by the Settings row and the review's own button, saved the moment it changes.
enum ReviewDisplay {
    static let showsChangesKey = "yullo.review.showsChanges"
    // Where it is saved; checks give it a store of their own.
    nonisolated(unsafe) static var store = UserDefaults.standard
}

enum LegacyDefaultsMigration {
    static let legacyDomain = "local.yullo.app"
    static func run(
        defaults: UserDefaults = .standard, currentDomain: String? = Bundle.main.bundleIdentifier,
        legacyDomain: String = Self.legacyDomain
    ) {
        guard let currentDomain, currentDomain != legacyDomain,
            (defaults.persistentDomain(forName: currentDomain) ?? [:]).isEmpty,
            let legacy = defaults.persistentDomain(forName: legacyDomain), !legacy.isEmpty
        else { return }
        defaults.setPersistentDomain(legacy, forName: currentDomain)
    }
}

// Whether the saved API connection is known not to stream; learned when a service
// accepted a request only without streaming. The record is a hash, never readable settings.
extension Preferences {
    private var apiStreamingFingerprint: String {
        let digest = SHA256.hash(data: Data(["api.streaming", endpoint, model].joined(separator: "\u{1F}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    var apiStreamingKnownUnsupported: Bool { apiStreamingUnsupported == apiStreamingFingerprint }
    var apiStreamsTranslations: Bool { apiStreamingEnabled && !apiStreamingKnownUnsupported }
    mutating func recordAPIStreamingUnsupported() { apiStreamingUnsupported = apiStreamingFingerprint }
    // What was learned about streaming belongs to one endpoint and model.
    mutating func clearAPIStreamingSupport(ifConnectionChangedFrom previous: Preferences) {
        if endpoint != previous.endpoint || model != previous.model { apiStreamingUnsupported = "" }
    }
}
