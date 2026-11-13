enum SettingsVisibilitySection: String, CaseIterable, Hashable, Sendable {
    case appOptions = "app-options", indicator
    case recognitionOptions = "recognition-options", finish, livePreview = "recognition-live"
    case translationPreferences = "translation-preferences"
    case apiStreaming = "api-response-streaming"
    case speechVoices = "speech-voices", appPreferences = "app-preferences"
    case dictationPresets = "dictation-presets", recentResult = "recent-result"
    case personalVocabulary = "personal-vocabulary"
    case apiConnection = "api", cliConnection = "cli", speechConnection = "speech-services"
    case modelMaintenance = "model-maintenance", languagePresentation = "language-presentation"
    case permissions, keyAccess = "keychain"
    case moreShortcuts = "more-shortcuts", dictationShortcuts = "dictation-shortcuts"
    case dictationSuggestions = "output-suggestions"

    static func section(forAnchor anchor: String) -> Self? {
        if let section = Self(rawValue: anchor) { return section }
        switch anchor {
        case "apple-speech", "apple-fallback", "recognition-language": return .recognitionOptions
        case "selection-editing", "direction", "quick-return": return .translationPreferences
        case "voice-result-copy-shortcut", "translator-shortcuts": return .moreShortcuts
        case "voice-translation-shortcut": return .dictationShortcuts
        default: return nil
        }
    }

    static func sections(forAnchor anchor: String) -> Set<Self> {
        if anchor == Self.apiStreaming.rawValue { return [.apiConnection, .apiStreaming] }
        if anchor == Self.speechConnection.rawValue { return [.speechConnection, .speechVoices] }
        if anchor == "catalog" { return [.languagePresentation] }
        if anchor == "models" || anchor == "model-browse" { return [.modelMaintenance] }
        return section(forAnchor: anchor).map { [$0] } ?? []
    }

}
