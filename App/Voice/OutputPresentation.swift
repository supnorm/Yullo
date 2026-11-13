import Foundation

// How outputs read in the menu bar, the recording window and Settings: a
// format, in a language ("Email in English", "What I say", "Notes").
enum OutputPresentation {
    // The Format menu: ten everyday formats in four groups. Older saved styles
    // still show their own names where they are in use.
    static let formatGroups: [[String]] = [
        ["spoken", "light"], ["casual", "polite"], ["email", "formal"],
        ["professional", "academic", "bullets", CoreOutput.technical]
    ]

    static func formatTitle(_ format: String, presets: CoreDictationPresetsConfiguration) -> String {
        switch format {
        case "spoken": return L10n.tr("What I say")
        case "light": return L10n.tr("Cleaned up")
        case "casual": return L10n.tr("Message")
        case "polite": return L10n.tr("Polite message")
        case "email": return L10n.tr("Email")
        case "formal": return L10n.tr("Formal letter")
        case "professional": return L10n.tr("Professional")
        case "academic": return L10n.tr("Academic")
        case "bullets": return L10n.tr("Notes")
        case CoreOutput.technical: return L10n.tr("Technical")
        default:
            if let style = RewriteStyle(rawValue: format) { return WritingStylePresentation.title(style) }
            let output = CoreOutput(format: format)
            if let id = output.presetID, let record = presets.record(for: id) {
                return DictationPresetPresentation.title(record)
            }
            return L10n.tr("Format removed")
        }
    }

    // Outputs name languages in the interface language ("French", "Französisch"), never as autonyms.
    // The "Language names" setting applies to language lists, not to these names.
    static func languageTitle(_ id: String?) -> String {
        guard let id else { return L10n.tr("Same as I speak") }
        return Language.displayName(for: id, localized: true, locale: L10n.locale)
    }
    // Language lists follow the "Language names" setting.
    static func languageTitle(_ id: String?, localized: Bool) -> String {
        guard let id else { return L10n.tr("Same as I speak") }
        return Language.displayName(for: id, localized: localized, locale: L10n.locale)
    }

    // What I say, in another language, is a translation: "Translate to English".
    static func name(_ output: CoreOutput, preferences: Preferences) -> String {
        let format = formatTitle(output.format, presets: preferences.dictationPresets)
        guard let language = output.language else { return format }
        if output.format == "spoken" { return L10n.format("Translate to %@", languageTitle(language)) }
        return L10n.format("%1$@ in %2$@", format, languageTitle(language))
    }
}
