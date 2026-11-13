import Foundation

/// The original document owns every structural byte, including JSON serialized
/// inside string values. Only final decoded text values are translated; API/CLI
/// batches may also carry bounded field context as task data.
public struct CoreJSONTranslationPlan: Sendable {
    public struct Leaf: Sendable {
        public let id: Int
        public let source: String
        public let context: [String]?
        fileprivate let range: Range<Int>
        fileprivate let escapingDepth: Int
    }
    public enum Issue: Error, Equatable, Sendable { case tooComplex, incomplete, outputTooLong }
    public static let maximumSourceBytes = 1_048_576
    public static let maximumOutputBytes = 4_194_304
    public static let maximumDecodedBytes = 4_194_304
    public let leaves: [Leaf]
    private let bytes: [UInt8]

    private struct AcceptedValue: Sendable {
        let text: String
        let unchanged: Bool
    }
    public struct Accumulator: Sendable {
        private let plan: CoreJSONTranslationPlan
        private var values: [Int: AcceptedValue] = [:]
        private var retainedBytes: Int
        fileprivate init(plan: CoreJSONTranslationPlan) {
            self.plan = plan
            retainedBytes = plan.bytes.count - plan.leaves.reduce(0) { $0 + $1.range.count }
        }
        public mutating func accept(id: Int, text: String) throws {
            try Task.checkCancellation()
            guard plan.leaves.indices.contains(id), values[id] == nil else { throw Issue.incomplete }
            guard
                text.utf8.count
                    <= CoreJSONTranslationPlan.maximumOutputBytes
            else { throw Issue.outputTooLong }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Issue.incomplete }
            let leaf = plan.leaves[id]
            let remaining = CoreJSONTranslationPlan.maximumOutputBytes - retainedBytes
            let unchanged = text.utf8.elementsEqual(leaf.source.utf8)
            let cost =
                unchanged
                ? leaf.range.count
                : try CoreJSONTranslationPlan.encodedSize(text, depth: leaf.escapingDepth, maximum: remaining)
            guard cost <= remaining else { throw Issue.outputTooLong }
            try Task.checkCancellation()
            retainedBytes += cost
            values[id] = AcceptedValue(text: text, unchanged: unchanged)
        }
        public func assemble() throws -> String { try plan.emit(values, capacity: retainedBytes) }
    }
    public func makeAccumulator() -> Accumulator { Accumulator(plan: self) }

    /// A cheap syntax cue only; parsing and validation remain in make(source:).
    public static func isCandidate(source: String) throws -> Bool {
        try Task.checkCancellation()
        var opening: UInt8?
        for (offset, byte) in source.utf8.prefix(maximumSourceBytes + 1).enumerated() {
            if offset.isMultiple(of: 4096) { try Task.checkCancellation() }
            if !Parser.whitespace(byte) {
                opening = byte
                break
            }
        }
        return opening == 123 || opening == 91
    }

    /// Ordinary prose and syntactically invalid JSON keep the ordinary path.
    public static func make(source: String) throws -> Self? {
        guard try isCandidate(source: source) else { return nil }
        guard source.utf8.count <= maximumSourceBytes else { throw Issue.tooComplex }
        let bytes = Array(source.utf8)
        let root = MappedText(bytes: bytes, origins: nil)
        var planner = Planner()
        guard try planner.expand(root, escapingDepth: 0) else { return nil }
        var previousEnd = 0
        for leaf in planner.leaves {
            guard leaf.range.lowerBound >= previousEnd, leaf.range.lowerBound < leaf.range.upperBound,
                leaf.range.upperBound <= bytes.count
            else { throw Issue.tooComplex }
            previousEnd = leaf.range.upperBound
        }
        try Task.checkCancellation()
        return Self(leaves: planner.leaves, bytes: bytes)
    }

    public func assemble(_ results: [Int: String]) throws -> String {
        try Task.checkCancellation()
        guard results.count == leaves.count else { throw Issue.incomplete }
        var accumulator = makeAccumulator()
        for leaf in leaves {
            guard let value = results[leaf.id] else { throw Issue.incomplete }
            try accumulator.accept(id: leaf.id, text: value)
        }
        return try accumulator.assemble()
    }

    // E^p of a quote or backslash has 2^p bytes. Short escaped controls have
    // 2^(p-1)+1 bytes; other controls have 2^(p-1)+5. Ordinary UTF8 stays literal.
    private static func power(_ exponent: Int, maximum: Int) throws -> Int {
        guard exponent >= 0, exponent < Int.bitWidth - 1 else { throw Issue.outputTooLong }
        let result = 1 << exponent
        guard result <= maximum else { throw Issue.outputTooLong }
        return result
    }
    private static func encodedSize(_ text: String, depth: Int, maximum: Int) throws -> Int {
        let quoteCost = try power(depth, maximum: maximum / 2)
        var count = quoteCost * 2
        let passes = depth + 1
        for (offset, byte) in text.utf8.enumerated() {
            if offset.isMultiple(of: 4096) { try Task.checkCancellation() }
            let remaining = maximum - count
            let size: Int
            switch byte {
            case 34, 92: size = try power(passes, maximum: remaining)
            case 8, 9, 10, 12, 13:
                guard remaining >= 1 else { throw Issue.outputTooLong }
                size = try power(passes - 1, maximum: remaining - 1) + 1
            case 0..<32:
                guard remaining >= 5 else { throw Issue.outputTooLong }
                size = try power(passes - 1, maximum: remaining - 5) + 5
            default: size = 1
            }
            guard size <= remaining else { throw Issue.outputTooLong }
            count += size
        }
        try Task.checkCancellation()
        return count
    }

    private func emit(_ values: [Int: AcceptedValue], capacity: Int) throws -> String {
        try Task.checkCancellation()
        guard values.count == leaves.count else { throw Issue.incomplete }
        var builder = Builder(capacity: capacity)
        var copied = 0
        for leaf in leaves {
            guard let value = values[leaf.id] else { throw Issue.incomplete }
            try Task.checkCancellation()
            try builder.append(bytes[copied..<leaf.range.lowerBound])
            if value.unchanged {
                try builder.append(bytes[leaf.range])
            } else {
                try builder.quoted(value.text, depth: leaf.escapingDepth)
            }
            copied = leaf.range.upperBound
        }
        try builder.append(bytes[copied...])
        try Task.checkCancellation()
        let result = String(decoding: builder.bytes, as: UTF8.self)
        try Task.checkCancellation()
        return result
    }

    private struct Builder {
        var bytes: [UInt8] = []
        var nextCheckpoint = 4096
        init(capacity: Int) { bytes.reserveCapacity(min(capacity, maximumOutputBytes)) }
        mutating func checkpoint() throws {
            if bytes.count >= nextCheckpoint {
                try Task.checkCancellation()
                nextCheckpoint = bytes.count + 4096
            }
        }
        mutating func byte(_ value: UInt8) throws {
            guard bytes.count < maximumOutputBytes else { throw Issue.outputTooLong }
            bytes.append(value)
            try checkpoint()
        }
        mutating func append<C: RandomAccessCollection>(_ data: C) throws where C.Element == UInt8 {
            guard data.count <= maximumOutputBytes - bytes.count else { throw Issue.outputTooLong }
            var index = data.startIndex
            while index < data.endIndex {
                try Task.checkCancellation()
                let end = data.index(index, offsetBy: min(4096, data.distance(from: index, to: data.endIndex)))
                bytes.append(contentsOf: data[index..<end])
                index = end
            }
        }
        mutating func repeated(_ value: UInt8, count: Int) throws {
            guard count <= maximumOutputBytes - bytes.count else { throw Issue.outputTooLong }
            var remaining = count
            while remaining > 0 {
                try Task.checkCancellation()
                let amount = min(4096, remaining)
                bytes.append(contentsOf: repeatElement(value, count: amount))
                remaining -= amount
            }
        }
        mutating func quoted(_ value: String, depth: Int) throws {
            let quoteSlashes = try power(depth, maximum: maximumOutputBytes) - 1
            try repeated(92, count: quoteSlashes)
            try byte(34)
            let passes = depth + 1
            let hex = Array("0123456789abcdef".utf8)
            var source = value
            try source.withUTF8 { buffer in
                var copied = 0, nextInputCheckpoint = 4096
                for index in buffer.indices {
                    if index >= nextInputCheckpoint {
                        try Task.checkCancellation()
                        nextInputCheckpoint = index + 4096
                    }
                    let value = buffer[index]
                    guard value < 32 || value == 34 || value == 92 else { continue }
                    try append(buffer[copied..<index])
                    switch value {
                    case 34:
                        try repeated(92, count: power(passes, maximum: maximumOutputBytes) - 1)
                        try byte(34)
                    case 92: try repeated(92, count: power(passes, maximum: maximumOutputBytes))
                    default:
                        try repeated(92, count: power(passes - 1, maximum: maximumOutputBytes))
                        let short: UInt8?
                        switch value {
                        case 8: short = 98
                        case 9: short = 116
                        case 10: short = 110
                        case 12: short = 102
                        case 13: short = 114
                        default: short = nil
                        }
                        if let short {
                            try byte(short)
                        } else {
                            try byte(117)
                            try byte(48)
                            try byte(48)
                            try byte(hex[Int(value >> 4)])
                            try byte(hex[Int(value & 15)])
                        }
                    }
                    copied = index + 1
                }
                try append(buffer[copied...])
            }
            try repeated(92, count: quoteSlashes)
            try byte(34)
        }
    }

    private struct MappedText {
        let bytes: [UInt8]
        // Root text uses identity offsets without allocating a map. Decoded
        // scalar interiors use -1; only exact whole-scalar boundaries can splice.
        let origins: [Int]?
        func origin(_ offset: Int) -> Int { origins?[offset] ?? offset }
    }
    private struct Planner {
        var leaves: [Leaf] = []
        var decodedBytes = 0
        mutating func expand(_ text: MappedText, escapingDepth: Int, context: [String]? = []) throws -> Bool {
            try Task.checkCancellation()
            guard escapingDepth <= 64 else { throw Issue.tooComplex }
            var parser = Parser(bytes: text.bytes)
            do {
                try parser.value(depth: 0, context: context)
                try parser.skipSpace()
                guard parser.index == text.bytes.count else { return false }
            } catch Parser.Invalid.syntax { return false }
            // Full-document validation precedes expansion: invalid nested JSON
            // cannot leave half of its jobs or consume final occurrence IDs.
            for (range, context) in parser.values {
                try Task.checkCancellation()
                guard let value = try? JSONDecoder().decode(String.self, from: Data(text.bytes[range])) else {
                    continue  // Unsupported lone surrogates remain exact literals.
                }
                let bytes = Array(value.utf8)
                guard bytes.count <= maximumDecodedBytes - decodedBytes else { throw Issue.tooComplex }
                decodedBytes += bytes.count
                let opening = bytes.first(where: { !Parser.whitespace($0) })
                if opening == 123 || opening == 91 {
                    let decoded = try mappedString(range, in: text, expected: bytes)
                    if try expand(decoded, escapingDepth: escapingDepth + 1, context: context) { continue }
                }
                guard Parser.isText(value) else { continue }
                guard leaves.count < 1024 else { throw Issue.tooComplex }
                let start = text.origin(range.lowerBound), end = text.origin(range.upperBound)
                guard start >= 0, end > start else { throw Issue.tooComplex }
                leaves.append(
                    Leaf(
                        id: leaves.count, source: value, context: context, range: start..<end,
                        escapingDepth: escapingDepth))
            }
            try Task.checkCancellation()
            return true
        }
        func mappedString(_ range: Range<Int>, in parent: MappedText, expected: [UInt8]) throws -> MappedText {
            let raw = parent.bytes
            var bytes: [UInt8] = [], origins = [parent.origin(range.lowerBound + 1)]
            bytes.reserveCapacity(expected.count)
            origins.reserveCapacity(expected.count + 1)
            var index = range.lowerBound + 1, nextCheckpoint = index + 4096
            func hex(_ value: UInt8) -> UInt32 {
                switch value {
                case 48...57: return UInt32(value - 48)
                case 65...70: return UInt32(value - 65 + 10)
                default: return UInt32(value - 97 + 10)
                }
            }
            func unit(_ start: Int) -> UInt32 {
                raw[start..<(start + 4)].reduce(0) { ($0 << 4) | hex($1) }
            }
            while index < range.upperBound - 1 {
                if index >= nextCheckpoint {
                    try Task.checkCancellation()
                    nextCheckpoint = index + 4096
                }
                let start = index
                if raw[index] != 92 {
                    bytes.append(raw[index])
                    index += 1
                    origins.append(parent.origin(index))
                    continue
                }
                index += 1
                let escape = raw[index]
                index += 1
                let scalar: UInt32
                switch escape {
                case 34, 92, 47: scalar = UInt32(escape)
                case 98: scalar = 8
                case 102: scalar = 12
                case 110: scalar = 10
                case 114: scalar = 13
                case 116: scalar = 9
                case 117:
                    let first = unit(index)
                    index += 4
                    if (0xD800...0xDBFF).contains(first) {
                        guard index + 6 <= range.upperBound - 1, raw[index] == 92, raw[index + 1] == 117 else {
                            throw Issue.tooComplex
                        }
                        let second = unit(index + 2)
                        guard (0xDC00...0xDFFF).contains(second) else { throw Issue.tooComplex }
                        scalar = 0x10000 + ((first - 0xD800) << 10) + second - 0xDC00
                        index += 6
                    } else {
                        scalar = first
                    }
                default: throw Issue.tooComplex
                }
                guard let value = UnicodeScalar(scalar), parent.origin(start) >= 0, parent.origin(index) >= 0 else {
                    throw Issue.tooComplex
                }
                let encoded = Array(String(value).utf8)
                bytes.append(contentsOf: encoded)
                origins.append(contentsOf: repeatElement(-1, count: encoded.count - 1))
                origins.append(parent.origin(index))
            }
            guard bytes.elementsEqual(expected), origins.count == bytes.count + 1 else { throw Issue.tooComplex }
            try Task.checkCancellation()
            return MappedText(bytes: bytes, origins: origins)
        }
    }

    private struct Parser {
        enum Invalid: Error { case syntax }
        let bytes: [UInt8]
        var index = 0
        var nodes = 0
        var nextCheckpoint = 4096
        var values: [(Range<Int>, [String]?)] = []
        static func whitespace(_ byte: UInt8) -> Bool { byte == 9 || byte == 10 || byte == 13 || byte == 32 }
        mutating func checkpoint() throws {
            if index >= nextCheckpoint {
                try Task.checkCancellation()
                nextCheckpoint = index + 4096
            }
        }
        mutating func skipSpace() throws {
            while index < bytes.count && Self.whitespace(bytes[index]) {
                try checkpoint()
                index += 1
            }
        }
        static func isText(_ value: String) -> Bool {
            guard value.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return false }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("`"), !trimmed.hasPrefix("``"), trimmed.hasSuffix("`"), trimmed.count > 1 {
                let body = trimmed.dropFirst().dropLast()
                if !body.contains("`"), !body.contains("\n"), !body.contains("\r") { return false }
            }
            let prefix = trimmed.prefix(8).lowercased()
            if ["https://", "http://", "mailto:", "file://"].contains(where: prefix.hasPrefix),
                !trimmed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) })
            {
                return false
            }
            return true
        }
        mutating func take(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }
        mutating func expect(_ byte: UInt8) throws { guard take(byte) else { throw Invalid.syntax } }
        func appending(_ component: String, to context: [String]?) -> [String]? {
            guard let context, context.count < 16 else { return nil }
            let result = context + [component]
            guard let encoded = try? JSONEncoder().encode(result), encoded.count <= 512 else { return nil }
            return result
        }
        mutating func value(depth: Int, context: [String]?) throws {
            nodes += 1
            guard depth <= 64 else { throw Issue.tooComplex }
            if nodes.isMultiple(of: 64) { try Task.checkCancellation() }
            try skipSpace()
            guard index < bytes.count else { throw Invalid.syntax }
            switch bytes[index] {
            case 123:
                index += 1
                try skipSpace()
                if take(125) { return }
                while true {
                    try skipSpace()
                    let keyStart = index
                    try string()
                    let key = try? JSONDecoder().decode(String.self, from: Data(bytes[keyStart..<index]))
                    let child = key.flatMap { appending("key:" + $0, to: context) }
                    try skipSpace()
                    try expect(58)
                    try value(depth: depth + 1, context: child)
                    try skipSpace()
                    if take(125) { return }
                    try expect(44)
                }
            case 91:
                index += 1
                try skipSpace()
                if take(93) { return }
                while true {
                    try value(depth: depth + 1, context: appending("array:", to: context))
                    try skipSpace()
                    if take(93) { return }
                    try expect(44)
                }
            case 34:
                let start = index
                try string()
                values.append((start..<index, context))
            case 116: try literal([116, 114, 117, 101])
            case 102: try literal([102, 97, 108, 115, 101])
            case 110: try literal([110, 117, 108, 108])
            default: try number()
            }
        }
        mutating func literal(_ word: [UInt8]) throws {
            guard bytes.count - index >= word.count, bytes[index..<(index + word.count)].elementsEqual(word) else {
                throw Invalid.syntax
            }
            index += word.count
        }
        mutating func string() throws {
            try expect(34)
            while index < bytes.count {
                try checkpoint()
                let byte = bytes[index]
                index += 1
                if byte == 34 { return }
                guard byte >= 32 else { throw Invalid.syntax }
                if byte == 92 {
                    guard index < bytes.count else { throw Invalid.syntax }
                    let escape = bytes[index]
                    index += 1
                    if escape == 117 {
                        guard bytes.count - index >= 4 else { throw Invalid.syntax }
                        for byte in bytes[index..<(index + 4)] {
                            guard (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
                            else { throw Invalid.syntax }
                        }
                        index += 4
                    } else if ![UInt8(34), 92, 47, 98, 102, 110, 114, 116].contains(escape) {
                        throw Invalid.syntax
                    }
                }
            }
            throw Invalid.syntax
        }
        mutating func digits() throws {
            let start = index
            while index < bytes.count && (48...57).contains(bytes[index]) {
                try checkpoint()
                index += 1
            }
            guard index > start else { throw Invalid.syntax }
        }
        mutating func number() throws {
            _ = take(45)
            if !take(48) {
                guard index < bytes.count, (49...57).contains(bytes[index]) else { throw Invalid.syntax }
                try digits()
            }
            if take(46) { try digits() }
            if take(101) || take(69) {
                if !take(43) { _ = take(45) }
                try digits()
            }
        }
    }
}
