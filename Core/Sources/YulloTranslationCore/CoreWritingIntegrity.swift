import Foundation

public enum CoreWritingIntegrityUnavailable: Equatable, Sendable {
    case inputTooLong, tooManyNames, invalidName
}

public struct CoreWritingProtectedName: Equatable, Sendable {
    public let name: String
    public let boundary: CoreVocabularyBoundary
    public init(name: String, boundary: CoreVocabularyBoundary = .wholeTerm) {
        self.name = name
        self.boundary = boundary
    }
}

public struct CoreWritingIntegrityReport: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        // The bounded literal scanner completed, not a semantic or factual check.
        case checked
        case notChecked(CoreWritingIntegrityUnavailable)
    }

    public let status: Status
    public let numericLiteralsChanged: Bool
    public let missingProtectedNames: [String]
    public var hasWarnings: Bool { numericLiteralsChanged || !missingProtectedNames.isEmpty }

    fileprivate init(
        status: Status, numericLiteralsChanged: Bool = false, missingProtectedNames: [String] = []
    ) {
        self.status = status
        self.numericLiteralsChanged = numericLiteralsChanged
        self.missingProtectedNames = missingProtectedNames
    }
}

// A local review cue for explicit spelling and decimal literals. A completed
// scan does not establish meaning, truth, units, dates or promise preservation.
// No output is repaired, normalized, delivered or retained here.
public enum CoreWritingIntegrity {
    public static let maximumTextBytes = 131_072
    public static let maximumProtectedNames = 16
    public static let maximumNameScalars = 64

    public static func analyze(
        source: String, result: String, protectedNames: [CoreWritingProtectedName] = []
    ) throws -> CoreWritingIntegrityReport {
        try Task.checkCancellation()
        guard bounded(source), bounded(result) else { return .init(status: .notChecked(.inputTooLong)) }
        guard protectedNames.count <= maximumProtectedNames else {
            return .init(status: .notChecked(.tooManyNames))
        }
        var names: [CoreWritingProtectedName] = [], indices: [String: Int] = [:]
        for protectedName in protectedNames {
            try Task.checkCancellation()
            let name = protectedName.name
            guard name.utf8.count <= maximumNameScalars * 4,
                name.unicodeScalars.count <= maximumNameScalars, !name.isEmpty,
                name == name.trimmingCharacters(in: .whitespacesAndNewlines),
                !name.unicodeScalars.contains(where: {
                    [.control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
                })
            else { return .init(status: .notChecked(.invalidName)) }
            let normalized = name.precomposedStringWithCanonicalMapping
            if let index = indices[normalized] {
                if protectedName.boundary == .wholeTerm { names[index] = protectedName }
            } else {
                indices[normalized] = names.count
                names.append(protectedName)
            }
        }
        if source.utf8.elementsEqual(result.utf8) {
            try Task.checkCancellation()
            return .init(status: .checked)
        }
        let sourceNumbers = try numericLiterals(in: source)
        let resultNumbers = try numericLiterals(in: result)
        var missing: [String] = []
        if !names.isEmpty {
            // Reuse vocabulary's bounded Unicode normalization and whole-term
            // matching. User text remains data; these are literal spellings.
            let configuration = CoreVocabularyConfiguration(
                enabled: true,
                entries: names.map {
                    CoreVocabularyEntry(canonical: $0.name, recognitionHint: true, boundary: $0.boundary)
                })
            let snapshot: CoreVocabularySnapshot
            do { snapshot = try CoreVocabularySnapshot(configuration: configuration) } catch {
                try Task.checkCancellation()
                return .init(status: .notChecked(.invalidName))
            }
            let sourceNames = Set(snapshot.refinementTerms(in: source).map(\.source))
            try Task.checkCancellation()
            let resultNames = Set(snapshot.refinementTerms(in: result).map(\.source))
            try Task.checkCancellation()
            missing = names.filter { sourceNames.contains($0.name) && !resultNames.contains($0.name) }.map(\.name)
        }
        try Task.checkCancellation()
        return .init(
            status: .checked, numericLiteralsChanged: sourceNumbers != resultNumbers,
            missingProtectedNames: missing)
    }

    private static func bounded(_ text: String) -> Bool {
        // Stop at the byte limit even for a much larger foreign String.
        text.utf8.prefix(maximumTextBytes + 1).count <= maximumTextBytes
    }

    private static func numericLiterals(in text: String) throws -> [String: Int] {
        let scalars = text.unicodeScalars
        var position = scalars.startIndex, literals: [String: Int] = [:], steps = 0
        func next(_ index: String.UnicodeScalarView.Index) -> String.UnicodeScalarView.Index {
            scalars.index(after: index)
        }
        func digit(_ index: String.UnicodeScalarView.Index) -> Bool {
            index < scalars.endIndex && scalars[index].properties.generalCategory == .decimalNumber
        }
        func check() throws {
            if steps & 1023 == 0 { try Task.checkCancellation() }
            steps += 1
        }
        while position < scalars.endIndex {
            try check()
            let start = position
            if sign(scalars[position]), digit(next(position)) { position = next(position) }
            guard digit(position) else {
                position = next(position)
                continue
            }
            position = next(position)
            while position < scalars.endIndex {
                try check()
                if digit(position) {
                    position = next(position)
                } else if separator(scalars[position]), digit(next(position)) {
                    position = next(next(position))
                } else {
                    break
                }
            }
            // Preserve decimal scientific notation as one literal, so changing
            // 1e3 to 3e1 cannot evade a multiset comparison of separate digits.
            if position < scalars.endIndex, scalars[position] == "e" || scalars[position] == "E" {
                var exponent = next(position)
                if exponent < scalars.endIndex, sign(scalars[exponent]) { exponent = next(exponent) }
                if digit(exponent) {
                    position = next(exponent)
                    while digit(position) {
                        try check()
                        position = next(position)
                    }
                }
            }
            if position < scalars.endIndex, percent(scalars[position]) { position = next(position) }
            literals[String(scalars[start..<position]), default: 0] += 1
        }
        try Task.checkCancellation()
        return literals
    }

    private static func sign(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2B, 0x2D, 0xB1, 0x2212, 0xFF0B, 0xFF0D: return true
        default: return false
        }
    }
    private static func separator(_ scalar: Unicode.Scalar) -> Bool {
        // Only attach a separator immediately between decimal digits. Sentence
        // punctuation and whitespace around a number are not part of it.
        switch scalar.value {
        case 0x27, 0x2C, 0x2D, 0x2E, 0x2F, 0x3A, 0xA0, 0x66B, 0x66C, 0x2009, 0x2010, 0x2011,
            0x2013, 0x2014, 0x2019, 0x202F, 0x2212, 0xFF0C, 0xFF0D, 0xFF0E, 0xFF0F, 0xFF1A:
            return true
        default: return false
        }
    }
    private static func percent(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x25, 0x66A, 0x2030, 0x2031, 0xFF05: return true
        default: return false
        }
    }
}
