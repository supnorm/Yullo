import Foundation

public enum CoreTermProtectionError: Error, Equatable, Sendable {
    case invalidTerms, inputTooLong, tooManyOccurrences, invalidMarkers
}

public struct CoreTermProtection: Sendable {
    public struct Occurrence: Sendable {
        public let id: String
        public let source: String
        public let target: String
        public let opening: String
    }
    public let text: String
    public let tagName: String
    public let occurrences: [Occurrence]
    public var active: Bool { !occurrences.isEmpty }

    public static func make(source: String, terms: [CoreVocabularyTranslationTerm]) throws -> Self {
        try Task.checkCancellation()
        guard source.utf8.count <= 131_072 else { throw CoreTermProtectionError.inputTooLong }
        guard terms.count <= 16 else { throw CoreTermProtectionError.invalidTerms }
        guard !terms.isEmpty else { return Self(text: source, tagName: "x", occurrences: []) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard try encoder.encode(terms).count <= 512 else { throw CoreTermProtectionError.invalidTerms }
        var names: Set<String> = []
        for value in [source] + terms.flatMap({ [$0.source, $0.target] }) {
            try Task.checkCancellation()
            let bytes = Array(value.utf8)
            var cursor = 0
            while cursor < bytes.count {
                if cursor.isMultiple(of: 4096) { try Task.checkCancellation() }
                guard bytes[cursor] == 60 else {
                    cursor += 1
                    continue
                }
                cursor += 1
                if cursor < bytes.count, bytes[cursor] == 47 { cursor += 1 }
                let start = cursor
                while cursor < bytes.count, nameUnit(bytes[cursor]) { cursor += 1 }
                if cursor > start { names.insert(String(decoding: bytes[start..<cursor], as: UTF8.self).lowercased()) }
            }
        }
        var tag = "x", suffix = 0
        while names.contains(tag) {
            suffix += 1
            tag = "x\(suffix)"
        }
        var mapping: [String: CoreVocabularyTranslationTerm] = [:]
        var entries: [CoreVocabularyEntry] = []
        for term in terms {
            let key = term.source.precomposedStringWithCanonicalMapping
            guard mapping[key] == nil else { throw CoreTermProtectionError.invalidTerms }
            mapping[key] = term
            entries.append(
                .init(canonical: term.source, useInTranslation: true, translation: term.target, targetLanguage: "en"))
        }
        let snapshot = try CoreVocabularySnapshot(configuration: .init(enabled: true, entries: entries))
        let ranges = try snapshot.translationSourceRanges(in: source, targetLanguage: "en")
        let raw = source as NSString
        let excluded = try protectedLiteralRanges(source)
        var text = "", occurrences: [Occurrence] = []
        var copied = 0, excludedIndex = 0, byteCount = 0
        for range in ranges {
            try Task.checkCancellation()
            while excludedIndex < excluded.count, NSMaxRange(excluded[excludedIndex]) <= range.location {
                excludedIndex += 1
            }
            if excludedIndex < excluded.count, NSIntersectionRange(excluded[excludedIndex], range).length > 0 {
                continue
            }
            guard occurrences.count < 256 else { throw CoreTermProtectionError.tooManyOccurrences }
            let key = raw.substring(with: range).precomposedStringWithCanonicalMapping
            guard let term = mapping[key] else { throw CoreTermProtectionError.invalidTerms }
            let id = String(occurrences.count), opening = "<\(tag) id=\"\(occurrences.count)\">"
            let unchanged = raw.substring(with: NSRange(location: copied, length: range.location - copied))
            let tagged = opening + raw.substring(with: range) + "</\(tag)>"
            byteCount += unchanged.utf8.count + tagged.utf8.count
            guard byteCount <= 131_072 else { throw CoreTermProtectionError.inputTooLong }
            text += unchanged + tagged
            copied = NSMaxRange(range)
            occurrences.append(.init(id: id, source: term.source, target: term.target, opening: opening))
        }
        text += raw.substring(from: copied)
        guard text.utf8.count <= 131_072 else { throw CoreTermProtectionError.inputTooLong }
        return Self(text: text, tagName: tag, occurrences: occurrences)
    }

    public func restore(_ output: String) throws -> String {
        try Task.checkCancellation()
        guard active else { return output }
        guard output.utf8.count <= 262_144 else { throw CoreTermProtectionError.inputTooLong }
        let bytes = Array(output.utf8)
        let definitions = Dictionary(uniqueKeysWithValues: occurrences.map { ($0.opening, $0) })
        var owned: [Tag] = []
        for token in try Self.lexicalTokens(bytes) {
            switch token.kind {
            case .tag(let name, let closing) where name.lowercased() == tagName:
                owned.append(
                    Tag(
                        start: token.range.lowerBound, end: token.range.upperBound,
                        literal: String(decoding: bytes[token.range], as: UTF8.self), closing: closing))
            default:
                // A transport delimiter cannot be borrowed from a foreign
                // quoted attribute, comment, CDATA, instruction or code span.
                if try containsOwnedSyntax(bytes[token.range]) { throw CoreTermProtectionError.invalidMarkers }
            }
        }
        var seen: Set<String> = []
        var result: [UInt8] = []
        var cursor = 0
        func append(_ value: ArraySlice<UInt8>) throws {
            guard value.count <= 262_144 - result.count else { throw CoreTermProtectionError.inputTooLong }
            result.append(contentsOf: value)
        }
        var tokenIndex = 0
        while tokenIndex < owned.count {
            try Task.checkCancellation()
            let opening = owned[tokenIndex]
            guard !opening.closing, let definition = definitions[opening.literal], seen.insert(definition.id).inserted
            else {
                throw CoreTermProtectionError.invalidMarkers
            }
            try append(bytes[cursor..<opening.start])
            guard tokenIndex + 1 < owned.count else { throw CoreTermProtectionError.invalidMarkers }
            let closing = owned[tokenIndex + 1]
            guard closing.closing, closing.literal == "</\(tagName)>" else {
                throw CoreTermProtectionError.invalidMarkers
            }
            let bodyBytes = bytes[opening.end..<closing.start]
            let body = String(decoding: bodyBytes, as: UTF8.self)
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw CoreTermProtectionError.invalidMarkers }
            let content = trimmed.utf8.prefix(4097).count <= 4096 ? trimmed.precomposedStringWithCanonicalMapping : nil
            let original = definition.source.precomposedStringWithCanonicalMapping
            let target = definition.target.precomposedStringWithCanonicalMapping
            if content == original {
                let leading = String(body.prefix(while: { $0.isWhitespace }))
                let trailing = String(body.reversed().prefix(while: { $0.isWhitespace }).reversed())
                try append(Array((leading + definition.target + trailing).utf8)[...])
            } else if original == target {
                throw CoreTermProtectionError.invalidMarkers
            } else {
                try append(bodyBytes)
            }
            cursor = closing.end
            tokenIndex += 2
        }
        try append(bytes[cursor...])
        guard seen.count == occurrences.count else { throw CoreTermProtectionError.invalidMarkers }
        try Task.checkCancellation()
        return String(decoding: result, as: UTF8.self)
    }

    private struct Tag {
        let start: Int
        let end: Int
        let literal: String
        let closing: Bool
    }
    private func containsOwnedSyntax(_ bytes: ArraySlice<UInt8>) throws -> Bool {
        var cursor = bytes.startIndex
        while cursor < bytes.endIndex {
            if cursor.isMultiple(of: 4096) { try Task.checkCancellation() }
            guard bytes[cursor] == 60 else {
                cursor += 1
                continue
            }
            cursor += 1
            if cursor < bytes.endIndex, bytes[cursor] == 47 { cursor += 1 }
            let start = cursor
            while cursor < bytes.endIndex, Self.nameUnit(bytes[cursor]) { cursor += 1 }
            if String(decoding: bytes[start..<cursor], as: UTF8.self).lowercased() == tagName { return true }
        }
        return false
    }

    private enum LexicalKind { case tag(String, Bool), opaque }
    private struct LexicalToken {
        let range: Range<Int>
        let kind: LexicalKind
    }

    // This is a finite boundary scan, not an HTML/XML document parser. It
    // neither interprets entities nor changes or balances foreign markup.
    private static func lexicalTokens(_ bytes: [UInt8]) throws -> [LexicalToken] {
        var tokens: [LexicalToken] = [], cursor = 0
        func has(_ literal: String, at index: Int) -> Bool {
            bytes[index...].starts(with: literal.utf8)
        }
        func ending(_ literal: String, from start: Int) throws -> Int {
            var index = start
            while index < bytes.count {
                if index.isMultiple(of: 4096) { try Task.checkCancellation() }
                if has(literal, at: index) { return index + literal.utf8.count }
                index += 1
            }
            return bytes.count
        }
        while cursor < bytes.count {
            if cursor.isMultiple(of: 4096) { try Task.checkCancellation() }
            if bytes[cursor] == 96 {
                let start = cursor
                while cursor < bytes.count, bytes[cursor] == 96 { cursor += 1 }
                cursor = try ending(String(repeating: "`", count: cursor - start), from: cursor)
                tokens.append(.init(range: start..<cursor, kind: .opaque))
                continue
            }
            guard bytes[cursor] == 60 else {
                cursor += 1
                continue
            }
            let start = cursor
            if has("<!--", at: start) {
                cursor = try ending("-->", from: start + 4)
                tokens.append(.init(range: start..<cursor, kind: .opaque))
                continue
            }
            if has("<![CDATA[", at: start) {
                cursor = try ending("]]>", from: start + 9)
                tokens.append(.init(range: start..<cursor, kind: .opaque))
                continue
            }
            let instruction = has("<?", at: start)
            let declaration = has("<!", at: start)
            var index = start + 1
            var closing = false
            if index < bytes.count, bytes[index] == 47 {
                closing = true
                index += 1
            }
            let nameStart = index
            while index < bytes.count, nameUnit(bytes[index]) { index += 1 }
            let name = String(decoding: bytes[nameStart..<index], as: UTF8.self)
            guard instruction || declaration || !name.isEmpty else {
                cursor += 1
                continue
            }
            var quote: UInt8?, brackets = 0, complete = false
            while index < bytes.count {
                if index.isMultiple(of: 4096) { try Task.checkCancellation() }
                let byte = bytes[index]
                if let current = quote {
                    if byte == current { quote = nil }
                } else if byte == 34 || byte == 39 {
                    quote = byte
                } else if declaration && byte == 91 {
                    brackets += 1
                } else if declaration && byte == 93 && brackets > 0 {
                    brackets -= 1
                } else if byte == 62 && brackets == 0 && (!instruction || (index > start && bytes[index - 1] == 63)) {
                    index += 1
                    complete = true
                    break
                }
                index += 1
            }
            cursor = index
            tokens.append(
                .init(
                    range: start..<cursor,
                    kind: complete && !instruction && !declaration ? .tag(name, closing) : .opaque))
        }
        return tokens
    }
    private static func nameUnit(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 95 || byte == 45
            || byte == 58
    }
    private static func protectedLiteralRanges(_ source: String) throws -> [NSRange] {
        let bytes = Array(source.utf8)
        let tokens = try lexicalTokens(bytes)
        var offsets = [Int](repeating: -1, count: bytes.count + 1)
        var byteOffset = 0, unitOffset = 0
        offsets[0] = 0
        for (index, scalar) in source.unicodeScalars.enumerated() {
            if index.isMultiple(of: 1024) { try Task.checkCancellation() }
            let value = scalar.value
            byteOffset += value < 128 ? 1 : (value < 2048 ? 2 : (value < 65536 ? 3 : 4))
            unitOffset += value > 65535 ? 2 : 1
            offsets[byteOffset] = unitOffset
        }
        let raw = source as NSString
        var ranges: [NSRange] = [], cursor = 0
        func delimiter(_ unit: UInt16) -> Bool {
            unit == 34 || unit == 39 || unit == 60 || unit == 62 || unit == 96
                || (UnicodeScalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false)
        }
        func textURLs(_ start: Int, _ end: Int) throws {
            var index = start
            while index < end {
                if index.isMultiple(of: 4096) { try Task.checkCancellation() }
                let beginning = index
                while index < end, !delimiter(raw.character(at: index)) {
                    if index.isMultiple(of: 4096) { try Task.checkCancellation() }
                    index += 1
                }
                if index > beginning {
                    let atom = raw.substring(with: NSRange(location: beginning, length: index - beginning))
                    if atom.contains("://") || atom.hasPrefix("mailto:") || (atom.contains("@") && atom.contains(".")) {
                        ranges.append(NSRange(location: beginning, length: index - beginning))
                    }
                } else {
                    index += 1
                }
            }
        }
        for token in tokens {
            try Task.checkCancellation()
            let start = offsets[token.range.lowerBound], end = offsets[token.range.upperBound]
            guard start >= cursor, end >= start else { throw CoreTermProtectionError.invalidTerms }
            try textURLs(cursor, start)
            ranges.append(NSRange(location: start, length: end - start))
            cursor = end
        }
        try textURLs(cursor, raw.length)
        var merged: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1].length = max(NSMaxRange(last), NSMaxRange(range)) - last.location
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
