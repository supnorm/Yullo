import Foundation

// Stable identifiers preserve the last page while display names can evolve.
// Voice input and read aloud are separate input/output workflows. A remembered
// identifier that no longer exists, such as the former Advanced page, opens General.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "General", translation = "Translation", refine = "Refine", dictation = "Dictation",
        speech = "Speech", history = "History", languages = "Languages", models = "Services",
        setup = "Setup", about = "About"
    var id: String { rawValue }
    // A page remembered by an earlier build under its former identifier.
    static func stored(_ value: String) -> SettingsPage? {
        SettingsPage(rawValue: value == "Models & connections" ? SettingsPage.models.rawValue : value)
    }
    static let displayOrder: [SettingsPage] = [
        .setup, .general, .translation, .refine, .dictation, .speech, .history, .languages, .models, .about
    ]
    var title: String {
        switch self {
        case .dictation: return L10n.tr("Dictation")
        case .speech: return L10n.tr("Read aloud")
        case .models: return L10n.tr("Services")
        case .setup: return L10n.tr("Quick setup")
        default: return L10n.tr(rawValue)
        }
    }
    static func destination(_ page: SettingsPage, anchor: String?) -> SettingsPage {
        // Former Advanced anchors follow their controls to the pages that now own them.
        if [
            "app-options", "voice-shortcuts", "voice-global-shortcuts", "voice-translation-shortcut",
            "scenario-shortcut", "refine-selection-shortcut", "refine-in-place-shortcut", "window",
            "translator-shortcuts", "cache", "experience-mode"
        ].contains(anchor ?? "") {
            return .general
        }
        if anchor == "recent-result" { return .history }
        // Your formats are made and chosen where dictation's outputs are.
        if ["indicator", "output", "dictation-shortcuts", "voice-translation", "writing-presets", "dictation-presets"]
            .contains(anchor ?? "")
        {
            return .dictation
        }
        // Refine's rows and its writer left Translation for the Refine page.
        if ["refine-selection", "refine-in-place", "refine-writer", "translation-comparison"]
            .contains(anchor ?? "")
        {
            return .refine
        }
        // A writing-service link from a task with its own page stays there; the rest open Translation.
        if ["writing-service", "refine-setup", "translation-writing", "quick-return"].contains(anchor ?? ""),
            page != .refine, page != .dictation
        {
            return .translation
        }
        if page == .general,
            ["permissions", "selection", "quick-setup", "processing", "experience-setup", "trial-details"].contains(
                anchor ?? "")
        {
            return .setup
        }
        return page
    }
    var symbol: String {
        switch self {
        case .setup: return "sparkles"
        case .general: return "switch.2"
        case .dictation: return "mic"
        case .models: return "externaldrive"
        case .about: return "info.circle"
        case .translation: return "translate"
        case .refine: return "wand.and.sparkles"
        case .speech: return "speaker.wave.2"
        case .languages: return "globe"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

struct SettingsSearchEntry: Identifiable {
    let titleKey: String
    let page: SettingsPage
    let anchor: String
    let relatedKeys: [String]
    let contextKey: String?
    init(titleKey: String, page: SettingsPage, anchor: String, relatedKeys: [String], contextKey: String? = nil) {
        self.titleKey = titleKey
        self.page = page
        self.anchor = anchor
        self.relatedKeys = relatedKeys
        self.contextKey = contextKey
    }
    var id: String { titleKey }
    var title: String { L10n.tr(titleKey) }
    var location: String { ([page.title] + (contextKey.map { [L10n.tr($0)] } ?? [])).joined(separator: " · ") }
    func matches(_ query: String) -> Bool {
        let text = ([title, location, L10n.tr(page.rawValue)] + relatedKeys.map(L10n.tr)).joined(separator: " ")
        let terms = query.split(whereSeparator: \.isWhitespace)
        return !terms.isEmpty && terms.allSatisfy { text.localizedStandardContains(String($0)) }
    }
    /// Lower is closer: exact title, title prefix, title contains, then any other matching text.
    func rank(for query: String) -> Int {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        if title.compare(query, options: options) == .orderedSame { return 0 }
        if title.range(of: query, options: options.union(.anchored)) != nil { return 1 }
        return title.localizedStandardContains(query) ? 2 : 3
    }
}

enum SettingsConnectionSection: String, Hashable { case api, cli, speech = "speech-services" }
enum SettingsCustomizationGroup: String, CaseIterable, Hashable {
    case translationPreferences = "translation-preferences", speechVoices = "speech-voices"

    static func matching(anchor: String) -> Self? {
        if let group = Self(rawValue: anchor) { return group }
        if anchor == "selection-editing" || anchor == "direction" || anchor == "quick-return" {
            return .translationPreferences
        }
        return nil
    }
}
enum SettingsDisclosurePolicy {
    static func connections(translation: String, refinement: String, refining: Bool, speech: String) -> Set<
        SettingsConnectionSection
    > {
        var result = Set<SettingsConnectionSection>()
        for engine in [translation] + (refining ? [refinement] : []) {
            if engine == "api" { result.insert(.api) }
            if engine == "cli" { result.insert(.cli) }
        }
        if speech != "macos" && speech != "local" { result.insert(.speech) }
        return result
    }
}

enum SettingsSearch {
    // The former Advanced page's vocabulary still finds the controls it held.
    private static let formerAdvancedKeys = ["Advanced settings", "Detailed settings", "Show advanced settings"]
    static let entries: [SettingsSearchEntry] = [
        .init(
            titleKey: "Remember the last translation for 30 seconds", page: .translation, anchor: "quick-return",
            relatedKeys: [
                "Keep translation for quick return", "Return within 30 seconds after clicking outside.",
                "Yullo window"
            ]),
        .init(
            titleKey: "Your formats", page: .dictation, anchor: "output",
            relatedKeys: ["New format…", "Edit formats…", "Start from", "Academic", "Instructions", "Formats", "Format"]
        ),
        .init(
            titleKey: "Copy result", page: .general, anchor: "voice-result-copy-shortcut",
            relatedKeys: ["Copy voice result", "Copy", "Copy draft", "Keyboard shortcuts", "While a result is showing"]),
        .init(
            titleKey: "Translate now", page: .general, anchor: "translator-shortcuts",
            relatedKeys: ["Keyboard shortcuts", "Yullo shortcuts", "When Yullo is active"]
                + formerAdvancedKeys),
        .init(
            titleKey: "What dictation writes", page: .dictation, anchor: "output",
            relatedKeys: [
                "Everywhere else", "Writes", "Format", "Language", "Same as I speak", "More languages…",
                "Output language", "Default output", "Default output language", "Allow translation and refinement",
                "Output modes", "Original", "Translate", "Refine", "Style", "Email", "Notes", "Voice input",
                "Technical writing", "Technical"
            ]),
        .init(
            titleKey: "Add app…", page: .dictation, anchor: "output",
            relatedKeys: ["App preferences", "Use app preferences", "Style or format", "Everywhere else"],
            contextKey: "What dictation writes"),
        .init(
            titleKey: "Dictation shortcuts", page: .dictation, anchor: "dictation-shortcuts",
            relatedKeys: [
                "Add shortcut…", "Voice translation", "Voice translation shortcut", "Start voice translation",
                "Translate to", "Default target language", "Message translation", "More shortcuts"
            ]),
        .init(
            titleKey: "Saved keys", page: .setup, anchor: "keychain",
            relatedKeys: [
                "Saved keys", "Keychain", "Check saved key access", "Check access", "Allow access…", "No saved key",
                "Key available"
            ]),
        .init(
            titleKey: "History", page: .history, anchor: "history",
            relatedKeys: [
                "Search history", "Translate again", "All types",
                "Result type", "Date range", "Reset filters"
            ]),
        .init(
            titleKey: "History settings", page: .history, anchor: "history-settings",
            relatedKeys: [
                "Save new results", "Keep for", "Forever", "Custom…", "Save on this Mac",
                "Clear history…", "Clear all history…", "Auto-delete"
            ]),
        .init(
            titleKey: "Personal vocabulary", page: .languages, anchor: "personal-vocabulary",
            relatedKeys: [
                "Use personal vocabulary", "Recognition hint", "Spelling correction", "Translation term",
                "Preferred spelling", "Personalization"
            ]),
        .init(
            titleKey: "Review before inserting", page: .dictation, anchor: "after-speaking",
            relatedKeys: [
                "Show before and after", "Compare original and result", "When finished", "Insert directly",
                "Preview", "Preview first", "Comparison"
            ]),
        .init(
            titleKey: "Setup", page: .setup, anchor: "get-started",
            relatedKeys: [
                "Get started", "Start guide…", "Continue setup…", "Tutorial", "Permissions", "Try dictation"
            ]),
        .init(titleKey: "Dictation", page: .dictation, anchor: "start-dictation", relatedKeys: ["Voice input"]),
        .init(
            titleKey: "Recording indicator", page: .dictation, anchor: "indicator",
            relatedKeys: ["Recording", "Notch", "Bottom bar", "Near caret"]),
        .init(
            titleKey: "Use Apple Speech if local recognition fails", page: .dictation,
            anchor: "recognition",
            relatedKeys: ["Apple fallback on", "Apple fallback off", "Recognition options"]),
        .init(
            titleKey: "Apple Speech language", page: .dictation, anchor: "recognition-language",
            relatedKeys: ["Download Apple Speech language", "System language", "Recognition options"]),
        .init(
            titleKey: "Recognition model", page: .dictation, anchor: "recognition",
            relatedKeys: [
                "Browse models…", "Spoken language", "Cohere", "Apple Speech · on device",
                "Use Apple Speech if local recognition fails", "Use Apple Speech if Whisper fails",
                "Apple Speech language", "Download Apple Speech language", "Show words while listening", "Live preview"
            ]),
        .init(
            titleKey: "End recording", page: .dictation, anchor: "finish",
            relatedKeys: [
                "Return", "Press shortcut again", "Press the shortcut that started recording.",
                "End after a pause", "After a pause", "Press Return", "Pause duration"
            ]),
        .init(
            titleKey: "Start dictation", page: .dictation, anchor: "start-dictation",
            relatedKeys: ["Keyboard shortcuts", "Dictation"]),
        .init(
            titleKey: "Temporary format", page: .general, anchor: "scenario-shortcut",
            // The former names stay findable.
            relatedKeys: ["Situation", "Start scenario…", "Describe the format", "Keyboard shortcuts", "Formats"]),
        .init(
            titleKey: "Refine in Yullo window", page: .refine, anchor: "refine-selection",
            relatedKeys: ["Refine selected text", "Refine", "Selected text", "Keyboard shortcuts"]),
        .init(
            titleKey: "Refine in place", page: .refine, anchor: "refine-in-place",
            relatedKeys: ["Replace selected text", "Add another…", "Refine", "Selected text", "Keyboard shortcuts"]),
        .init(
            titleKey: "Edit with voice", page: .refine, anchor: "edit-with-voice",
            relatedKeys: ["Review before replacing", "Selected text", "Keyboard shortcuts"]),
        .init(
            titleKey: "Show changes", page: .refine, anchor: "edit-review",
            relatedKeys: [
                "Mark what changed in the review.", "Press ⇧⌘D there to switch.", "Show Changes",
                "Review before replacing", "Edit with voice", "Edit with text"
            ]),
        .init(
            titleKey: "Edit with text", page: .refine, anchor: "edit-with-text",
            relatedKeys: ["Edit with voice", "Selected text", "Keyboard shortcuts"]),
        .init(
            titleKey: "Browse models", page: .models, anchor: "model-browse",
            relatedKeys: [
                "Browse models…", "Search models", "Download", "Recommended", "On this Mac", "Apple Foundation Model"
            ],
            contextKey: "On this Mac"),
        .init(
            titleKey: "Services", page: .models, anchor: "models",
            relatedKeys: [
                "Download", "Import model…", "Import speech model…",
                "Import translation model…", "Import voice model…", "On this Mac", "Model source",
                "More model sources", "Local model"
            ]),
        .init(
            titleKey: "Ollama", page: .models, anchor: "ollama",
            relatedKeys: ["Get Ollama…", "Open Ollama", "Address", "Model", "Other models…", "Local model"],
            contextKey: "Services"),
        .init(
            titleKey: "Where Yullo works", page: .setup, anchor: "processing",
            relatedKeys: [
                "On this Mac only", "On this Mac and online", "Choose models…",
                "local offline privacy on device online cloud processing"
            ]),
        .init(
            titleKey: "Quick setup", page: .setup, anchor: "quick-setup",
            relatedKeys: [
                "Setup", "Set up…", "On this Mac", "Your services", "Download models", "Apply setup",
                "On this Mac only",
                "On this Mac and online",
                "Translation API", "Voice service", "Browse local models…"
            ]),
        .init(
            titleKey: "Start guide…", page: .setup, anchor: "get-started",
            relatedKeys: ["Continue setup…", "Task setup…", "Tutorial"]),
        .init(
            titleKey: "Try dictation", page: .setup, anchor: "quick-setup",
            relatedKeys: [
                "Selected recognizer: %@", "Dictation shortcut: %@",
                "Uses your recognition settings, including fallback. Shows a preview without inserting into another app."
            ]),
        .init(
            titleKey: "About", page: .about, anchor: "top",
            relatedKeys: ["Version", "Build", "Open-source licenses", "Third-party notices"]),
        .init(titleKey: "Interface language", page: .general, anchor: "app", relatedKeys: ["Languages", "System"]),
        .init(titleKey: "Show in Dock", page: .general, anchor: "app-options", relatedKeys: ["App"]),
        .init(
            titleKey: "Show in menu bar", page: .general, anchor: "app-options", relatedKeys: ["App"]
        ),
        .init(
            titleKey: "Launch at login", page: .general, anchor: "launch-at-login",
            relatedKeys: ["App", "Start quietly when you log in to your Mac."]),
        .init(
            titleKey: "Automatically check for updates", page: .general, anchor: "automatic-updates",
            relatedKeys: ["App", "Check for Updates…"]),
        .init(
            titleKey: "When Yullo opens", page: .general, anchor: "app-options",
            relatedKeys: ["Open at launch", "App", "Settings", "Launch at login", "Nothing opens at login."]),
        .init(
            titleKey: "Hide when another app becomes active", page: .general, anchor: "window",
            relatedKeys: ["Window", "Window behavior", "Hide on app switch", "Keep translation for quick return"]
                + formerAdvancedKeys),
        .init(
            titleKey: "Main window position", page: .general, anchor: "window",
            relatedKeys: ["Center on current screen", "Remember last position", "Window", "Window behavior"]
                + formerAdvancedKeys),
        .init(
            titleKey: "Appearance", page: .general, anchor: "app",
            relatedKeys: ["App", "Appearance", "Light", "Dark", "System"]),
        .init(
            titleKey: "Text size in Yullo windows", page: .general, anchor: "text-size",
            relatedKeys: ["Text size", "Bold text", "App", "Appearance"]),
        .init(
            titleKey: "Keyboard shortcuts", page: .general, anchor: "shortcuts",
            relatedKeys: [
                "Show / hide Yullo", "Translate selected text", "Click a shortcut to edit.",
                "Reset translator shortcuts",
                "Reset to defaults"
            ]),
        .init(
            titleKey: "Copy translation", page: .general, anchor: "translator-shortcuts",
            relatedKeys: ["Yullo shortcuts", "Keyboard shortcuts"] + formerAdvancedKeys),
        .init(
            titleKey: "Replace selection", page: .general, anchor: "translator-shortcuts",
            relatedKeys: ["Yullo shortcuts", "Keyboard shortcuts"] + formerAdvancedKeys),
        .init(
            titleKey: "Hide Yullo", page: .general, anchor: "translator-shortcuts",
            relatedKeys: ["Yullo shortcuts", "Keyboard shortcuts"] + formerAdvancedKeys),
        .init(
            titleKey: "Accessibility", page: .setup, anchor: "permissions",
            relatedKeys: ["Selected text", "Translate selected text", "Accessibility required", "Accessibility enabled"]
        ),
        .init(
            titleKey: "Let me edit the text first", page: .translation, anchor: "selected-text",
            relatedKeys: ["Start selected text in edit mode", "Selected text", "Edit source text"]),
        .init(
            titleKey: "Permissions", page: .setup, anchor: "permissions",
            relatedKeys: ["Enable voice input", "Microphone", "Accessibility required", "Open Microphone Settings"]),
        .init(
            titleKey: "Translate with", page: .translation, anchor: "translation-model",
            relatedKeys: [
                "Translation service", "Translation model", "Apple · on device", "Local model", "Ollama",
                "Translation API", "API connection", "Your API", "Command-line tools", "Translator"
            ]),
        .init(
            titleKey: "Manage languages…", page: .translation, anchor: "apple",
            relatedKeys: [
                "Download languages", "Apple translation languages", "Apple · on device", "Offline & fallback"
            ]),
        .init(
            titleKey: "API connection", page: .models, anchor: "api",
            relatedKeys: [
                "Translation API", "Your API", "API URL", "Model ID", "API key", "Test connection", "Keychain"
            ]),
        .init(
            titleKey: "Stream translations", page: .models, anchor: "api-response-streaming",
            relatedKeys: ["API connection", "Translation"]),
        .init(
            titleKey: "Command-line tools", page: .models, anchor: "cli",
            relatedKeys: [
                "CLI provider", "Executable path", "Model ID", "Check installation", "Setup guide", "Detect locally",
                "Suggested models", "Refresh models", "Test translation", "Recommended", "Set up command-line tools…",
                "Prefer faster responses", "When the model supports it, uses less reasoning to respond faster."
            ]),
        .init(
            titleKey: "If it fails, use Apple", page: .translation, anchor: "apple",
            relatedKeys: ["Use Apple if translation fails", "Offline & fallback"]),
        .init(
            titleKey: "Show before and after", page: .refine, anchor: "translation-comparison",
            relatedKeys: ["Compare translation and refined text", "Comparison", "Refine translations", "Yullo window"]
                + formerAdvancedKeys,
            contextKey: "In the Yullo window"),
        .init(
            titleKey: "Translate as I type", page: .translation, anchor: "yullo-window",
            relatedKeys: ["Automatic translation", "Yullo window"]),
        .init(
            titleKey: "Translate right away", page: .translation, anchor: "selected-text",
            relatedKeys: ["Translate selected text automatically", "Automatic translation", "Selected text"]),
        .init(
            titleKey: "Suggest my usual languages", page: .translation, anchor: "language-suggestions",
            relatedKeys: [
                "Target language", "Auto-detect", "Use my usual target languages", "Reset remembered languages",
                "Reset remembered language choices", "Translation direction", "Learn from my language choices",
                "Reset learned directions"
            ]),
        .init(
            titleKey: "Clear cached translations and audio", page: .general, anchor: "cache",
            relatedKeys: ["Maintenance", "Clear translation & audio cache", "History and settings aren’t affected."]
                + formerAdvancedKeys),
        .init(
            titleKey: "Show language button", page: .dictation, anchor: "language-switch",
            relatedKeys: ["Recording indicator", "Quick languages"]),
        .init(
            titleKey: "Quick languages", page: .dictation, anchor: "quick-languages",
            relatedKeys: ["More languages…", "Same as I speak"]),
        .init(
            titleKey: "Live preview", page: .dictation, anchor: "recognition-live",
            relatedKeys: [
                "Show words while listening", "Choose a model with live preview…", "Recognition model",
                "Preview size", "2 lines", "4 lines", "Scrollable preview"
            ]),
        .init(
            titleKey: "Recent result", page: .history, anchor: "recent-result",
            relatedKeys: ["Keep the latest result briefly", "Keep for", "Clear recent result"]),
        .init(titleKey: "Speed", page: .speech, anchor: "playback", relatedKeys: ["Playback"]),
        .init(
            titleKey: "Voice", page: .speech, anchor: "speech-voices",
            relatedKeys: ["macOS", "Automatic", "Play sample", "Use my own recording…"]),
        .init(
            titleKey: "Customize voices", page: .speech, anchor: "speech-voices",
            relatedKeys: ["Voice language", "Voice override", "This language only."]),
        .init(
            titleKey: "Cloud voice", page: .models, anchor: "speech-services",
            relatedKeys: [
                "Voice connection", "Voice service", "Voice services", "Speech services", "Azure Speech", "Google",
                "ElevenLabs",
                "Custom speech service",
                "Voice ID",
                "Speech key", "Speech API key", "Test voice", "Load available voices", "Refresh voice list",
                "Refresh voices", "Refresh models"
            ], contextKey: "Cloud voices"),
        .init(
            titleKey: "Sign letters as", page: .languages, anchor: "sign-off-name",
            relatedKeys: ["Your name", "Email", "Formal letter", "Sign-off", "Signature", "Name", "Letter"],
            contextKey: "Personalization"),
        .init(
            titleKey: "Write with", page: .refine, anchor: "writing-service",
            relatedKeys: [
                "Writing service", "Refine service", "Voice editing", "Writer", "Ollama", "API connection",
                "Your API", "Command-line tools", "Refine setup…"
            ]),
        .init(
            titleKey: "Names in English", page: .languages, anchor: "language-presentation",
            relatedKeys: ["Names in interface language", "Languages"]),
        .init(
            titleKey: "Your languages", page: .languages, anchor: "catalog",
            relatedKeys: [
                "Add language…", "Search languages", "Names in English", "Names in interface language",
                "Move to top", "Move up", "Move down", "Reset to defaults",
                "Apple translation support. Language pairs may need a download."
            ])
    ]
    /// Matching entries, closest titles first; declaration order is kept within each tier.
    static func results(for query: String, hiding hidden: Set<String> = []) -> [SettingsSearchEntry] {
        entries.enumerated().filter { !hidden.contains($0.element.anchor) && $0.element.matches(query) }
            .map { (rank: $0.element.rank(for: query), index: $0.offset, entry: $0.element) }
            .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.map(\.entry)
    }
}
