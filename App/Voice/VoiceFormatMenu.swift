import Foundation

// What a format runs for this recording, from the same plan as Settings.
struct VoiceFormatPlan: Equatable {
    let choice: VoiceOutputChoice
    let instructions: String?
    let preserveTechnicalLiterals: Bool
}

// Builds the menu and plans picks from one settings snapshot; the app owns it per recording.
@MainActor final class VoiceFormatSource {
    let resolved: String
    private let presets: CoreDictationPresetsConfiguration
    private let defaultStyle: RewriteStyle
    private let fallbackLanguage: String
    private let groups: [[String]]
    private let titles: [String: String]
    private let recents: VoicePillRecents

    init(
        resolved: String, preferences: Preferences, presets: CoreDictationPresetsConfiguration,
        recents: VoicePillRecents
    ) {
        self.resolved = resolved
        self.presets = presets
        self.recents = recents
        defaultStyle = RewriteStyle(rawValue: preferences.voiceRefinementStyle) ?? .professional
        fallbackLanguage = Language.enabled(preferences.enabledLanguages).first?.id ?? "en"
        let own = YourFormats.records(presets).map { CoreOutput.preset($0.id).format }
        groups = OutputPresentation.formatGroups + (own.isEmpty ? [] : [own])
        var titles: [String: String] = [:]
        for format in groups.joined() + [resolved] {
            titles[format] = OutputPresentation.formatTitle(format, presets: presets)
        }
        self.titles = titles
    }

    func menu(selected: String) -> VoiceFormatMenu {
        let composed = CorePillFormats.menu(resolved: resolved, recents: recents.formats, groups: groups)
        let all = composed.top + composed.more.joined()
        return .init(
            top: composed.top, pinned: CorePillFormats.pinned.count, more: composed.more, selected: selected,
            titles: titles,
            writes: Set(all.filter { plan($0, language: nil)?.choice.writes == true }))
    }

    func plan(_ format: String, language: String?) -> VoiceFormatPlan? {
        let output = CoreOutput(format: format, language: language)
        guard output.isValid else { return nil }
        let plan = CoreOutputPlan.make(
            for: output, presets: presets, defaultStyle: defaultStyle, fallbackLanguage: fallbackLanguage)
        let choice: VoiceOutputChoice
        switch plan.task {
        case .asSpoken: choice = .original
        case .translate(let target): choice = .translation(target)
        case .write(let style, _): choice = .refinement(style)
        }
        return .init(
            choice: choice, instructions: plan.instructions, preserveTechnicalLiterals: plan.preserveTechnicalLiterals)
    }

    func remember(_ format: String) { recents.remember(format) }
}

extension VoiceOutputChoice {
    var writes: Bool {
        if case .refinement = self { return true }
        return false
    }
}

// The pill's recent picks, most recent first. Formats only: never text, apps or sites.
final class VoicePillRecents {
    static let key = "voicePillRecentFormats"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var formats: [String] {
        (defaults.stringArray(forKey: Self.key) ?? []).filter { CoreOutput(format: $0).isValid }
    }
    func remember(_ format: String) {
        defaults.set(CorePillFormats.remembering(format, in: formats), forKey: Self.key)
    }
}
