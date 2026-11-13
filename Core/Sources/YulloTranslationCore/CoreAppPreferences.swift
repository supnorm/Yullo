import Foundation

public enum CoreAppOutputChoice: Equatable, Sendable {
    case original, translation(String), refinement(RewriteStyle)
}

public enum CoreAppPreferenceContext: Sendable {
    case dictation, voiceTranslation, sourceEditor, trial, recentResult, voiceEdit
}

// Optional fields inherit. Raw strings intentionally retain decoded values
// that need repair instead of discarding the person's other saved rules.
public struct CoreAppPreferenceRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var enabled: Bool
    public var applicationBundleID: String
    public var applicationName: String
    public var mode: String?
    public var targetLanguage: String?
    public var rewriteStyle: String?
    // One of the person's presets, used in place of a style when this app
    // refines. Nil inherits; a missing key in older saved rules decodes as nil.
    public var presetID: String?

    public init(
        id: UUID = UUID(), enabled: Bool = true, applicationBundleID: String, applicationName: String,
        mode: String? = nil, targetLanguage: String? = nil, rewriteStyle: String? = nil, presetID: String? = nil
    ) {
        self.id = id
        self.enabled = enabled
        self.applicationBundleID = applicationBundleID
        self.applicationName = applicationName
        self.mode = mode
        self.targetLanguage = targetLanguage
        self.rewriteStyle = rewriteStyle
        self.presetID = presetID
    }

    // The preset this rule refines with, when it can still be used. A removed
    // or unusable preset never resolves to another one.
    public func usablePreset(in library: CoreDictationPresetsConfiguration?) -> CoreDictationPresetRecord? {
        guard let presetID, let record = library?.record(for: presetID), record.legacyIssue == nil,
            record.definition.isAppStyle
        else { return nil }
        return record
    }
    public func presetIssue(in library: CoreDictationPresetsConfiguration?) -> CoreAppPreferenceRuleIssue? {
        guard let presetID, usablePreset(in: library) == nil else { return nil }
        return library?.record(for: presetID) == nil ? .presetRemoved : .presetNeedsReview
    }

    // A ready-made rule for a mail app: refine dictation as an email.
    public static func email(applicationBundleID: String, applicationName: String) -> Self {
        .init(
            applicationBundleID: applicationBundleID, applicationName: applicationName, mode: "refine",
            rewriteStyle: RewriteStyle.email.rawValue)
    }
}

// Shown beside a rule; recordings fall back to the global default style.
public enum CoreAppPreferenceRuleIssue: String, Equatable, Sendable {
    case presetRemoved, presetNeedsReview
}

public enum CoreAppPreferenceValidationError: Error, Equatable, Sendable {
    case tooManyRules, duplicateIdentifier, invalidApplicationID, invalidApplicationName
    case duplicateApplication, invalidMode, invalidLanguage, invalidStyle, invalidPreset, staleRule

    public var messageKey: String {
        switch self {
        case .tooManyRules: return "Keep at most 128 app preferences."
        case .duplicateIdentifier: return "Each app preference needs a unique identifier."
        case .invalidApplicationID: return "Choose an application with a valid bundle identifier."
        case .invalidApplicationName: return "Keep the application name within 128 characters, without line breaks."
        case .duplicateApplication: return "This application already has a preference."
        case .invalidMode: return "Choose Original, Translate, Refine or Use global default."
        case .invalidLanguage: return "Choose an available target language or Use global default."
        case .invalidStyle: return "Choose an available rewrite style or Use global default."
        case .invalidPreset: return "Choose a style or a preset, or Use global default."
        case .staleRule: return "This app preference changed. Close the editor and try again."
        }
    }
}

public struct CoreAppPreferenceResolution: Equatable, Sendable {
    public let choice: CoreAppOutputChoice
    public let appliedRuleID: UUID?
    public let appliedPresetID: String?
    public let preserveTechnicalLiterals: Bool
    public let fieldSources: CoreDictationFieldSources?
    public let presetIssue: CoreDictationPresetIssue?
    // The applied preset's own instructions in prompt form, for translation or
    // refinement output only.
    public let presetInstructions: String?
    // The matched app rule names a preset that can no longer be used. Unlike
    // presetIssue it does not stop a recording: the global default style applies.
    public let ruleIssue: CoreAppPreferenceRuleIssue?
    public init(
        choice: CoreAppOutputChoice, appliedRuleID: UUID? = nil,
        appliedPresetID: String? = nil, preserveTechnicalLiterals: Bool = false,
        fieldSources: CoreDictationFieldSources? = nil, presetIssue: CoreDictationPresetIssue? = nil,
        presetInstructions: String? = nil, ruleIssue: CoreAppPreferenceRuleIssue? = nil
    ) {
        self.presetInstructions = presetInstructions
        self.ruleIssue = ruleIssue
        self.choice = choice
        self.appliedRuleID = appliedRuleID
        self.appliedPresetID = appliedPresetID
        self.preserveTechnicalLiterals = preserveTechnicalLiterals
        self.fieldSources = fieldSources
        self.presetIssue = presetIssue
    }
}

public struct CoreAppPreferencesConfiguration: Codable, Equatable, Sendable {
    public static let maximumRules = 128
    public var enabled: Bool
    public var rules: [CoreAppPreferenceRule]

    public init(enabled: Bool = false, rules: [CoreAppPreferenceRule] = []) {
        self.enabled = enabled
        self.rules = rules
    }

    @discardableResult public func validated() throws -> Self {
        guard rules.count <= Self.maximumRules else { throw CoreAppPreferenceValidationError.tooManyRules }
        var identifiers: Set<UUID> = [], applications: Set<String> = []
        for rule in rules {
            try Self.validate(rule)
            guard identifiers.insert(rule.id).inserted else {
                throw CoreAppPreferenceValidationError.duplicateIdentifier
            }
            guard applications.insert(rule.applicationBundleID).inserted else {
                throw CoreAppPreferenceValidationError.duplicateApplication
            }
        }
        return self
    }

    public func rule(forApplication applicationBundleID: String) -> CoreAppPreferenceRule? {
        rules.first { $0.applicationBundleID == applicationBundleID }
    }

    // Adds the email rule for an app that has none. The switch is global, so
    // Add turns it on only when no other enabled rule would wake with it; then
    // the caller says so. Otherwise the person turns it on explicitly.
    // Translation and refinement permission is never touched here.
    public func addingEmailRule(applicationBundleID: String, applicationName: String) throws -> Self {
        let rule = try validatedRule(
            .email(applicationBundleID: applicationBundleID, applicationName: applicationName))
        var next = self
        let othersWouldWake = !enabled && rules.contains(where: \.enabled)
        next.rules.append(rule)
        if !othersWouldWake, let on = try? next.turningOn() { next = on }
        return next
    }

    // The explicit Turn on: every rule must be valid first.
    public func turningOn() throws -> Self {
        var next = self
        next.enabled = true
        return try next.validated()
    }

    // Repair one decoded row without requiring unrelated malformed fields to
    // be rewritten. The exact occurrence is the caller's authority to replace.
    @discardableResult public func validatedRule(_ rule: CoreAppPreferenceRule, replacing index: Int? = nil) throws
        -> CoreAppPreferenceRule
    {
        if let index {
            guard rules.indices.contains(index) else { throw CoreAppPreferenceValidationError.staleRule }
        } else if rules.count >= Self.maximumRules {
            throw CoreAppPreferenceValidationError.tooManyRules
        }
        try Self.validate(rule)
        for (offset, other) in rules.enumerated() where offset != index {
            guard other.id != rule.id else { throw CoreAppPreferenceValidationError.duplicateIdentifier }
            guard other.applicationBundleID != rule.applicationBundleID else {
                throw CoreAppPreferenceValidationError.duplicateApplication
            }
        }
        return rule
    }

    private static func validate(_ rule: CoreAppPreferenceRule) throws {
        let identifier = rule.applicationBundleID.utf8
        guard !identifier.isEmpty, identifier.count <= 255,
            identifier.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                    || $0 == 45 || $0 == 46
            })
        else { throw CoreAppPreferenceValidationError.invalidApplicationID }
        guard !rule.applicationName.isEmpty, rule.applicationName.utf8.count <= 512,
            rule.applicationName.unicodeScalars.count <= 128,
            !rule.applicationName.unicodeScalars.contains(where: {
                $0.properties.generalCategory == .control || $0.properties.generalCategory == .lineSeparator
                    || $0.properties.generalCategory == .paragraphSeparator
            })
        else { throw CoreAppPreferenceValidationError.invalidApplicationName }
        if let mode = rule.mode, !["original", "translate", "refine"].contains(mode) {
            throw CoreAppPreferenceValidationError.invalidMode
        }
        if let language = rule.targetLanguage {
            guard !language.isEmpty, language.utf8.count <= 35,
                language.utf8.allSatisfy({
                    (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
                })
            else { throw CoreAppPreferenceValidationError.invalidLanguage }
        }
        if let style = rule.rewriteStyle, RewriteStyle(rawValue: style) == nil {
            throw CoreAppPreferenceValidationError.invalidStyle
        }
        // A preset replaces the style; both at once has no single meaning.
        if let preset = rule.presetID {
            guard rule.rewriteStyle == nil, CoreDictationPresetsConfiguration.validIdentifier(preset) else {
                throw CoreAppPreferenceValidationError.invalidPreset
            }
        }
    }

    // Shared raw rule admission; no task tuple is constructed here.
    func matchingRawRule(
        applicationBundleID: String?, outputModesEnabled: Bool, availableTargetLanguageIDs: Set<String>
    ) -> CoreAppPreferenceRule? {
        guard enabled, outputModesEnabled, let applicationBundleID, (try? validated()) != nil,
            let rule = rules.first(where: { $0.enabled && $0.applicationBundleID == applicationBundleID })
        else { return nil }
        if let target = rule.targetLanguage, !availableTargetLanguageIDs.contains(target) { return nil }
        return rule
    }

    // Call once while assembling the immutable recording session. No app
    // identity or name is returned as model context; only task parameters are.
    public func resolve(
        applicationBundleID: String?, context: CoreAppPreferenceContext, outputModesEnabled: Bool,
        globalChoice: CoreAppOutputChoice, voiceTranslationTarget: String,
        defaultDictationTarget: String, defaultRefinementStyle: RewriteStyle,
        availableTargetLanguageIDs: Set<String>, sessionChoice: CoreAppOutputChoice? = nil,
        presets: CoreDictationPresetsConfiguration? = nil,
        currentFields: CoreDictationOutputOverrides? = nil,
        presetLibrary: CoreDictationPresetsConfiguration? = nil
    ) -> CoreAppPreferenceResolution {
        // Saved presets an app rule may name; the selection still comes from `presets`.
        let library = presetLibrary ?? presets
        switch context {
        case .sourceEditor, .trial, .recentResult, .voiceEdit:
            return .init(choice: globalChoice)
        case .dictation:
            if !outputModesEnabled {
                // A plain Original preset remains meaningful with transformation
                // disabled. No malformed or external task may escape this gate.
                if let resolved = resolvePresetFields(
                    applicationBundleID: applicationBundleID, globalChoice: globalChoice,
                    defaultDictationTarget: defaultDictationTarget, defaultRefinementStyle: defaultRefinementStyle,
                    availableTargetLanguageIDs: availableTargetLanguageIDs, sessionChoice: sessionChoice,
                    presets: presets, currentFields: currentFields, presetLibrary: library),
                    resolved.choice == .original, resolved.presetIssue == nil
                {
                    return resolved
                }
                return .init(choice: .original)
            }
        case .voiceTranslation: break
        }
        if context == .dictation,
            let resolved = resolvePresetFields(
                applicationBundleID: applicationBundleID, globalChoice: globalChoice,
                defaultDictationTarget: defaultDictationTarget, defaultRefinementStyle: defaultRefinementStyle,
                availableTargetLanguageIDs: availableTargetLanguageIDs, sessionChoice: sessionChoice,
                presets: presets, currentFields: currentFields, presetLibrary: library)
        {
            return resolved
        }
        let fallback: CoreAppOutputChoice =
            context == .voiceTranslation ? .translation(voiceTranslationTarget) : globalChoice
        if let sessionChoice {
            if !outputModesEnabled, case .refinement = sessionChoice { return .init(choice: fallback) }
            return .init(choice: sessionChoice)
        }
        // Off and the hard task gate do not inspect even malformed saved rows.
        guard
            let rule = matchingRawRule(
                applicationBundleID: applicationBundleID, outputModesEnabled: outputModesEnabled,
                availableTargetLanguageIDs: availableTargetLanguageIDs)
        else { return .init(choice: fallback) }
        if context == .voiceTranslation {
            guard rule.mode == "translate", let target = rule.targetLanguage else {
                return .init(choice: fallback)
            }
            return .init(choice: .translation(target), appliedRuleID: rule.id)
        }
        let choice: CoreAppOutputChoice
        var inheritedStyle = defaultRefinementStyle
        switch rule.mode {
        case "original": choice = .original
        case "translate":
            choice = .translation(rule.targetLanguage ?? defaultDictationTarget)
        case "refine":
            choice = .refinement(rule.rewriteStyle.flatMap(RewriteStyle.init(rawValue:)) ?? defaultRefinementStyle)
        default:
            switch globalChoice {
            case .original: choice = .original
            case .translation(let target): choice = .translation(rule.targetLanguage ?? target)
            case .refinement(let style):
                inheritedStyle = style
                choice = .refinement(rule.rewriteStyle.flatMap(RewriteStyle.init(rawValue:)) ?? style)
            }
        }
        // A rule's preset refines as one unit: its style, technical text and
        // instructions. A removed preset falls back to the default style.
        guard case .refinement = choice, rule.presetID != nil else {
            return .init(choice: choice, appliedRuleID: rule.id)
        }
        guard let preset = rule.usablePreset(in: library) else {
            return .init(
                choice: .refinement(inheritedStyle), appliedRuleID: rule.id,
                ruleIssue: rule.presetIssue(in: library))
        }
        return .init(
            choice: .refinement(preset.definition.style.flatMap(RewriteStyle.init(rawValue:)) ?? inheritedStyle),
            appliedRuleID: rule.id, appliedPresetID: preset.id,
            preserveTechnicalLiterals: preset.definition.preserveTechnicalLiterals,
            presetInstructions: CorePresetInstructions.normalized(preset.definition.instructions))
    }
}
