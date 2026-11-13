import Foundation

public enum CoreVocabularyBoundary: String, CaseIterable, Codable, Hashable, Sendable {
    case wholeTerm, substring
}

public struct CoreVocabularyEntry: Codable, Equatable, Identifiable, Sendable {
    public static let allTranslationLanguages = "*"
    public var id: UUID
    public var enabled: Bool
    public var canonical: String
    public var alias: String
    public var recognitionHint: Bool
    public var correctAlias: Bool
    public var useInTranslation: Bool
    public var translation: String
    public var targetLanguage: String
    public var boundary: CoreVocabularyBoundary
    public var preservesSpelling: Bool { useInTranslation && targetLanguage == Self.allTranslationLanguages }

    public init(
        id: UUID = UUID(), enabled: Bool = true, canonical: String, alias: String = "",
        recognitionHint: Bool = false, correctAlias: Bool = false, useInTranslation: Bool = false,
        translation: String = "", targetLanguage: String = "", boundary: CoreVocabularyBoundary = .wholeTerm
    ) {
        self.id = id
        self.enabled = enabled
        self.canonical = canonical
        self.alias = alias
        self.recognitionHint = recognitionHint
        self.correctAlias = correctAlias
        self.useInTranslation = useInTranslation
        self.translation = translation
        self.targetLanguage = targetLanguage
        self.boundary = boundary
    }

    // Matching and duplicate detection intentionally use canonical Unicode
    // equivalence. Configuration identity must instead preserve the exact
    // replacement spelling selected by the person, including UTF-16 form.
    public static func == (left: Self, right: Self) -> Bool {
        left.id == right.id && left.enabled == right.enabled && left.recognitionHint == right.recognitionHint
            && left.correctAlias == right.correctAlias && left.useInTranslation == right.useInTranslation
            && left.boundary == right.boundary
            && left.canonical.utf16.elementsEqual(right.canonical.utf16)
            && left.alias.utf16.elementsEqual(right.alias.utf16)
            && left.translation.utf16.elementsEqual(right.translation.utf16)
            && left.targetLanguage.utf16.elementsEqual(right.targetLanguage.utf16)
    }
}

public enum CoreVocabularyField: String, Equatable, Sendable {
    case canonical, alias, translation, targetLanguage
}

public enum CoreVocabularyValidationError: Error, Equatable, Sendable {
    case tooManyEntries, duplicateIdentifier, emptyCanonical, fieldTooLong(CoreVocabularyField)
    case invalidCharacters(CoreVocabularyField), noUsage, missingAlias, identicalAlias, missingTranslation
    case invalidTargetLanguage, duplicateCanonical, duplicateAlias, invalidPattern, inputTooLong, outputTooLong

    public var messageKey: String {
        switch self {
        case .tooManyEntries: return "Keep at most 256 personal vocabulary entries."
        case .duplicateIdentifier: return "Each vocabulary entry needs a unique identifier."
        case .emptyCanonical: return "Enter a preferred word or phrase."
        case .fieldTooLong(.translation): return "Keep preferred translations within 128 characters."
        case .fieldTooLong(.targetLanguage), .invalidTargetLanguage: return "Choose a target language."
        case .fieldTooLong: return "Keep words and heard-as phrases within 64 characters."
        case .invalidCharacters:
            return "Vocabulary entries cannot contain outer spaces, line breaks or control characters."
        case .noUsage: return "Choose at least one use for this vocabulary entry."
        case .missingAlias: return "Enter the heard-as phrase to correct."
        case .identicalAlias: return "The heard-as phrase must differ from the preferred spelling."
        case .missingTranslation: return "Enter a preferred translation."
        case .duplicateCanonical: return "This spelling already has an entry for the same use or target language."
        case .duplicateAlias: return "This heard-as phrase is already used by another correction."
        case .invalidPattern: return "This vocabulary entry could not be prepared."
        case .inputTooLong: return "This text is too long for personal vocabulary processing."
        case .outputTooLong: return "Personal vocabulary corrections would make this text too long."
        }
    }
}

public struct CoreVocabularyConfiguration: Codable, Equatable, Sendable {
    public static let maximumEntries = 256
    public static let maximumTextBytes = 262_144
    public var enabled: Bool
    public var entries: [CoreVocabularyEntry]

    public init(enabled: Bool = false, entries: [CoreVocabularyEntry] = []) {
        self.enabled = enabled
        self.entries = entries
    }

    @discardableResult public func validated() throws -> Self {
        guard entries.count <= Self.maximumEntries else { throw CoreVocabularyValidationError.tooManyEntries }
        var identifiers: Set<UUID> = [], canonical: [String: [CoreVocabularyEntry]] = [:], aliases: Set<String> = []
        for entry in entries {
            guard identifiers.insert(entry.id).inserted else { throw CoreVocabularyValidationError.duplicateIdentifier }
            try Self.validate(entry.canonical, field: .canonical, maximum: 64)
            try Self.validate(entry.alias, field: .alias, maximum: 64)
            try Self.validate(entry.translation, field: .translation, maximum: 128)
            try Self.validate(entry.targetLanguage, field: .targetLanguage, maximum: 35)
            guard !entry.canonical.isEmpty else { throw CoreVocabularyValidationError.emptyCanonical }
            let spelling = entry.canonical.precomposedStringWithCanonicalMapping
            if let previous = canonical[spelling] {
                func translationOnly(_ value: CoreVocabularyEntry) -> Bool {
                    value.useInTranslation && !value.recognitionHint && !value.correctAlias
                }
                guard translationOnly(entry), previous.allSatisfy(translationOnly),
                    !previous.contains(where: { $0.targetLanguage == entry.targetLanguage })
                else { throw CoreVocabularyValidationError.duplicateCanonical }
            }
            canonical[spelling, default: []].append(entry)
            if entry.enabled && !entry.recognitionHint && !entry.correctAlias && !entry.useInTranslation {
                throw CoreVocabularyValidationError.noUsage
            }
            if entry.correctAlias {
                guard !entry.alias.isEmpty else { throw CoreVocabularyValidationError.missingAlias }
                let alias = entry.alias.precomposedStringWithCanonicalMapping
                guard alias != spelling else { throw CoreVocabularyValidationError.identicalAlias }
                guard aliases.insert(alias).inserted else { throw CoreVocabularyValidationError.duplicateAlias }
            }
            if entry.useInTranslation {
                guard !entry.translation.isEmpty else { throw CoreVocabularyValidationError.missingTranslation }
                guard
                    entry.preservesSpelling
                        ? entry.translation.utf16.elementsEqual(entry.canonical.utf16)
                        : !entry.targetLanguage.isEmpty
                            && entry.targetLanguage.utf8.allSatisfy({
                                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
                            })
                else { throw CoreVocabularyValidationError.invalidTargetLanguage }
            }
        }
        return self
    }

    // A disabled, recoverable profile can contain several independently bad
    // rows. Repair one without requiring the other rows to be valid first.
    // The index is the occurrence being replaced, not a potentially duplicate
    // decoded ID. The caller's candidate and identifier are never rewritten.
    @discardableResult public func validatedEntry(
        _ candidate: CoreVocabularyEntry, replacing index: Int? = nil
    ) throws -> CoreVocabularyEntry {
        if let index {
            guard entries.indices.contains(index) else { throw CoreVocabularyValidationError.invalidPattern }
        } else {
            guard entries.count < Self.maximumEntries else { throw CoreVocabularyValidationError.tooManyEntries }
        }
        _ = try Self(entries: [candidate]).validated()
        let spelling = candidate.canonical.precomposedStringWithCanonicalMapping
        let alias = candidate.alias.precomposedStringWithCanonicalMapping
        func contextKey(_ value: String) -> String? {
            // Unrelated malformed fields do not justify unbounded normalization
            // on an editor save. Full validation still gates enabling the list.
            guard value.utf8.count <= 4096 else { return nil }
            return value.precomposedStringWithCanonicalMapping
        }
        func translationOnly(_ entry: CoreVocabularyEntry) -> Bool {
            entry.useInTranslation && !entry.recognitionHint && !entry.correctAlias
        }
        for (offset, other) in entries.enumerated() where offset != index {
            guard candidate.id != other.id else { throw CoreVocabularyValidationError.duplicateIdentifier }
            if contextKey(other.canonical) == spelling {
                guard translationOnly(candidate), translationOnly(other),
                    candidate.targetLanguage != other.targetLanguage
                else { throw CoreVocabularyValidationError.duplicateCanonical }
            }
            if candidate.correctAlias, other.correctAlias, contextKey(other.alias) == alias {
                throw CoreVocabularyValidationError.duplicateAlias
            }
        }
        return candidate
    }

    private static func validate(_ value: String, field: CoreVocabularyField, maximum: Int) throws {
        // The cheap byte bound precedes scalar counting/normalization/regex work.
        guard value.utf8.count <= maximum * 4, value.unicodeScalars.count <= maximum else {
            throw CoreVocabularyValidationError.fieldTooLong(field)
        }
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.unicodeScalars.contains(where: {
                [.control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
            })
        else { throw CoreVocabularyValidationError.invalidCharacters(field) }
    }
}

public struct CoreVocabularyTranslationTerm: Codable, Equatable, Sendable {
    public let source: String
    public let target: String
    public init(source: String, target: String) {
        self.source = source
        self.target = target
    }
}

// An immutable task snapshot. Literal prefix tries are compiled after bounded
// validation, never for provisional audio updates. No user text is a pattern.
public struct CoreVocabularySnapshot: Sendable {
    private struct Rule: Sendable {
        let source: String
        let replacement: String
        let boundary: CoreVocabularyBoundary
        let scope: String
    }
    private struct Matcher: Sendable {
        private struct Node: Sendable {
            var edges: [UInt16: Int] = [:]
            var rules: [String: Rule] = [:]
        }
        private let nodes: [Node]
        private let maximumLength: Int
        private let hasSubstring: Bool

        init(_ rules: [Rule]) throws {
            var nodes = [Node()]
            var maximum = 0
            for rule in rules {
                var current = 0, length = 0
                for unit in rule.source.utf16 {
                    if let next = nodes[current].edges[unit] {
                        current = next
                    } else {
                        let next = nodes.count
                        nodes.append(Node())
                        nodes[current].edges[unit] = next
                        current = next
                    }
                    length += 1
                }
                guard length > 0, nodes[current].rules[rule.scope] == nil else {
                    throw CoreVocabularyValidationError.invalidPattern
                }
                nodes[current].rules[rule.scope] = rule
                maximum = max(maximum, length)
            }
            self.nodes = nodes
            maximumLength = maximum
            hasSubstring = rules.contains { $0.boundary == .substring }
        }

        func forEachMatch(in text: PreparedText, scope: String = "", visit: (NSRange, Rule) -> Bool) {
            var start = 0
            while start < text.units.count {
                if Task.isCancelled { return }
                let startsInsideWord = start > 0 && text.wordUnits[start - 1]
                if !hasSubstring && startsInsideWord {
                    start += 1
                    continue
                }
                var node = 0, end = start
                var best: (end: Int, range: NSRange, rule: Rule)?
                while end < text.units.count && end - start < maximumLength,
                    let next = nodes[node].edges[text.units[end]]
                {
                    node = next
                    end += 1
                    // Resolve scope before boundaries and longest-leftmost
                    // selection. Irrelevant rules never consume a source span.
                    guard
                        let rule = nodes[node].rules[scope]
                            ?? (scope.isEmpty ? nil : nodes[node].rules[CoreVocabularyEntry.allTranslationLanguages])
                    else { continue }
                    if rule.boundary == .wholeTerm
                        && (startsInsideWord || (end < text.units.count && text.wordUnits[end]))
                    {
                        continue
                    }
                    guard let range = text.originalRange(NSRange(location: start, length: end - start)) else {
                        continue
                    }
                    best = (end, range, rule)
                }
                if let best {
                    guard visit(best.range, best.rule) else { return }
                    start = best.end
                } else {
                    start += 1
                }
            }
        }
    }
    private struct PreparedText {
        let original: NSString
        let normalized: String
        let units: [UInt16]
        let wordUnits: [Bool]
        private let offsets: [Int]
        init(_ text: String) throws {
            try Task.checkCancellation()
            original = text as NSString
            let rawUnits = Array(text.utf16)
            let ascii = rawUnits.allSatisfy { $0 < 128 }
            // Normalization itself can be quadratic when thousands of marks
            // with conflicting combining classes form one grapheme. Such a
            // cluster cannot be one of our bounded literal rules. Keep it as
            // an opaque original span rather than feeding it to Foundation NFC.
            let clusterLimit = 1024
            func oversized(_ part: String) -> Bool {
                part.unicodeScalars.prefix(clusterLimit + 1).count > clusterLimit
            }
            func normalizedPart(_ part: String) -> String {
                oversized(part) ? part : part.precomposedStringWithCanonicalMapping
            }
            var needsOpaqueSpans = false
            if !ascii {
                for character in text {
                    try Task.checkCancellation()
                    if oversized(String(character)) {
                        needsOpaqueSpans = true
                        break
                    }
                }
            }
            if ascii {
                normalized = text
            } else if !needsOpaqueSpans {
                normalized = text.precomposedStringWithCanonicalMapping
            } else {
                var view = ""
                view.reserveCapacity(text.utf8.count)
                for character in text {
                    try Task.checkCancellation()
                    view += normalizedPart(String(character))
                }
                normalized = view
            }
            units = ascii ? rawUnits : Array(normalized.utf16)
            var words: [Bool] = []
            words.reserveCapacity(units.count)
            var scalarCount = 0
            for scalar in normalized.unicodeScalars {
                if scalarCount & 1023 == 0 { try Task.checkCancellation() }
                scalarCount += 1
                let isWord: Bool
                switch scalar.properties.generalCategory {
                case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                    .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber, .letterNumber, .otherNumber,
                    .connectorPunctuation:
                    isWord = true
                default: isWord = false
                }
                words.append(isWord)
                if scalar.value > 0xFFFF { words.append(isWord) }
            }
            wordUnits = words
            if ascii {
                var map = Array(0...units.count)
                for offset in units.indices where offset > 0 {
                    if offset & 4095 == 0 { try Task.checkCancellation() }
                    // CRLF is the only multi-unit ASCII grapheme.
                    if units[offset - 1] == 13 && units[offset] == 10 { map[offset] = -1 }
                }
                offsets = map
                return
            }
            let unchanged = text.utf16.elementsEqual(normalized.utf16)
            var map = [Int](repeating: -1, count: units.count + 1)
            var rawOffset = 0, normalizedOffset = 0
            map[0] = 0
            // Enumerate each Swift Character once. Querying NSString composed
            // ranges separately for every candidate is quadratic for one long
            // combining cluster and can disagree on isolated Indic marks.
            for character in text {
                try Task.checkCancellation()
                let part = String(character)
                let rawLength = part.utf16.count
                rawOffset += rawLength
                normalizedOffset += unchanged ? rawLength : normalizedPart(part).utf16.count
                if normalizedOffset < map.count { map[normalizedOffset] = rawOffset }
            }
            guard normalizedOffset == units.count, rawOffset == original.length else {
                throw CoreVocabularyValidationError.invalidPattern
            }
            offsets = map
        }
        func originalRange(_ range: NSRange) -> NSRange? {
            let end = range.location + range.length
            guard end < offsets.count, offsets[range.location] >= 0, offsets[end] >= 0 else { return nil }
            return NSRange(location: offsets[range.location], length: offsets[end] - offsets[range.location])
        }
    }
    public let recognitionHintText: String
    private let corrections: Matcher?
    private let translations: Matcher?
    private let translationOrder: [CoreVocabularyEntry]
    private let protectedTerms: Matcher?
    private let protectionOrder: [CoreVocabularyEntry]

    public init(configuration: CoreVocabularyConfiguration) throws {
        guard configuration.enabled else {
            recognitionHintText = ""
            corrections = nil
            translations = nil
            translationOrder = []
            protectedTerms = nil
            protectionOrder = []
            return
        }
        _ = try configuration.validated()
        let active = configuration.entries.filter(\.enabled)
        func rule(_ entry: CoreVocabularyEntry, source: String, replacement: String, scope: String = "") -> Rule {
            Rule(
                source: source.precomposedStringWithCanonicalMapping, replacement: replacement,
                boundary: entry.boundary,
                scope: scope
            )
        }
        let correctionRules = active.filter(\.correctAlias).map {
            rule($0, source: $0.alias, replacement: $0.canonical)
        }
        corrections = correctionRules.isEmpty ? nil : try Matcher(correctionRules)
        translationOrder = active.filter(\.useInTranslation)
        // One scoped trie keeps storage proportional to the term list,
        // including when many languages share a fixed spelling.
        translations =
            translationOrder.isEmpty
            ? nil
            : try Matcher(
                translationOrder.map {
                    rule($0, source: $0.canonical, replacement: $0.translation, scope: $0.targetLanguage)
                })
        var protection: [CoreVocabularyEntry] = []
        var protectedIndices: [String: Int] = [:]
        for entry in active where entry.recognitionHint || entry.correctAlias || entry.useInTranslation {
            let spelling = entry.canonical.precomposedStringWithCanonicalMapping
            if let index = protectedIndices[spelling] {
                if entry.boundary == .wholeTerm { protection[index].boundary = .wholeTerm }
            } else {
                protectedIndices[spelling] = protection.count
                protection.append(entry)
            }
        }
        protectionOrder = protection
        protectedTerms =
            protectionOrder.isEmpty
            ? nil : try Matcher(protectionOrder.map { rule($0, source: $0.canonical, replacement: $0.canonical) })
        var hint = "", count = 0
        for entry in active where entry.recognitionHint && count < 16 {
            // Whisper treats control-token literals specially. A spelling hint
            // never needs them and must not manufacture model control tokens.
            guard !entry.canonical.contains("<|"), !entry.canonical.contains("|>") else { continue }
            let addition = (hint.isEmpty ? "" : ", ") + entry.canonical
            guard hint.utf8.count + addition.utf8.count <= 192 else { continue }
            hint += addition
            count += 1
        }
        recognitionHintText = hint
    }

    public func correct(_ text: String) throws -> String {
        try Task.checkCancellation()
        guard let corrections else { return text }
        guard text.utf8.count <= CoreVocabularyConfiguration.maximumTextBytes else {
            throw CoreVocabularyValidationError.inputTooLong
        }
        let prepared = try PreparedText(text)
        var result = "", copiedThrough = 0, bytes = 0
        var issue: CoreVocabularyValidationError?
        func append(_ piece: String) -> Bool {
            let count = piece.utf8.count
            guard count <= CoreVocabularyConfiguration.maximumTextBytes - bytes else {
                issue = .outputTooLong
                return false
            }
            result += piece
            bytes += count
            return true
        }
        corrections.forEachMatch(in: prepared) { range, rule in
            let unchanged = prepared.original.substring(
                with: NSRange(location: copiedThrough, length: range.location - copiedThrough))
            guard append(unchanged), append(rule.replacement) else { return false }
            copiedThrough = range.location + range.length
            return true
        }
        try Task.checkCancellation()
        if let issue { throw issue }
        _ = append(prepared.original.substring(from: copiedThrough))
        if let issue { throw issue }
        return result
    }

    public func translationTerms(in text: String, targetLanguage: String) -> [CoreVocabularyTranslationTerm] {
        let specific = Set(
            translationOrder.filter { $0.targetLanguage == targetLanguage }.map {
                $0.canonical.precomposedStringWithCanonicalMapping
            })
        return select(
            in: text,
            matcher: translations, scope: targetLanguage,
            order: translationOrder.filter {
                $0.targetLanguage == targetLanguage
                    || ($0.preservesSpelling && !specific.contains($0.canonical.precomposedStringWithCanonicalMapping))
            }, translate: true)
    }

    public func refinementTerms(in text: String, excluding protectedRanges: [NSRange] = [])
        -> [CoreVocabularyTranslationTerm]
    {
        select(in: text, matcher: protectedTerms, order: protectionOrder, translate: false, excluding: protectedRanges)
    }

    // Planning can admit a larger source than one model request. The matcher
    // emits exact original UTF16 ranges in leftmost order. Adjacent terms stay
    // separate, because a chunk boundary between them does not split a term.
    public func translationSourceRanges(
        in text: String, targetLanguage: String,
        maximumTextBytes: Int = CoreVocabularyConfiguration.maximumTextBytes
    ) throws -> [NSRange] {
        try Task.checkCancellation()
        guard let translations else { return [] }
        guard (1...1_048_576).contains(maximumTextBytes),
            text.utf8.prefix(maximumTextBytes + 1).count <= maximumTextBytes
        else { throw CoreVocabularyValidationError.inputTooLong }
        let prepared = try PreparedText(text)
        var ranges: [NSRange] = []
        translations.forEachMatch(in: prepared, scope: targetLanguage) { range, _ in
            ranges.append(range)
            return true
        }
        try Task.checkCancellation()
        return ranges
    }

    // Refine a translation using only mappings that applied to its original
    // source. The provider receives the bounded output spellings, not that
    // source text. Exclusions refer to translatedText, not originalSource.
    // Matching keeps the configured boundary and never rewrites.
    public func translatedRefinementTerms(
        in originalSource: String, targetLanguage: String, translatedText: String,
        excluding protectedRanges: [NSRange] = []
    ) -> [CoreVocabularyTranslationTerm] {
        let mappings = translationTerms(in: originalSource, targetLanguage: targetLanguage)
        var candidates: [CoreVocabularyEntry] = []
        for term in mappings where term.source != term.target {
            let source = term.source.precomposedStringWithCanonicalMapping
            guard
                let entry = translationOrder.first(where: {
                    $0.targetLanguage == targetLanguage && $0.canonical.precomposedStringWithCanonicalMapping == source
                })
            else { continue }
            var output = entry
            output.canonical = term.target
            candidates.append(output)
        }
        candidates += protectionOrder
        var order: [CoreVocabularyEntry] = [], indices: [String: Int] = [:]
        for entry in candidates {
            let name = entry.canonical.precomposedStringWithCanonicalMapping
            if let index = indices[name] {
                if entry.boundary == .wholeTerm { order[index].boundary = .wholeTerm }
            } else {
                indices[name] = order.count
                order.append(entry)
            }
        }
        guard !order.isEmpty,
            let matcher = try? Matcher(
                order.map {
                    Rule(
                        source: $0.canonical.precomposedStringWithCanonicalMapping, replacement: $0.canonical,
                        boundary: $0.boundary, scope: "")
                })
        else { return [] }
        return select(in: translatedText, matcher: matcher, order: order, translate: false, excluding: protectedRanges)
    }

    // Invalid caller ranges withhold hints instead of exposing a protected
    // occurrence. Empty callers never build or validate this optional index.
    private static func excludedRanges(_ ranges: [NSRange], in source: NSString) -> [Range<Int>]? {
        guard ranges.count <= 512 else { return nil }
        let length = source.length
        func scalarBoundary(_ offset: Int) -> Bool {
            guard offset > 0 && offset < length else { return true }
            return
                !((0xD800...0xDBFF).contains(source.character(at: offset - 1))
                && (0xDC00...0xDFFF).contains(source.character(at: offset)))
        }
        var validated: [Range<Int>] = []
        for range in ranges {
            if Task.isCancelled { return nil }
            guard range.location >= 0, range.location <= length, range.length > 0,
                range.length <= length - range.location
            else { return nil }
            let end = range.location + range.length
            guard scalarBoundary(range.location), scalarBoundary(end) else { return nil }
            validated.append(range.location..<end)
        }
        var result: [Range<Int>] = []
        for range in validated.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, last.upperBound >= range.lowerBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    private func select(
        in text: String, matcher: Matcher?, scope: String = "", order: [CoreVocabularyEntry], translate: Bool,
        excluding protectedRanges: [NSRange] = []
    )
        -> [CoreVocabularyTranslationTerm]
    {
        guard let matcher, !text.isEmpty,
            text.utf8.count <= CoreVocabularyConfiguration.maximumTextBytes
        else {
            return []
        }
        guard let prepared = try? PreparedText(text) else { return [] }
        var matched: Set<String> = []
        if protectedRanges.isEmpty {
            // Keep the ordinary path and original occurrence selection unchanged.
            matcher.forEachMatch(in: prepared, scope: scope) { _, rule in
                matched.insert(rule.source)
                return true
            }
        } else {
            guard let excluded = Self.excludedRanges(protectedRanges, in: prepared.original) else { return [] }
            var cursor = 0
            matcher.forEachMatch(in: prepared, scope: scope) { range, rule in
                // Matches are original UTF16 ranges in leftmost order. Advance
                // through exclusions once; no per-match scan of the whole list.
                while cursor < excluded.count && excluded[cursor].upperBound <= range.location { cursor += 1 }
                if cursor < excluded.count && excluded[cursor].lowerBound < range.location + range.length {
                    return true
                }
                matched.insert(rule.source)
                return true
            }
        }
        if Task.isCancelled { return [] }
        var selected: [CoreVocabularyTranslationTerm] = []
        for entry in order
        where selected.count < 16 && matched.contains(entry.canonical.precomposedStringWithCanonicalMapping) {
            let term = CoreVocabularyTranslationTerm(
                source: entry.canonical, target: translate ? entry.translation : entry.canonical)
            let candidate = selected + [term]
            guard
                let encoded = try? JSONSerialization.data(
                    withJSONObject: candidate.map { ["source": $0.source, "target": $0.target] },
                    options: [.sortedKeys, .withoutEscapingSlashes]), encoded.count <= 512
            else { continue }
            selected = candidate
        }
        return selected
    }
}

// Pure memoization of validated value snapshots, shared by native adapters.
// In-flight tasks retain their immutable snapshot when a later edit replaces
// this one-entry cache. No input text, matching result or history is cached.
public final class CoreVocabularyProcessor: @unchecked Sendable {
    public static let shared = CoreVocabularyProcessor()
    private let lock = NSLock()
    private let compile: @Sendable (CoreVocabularyConfiguration) throws -> CoreVocabularySnapshot
    private var configuration: CoreVocabularyConfiguration?
    private var cached: Result<CoreVocabularySnapshot, Error>?

    public init(
        compile: @escaping @Sendable (CoreVocabularyConfiguration) throws -> CoreVocabularySnapshot = {
            try CoreVocabularySnapshot(configuration: $0)
        }
    ) {
        self.compile = compile
    }

    public func snapshot(for configuration: CoreVocabularyConfiguration) throws -> CoreVocabularySnapshot {
        lock.lock()
        defer { lock.unlock() }
        if self.configuration == configuration, let cached { return try cached.get() }
        let value = Result { try compile(configuration) }
        self.configuration = configuration
        cached = value
        return try value.get()
    }
}
