import Foundation

// What dictation or Refine in place writes: a format, in a language. One value
// serves Everywhere else, app rules, dictation shortcuts and Refine rows, so
// every picker writes exactly the output it names.
public struct CoreOutput: Codable, Equatable, Hashable, Sendable {
    // "spoken" (What I say), "technical", a RewriteStyle raw value, or
    // "preset:<record id>" for one of the person's own presets.
    public var format: String
    // nil means the language the person speaks.
    public var language: String?

    public init(format: String, language: String? = nil) {
        self.format = format
        self.language = language
    }

    public static let spoken = CoreOutput(format: "spoken")
    public static let technical = "technical"
    static let presetPrefix = "preset:"

    public var isSpoken: Bool { format == "spoken" }
    public var style: RewriteStyle? { RewriteStyle(rawValue: format) }
    public var presetID: String? {
        format.hasPrefix(Self.presetPrefix) ? String(format.dropFirst(Self.presetPrefix.count)) : nil
    }
    public static func preset(_ id: String, language: String? = nil) -> Self {
        .init(format: presetPrefix + id, language: language)
    }
    public var isValid: Bool {
        if isSpoken || format == Self.technical || style != nil { return true }
        return presetID.map { CoreDictationPresetsConfiguration.validIdentifier($0) } ?? false
    }
}

// What the pipeline runs for an output. A format in another language is one
// writing request in that language; translation alone is the translator's job.
public enum CoreOutputTask: Equatable, Sendable {
    case asSpoken
    case translate(String)
    case write(style: RewriteStyle, language: String?)
}

public struct CoreOutputPlan: Equatable, Sendable {
    public let task: CoreOutputTask
    public let presetID: String?
    public let instructions: String?
    public let preserveTechnicalLiterals: Bool
    // A preset that no longer exists falls back to the default style, never another preset.
    public let presetMissing: Bool

    public static func make(
        for output: CoreOutput, presets: CoreDictationPresetsConfiguration?, defaultStyle: RewriteStyle,
        fallbackLanguage: String
    ) -> Self {
        if output.isSpoken {
            return .init(task: output.language.map { .translate($0) } ?? .asSpoken)
        }
        if output.format == CoreOutput.technical {
            return .init(task: .write(style: .professional, language: output.language), literals: true)
        }
        if let style = output.style { return .init(task: .write(style: style, language: output.language)) }
        guard let id = output.presetID, let record = presets?.record(for: id), record.legacyIssue == nil else {
            return .init(task: .write(style: defaultStyle, language: output.language), presetMissing: true)
        }
        let definition = record.definition
        let instructions = definition.instructions
        switch definition.mode {
        case "original":
            // Based on What I say: your words, translated with the instructions when the row names a language.
            guard let language = output.language else { return .init(task: .asSpoken, presetID: id) }
            return .init(task: .translate(language), presetID: id, instructions: instructions)
        case "translate":
            let target = output.language ?? definition.targetLanguage ?? fallbackLanguage
            return .init(task: .translate(target), presetID: id, instructions: instructions)
        default:
            let style = definition.style.flatMap(RewriteStyle.init(rawValue:)) ?? defaultStyle
            return .init(
                task: .write(style: style, language: output.language), presetID: id, instructions: instructions,
                literals: definition.preserveTechnicalLiterals)
        }
    }

    init(
        task: CoreOutputTask, presetID: String? = nil, instructions: String? = nil, literals: Bool = false,
        presetMissing: Bool = false
    ) {
        self.task = task
        self.presetID = presetID
        self.instructions = instructions
        self.preserveTechnicalLiterals = literals
        self.presetMissing = presetMissing
    }
}

public struct CoreOutputRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    // Empty for a website rule.
    public var applicationBundleID: String
    // The app's name, or the website's domain.
    public var applicationName: String
    // A migrated rule that was paused stays visible and Off until the person turns it on.
    public var enabled: Bool
    public var output: CoreOutput
    // A website rule's domain ("mail.google.com"); it also covers its subdomains.
    public var website: String?

    public init(
        id: UUID = UUID(), applicationBundleID: String, applicationName: String, enabled: Bool = true,
        output: CoreOutput
    ) {
        self.id = id
        self.applicationBundleID = applicationBundleID
        self.applicationName = applicationName
        self.enabled = enabled
        self.output = output
    }

    public static func website(_ domain: String, output: CoreOutput, id: UUID = UUID()) -> Self {
        var rule = Self(id: id, applicationBundleID: "", applicationName: domain, output: output)
        rule.website = domain
        return rule
    }
}

// A row with its own key. The key itself is stored by the app, by row id.
public struct CoreOutputShortcut: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var output: CoreOutput

    public init(id: String, output: CoreOutput) {
        self.id = id
        self.output = output
    }
}

public enum CoreOutputSource: Equatable, Sendable {
    case recording, shortcut(String), application(UUID), everywhere
}

public struct CoreOutputResolution: Equatable, Sendable {
    public let output: CoreOutput
    public let source: CoreOutputSource
}

public struct CoreOutputSettings: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumRefineRows = 3
    public static let maximumShortcuts = 16
    public static let voiceTranslationShortcutID = "voiceTranslation"

    public var version = Self.currentVersion
    public var everywhere: CoreOutput
    public var rules: [CoreOutputRule]
    public var dictationShortcuts: [CoreOutputShortcut]
    public var refineInPlace: [CoreOutputShortcut]

    public init(
        everywhere: CoreOutput = .spoken, rules: [CoreOutputRule] = [], dictationShortcuts: [CoreOutputShortcut] = [],
        refineInPlace: [CoreOutputShortcut] = [
            .init(id: "refine-1", output: .init(format: RewriteStyle.light.rawValue))
        ]
    ) {
        self.everywhere = everywhere
        self.rules = rules
        self.dictationShortcuts = dictationShortcuts
        self.refineInPlace = refineInPlace
    }

    // One whole output, decided once: a choice made while recording, then the
    // shortcut that started it, then the rule for the website in front (its host
    // only, read for this one recording), then the app in front, then Everywhere else.
    public func resolve(
        applicationBundleID: String?, website: String? = nil, shortcutID: String? = nil,
        recordingChoice: CoreOutput? = nil
    ) -> CoreOutputResolution {
        if let recordingChoice { return .init(output: recordingChoice, source: .recording) }
        if let shortcutID, let row = dictationShortcuts.first(where: { $0.id == shortcutID }) {
            return .init(output: row.output, source: .shortcut(row.id))
        }
        if let website, let rule = rule(forWebsite: website) {
            return .init(output: rule.output, source: .application(rule.id))
        }
        if let applicationBundleID, let rule = rule(forApplication: applicationBundleID) {
            return .init(output: rule.output, source: .application(rule.id))
        }
        return .init(output: everywhere, source: .everywhere)
    }

    public func rule(forApplication bundleID: String) -> CoreOutputRule? {
        guard !bundleID.isEmpty else { return nil }
        return rules.first {
            $0.enabled && $0.website == nil && $0.applicationBundleID.caseInsensitiveCompare(bundleID) == .orderedSame
        }
    }

    // The most specific website rule that covers the host: "mail.google.com" wins over "google.com".
    public func rule(forWebsite host: String) -> CoreOutputRule? {
        guard let host = CoreWebsite.domain(host) else { return nil }
        return rules.filter { rule in
            guard rule.enabled, let domain = rule.website.flatMap(CoreWebsite.domain) else { return false }
            return CoreWebsite.covers(domain, host: host)
        }.max { ($0.website ?? "").count < ($1.website ?? "").count }
    }

    // The app or website a row is for, as a stable key ("app:com.apple.mail", "site:notion.so").
    public func rule(for place: CoreOutputPlace) -> CoreOutputRule? {
        rules.first { CoreOutputPlace($0) == place }
    }

    // Removing an output a row uses names every effect; these are the effects.
    public func uses(presetID: String) -> (
        rules: [CoreOutputRule], shortcuts: [String], refine: [String], everywhere: Bool
    ) {
        let preset = CoreOutput.presetPrefix + presetID
        return (
            rules.filter { $0.output.format == preset },
            dictationShortcuts.filter { $0.output.format == preset }.map(\.id),
            refineInPlace.filter { $0.output.format == preset }.map(\.id), everywhere.format == preset
        )
    }

    // Deleting a format of your own: each row that used it writes its base format, same language.
    public func replacing(presetID: String, with format: String) -> Self {
        let preset = CoreOutput.presetPrefix + presetID
        var value = self
        let replace: (inout CoreOutput, Bool) -> Void = { output, refines in
            guard output.format == preset else { return }
            output.format = refines && format == CoreOutput.spoken.format ? RewriteStyle.light.rawValue : format
        }
        replace(&value.everywhere, false)
        for row in value.rules.indices { replace(&value.rules[row].output, false) }
        for row in value.dictationShortcuts.indices { replace(&value.dictationShortcuts[row].output, false) }
        for row in value.refineInPlace.indices { replace(&value.refineInPlace[row].output, true) }
        return value
    }

    public func validated(languages: Set<String>) -> Self {
        var value = self
        let check: (CoreOutput) -> CoreOutput = { output in
            guard output.isValid else { return .spoken }
            if let language = output.language, !languages.contains(language) {
                return .init(format: output.format, language: nil)
            }
            return output
        }
        value.everywhere = check(everywhere)
        value.rules = rules.compactMap {
            var rule = $0
            rule.output = check(rule.output)
            // A website rule keeps only a well-formed domain.
            if let website = rule.website {
                guard let domain = CoreWebsite.domain(website) else { return nil }
                rule.website = domain
                rule.applicationBundleID = ""
                rule.applicationName = domain
            }
            return rule
        }
        value.dictationShortcuts = Array(dictationShortcuts.prefix(Self.maximumShortcuts)).map {
            .init(id: $0.id, output: check($0.output))
        }
        // Refine rows always change the text, so they never write What I say.
        value.refineInPlace = Array(refineInPlace.prefix(Self.maximumRefineRows)).map {
            let output = check($0.output)
            return .init(
                id: $0.id,
                output: output.isSpoken ? .init(format: RewriteStyle.light.rawValue, language: output.language) : output
            )
        }
        if value.refineInPlace.isEmpty { value.refineInPlace = Self().refineInPlace }
        return value
    }
}

// Today's settings, as saved before outputs existed.
public struct CoreOutputLegacy: Equatable, Sendable {
    public var translationAndRefinementEnabled: Bool
    public var outputMode: String
    public var dictationTarget: String
    public var refinementStyle: String
    public var voiceTranslationTarget: String
    // Whether the person had assigned voice translation a key; only then does it keep a row.
    public var voiceTranslationKeyAssigned: Bool
    public var selectedTextRefinementStyle: String?
    public var presets: CoreDictationPresetsConfiguration
    public var appPreferences: CoreAppPreferencesConfiguration
    public var languages: [String]

    public init(
        translationAndRefinementEnabled: Bool, outputMode: String, dictationTarget: String, refinementStyle: String,
        voiceTranslationTarget: String, voiceTranslationKeyAssigned: Bool = false,
        selectedTextRefinementStyle: String? = nil,
        presets: CoreDictationPresetsConfiguration = .init(), appPreferences: CoreAppPreferencesConfiguration = .init(),
        languages: [String]
    ) {
        self.voiceTranslationKeyAssigned = voiceTranslationKeyAssigned
        self.translationAndRefinementEnabled = translationAndRefinementEnabled
        self.outputMode = outputMode
        self.dictationTarget = dictationTarget
        self.refinementStyle = refinementStyle
        self.voiceTranslationTarget = voiceTranslationTarget
        self.selectedTextRefinementStyle = selectedTextRefinementStyle
        self.presets = presets
        self.appPreferences = appPreferences
        self.languages = languages
    }
}

public enum CoreOutputMigration {
    // Maps today's settings to outputs that produce the same result. Unsaved
    // preset edits become their own record so nothing is lost; the library is
    // returned with that record added.
    public static func migrate(_ legacy: CoreOutputLegacy) -> (
        settings: CoreOutputSettings, presets: CoreDictationPresetsConfiguration
    ) {
        var presets = legacy.presets
        let style = RewriteStyle(rawValue: legacy.refinementStyle) ?? .professional
        let target = language(legacy.dictationTarget, in: legacy.languages)

        var everywhere = CoreOutput.spoken
        if legacy.translationAndRefinementEnabled {
            if let selected = legacy.presets.selectedID, let record = legacy.presets.record(for: selected) {
                everywhere = output(
                    forPreset: record, overrides: legacy.presets.currentOverrides, library: &presets, style: style,
                    target: target)
                presets.currentOverrides = .init()
            } else {
                everywhere = output(mode: legacy.outputMode, target: target, style: style)
            }
        }
        presets.selectedID = nil

        let rules = legacy.appPreferences.rules.map { rule -> CoreOutputRule in
            let active = rule.enabled && legacy.appPreferences.enabled && legacy.translationAndRefinementEnabled
            return .init(
                id: rule.id, applicationBundleID: rule.applicationBundleID, applicationName: rule.applicationName,
                enabled: active,
                output: output(
                    rule: rule, everywhere: everywhere, library: legacy.presets, style: style, target: target))
        }

        let voiceTarget =
            language(legacy.voiceTranslationTarget, in: legacy.languages) ?? legacy.languages.first ?? "en"
        // A voice translation row only for a key the person set; otherwise rows are theirs to add.
        let shortcuts =
            legacy.voiceTranslationKeyAssigned
            ? [
                CoreOutputShortcut(
                    id: CoreOutputSettings.voiceTranslationShortcutID,
                    output: .init(format: "spoken", language: voiceTarget))
            ] : []
        let refineStyle = legacy.selectedTextRefinementStyle.flatMap(RewriteStyle.init(rawValue:)) ?? .light
        let settings = CoreOutputSettings(
            everywhere: everywhere, rules: rules, dictationShortcuts: shortcuts,
            refineInPlace: [.init(id: "refine-1", output: .init(format: refineStyle.rawValue))])
        return (settings.validated(languages: Set(legacy.languages)), presets)
    }

    // A format of your own takes its language from the row. A translate record
    // becomes one based on What I say; each row that used it without a language
    // gets the language it translated to, so every output stays the same.
    public static func formatLanguages(
        _ settings: CoreOutputSettings, _ presets: CoreDictationPresetsConfiguration, fallbackLanguage: String
    ) -> (settings: CoreOutputSettings, presets: CoreDictationPresetsConfiguration) {
        var settings = settings
        var presets = presets
        for index in presets.records.indices where !presets.records[index].isBuiltIn {
            let definition = presets.records[index].definition
            guard definition.mode == "translate" else { continue }
            let format = CoreOutput.preset(presets.records[index].id).format
            let language = definition.targetLanguage ?? fallbackLanguage
            let fill: (inout CoreOutput) -> Void = { output in
                if output.format == format && output.language == nil { output.language = language }
            }
            fill(&settings.everywhere)
            for row in settings.rules.indices { fill(&settings.rules[row].output) }
            for row in settings.dictationShortcuts.indices { fill(&settings.dictationShortcuts[row].output) }
            for row in settings.refineInPlace.indices { fill(&settings.refineInPlace[row].output) }
            presets.records[index].definition.mode = "original"
            presets.records[index].definition.targetLanguage = nil
        }
        return (settings, presets)
    }

    static func language(_ value: String?, in languages: [String]) -> String? {
        guard let value, value != "original", value != "auto", !value.isEmpty else { return nil }
        return languages.contains(value) ? value : nil
    }

    static func output(mode: String?, target: String?, style: RewriteStyle) -> CoreOutput {
        switch mode {
        case "translate": return .init(format: "spoken", language: target)
        case "refine": return .init(format: style.rawValue)
        default: return .spoken
        }
    }

    static func output(
        rule: CoreAppPreferenceRule, everywhere: CoreOutput, library: CoreDictationPresetsConfiguration,
        style: RewriteStyle, target: String?
    ) -> CoreOutput {
        switch rule.mode {
        case nil: return everywhere
        case "original": return .spoken
        case "translate":
            return .init(
                format: "spoken", language: rule.targetLanguage.flatMap { $0 == "original" ? nil : $0 } ?? target)
        default:
            if let id = rule.presetID, library.record(for: id) != nil { return .preset(id) }
            return .init(format: rule.rewriteStyle.flatMap(RewriteStyle.init(rawValue:))?.rawValue ?? style.rawValue)
        }
    }

    static func output(
        forPreset record: CoreDictationPresetRecord, overrides: CoreDictationOutputOverrides,
        library: inout CoreDictationPresetsConfiguration, style: RewriteStyle, target: String?
    ) -> CoreOutput {
        var definition = record.definition.applying(overrides)
        if definition.mode == nil { definition.mode = "refine" }
        let plain = definition.instructions == nil && !definition.preserveTechnicalLiterals
        if plain {
            switch definition.mode {
            case "original": return .spoken
            case "translate": return .init(format: "spoken", language: definition.targetLanguage ?? target)
            default: return .init(format: definition.style ?? style.rawValue)
            }
        }
        if definition.mode == "refine" && definition.instructions == nil && definition.style == nil {
            return .init(format: CoreOutput.technical)
        }
        guard !overrides.isEmpty else { return .preset(record.id) }
        // Unsaved edits become "<Name> (edited)"; a full library keeps them in place.
        var edited = record
        edited.definition = definition
        if library.records.filter({ !$0.isBuiltIn }).count < CoreDictationPresetsConfiguration.maximumUserRecords {
            edited.id = "edited-" + record.id
            edited.name = (record.name ?? record.id) + " (edited)"
            edited.templateID = nil
            library.records.removeAll { $0.id == edited.id }
            library.records.append(edited)
        } else if let index = library.records.firstIndex(where: { $0.id == record.id }) {
            library.records[index] = edited
        }
        return .preset(edited.id)
    }
}

// An empty shortcut box suggests ⌃⇧ plus the first free letter of the row's
// name. Only letters no common app or input method claims are offered; the
// person can still type any key. Nothing is saved until they accept it.
public enum CoreShortcutSuggestion {
    public static let letters: [Character] = Array("ABCEFHIMNOPQSUWXZ")

    public static func letter(for name: String, taken: Set<Character>) -> Character? {
        let candidates = name.uppercased().filter { letters.contains($0) } + String(letters)
        return candidates.first { !taken.contains($0) }
    }
}
