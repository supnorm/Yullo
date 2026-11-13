import Foundation

// Shared legacy code/URL rules; additional technical rules live outside this owner.
enum CoreLiteralScanner {
    struct Token {
        let range: Range<Int>
        let text: String
    }

    static let urlPrefixes: [[UInt16]] = ["https://", "http://", "ftp://", "mailto:"].map { Array($0.utf16) }

    struct Scan {
        let tokens: [Token]
        let noBreak: [Range<Int>]
    }

    static func tokens(_ units: [UInt16]) throws -> [Token] {
        try scan(units).tokens
    }

    static func scan(_ units: [UInt16], additionalURLPrefixes: [[UInt16]] = []) throws -> Scan {
        let prefixes = urlPrefixes + additionalURLPrefixes
        var runs: [(start: Int, end: Int, escapeStart: Int, escaped: Bool)] = []
        var cursor = 0
        var slashes = 0
        while cursor < units.count {
            if cursor & 4_095 == 0 { try Task.checkCancellation() }
            if units[cursor] == 96 {
                let start = cursor
                repeat { cursor += 1 } while cursor < units.count && units[cursor] == 96
                runs.append((start, cursor, start - slashes, slashes % 2 == 1))
                slashes = 0
            } else {
                slashes = units[cursor] == 92 ? slashes + 1 : 0
                cursor += 1
            }
        }
        var next = Array<Int?>(repeating: nil, count: runs.count)
        var byLength: [Int: Int] = [:]
        for index in runs.indices.reversed() {
            let length = runs[index].end - runs[index].start
            next[index] = byLength[length]
            byLength[length] = index
        }
        var code: [Range<Int>] = []
        var index = 0
        while index < runs.count {
            if !runs[index].escaped, let close = next[index] {
                code.append(runs[index].start..<runs[close].end)
                index = close + 1
            } else {
                index += 1
            }
        }
        var result: [Token] = []
        cursor = 0
        var codeIndex = 0
        while cursor < units.count {
            if cursor & 4_095 == 0 { try Task.checkCancellation() }
            if codeIndex < code.count && cursor == code[codeIndex].lowerBound {
                let range = code[codeIndex]
                result.append(Token(range: range, text: String(decoding: units[range], as: UTF16.self)))
                cursor = range.upperBound
                codeIndex += 1
                continue
            }
            let start = cursor
            if let prefix = prefixes.first(where: { matches($0, units, cursor) }) {
                cursor += prefix.count
                var depth = 0
                while cursor < units.count && !urlEnd(units[cursor]) {
                    if units[cursor] == 40 { depth += 1 }
                    if units[cursor] == 41 {
                        if depth == 0 { break }
                        depth -= 1
                    }
                    // Code spans have precedence over a preceding URL.
                    if codeIndex < code.count && cursor == code[codeIndex].lowerBound { break }
                    cursor += 1
                }
                while cursor > start + prefix.count && [UInt16(46), 44, 33, 59, 58].contains(units[cursor - 1]) {
                    cursor -= 1
                }
                if cursor > start + prefix.count {
                    let range = start..<cursor
                    result.append(Token(range: range, text: String(decoding: units[range], as: UTF16.self)))
                    continue
                }
            }
            cursor = start + 1
        }
        // Unmatched delimiter runs and their escape prefixes also remain
        // whole: splitting ``` into ` can invent an inline token.
        var noBreak: [Range<Int>] = []
        var runIndex = 0
        var tokenIndex = 0
        while runIndex < runs.count || tokenIndex < result.count {
            let range: Range<Int>
            if runIndex < runs.count,
                tokenIndex == result.count || runs[runIndex].escapeStart <= result[tokenIndex].range.lowerBound
            {
                range = runs[runIndex].escapeStart..<runs[runIndex].end
                runIndex += 1
            } else {
                range = result[tokenIndex].range
                tokenIndex += 1
            }
            if let previous = noBreak.last, previous.upperBound > range.lowerBound {
                noBreak[noBreak.count - 1] = previous.lowerBound..<max(previous.upperBound, range.upperBound)
            } else {
                noBreak.append(range)
            }
        }
        return Scan(tokens: result, noBreak: noBreak)
    }

    static func matches(_ prefix: [UInt16], _ units: [UInt16], _ start: Int) -> Bool {
        guard prefix.count <= units.count - start else { return false }
        for offset in prefix.indices {
            let value = units[start + offset]
            let lower = (65...90).contains(value) ? value + 32 : value
            if lower != prefix[offset] { return false }
        }
        return true
    }

    static func urlEnd(_ unit: UInt16) -> Bool {
        // Bare URLs have punctuation ambiguity. Match the existing prose
        // heuristic for common CJK punctuation/quotes, while retaining
        // Unicode letters/path characters and percent-encoded punctuation.
        switch unit {
        case 60, 62, 34, 39, 96, 0xFF0C, 0xFF0E, 0xFF1A, 0xFF1B, 0xFF01, 0xFF1F,
            0x3001, 0x3002, 0x3008, 0x3009, 0x300A, 0x300B, 0x300C, 0x300D, 0x300E, 0x300F,
            0x3010, 0x3011, 0x3014, 0x3015, 0x3016, 0x3017, 0x3018, 0x3019, 0x301A, 0x301B,
            0xFF08, 0xFF09, 0xFF3B, 0xFF3D, 0xFF5B, 0xFF5D, 0x2018, 0x2019, 0x201C, 0x201D, 0x2026, 0x00AB, 0x00BB:
            return true
        default: break
        }
        return UnicodeScalar(unit).map { CharacterSet.whitespacesAndNewlines.contains($0) } ?? false
    }

    static func fenceAt(_ units: [UInt16], _ start: Int, _ end: Int) -> (
        marker: UInt16, length: Int, tail: ArraySlice<UInt16>
    )? {
        var index = start
        while index < end && units[index] == 32 && index - start < 4 { index += 1 }
        guard index - start <= 3, index < end, units[index] == 96 || units[index] == 126 else { return nil }
        let marker = units[index]
        let runStart = index
        while index < end && units[index] == marker { index += 1 }
        guard index - runStart >= 3 else { return nil }
        return (marker, index - runStart, units[index..<end])
    }

    static func newline(_ unit: UInt16) -> Bool {
        unit == 10 || unit == 13 || unit == 0x85 || unit == 0x2028 || unit == 0x2029
    }

    static func fencedRanges(_ units: [UInt16]) throws -> [Range<Int>] {
        var result: [Range<Int>] = [], cursor = 0
        var fence: (marker: UInt16, length: Int, start: Int)?
        while cursor < units.count {
            try Task.checkCancellation()
            let start = cursor
            while cursor < units.count && !newline(units[cursor]) { cursor += 1 }
            let contentEnd = cursor
            if cursor < units.count {
                if units[cursor] == 13 && cursor + 1 < units.count && units[cursor + 1] == 10 { cursor += 1 }
                cursor += 1
            }
            if let open = fence {
                if let close = fenceAt(units, start, contentEnd), close.marker == open.marker,
                    close.length >= open.length, close.tail.allSatisfy({ $0 == 32 || $0 == 9 })
                {
                    result.append(open.start..<cursor)
                    fence = nil
                }
            } else if let open = fenceAt(units, start, contentEnd), open.marker != 96 || !open.tail.contains(96) {
                fence = (open.marker, open.length, start)
            }
        }
        if let fence { result.append(fence.start..<units.count) }
        try Task.checkCancellation()
        return result
    }
}
