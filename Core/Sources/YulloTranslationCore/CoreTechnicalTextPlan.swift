import Foundation

public struct CoreTechnicalTextPlan: Sendable {
    public enum Issue: Error, Equatable, Sendable {
        case inputTooLong, tooManyLiterals, invalidMarkers, outputTooLong
    }
    public struct Literal: Sendable {
        public let id: Int
        public let range: NSRange
        public let text: String
        public let marker: String
    }
    public static let maximumSourceBytes = 131_072
    public static let maximumOutputBytes = 4_194_304
    public static let maximumLiterals = 512
    public let text: String
    public let literals: [Literal]
    public let namespace: String
    private let originalText: String
    /// The native owner can return exact original input without a provider call
    /// when every remaining unit is whitespace, as for a code-only message.
    public let requiresTransformation: Bool
    public var writingRequirements: CoreWritingRequirements { .init(technicalMarkerNamespace: namespace) }

    public static func make(source: String, enabled: Bool = true) throws -> Self? {
        try Task.checkCancellation()
        guard enabled else { return nil }
        guard source.utf8.count <= maximumSourceBytes else { throw Issue.inputTooLong }
        let units = Array(source.utf16)
        var ranges = try CoreLiteralScanner.scan(units, additionalURLPrefixes: [Array("file://".utf16)]).tokens.map(
            \.range)
        ranges += try CoreLiteralScanner.fencedRanges(units)
        ranges = try merged(ranges)
        let paths = try pathRanges(units)
        ranges = try merged(ranges + paths.paths)
        for regex in [identifier, flag] {
            let fixed = ranges
            var visited = 0, failed: Issue?
            regex.enumerateMatches(in: source, range: NSRange(location: 0, length: units.count)) { match, _, stop in
                visited += 1
                if visited.isMultiple(of: 64), Task.isCancelled {
                    stop.pointee = true
                    return
                }
                guard let range = match?.range, range.length > 0 else { return }
                var interval = range.location..<(range.location + range.length)
                if regex === flag, let end = units[interval].firstIndex(where: CoreLiteralScanner.urlEnd) {
                    interval = interval.lowerBound..<end
                }
                guard !interval.isEmpty else { return }
                guard !contains(fixed, interval), !intersects(paths.emails, interval) else { return }
                if regex === identifier {
                    if units[interval].contains(95) {
                        let value = String(decoding: units[interval], as: UTF16.self)
                        if value.hasPrefix("_"), interval.lowerBound > 0 {
                            let position = String.Index(utf16Offset: interval.lowerBound, in: source)
                            let previous = source.unicodeScalars[source.unicodeScalars.index(before: position)]
                            if previous.properties.isAlphabetic && !previous.properties.isLowercase
                                && !previous.properties.isUppercase
                            {
                                return
                            }
                        }
                        guard value.unicodeScalars.contains(where: { $0.properties.isAlphabetic }) else { return }
                    } else {
                        guard
                            units[interval].contains(where: { unit in
                                if (65...90).contains(unit) { return true }
                                guard unit > 127 else { return false }
                                return (0xD800...0xDFFF).contains(unit)
                                    || (UnicodeScalar(unit)?.properties.isUppercase ?? false)
                            })
                        else { return }
                        guard camelCase(String(decoding: units[interval], as: UTF16.self)) else { return }
                    }
                }
                ranges.append(interval)
                if ranges.count > maximumLiterals * 3 {
                    failed = .tooManyLiterals
                    stop.pointee = true
                }
            }
            try Task.checkCancellation()
            if let failed { throw failed }
            ranges = try merged(ranges)
        }
        ranges = try merged(ranges)
        guard !ranges.isEmpty else { return nil }
        let namespace = try availableNamespace(source)
        let raw = source as NSString
        var text = "", literals: [Literal] = [], copied = 0, hasProse = false
        for range in ranges {
            try Task.checkCancellation()
            let original = raw.substring(with: NSRange(location: range.lowerBound, length: range.count))
            let prefix = raw.substring(with: NSRange(location: copied, length: range.lowerBound - copied))
            let marker = "[[\(namespace):\(literals.count)]]"
            text += prefix + marker
            if !hasProse {
                hasProse = prefix.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) }
            }
            literals.append(
                Literal(
                    id: literals.count, range: NSRange(location: range.lowerBound, length: range.count), text: original,
                    marker: marker))
            copied = range.upperBound
        }
        let tail = raw.substring(from: copied)
        text += tail
        if !hasProse { hasProse = tail.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) } }
        // A literal-only task never sends this mask to a provider. Its exact
        // original can return even if replacing a short token enlarged the mask.
        guard !hasProse || text.utf8.count <= maximumSourceBytes else { throw Issue.inputTooLong }
        try Task.checkCancellation()
        return Self(
            text: text, literals: literals, namespace: namespace,
            originalText: source, requiresTransformation: hasProse)
    }

    /// The vocabulary owner excludes actual original occurrences before its
    /// existing ordering and budget rules, without changing source boundaries.
    public func refinementTerms(using vocabulary: CoreVocabularySnapshot) -> [CoreVocabularyTranslationTerm] {
        vocabulary.refinementTerms(in: originalText, excluding: literals.map(\.range))
    }

    public func translatedRefinementTerms(
        using vocabulary: CoreVocabularySnapshot, originalSource: String, targetLanguage: String
    ) -> [CoreVocabularyTranslationTerm] {
        vocabulary.translatedRefinementTerms(
            in: originalSource, targetLanguage: targetLanguage, translatedText: originalText,
            excluding: literals.map(\.range))
    }

    /// Final-result admission only. Do not pass marker-bearing provisional text
    /// to presentation; protected writing should use the existing final callback.
    public func restore(_ output: String) throws -> String {
        try Task.checkCancellation()
        guard output.utf8.count <= Self.maximumOutputBytes else { throw Issue.outputTooLong }
        let bytes = Array(output.utf8), needle = Array(namespace.utf8)
        var result: [UInt8] = [], seen = Set<Int>(), cursor = 0, copied = 0, nextCheckpoint = 4096
        result.reserveCapacity(bytes.count)
        func matches(_ value: [UInt8], _ start: Int) -> Bool {
            start >= 0 && value.count <= bytes.count - start
                && bytes[start..<(start + value.count)].elementsEqual(value)
        }
        func append(_ value: ArraySlice<UInt8>) throws {
            guard value.count <= Self.maximumOutputBytes - result.count else { throw Issue.outputTooLong }
            var offset = value.startIndex
            while offset < value.endIndex {
                try Task.checkCancellation()
                let end = min(value.endIndex, offset + 4096)
                result.append(contentsOf: value[offset..<end])
                offset = end
            }
        }
        while cursor < bytes.count {
            if cursor >= nextCheckpoint {
                try Task.checkCancellation()
                nextCheckpoint = cursor + 4096
            }
            guard matches(needle, cursor) else {
                cursor += 1
                continue
            }
            guard cursor >= copied + 2, bytes[cursor - 2] == 91, bytes[cursor - 1] == 91 else {
                throw Issue.invalidMarkers
            }
            let start = cursor - 2
            var end = cursor + needle.count
            guard end < bytes.count, bytes[end] == 58 else { throw Issue.invalidMarkers }
            end += 1
            let digits = end
            var id = 0
            while end < bytes.count && (48...57).contains(bytes[end]) {
                guard end - digits < 4 else { throw Issue.invalidMarkers }
                id = id * 10 + Int(bytes[end] - 48)
                end += 1
            }
            guard end > digits, end + 2 <= bytes.count, bytes[end] == 93, bytes[end + 1] == 93,
                literals.indices.contains(id), seen.insert(id).inserted
            else { throw Issue.invalidMarkers }
            end += 2
            guard bytes[start..<end].elementsEqual(literals[id].marker.utf8) else { throw Issue.invalidMarkers }
            try append(bytes[copied..<start])
            let literal = Array(literals[id].text.utf8)
            try append(literal[...])
            copied = end
            cursor = end
        }
        guard seen.count == literals.count else { throw Issue.invalidMarkers }
        try append(bytes[copied...])
        try Task.checkCancellation()
        let restored = String(decoding: result, as: UTF8.self)
        try Task.checkCancellation()
        return restored
    }

    private static let identifier = try! NSRegularExpression(
        pattern:
            #"(?<![\p{Lu}\p{Ll}\p{Lt}\p{M}\p{Nd}_])[\p{Lu}\p{Ll}\p{Lt}_][\p{Lu}\p{Ll}\p{Lt}\p{M}\p{Nd}_]*(?![\p{Lu}\p{Ll}\p{Lt}\p{M}\p{Nd}_])"#
    )
    private static let flag = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{M}\p{N}_-])--[A-Za-z][A-Za-z0-9_-]*(?:=[^\s`"'<>\[\]{}(),;!?]+)?"#)

    private static func camelCase(_ value: String) -> Bool {
        var lower = false, upperRun = 0
        for scalar in value.unicodeScalars {
            if scalar.properties.isUppercase {
                if lower { return true }
                upperRun += 1
            } else if scalar.properties.isLowercase {
                if upperRun >= 2 { return true }
                lower = true
                upperRun = 0
            } else if scalar.properties.generalCategory == .decimalNumber {
                lower = true
                upperRun = 0
            } else if !CharacterSet.nonBaseCharacters.contains(scalar) {
                lower = false
                upperRun = 0
            }
        }
        return false
    }
    private static func merged(_ ranges: [Range<Int>]) throws -> [Range<Int>] {
        var result: [Range<Int>] = []
        for range in ranges.sorted(by: {
            $0.lowerBound == $1.lowerBound ? $0.upperBound > $1.upperBound : $0.lowerBound < $1.lowerBound
        }) {
            try Task.checkCancellation()
            if let previous = result.last, previous.upperBound > range.lowerBound {
                result[result.count - 1] = previous.lowerBound..<max(previous.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        guard result.count <= maximumLiterals else { throw Issue.tooManyLiterals }
        return result
    }
    private static func contains(_ ranges: [Range<Int>], _ range: Range<Int>) -> Bool {
        let index = preceding(ranges, range.lowerBound)
        return index >= 0 && ranges[index].upperBound >= range.upperBound
    }
    private static func intersects(_ ranges: [Range<Int>], _ range: Range<Int>) -> Bool {
        let index = preceding(ranges, range.upperBound - 1)
        return index >= 0 && ranges[index].upperBound > range.lowerBound
    }
    private static func preceding(_ ranges: [Range<Int>], _ offset: Int) -> Int {
        var lower = 0, upper = ranges.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if ranges[middle].lowerBound <= offset { lower = middle + 1 } else { upper = middle }
        }
        return lower - 1
    }

    private static func availableNamespace(_ source: String) throws -> String {
        let bytes = Array(source.utf8), prefix = Array("YULLO".utf8)
        var used = Set<Int>(), cursor = 0, nextCheckpoint = 4096
        while cursor < bytes.count {
            if cursor >= nextCheckpoint {
                try Task.checkCancellation()
                nextCheckpoint = cursor + 4096
            }
            if prefix.count <= bytes.count - cursor, bytes[cursor..<(cursor + prefix.count)].elementsEqual(prefix) {
                cursor += prefix.count
                var number = 0, bounded = true
                while cursor < bytes.count && (48...57).contains(bytes[cursor]) {
                    if bounded {
                        let digit = Int(bytes[cursor] - 48)
                        if number <= (maximumSourceBytes - digit) / 10 {
                            number = number * 10 + digit
                            used.insert(number)
                        } else {
                            bounded = false
                        }
                    }
                    cursor += 1
                }
            } else {
                cursor += 1
            }
        }
        var number = 0
        while used.contains(number) { number += 1 }
        let result = "YULLO\(number)"
        guard !source.contains(result) else { throw Issue.invalidMarkers }
        try Task.checkCancellation()
        return result
    }

    private static func pathRanges(_ units: [UInt16]) throws -> (paths: [Range<Int>], emails: [Range<Int>]) {
        var result: [Range<Int>] = [], emails: [Range<Int>] = [], cursor = 0, nextCheckpoint = 4096
        func space(_ value: UInt16) -> Bool {
            UnicodeScalar(value).map(CharacterSet.whitespacesAndNewlines.contains) ?? false
        }
        func boundary(_ value: UInt16) -> Bool {
            CoreLiteralScanner.urlEnd(value)
                || [UInt16(40), 41, 44, 59, 91, 93, 123, 125].contains(value)
        }
        func path(_ range: Range<Int>) -> Bool {
            guard range.count > 1 else { return false }
            let value = Array(units[range])
            let first = value[0]
            if first == 47, value[1] != 47 { return true }
            if value.starts(with: [46, 47]) || value.starts(with: [46, 46, 47]) || value.starts(with: [126, 47])
                || value.starts(with: [92, 92])
            {
                return true
            }
            if value.count >= 3, ((65...90).contains(first) || (97...122).contains(first)), value[1] == 58,
                value[2] == 92 || value[2] == 47
            {
                return true
            }
            guard let slash = value.lastIndex(where: { $0 == 47 || $0 == 92 }), slash > 0, slash + 1 < value.count,
                let dot = value[(slash + 1)...].lastIndex(of: 46), dot > slash + 1, dot + 1 < value.count,
                value.count - dot <= 17
            else { return false }
            return value[(dot + 1)...].allSatisfy {
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
            }
        }
        func scalarAt(_ index: Int, before end: Int) -> (UnicodeScalar, Int)? {
            let first = units[index]
            if (0xD800...0xDBFF).contains(first), index + 1 < end {
                let second = units[index + 1]
                guard (0xDC00...0xDFFF).contains(second) else { return nil }
                let value = 0x10000 + (UInt32(first - 0xD800) << 10) + UInt32(second - 0xDC00)
                return UnicodeScalar(value).map { ($0, 2) }
            }
            return UnicodeScalar(first).map { ($0, 1) }
        }
        while cursor < units.count {
            if cursor >= nextCheckpoint {
                try Task.checkCancellation()
                nextCheckpoint = cursor + 4096
            }
            if units[cursor] == 34 || units[cursor] == 39 {
                let quote = units[cursor], start = cursor
                var end = cursor + 1
                while end < units.count && !CoreLiteralScanner.newline(units[end]) && units[end] != quote {
                    if units[end] == 92 && end + 1 < units.count && units[end + 1] == quote {
                        end += 2
                    } else {
                        end += 1
                    }
                }
                if end < units.count, units[end] == quote, path((start + 1)..<end) {
                    result.append(start..<(end + 1))
                    cursor = end + 1
                    continue
                }
                cursor += 1
                continue
            }
            if boundary(units[cursor]) {
                cursor += 1
                continue
            }
            let start = cursor
            var round = 0
            while cursor < units.count {
                let value = units[cursor]
                if value == 92, cursor + 1 < units.count, space(units[cursor + 1]) {
                    cursor += 2
                    continue
                }
                if value == 40 {
                    round += 1
                } else if value == 41 {
                    if round == 0 { break }
                    round -= 1
                } else if boundary(value) || space(value) {
                    break
                }
                cursor += 1
            }
            var end = cursor
            while end > start && [UInt16(46), 44, 59, 58, 33, 63].contains(units[end - 1]) { end -= 1 }
            let range = start..<end
            var pathStart = start
            while pathStart < end, let (scalar, length) = scalarAt(pathStart, before: end),
                (scalar.properties.isAlphabetic && !scalar.properties.isLowercase && !scalar.properties.isUppercase)
                    || CharacterSet.nonBaseCharacters.contains(scalar)
            { pathStart += length }
            if path(pathStart..<end) { result.append(pathStart..<end) }
            if let at = units[range].firstIndex(of: 64), units[(at + 1)..<end].contains(46) { emails.append(range) }
            if cursor == start { cursor += 1 }
        }
        try Task.checkCancellation()
        return (result, emails)
    }
}
