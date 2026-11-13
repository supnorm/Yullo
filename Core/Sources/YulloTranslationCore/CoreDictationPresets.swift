import Foundation

// Built-in template identity only. Named records have independent stable IDs.
public enum CoreDictationPresetID: String, Codable, CaseIterable, Sendable {
    case technicalWriting, messageTranslation
}

public struct CoreDictationPresetDefinition: Codable, Equatable, Sendable {
    public var mode: String?
    public var targetLanguage: String?
    public var style: String?
    public var preserveTechnicalLiterals: Bool
    // The person's own style guidance for translation and refinement output.
    // See CorePresetInstructions; never source text or a task change.
    public var instructions: String?

    public init(
        mode: String? = nil, targetLanguage: String? = nil, style: String? = nil,
        preserveTechnicalLiterals: Bool = false, instructions: String? = nil
    ) {
        self.mode = mode
        self.targetLanguage = targetLanguage
        self.style = style
        self.preserveTechnicalLiterals = preserveTechnicalLiterals
        self.instructions = instructions
    }
    // Presentation scope only; execution still validates the resolved task fields.
    public var isWritingPreset: Bool {
        mode == "refine" || (mode == nil && (style != nil || preserveTechnicalLiterals))
    }
    // An app rule can refine with this preset in place of a style: a writing
    // preset, or one that only carries the person's own instructions.
    public var isAppStyle: Bool { isWritingPreset || (mode == nil && instructions != nil) }
    public static func factory(_ id: CoreDictationPresetID) -> Self {
        switch id {
        case .technicalWriting: return .init(mode: "refine", preserveTechnicalLiterals: true)
        case .messageTranslation: return .init(mode: "translate")
        }
    }
    // The format a record of yours is based on: What I say, Technical or a style.
    public func baseFormat(defaultStyle: RewriteStyle) -> String {
        startFormat(defaultStyle: defaultStyle) ?? RewriteStyle.light.rawValue
    }
    // The built-in format this one starts from, or nil when its instructions
    // alone shape it (it then falls back to Cleaned up when deleted).
    public func startFormat(defaultStyle: RewriteStyle) -> String? {
        if mode != "original", mode != "translate", style == RewriteStyle.instructed.rawValue { return nil }
        switch mode {
        case "original", "translate": return CoreOutput.spoken.format
        default:
            if preserveTechnicalLiterals && (style == nil || style == RewriteStyle.professional.rawValue) {
                return CoreOutput.technical
            }
            return style.flatMap(RewriteStyle.init(rawValue:))?.rawValue ?? defaultStyle.rawValue
        }
    }
    // Instructions stay; the base decides the task. Another style keeps a stored
    // technical-text flag only while its base is unchanged.
    public func based(on format: String?, defaultStyle: RewriteStyle) -> Self {
        guard format != startFormat(defaultStyle: defaultStyle) else { return self }
        var value = Self(instructions: instructions)
        let format = format ?? RewriteStyle.instructed.rawValue
        switch format {
        case CoreOutput.spoken.format: value.mode = "original"
        case CoreOutput.technical:
            value.mode = "refine"
            value.style = RewriteStyle.professional.rawValue
            value.preserveTechnicalLiterals = true
        default:
            value.mode = "refine"
            value.style = format
        }
        return value
    }
    // Used only when migrating the old two fixed-task records.
    public func supportsTask(for id: CoreDictationPresetID) -> Bool { mode == Self.factory(id).mode }
    private enum CodingKeys: String, CodingKey {
        case mode, targetLanguage, style, preserveTechnicalLiterals, instructions
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(String.self, forKey: .mode)
        targetLanguage = try values.decodeIfPresent(String.self, forKey: .targetLanguage)
        style = try values.decodeIfPresent(String.self, forKey: .style)
        preserveTechnicalLiterals = try values.decodeIfPresent(Bool.self, forKey: .preserveTechnicalLiterals) ?? false
        instructions = try values.decodeIfPresent(String.self, forKey: .instructions)
    }
    public init(resolution: CoreAppPreferenceResolution) {
        self.init()
        switch resolution.choice {
        case .original: mode = "original"
        case .translation(let target):
            mode = "translate"
            targetLanguage = target
        case .refinement(let style):
            mode = "refine"
            self.style = style.rawValue
            preserveTechnicalLiterals = resolution.preserveTechnicalLiterals
        }
    }
    public func applying(_ overrides: CoreDictationOutputOverrides) -> Self {
        var value = self
        if let mode = overrides.mode { value.mode = mode }
        if let target = overrides.targetLanguage { value.targetLanguage = target }
        if let style = overrides.style { value.style = style }
        if let preserve = overrides.preserveTechnicalLiterals { value.preserveTechnicalLiterals = preserve }
        return value
    }
}

public struct CoreDictationPresetRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    // Nil retains the localized template title. Explicit names are never translated.
    public var name: String?
    public var templateID: CoreDictationPresetID?
    public var definition: CoreDictationPresetDefinition
    // Compatibility state: all records are selectable; explicit selection activates.
    public var enabled: Bool
    public var legacyIssue: CoreDictationPresetIssue?
    public init(
        id: String, name: String? = nil, templateID: CoreDictationPresetID? = nil,
        definition: CoreDictationPresetDefinition, enabled: Bool = true, legacyIssue: CoreDictationPresetIssue? = nil
    ) {
        self.id = id
        self.name = name
        self.templateID = templateID
        self.definition = definition
        self.enabled = enabled
        self.legacyIssue = legacyIssue
    }
    public var isBuiltIn: Bool { CoreDictationPresetID(rawValue: id) != nil }
}

public enum CoreDictationPresetValidationError: Error, Equatable, Sendable {
    case tooManyRecords, invalidIdentifier, duplicateIdentifier, invalidName
    case invalidMode, invalidTarget, invalidStyle, invalidInstructions, staleRecord, unknownSelection
}

public struct CoreDictationPresetsConfiguration: Codable, Equatable, Sendable {
    public static let maximumUserRecords = 32
    public var records: [CoreDictationPresetRecord]
    public var selectedID: String?
    public var currentOverrides: CoreDictationOutputOverrides
    public init(
        records: [CoreDictationPresetRecord] = Self.builtInRecords,
        selectedID: String? = nil, currentOverrides: CoreDictationOutputOverrides = .init()
    ) {
        self.records = records
        self.selectedID = selectedID
        self.currentOverrides = currentOverrides
    }
    public static var builtInRecords: [CoreDictationPresetRecord] {
        CoreDictationPresetID.allCases.map {
            .init(id: $0.rawValue, templateID: $0, definition: .factory($0), enabled: false)
        }
    }
    public var isModified: Bool { selectedID != nil && !currentOverrides.isEmpty }
    private enum CodingKeys: String, CodingKey {
        case version, records, selectedID, currentOverrides, technicalWriting, messageTranslation
    }
    private struct LegacyState: Decodable {
        var enabled: Bool
        var definition: CoreDictationPresetDefinition
        private enum CodingKeys: String, CodingKey { case enabled, definition }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
            definition = try values.decodeIfPresent(CoreDictationPresetDefinition.self, forKey: .definition) ?? .init()
        }
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        selectedID = try values.decodeIfPresent(String.self, forKey: .selectedID)
        if values.contains(.records) {
            records = try values.decode([CoreDictationPresetRecord].self, forKey: .records)
            currentOverrides =
                try values.decodeIfPresent(CoreDictationOutputOverrides.self, forKey: .currentOverrides)
                ?? .init()
        } else {
            records = try CoreDictationPresetID.allCases.map { id in
                let key: CodingKeys = id == .technicalWriting ? .technicalWriting : .messageTranslation
                guard let state = try values.decodeIfPresent(LegacyState.self, forKey: key) else {
                    return .init(id: id.rawValue, templateID: id, definition: .factory(id), enabled: false)
                }
                return .init(
                    id: id.rawValue, templateID: id, definition: state.definition, enabled: state.enabled,
                    legacyIssue: state.definition.supportsTask(for: id) ? nil : .invalidMode)
            }
            currentOverrides = .init()
        }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(2, forKey: .version)
        try values.encode(records, forKey: .records)
        try values.encodeIfPresent(selectedID, forKey: .selectedID)
        try values.encode(currentOverrides, forKey: .currentOverrides)
    }
    public func record(for id: String) -> CoreDictationPresetRecord? {
        guard Self.validIdentifier(id) else { return nil }
        let matches = records.filter { $0.id == id }
        return matches.count == 1 ? matches[0] : nil
    }
    @discardableResult public mutating func select(_ id: String?) -> Bool {
        if let id {
            guard records.filter({ $0.id == id }).count == 1,
                let index = records.firstIndex(where: { $0.id == id }), Self.validIdentifier(id)
            else { return false }
            records[index].enabled = true
        }
        selectedID = id
        currentOverrides = .init()
        return true
    }
    public mutating func revertChanges() { currentOverrides = .init() }
    // A temporary preset (a scenario) for resolving new tasks. The returned copy
    // selects it; the saved configuration, its selection and limits stay as they were.
    public func activatingTemporary(_ record: CoreDictationPresetRecord) throws -> Self {
        guard !record.isBuiltIn, !records.contains(where: { $0.id == record.id }) else {
            throw CoreDictationPresetValidationError.duplicateIdentifier
        }
        try Self.validate(record, availableTargetLanguageIDs: nil)
        var value = self
        var active = record
        active.enabled = true
        active.legacyIssue = nil
        value.records.append(active)
        value.selectedID = record.id
        value.currentOverrides = .init()
        return value
    }
    @discardableResult public mutating func create(
        name: String, definition: CoreDictationPresetDefinition, templateID: CoreDictationPresetID? = nil,
        id: String = "custom." + UUID().uuidString, availableTargetLanguageIDs: Set<String>? = nil
    ) throws -> String {
        let record = CoreDictationPresetRecord(id: id, name: name, templateID: templateID, definition: definition)
        guard !record.isBuiltIn else { throw CoreDictationPresetValidationError.invalidIdentifier }
        guard records.filter({ !$0.isBuiltIn }).count < Self.maximumUserRecords else {
            throw CoreDictationPresetValidationError.tooManyRecords
        }
        try Self.validate(record, availableTargetLanguageIDs: availableTargetLanguageIDs)
        guard !records.contains(where: { $0.id == id }) else {
            throw CoreDictationPresetValidationError.duplicateIdentifier
        }
        records.append(record)
        return id
    }
    public mutating func update(
        _ record: CoreDictationPresetRecord, replacing expected: CoreDictationPresetRecord,
        availableTargetLanguageIDs: Set<String>? = nil
    ) throws {
        guard record.id == expected.id, self.record(for: expected.id) == expected,
            let index = records.firstIndex(where: { $0.id == expected.id })
        else { throw CoreDictationPresetValidationError.staleRecord }
        try Self.validate(record, availableTargetLanguageIDs: availableTargetLanguageIDs)
        var saved = record
        saved.legacyIssue = nil
        records[index] = saved
    }
    @discardableResult public mutating func duplicate(
        _ id: String, name: String, newID: String = "custom." + UUID().uuidString,
        availableTargetLanguageIDs: Set<String>? = nil
    ) throws -> String {
        guard let record = record(for: id) else { throw CoreDictationPresetValidationError.unknownSelection }
        return try create(
            name: name, definition: record.definition, templateID: record.templateID,
            id: newID, availableTargetLanguageIDs: availableTargetLanguageIDs)
    }
    public mutating func remove(_ expected: CoreDictationPresetRecord) throws {
        guard record(for: expected.id) == expected else { throw CoreDictationPresetValidationError.staleRecord }
        records.removeAll { $0.id == expected.id }
        if selectedID == expected.id {
            selectedID = nil
            currentOverrides = .init()
        }
    }
    @discardableResult public mutating func reset(_ expected: CoreDictationPresetRecord) throws
        -> CoreDictationPresetRecord
    {
        var reset = expected
        reset.definition = expected.templateID.map(CoreDictationPresetDefinition.factory) ?? .init()
        try update(reset, replacing: expected)
        if selectedID == expected.id { currentOverrides = .init() }
        return expected
    }
    public mutating func saveChanges(availableTargetLanguageIDs: Set<String>? = nil) throws {
        guard let selectedID, let record = record(for: selectedID) else {
            throw CoreDictationPresetValidationError.unknownSelection
        }
        var saved = record
        saved.definition = record.definition.applying(currentOverrides)
        saved.enabled = true
        try update(saved, replacing: record, availableTargetLanguageIDs: availableTargetLanguageIDs)
        currentOverrides = .init()
    }
    @discardableResult public mutating func saveAs(
        name: String, definition: CoreDictationPresetDefinition, templateID: CoreDictationPresetID? = nil,
        id: String = "custom." + UUID().uuidString, availableTargetLanguageIDs: Set<String>? = nil
    ) throws -> String {
        let id = try create(
            name: name, definition: definition, templateID: templateID, id: id,
            availableTargetLanguageIDs: availableTargetLanguageIDs)
        _ = select(id)
        return id
    }
    static func validIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 64
            && id.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
            }
    }
    private static func validate(
        _ record: CoreDictationPresetRecord, availableTargetLanguageIDs: Set<String>?
    ) throws {
        guard validIdentifier(record.id) else { throw CoreDictationPresetValidationError.invalidIdentifier }
        if let name = record.name {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                name.unicodeScalars.count <= 64, name.utf8.count <= 256,
                !name.unicodeScalars.contains(where: {
                    [.control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
                })
            else { throw CoreDictationPresetValidationError.invalidName }
        } else if record.templateID == nil {
            throw CoreDictationPresetValidationError.invalidName
        }
        let value = record.definition
        if let mode = value.mode, !["original", "translate", "refine"].contains(mode) {
            throw CoreDictationPresetValidationError.invalidMode
        }
        if let target = value.targetLanguage {
            guard !target.isEmpty, target.utf8.count <= 35,
                target.utf8.allSatisfy({
                    (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
                }), availableTargetLanguageIDs.map({ $0.contains(target) }) ?? true
            else { throw CoreDictationPresetValidationError.invalidTarget }
        }
        if let style = value.style, RewriteStyle(rawValue: style) == nil {
            throw CoreDictationPresetValidationError.invalidStyle
        }
        do { _ = try CorePresetInstructions.validated(value.instructions) } catch {
            throw CoreDictationPresetValidationError.invalidInstructions
        }
    }
}

// Nil means not explicitly chosen in the current task. A resolved default must
// never be converted back into this type as if the person had chosen it.
public struct CoreDictationOutputOverrides: Codable, Equatable, Sendable {
    public var mode: String?
    public var targetLanguage: String?
    public var style: String?
    public var preserveTechnicalLiterals: Bool?
    public init(
        mode: String? = nil, targetLanguage: String? = nil, style: String? = nil,
        preserveTechnicalLiterals: Bool? = nil
    ) {
        self.mode = mode
        self.targetLanguage = targetLanguage
        self.style = style
        self.preserveTechnicalLiterals = preserveTechnicalLiterals
    }
    public init(choice: CoreAppOutputChoice) {
        self.init()
        switch choice {
        case .original: mode = "original"
        case .translation(let target):
            mode = "translate"
            targetLanguage = target
        case .refinement(let style):
            mode = "refine"
            self.style = style.rawValue
        }
    }
    public var isEmpty: Bool {
        mode == nil && targetLanguage == nil && style == nil && preserveTechnicalLiterals == nil
    }
}

public enum CoreDictationFieldSource: String, Equatable, Sendable {
    case current, preset, application, global
}

public struct CoreDictationFieldSources: Equatable, Sendable {
    public let mode: CoreDictationFieldSource
    public let targetLanguage: CoreDictationFieldSource?
    public let style: CoreDictationFieldSource?
    public let technicalLiterals: CoreDictationFieldSource?
}

public enum CoreDictationPresetIssue: String, Codable, Equatable, Sendable {
    case unknownSelection, invalidMode, invalidTarget, invalidStyle
}

extension CoreAppPreferencesConfiguration {
    // Field-by-field once: task > working copy > preset > application > global.
    // Nil means inherit, never a materialized value copied back into storage.
    func resolvePresetFields(
        applicationBundleID: String?, globalChoice: CoreAppOutputChoice,
        defaultDictationTarget: String, defaultRefinementStyle: RewriteStyle,
        availableTargetLanguageIDs: Set<String>, sessionChoice: CoreAppOutputChoice?,
        presets: CoreDictationPresetsConfiguration?, currentFields: CoreDictationOutputOverrides?,
        presetLibrary: CoreDictationPresetsConfiguration?
    ) -> CoreAppPreferenceResolution? {
        var active: CoreDictationPresetRecord?
        var working = CoreDictationOutputOverrides()
        if let id = presets?.selectedID {
            guard let record = presets?.record(for: id) else {
                return .init(choice: .original, presetIssue: .unknownSelection)
            }
            if record.enabled {
                active = record
                working = presets?.currentOverrides ?? .init()
            }
        }
        guard active != nil || !working.isEmpty || currentFields.map({ !$0.isEmpty }) == true else { return nil }
        let definition = active?.definition
        let rule = matchingRawRule(
            applicationBundleID: applicationBundleID, outputModesEnabled: true,
            availableTargetLanguageIDs: availableTargetLanguageIDs)
        let alias = sessionChoice.map(CoreDictationOutputOverrides.init(choice:))
        let current = currentFields ?? .init()
        if let issue = active?.legacyIssue, current.mode == nil, alias?.mode == nil, working.mode == nil {
            return .init(choice: .original, presetIssue: issue)
        }
        func field(
            _ task: String?, _ alias: String?, _ working: String?, _ preset: String?,
            _ application: String?, _ global: String
        ) -> (String, CoreDictationFieldSource) {
            if let task { return (task, .current) }
            if let alias { return (alias, .current) }
            if let working { return (working, .current) }
            if let preset { return (preset, .preset) }
            if let application { return (application, .application) }
            return (global, .global)
        }
        let global = CoreDictationOutputOverrides(choice: globalChoice)
        let mode = field(current.mode, alias?.mode, working.mode, definition?.mode, rule?.mode, global.mode!)
        guard ["original", "translate", "refine"].contains(mode.0) else {
            return .init(choice: .original, presetIssue: .invalidMode)
        }
        let choice: CoreAppOutputChoice
        var targetSource: CoreDictationFieldSource?, styleSource: CoreDictationFieldSource?
        var rulePreset: CoreDictationPresetRecord?, ruleIssue: CoreAppPreferenceRuleIssue?
        switch mode.0 {
        case "translate":
            let target = field(
                current.targetLanguage, alias?.targetLanguage, working.targetLanguage, definition?.targetLanguage,
                rule?.targetLanguage, global.targetLanguage ?? defaultDictationTarget)
            guard availableTargetLanguageIDs.contains(target.0) else {
                return .init(choice: .original, presetIssue: .invalidTarget)
            }
            choice = .translation(target.0)
            targetSource = target.1
        case "refine":
            // The rule's preset is the app's style as one unit, and only while
            // no preset is selected and nothing above chose a style.
            if active == nil, current.style == nil, alias?.style == nil, working.style == nil, let rule {
                rulePreset = rule.usablePreset(in: presetLibrary)
                ruleIssue = rule.presetIssue(in: presetLibrary)
            }
            let style = field(
                current.style, alias?.style, working.style, definition?.style,
                rulePreset?.definition.style ?? rule?.rewriteStyle, global.style ?? defaultRefinementStyle.rawValue)
            guard let parsed = RewriteStyle(rawValue: style.0) else {
                return .init(choice: .original, presetIssue: .invalidStyle)
            }
            choice = .refinement(parsed)
            styleSource = style.1
        default: choice = .original
        }
        let preserved: Bool
        let preservationSource: CoreDictationFieldSource?
        if case .refinement = choice {
            if let explicit = current.preserveTechnicalLiterals {
                preserved = explicit
                preservationSource = .current
            } else if let value = working.preserveTechnicalLiterals {
                preserved = value
                preservationSource = .current
            } else if let definition {
                preserved = definition.preserveTechnicalLiterals
                preservationSource = .preset
            } else if let rulePreset {
                preserved = rulePreset.definition.preserveTechnicalLiterals
                preservationSource = .application
            } else {
                preserved = false
                preservationSource = .global
            }
        } else {
            preserved = false
            preservationSource = nil
        }
        let sources = CoreDictationFieldSources(
            mode: mode.1, targetLanguage: targetSource, style: styleSource, technicalLiterals: preservationSource)
        let applicationUsed =
            rulePreset != nil || [mode.1, targetSource, styleSource].contains { $0 == .application }
        let instructions: String?
        if case .original = choice {
            instructions = nil
        } else {
            instructions = definition?.instructions ?? rulePreset?.definition.instructions
        }
        return .init(
            choice: choice, appliedRuleID: applicationUsed ? rule?.id : nil,
            appliedPresetID: active?.id ?? rulePreset?.id, preserveTechnicalLiterals: preserved,
            fieldSources: sources, presetInstructions: CorePresetInstructions.normalized(instructions),
            ruleIssue: ruleIssue)
    }
}
