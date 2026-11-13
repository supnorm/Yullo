import Foundation

public enum CoreLongTranslationError: Error, Equatable, Sendable {
    case invalidLimits, sourceTooLarge, tooManyJobs, duplicateJob, unexpectedJob, incomplete
    case emptyTranslation, outputTooLarge, protectedLiteralChanged, invalidProtectedRanges
}

/// A current-task partition, independent of providers, tokenizers and presentation.
/// Common paragraph/list boundaries and fenced code are preserved literally.
/// Inline backtick code and explicit URLs stay in jobs and must survive verbatim.
public struct CoreLongTranslationPlan: Sendable {
    public struct Limits: Equatable, Sendable {
        public var sourceBytes: Int
        public var jobBytes: Int
        public var maximumJobs: Int
        public var outputBytes: Int

        public init(
            sourceBytes: Int = 1_048_576, jobBytes: Int = 8_192,
            maximumJobs: Int = 1_024, outputBytes: Int = 4_194_304
        ) {
            self.sourceBytes = sourceBytes
            self.jobBytes = jobBytes
            self.maximumJobs = maximumJobs
            self.outputBytes = outputBytes
        }
    }

    public struct Job: Sendable {
        public let id: Int
        public let sourceRange: NSRange
        public let text: String
        public let protectedLiterals: [String]
    }

    public enum Piece: Equatable, Sendable {
        case literal(NSRange)
        case translation(jobID: Int, sourceRange: NSRange)

        public var sourceRange: NSRange {
            switch self {
            case .literal(let range), .translation(_, let range): range
            }
        }
    }

    public struct CompletedJob: Sendable {
        public let id: Int
        public let text: String
        public init(id: Int, text: String) {
            self.id = id
            self.text = text
        }
    }

    /// Unaccepted presentation data. Even an entirely completed prefix must pass
    /// `assemble` before it becomes a final result, cache entry or insertion.
    public struct Progress: Sendable {
        public let text: String
        public let completedPrefixJobs: Int
        public let receivedJobs: Int
        public let totalJobs: Int
        public let nextIncompleteJobID: Int?
        public var hasAllJobs: Bool { receivedJobs == totalJobs }
    }

    /// One task's mutable progress state. Each job is validated once on arrival
    /// and each source piece is appended once when its preceding gap closes.
    /// Snapshots remain unaccepted; final assembly validates the whole result.
    public struct ProgressAccumulator: Sendable {
        private let plan: CoreLongTranslationPlan
        private let literals: [String?]
        private let literalBytes: Int
        private var received: [Int: String] = [:]
        private var receivedBytes = 0
        private var nextPiece = 0
        private var prefixJobs = 0
        private var prefix = ""

        fileprivate init(plan: CoreLongTranslationPlan) throws {
            self.plan = plan
            let original = plan.source as NSString
            var values: [String?] = []
            var bytes = 0
            for piece in plan.pieces {
                try Task.checkCancellation()
                if case .literal(let range) = piece {
                    let text = original.substring(with: range)
                    let size = text.utf8.count
                    guard size <= plan.limits.outputBytes - bytes else { throw CoreLongTranslationError.outputTooLarge }
                    bytes += size
                    values.append(text)
                } else {
                    values.append(nil)
                }
            }
            literals = values
            literalBytes = bytes
            advance()
        }

        public mutating func accept(_ completed: CompletedJob) throws {
            try Task.checkCancellation()
            guard plan.jobs.indices.contains(completed.id) else { throw CoreLongTranslationError.unexpectedJob }
            guard received[completed.id] == nil else { throw CoreLongTranslationError.duplicateJob }
            let size = try plan.validate(
                completed, availableBytes: plan.limits.outputBytes - literalBytes - receivedBytes)
            // Failed admission leaves every prior valid completion intact.
            received[completed.id] = completed.text
            receivedBytes += size
            advance()
        }

        public var progress: Progress {
            Progress(
                text: prefix, completedPrefixJobs: prefixJobs, receivedJobs: received.count,
                totalJobs: plan.jobs.count, nextIncompleteJobID: prefixJobs < plan.jobs.count ? prefixJobs : nil)
        }

        public func assemble() throws -> String {
            try plan.assemble(completed: received.map { CompletedJob(id: $0.key, text: $0.value) })
        }

        private mutating func advance() {
            while nextPiece < plan.pieces.count {
                switch plan.pieces[nextPiece] {
                case .literal:
                    prefix.append(literals[nextPiece]!)
                case .translation(let id, _):
                    guard let text = received[id] else { return }
                    prefix.append(text)
                    prefixJobs += 1
                }
                nextPiece += 1
            }
        }
    }

    public let source: String
    public let limits: Limits
    public let jobs: [Job]
    public let pieces: [Piece]

    /// Protected ranges are sorted, original UTF16 no-cut ranges. They may
    /// translate; unlike URL/code literals, they impose no exact-output text.
    /// Only overlaps merge, so adjacent independent terms remain valid cuts.
    public static func make(source: String, limits: Limits = .init(), protectedRanges: [NSRange] = []) throws -> Self {
        try Task.checkCancellation()
        guard (1...1_048_576).contains(limits.sourceBytes), (1...8_192).contains(limits.jobBytes),
            (1...1_024).contains(limits.maximumJobs), (1...4_194_304).contains(limits.outputBytes)
        else { throw CoreLongTranslationError.invalidLimits }
        guard source.utf8.prefix(limits.sourceBytes + 1).count <= limits.sourceBytes else {
            throw CoreLongTranslationError.sourceTooLarge
        }
        var builder = try Builder(source: source, limits: limits, protectedRanges: protectedRanges)
        try builder.build()
        return Self(source: source, limits: limits, jobs: builder.jobs, pieces: builder.pieces)
    }

    public func assemble(completed: [CompletedJob]) throws -> String {
        let results = try validated(completed)
        guard results.count == jobs.count else { throw CoreLongTranslationError.incomplete }
        return try render(results: results, prefixOnly: false).text
    }

    /// Batch inspection. Repeated live updates should use ProgressAccumulator
    /// so earlier completed jobs are not rescanned on every arrival.
    public func completedPrefix(completed: [CompletedJob]) throws -> Progress {
        let results = try validated(completed)
        let rendered = try render(results: results, prefixOnly: true)
        return Progress(
            text: rendered.text, completedPrefixJobs: rendered.jobs, receivedJobs: results.count,
            totalJobs: jobs.count, nextIncompleteJobID: rendered.jobs < jobs.count ? rendered.jobs : nil)
    }

    public func makeProgressAccumulator() throws -> ProgressAccumulator {
        try Task.checkCancellation()
        return try ProgressAccumulator(plan: self)
    }

    private func validated(_ completed: [CompletedJob]) throws -> [Int: String] {
        try Task.checkCancellation()
        guard completed.count <= limits.maximumJobs else { throw CoreLongTranslationError.unexpectedJob }
        guard completed.count <= jobs.count else {
            // Still distinguish duplicate IDs from excess unknown work.
            if Set(completed.map(\.id)).count != completed.count { throw CoreLongTranslationError.duplicateJob }
            throw CoreLongTranslationError.unexpectedJob
        }
        var results: [Int: String] = [:]
        var bytes = 0
        for item in completed {
            try Task.checkCancellation()
            guard jobs.indices.contains(item.id) else { throw CoreLongTranslationError.unexpectedJob }
            guard results[item.id] == nil else { throw CoreLongTranslationError.duplicateJob }
            bytes += try validate(item, availableBytes: limits.outputBytes - bytes)
            results[item.id] = item.text
        }
        return results
    }

    private func validate(_ item: CompletedJob, availableBytes: Int) throws -> Int {
        let size = item.text.utf8.prefix(availableBytes + 1).count
        guard size <= availableBytes else { throw CoreLongTranslationError.outputTooLarge }
        guard !item.text.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) else {
            throw CoreLongTranslationError.emptyTranslation
        }
        let expected = jobs[item.id].protectedLiterals
        if !expected.isEmpty {
            let actual = try LiteralScanner.tokens(Array(item.text.utf16)).map { Data($0.text.utf8) }
            var counts: [Data: Int] = [:]
            for value in actual { counts[value, default: 0] += 1 }
            for value in expected {
                let key = Data(value.utf8)
                guard let count = counts[key], count > 0 else { throw CoreLongTranslationError.protectedLiteralChanged }
                counts[key] = count - 1
            }
            // An expected literal must retain its exact occurrence count.
            for value in expected where counts[Data(value.utf8), default: 0] != 0 {
                throw CoreLongTranslationError.protectedLiteralChanged
            }
        }
        return size
    }

    private func render(results: [Int: String], prefixOnly: Bool) throws -> (text: String, jobs: Int) {
        let original = source as NSString
        var text = ""
        var bytes = 0
        var completedCount = 0
        for piece in pieces {
            try Task.checkCancellation()
            let part: String
            switch piece {
            case .literal(let range): part = original.substring(with: range)
            case .translation(let id, _):
                guard let translated = results[id] else {
                    if prefixOnly { return (text, completedCount) }
                    throw CoreLongTranslationError.incomplete
                }
                part = translated
                completedCount += 1
            }
            let size = part.utf8.count
            guard size <= limits.outputBytes - bytes else { throw CoreLongTranslationError.outputTooLarge }
            bytes += size
            text.append(part)
        }
        return (text, completedCount)
    }
}

private extension CoreLongTranslationPlan {
    struct Boundaries {
        var offsets = [0]
        var bytes = [0]
        var whitespace: [Bool] = []

        init(_ source: String) throws {
            var count = 0
            for character in source {
                if count & 1_023 == 0 { try Task.checkCancellation() }
                offsets.append(offsets.last! + character.utf16.count)
                bytes.append(bytes.last! + character.utf8.count)
                whitespace.append(
                    character.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) })
                count += 1
            }
        }

        func lower(_ value: Int) -> Int {
            var low = 0
            var high = offsets.count
            while low < high {
                let middle = (low + high) / 2
                if offsets[middle] < value { low = middle + 1 } else { high = middle }
            }
            return low
        }

        func floor(_ value: Int) -> Int {
            let index = lower(value)
            return index < offsets.count && offsets[index] == value ? index : index - 1
        }

        func budgetEnd(start: Int, end: Int, maximum: Int) -> Int {
            var low = start
            var high = end + 1
            while low < high {
                let middle = (low + high) / 2
                if bytes[middle] - bytes[start] <= maximum { low = middle + 1 } else { high = middle }
            }
            return low - 1
        }
    }

    struct Builder {
        let units: [UInt16]
        let limits: Limits
        let boundaries: Boundaries
        let protection: [Range<Int>]
        var structuralAtoms: [Range<Int>]?
        var jobs: [Job] = []
        var pieces: [Piece] = []

        init(source: String, limits: Limits, protectedRanges: [NSRange]) throws {
            units = Array(source.utf16)
            self.limits = limits
            boundaries = try Boundaries(source)
            guard protectedRanges.count <= units.count else { throw CoreLongTranslationError.invalidProtectedRanges }
            var ranges: [Range<Int>] = []
            var previousStart = -1
            for range in protectedRanges {
                try Task.checkCancellation()
                guard range.location >= 0, range.location >= previousStart, range.length > 0,
                    range.location < units.count, range.length <= units.count - range.location
                else { throw CoreLongTranslationError.invalidProtectedRanges }
                previousStart = range.location
                let start = boundaries.offsets[boundaries.floor(range.location)]
                let end = boundaries.offsets[boundaries.lower(range.location + range.length)]
                if let previous = ranges.last, previous.upperBound > start {
                    ranges[ranges.count - 1] = previous.lowerBound..<max(previous.upperBound, end)
                } else {
                    ranges.append(start..<end)
                }
            }
            protection = ranges
        }

        var coveredEnd: Int { pieces.last.map { NSMaxRange($0.sourceRange) } ?? 0 }

        func protectionIndex(endingAfter value: Int) -> Int {
            Self.rangeIndex(endingAfter: value, in: protection)
        }

        static func rangeIndex(endingAfter value: Int, in ranges: [Range<Int>]) -> Int {
            var low = 0
            var high = ranges.count
            while low < high {
                let middle = (low + high) / 2
                if ranges[middle].upperBound <= value { low = middle + 1 } else { high = middle }
            }
            return low
        }

        static func merge(_ first: [Range<Int>], _ second: [Range<Int>]) -> [Range<Int>] {
            var result: [Range<Int>] = []
            var left = 0
            var right = 0
            while left < first.count || right < second.count {
                let next: Range<Int>
                if left < first.count, right == second.count || first[left].lowerBound <= second[right].lowerBound {
                    next = first[left]
                    left += 1
                } else {
                    next = second[right]
                    right += 1
                }
                if let previous = result.last, previous.upperBound > next.lowerBound {
                    result[result.count - 1] = previous.lowerBound..<max(previous.upperBound, next.upperBound)
                } else {
                    result.append(next)
                }
            }
            return result
        }

        func protectedInterior(_ offset: Int) -> Bool {
            let index = protectionIndex(endingAfter: offset)
            return index < protection.count && protection[index].lowerBound < offset
        }

        mutating func structuralLiteral(_ requested: Range<Int>, includeSyntax: Bool = false) throws {
            literal(try structuralRange(requested, includeSyntax: includeSyntax))
        }

        mutating func structuralRange(_ requested: Range<Int>, includeSyntax: Bool) throws -> Range<Int> {
            guard !requested.isEmpty else { return requested }
            var lower = requested.lowerBound
            var upper = requested.upperBound
            var index = protectionIndex(endingAfter: lower)
            while index < protection.count && protection[index].lowerBound < upper {
                lower = min(lower, protection[index].lowerBound)
                upper = max(upper, protection[index].upperBound)
                index += 1
            }
            if includeSyntax || lower != requested.lowerBound || upper != requested.upperBound {
                // A term including a list marker may end inside a URL/code
                // token. Keep that whole syntax unit raw as well. This rare
                // structural expansion scans global syntax only once.
                if structuralAtoms == nil {
                    let syntax = try LiteralScanner.scan(units).noBreak.map {
                        let start = boundaries.offsets[boundaries.floor($0.lowerBound)]
                        let end = boundaries.offsets[boundaries.lower($0.upperBound)]
                        return start..<end
                    }
                    structuralAtoms = Self.merge(protection, syntax)
                }
                let atoms = structuralAtoms!
                var atomIndex = Self.rangeIndex(endingAfter: lower, in: atoms)
                while atomIndex < atoms.count && atoms[atomIndex].lowerBound < upper {
                    lower = min(lower, atoms[atomIndex].lowerBound)
                    upper = max(upper, atoms[atomIndex].upperBound)
                    atomIndex += 1
                }
            }
            return lower..<upper
        }

        mutating func literal(_ requested: Range<Int>) {
            let range = max(requested.lowerBound, coveredEnd)..<max(requested.upperBound, coveredEnd)
            guard !range.isEmpty else { return }
            if case .literal(let previous) = pieces.last, NSMaxRange(previous) == range.lowerBound {
                pieces[pieces.count - 1] = .literal(
                    NSRange(location: previous.location, length: range.upperBound - previous.location))
            } else {
                pieces.append(.literal(NSRange(location: range.lowerBound, length: range.count)))
            }
        }

        mutating func build() throws {
            var cursor = 0
            var proseStart = 0
            var fence: (marker: UInt16, length: Int)?
            var fenceStart = 0
            while cursor < units.count {
                try Task.checkCancellation()
                let lineStart = cursor
                while cursor < units.count && !Self.newline(units[cursor]) { cursor += 1 }
                let contentEnd = cursor
                if cursor < units.count {
                    if units[cursor] == 13 && cursor + 1 < units.count && units[cursor + 1] == 10 { cursor += 1 }
                    cursor += 1
                }
                let lineEnd = cursor
                if let open = fence {
                    if let candidate = fenceAt(lineStart, contentEnd), candidate.marker == open.marker,
                        candidate.length >= open.length, candidate.tail.allSatisfy({ $0 == 32 || $0 == 9 })
                    {
                        try structuralLiteral(fenceStart..<lineEnd)
                        fence = nil
                        proseStart = lineEnd
                    }
                    continue
                }
                if let candidate = fenceAt(lineStart, contentEnd),
                    candidate.marker != 96 || !candidate.tail.contains(96)
                {
                    try prose(proseStart..<lineStart)
                    fence = (candidate.marker, candidate.length)
                    fenceStart = lineStart
                    continue
                }
                if units[lineStart..<contentEnd].allSatisfy({ $0 == 32 || $0 == 9 }) {
                    try prose(proseStart..<lineStart)
                    try structuralLiteral(lineStart..<lineEnd)
                    proseStart = lineEnd
                } else if let body = listBody(lineStart, contentEnd) {
                    try prose(proseStart..<lineStart)
                    try structuralLiteral(lineStart..<body)
                    try prose(body..<contentEnd)
                    try structuralLiteral(contentEnd..<lineEnd)
                    proseStart = lineEnd
                }
            }
            if fence != nil {
                try structuralLiteral(fenceStart..<units.count)
            } else {
                try prose(proseStart..<units.count)
            }
        }

        func fenceAt(_ start: Int, _ end: Int) -> (marker: UInt16, length: Int, tail: ArraySlice<UInt16>)? {
            CoreLiteralScanner.fenceAt(units, start, end)
        }

        func listBody(_ start: Int, _ end: Int) -> Int? {
            var index = start
            while index < end && (units[index] == 32 || units[index] == 9) { index += 1 }
            guard index < end else { return nil }
            if units[index] == 45 || units[index] == 43 || units[index] == 42 {
                index += 1
            } else {
                let digits = index
                while index < end && units[index] >= 48 && units[index] <= 57 && index - digits < 10 { index += 1 }
                guard index > digits, index - digits <= 9, index < end, units[index] == 46 || units[index] == 41 else {
                    return nil
                }
                index += 1
            }
            guard index < end, units[index] == 32 || units[index] == 9 else { return nil }
            while index < end && (units[index] == 32 || units[index] == 9) { index += 1 }
            if index + 3 < end, units[index] == 91, units[index + 2] == 93,
                units[index + 1] == 32 || units[index + 1] == 120 || units[index + 1] == 88,
                units[index + 3] == 32 || units[index + 3] == 9
            {
                index += 4
                while index < end && (units[index] == 32 || units[index] == 9) { index += 1 }
            }
            return index
        }

        mutating func prose(_ requested: Range<Int>) throws {
            let lower = max(requested.lowerBound, coveredEnd)
            guard lower < requested.upperBound else { return }
            let index = protectionIndex(endingAfter: requested.upperBound)
            if index < protection.count, protection[index].lowerBound < requested.upperBound {
                // A term crossing a structural boundary stays wholly raw;
                // preserving a list/code boundary never splits that term.
                let crossing = try structuralRange(protection[index], includeSyntax: true)
                if lower < crossing.lowerBound { try proseBody(lower..<crossing.lowerBound) }
                literal(crossing)
            } else {
                try proseBody(lower..<requested.upperBound)
            }
        }

        mutating func proseBody(_ range: Range<Int>) throws {
            guard !range.isEmpty else { return }
            // Structural ASCII boundaries can be inside a grapheme (a space
            // followed by a combining mark). Expand them safely into literals.
            var first = boundaries.lower(range.lowerBound)
            let end = boundaries.floor(range.upperBound)
            guard first < end else {
                literal(range)
                return
            }
            literal(range.lowerBound..<min(boundaries.offsets[first], range.upperBound))
            while first < end && boundaries.whitespace[first] && !protectedInterior(boundaries.offsets[first + 1]) {
                literal(boundaries.offsets[first]..<boundaries.offsets[first + 1])
                first += 1
            }
            var last = end
            while last > first && boundaries.whitespace[last - 1] && !protectedInterior(boundaries.offsets[last - 1]) {
                last -= 1
            }
            let scan = try LiteralScanner.scan(Array(units[boundaries.offsets[first]..<boundaries.offsets[last]]))
            let base = boundaries.offsets[first]
            let tokens = scan.tokens
                .map {
                    Token(
                        range: ($0.range.lowerBound + base)..<($0.range.upperBound + base), text: $0.text)
                }
            var atoms: [Range<Int>] = []
            for range in scan.noBreak {
                let start = boundaries.offsets[boundaries.floor(base + range.lowerBound)]
                let end = boundaries.offsets[boundaries.lower(base + range.upperBound)]
                let expanded = start..<end
                if let previous = atoms.last, previous.upperBound > expanded.lowerBound {
                    atoms[atoms.count - 1] = previous.lowerBound..<max(previous.upperBound, expanded.upperBound)
                } else {
                    atoms.append(expanded)
                }
            }
            if !protection.isEmpty {
                let termStart = protectionIndex(endingAfter: base)
                var termEnd = termStart
                while termEnd < protection.count && protection[termEnd].lowerBound < boundaries.offsets[last] {
                    termEnd += 1
                }
                atoms = Self.merge(atoms, Array(protection[termStart..<termEnd]))
            }
            var tokenIndex = 0
            var atomIndex = 0
            while first < last {
                try Task.checkCancellation()
                while first < last && boundaries.whitespace[first] && !protectedInterior(boundaries.offsets[first + 1])
                {
                    literal(boundaries.offsets[first]..<boundaries.offsets[first + 1])
                    first += 1
                }
                if first == last { break }
                let start = boundaries.offsets[first]
                while tokenIndex < tokens.count && tokens[tokenIndex].range.upperBound <= start { tokenIndex += 1 }
                while atomIndex < atoms.count && atoms[atomIndex].upperBound <= start { atomIndex += 1 }
                var finish = boundaries.budgetEnd(start: first, end: last, maximum: limits.jobBytes)
                if finish == first {
                    // An oversized grapheme can also begin a protected term.
                    // Preserve the entire merged atom before advancing; emitting
                    // only this character would expose the remainder to translation.
                    let next =
                        atomIndex < atoms.count && atoms[atomIndex].lowerBound <= start
                        ? boundaries.lower(atoms[atomIndex].upperBound) : first + 1
                    literal(start..<boundaries.offsets[next])
                    first = next
                    continue
                }
                // Never cut a protected token. A token larger than this
                // runtime's work budget is retained locally as a literal.
                var candidate = atomIndex
                while candidate < atoms.count && atoms[candidate].lowerBound < boundaries.offsets[finish] {
                    let protectedStart = boundaries.lower(atoms[candidate].lowerBound)
                    let protectedEnd = boundaries.lower(atoms[candidate].upperBound)
                    if protectedEnd > finish {
                        finish = protectedStart
                        if finish <= first {
                            literal(start..<boundaries.offsets[protectedEnd])
                            first = protectedEnd
                        }
                        break
                    }
                    candidate += 1
                }
                if finish <= first { continue }
                if finish < last {
                    // Prefer a sentence or whitespace edge in the latter half
                    // of this work budget; bounded rescanning stays linear.
                    let minimum = boundaries.bytes[first] + (boundaries.bytes[finish] - boundaries.bytes[first]) / 2
                    var preferred: Int?
                    var edge = finish
                    var protectedIndex = min(candidate, atoms.count - 1)
                    while edge > first && boundaries.bytes[edge] >= minimum {
                        let offset = boundaries.offsets[edge]
                        while protectedIndex >= atomIndex && atoms[protectedIndex].lowerBound >= offset {
                            protectedIndex -= 1
                        }
                        let insideToken =
                            protectedIndex >= atomIndex && offset < atoms[protectedIndex].upperBound
                        if !insideToken {
                            if Self.sentenceEnd(units[offset - 1]) {
                                preferred = edge
                                break
                            }
                            if preferred == nil && boundaries.whitespace[edge - 1] { preferred = edge }
                        }
                        edge -= 1
                    }
                    if let preferred { finish = preferred }
                }
                var bodyEnd = finish
                while bodyEnd > first && boundaries.whitespace[bodyEnd - 1]
                    && !protectedInterior(boundaries.offsets[bodyEnd - 1])
                { bodyEnd -= 1 }
                if bodyEnd > first {
                    let sourceRange = start..<boundaries.offsets[bodyEnd]
                    let protected = tokens[tokenIndex...].prefix { $0.range.lowerBound < sourceRange.upperBound }
                        .filter {
                            $0.range.lowerBound >= sourceRange.lowerBound
                                && $0.range.upperBound <= sourceRange.upperBound
                        }
                    if boundaries.whitespace[first..<bodyEnd].allSatisfy({ $0 }) {
                        literal(sourceRange)
                    } else {
                        guard jobs.count < limits.maximumJobs else { throw CoreLongTranslationError.tooManyJobs }
                        let job = Job(
                            id: jobs.count, sourceRange: NSRange(location: start, length: sourceRange.count),
                            text: String(decoding: units[sourceRange], as: UTF16.self),
                            protectedLiterals: protected.map(\.text))
                        jobs.append(job)
                        pieces.append(.translation(jobID: job.id, sourceRange: job.sourceRange))
                    }
                }
                literal(boundaries.offsets[bodyEnd]..<boundaries.offsets[finish])
                first = finish
                while first < last && boundaries.whitespace[first] && !protectedInterior(boundaries.offsets[first + 1])
                {
                    literal(boundaries.offsets[first]..<boundaries.offsets[first + 1])
                    first += 1
                }
            }
            literal(boundaries.offsets[last]..<range.upperBound)
        }

        static func newline(_ unit: UInt16) -> Bool {
            CoreLiteralScanner.newline(unit)
        }
        static func sentenceEnd(_ unit: UInt16) -> Bool { [46, 33, 63, 59, 0x3002, 0xFF01, 0xFF1F].contains(unit) }
    }

    typealias Token = CoreLiteralScanner.Token
    typealias LiteralScanner = CoreLiteralScanner
}
