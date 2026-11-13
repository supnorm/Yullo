import Foundation

// Local, text-free preference learning. Only deliberate choices are recorded;
// automatic suggestions must never train themselves through this API.
public struct DirectionLearningHistory: Codable, Equatable, Sendable {
    public struct Record: Codable, Equatable, Sendable {
        public let source: String
        public let target: String
        public let decayedWeight: Double
        public let lastChosenAt: Date
        public let count: Int
        fileprivate init(source: String, target: String, decayedWeight: Double, lastChosenAt: Date, count: Int) {
            self.source = source
            self.target = target
            self.decayedWeight = decayedWeight
            self.lastChosenAt = lastChosenAt
            self.count = count
        }
        private enum CodingKeys: String, CodingKey { case source, target, decayedWeight, lastChosenAt, count }
        public init(from decoder: Decoder) throws {
            guard let values = try? decoder.container(keyedBy: CodingKeys.self),
                let source = try? values.decode(String.self, forKey: .source),
                let target = try? values.decode(String.self, forKey: .target),
                let weight = try? values.decode(Double.self, forKey: .decayedWeight),
                let date = try? values.decode(Date.self, forKey: .lastChosenAt),
                let count = try? values.decode(Int.self, forKey: .count)
            else {
                // One malformed row must not erase unrelated learned pairs.
                self.init(source: "", target: "", decayedWeight: 0, lastChosenAt: .distantPast, count: 0)
                return
            }
            self.init(source: source, target: target, decayedWeight: weight, lastChosenAt: date, count: count)
        }
    }

    public static let maximumRecords = 128
    public static let halfLife: TimeInterval = 30 * 86_400
    private static let retention: TimeInterval = 365 * 86_400
    private static let minimumScore = 0.01
    private static let maximumWeight = 1_000_000.0
    private static let maximumCount = 1_000_000
    public private(set) var records: [Record] = []

    public init() {}

    public mutating func record(source: String, target: String, now: Date, weight: Double = 1) {
        guard let source = Self.languageID(source), let target = Self.languageID(target), source != target,
            Self.validDate(now), weight.isFinite, weight > 0
        else { return }
        let existing = records.first { $0.source == source && $0.target == target }
        // A clock rollback cannot move this pair's own anchor backwards or
        // magnify its stored weight. Another pair's date is not a clock.
        let anchor = max(now, existing?.lastChosenAt ?? now)
        let accumulated = existing.map { Self.score($0, at: anchor) } ?? 0
        let updated = Record(
            source: source, target: target,
            decayedWeight: min(Self.maximumWeight, accumulated + min(1, weight)),
            lastChosenAt: anchor, count: min(Self.maximumCount, (existing?.count ?? 0) + 1))
        records.removeAll { $0.source == source && $0.target == target }
        records.append(updated)
        records = Self.compacted(records, at: now)
    }

    public func recommendedTarget(source: String, enabled: [String], now: Date) -> String? {
        guard let source = Self.languageID(source) else { return nil }
        return rankedTarget(source: source, excluding: source, enabled: enabled, now: now)
    }

    public func globalTarget(excluding source: String, enabled: [String], now: Date) -> String? {
        rankedTarget(source: nil, excluding: Self.languageID(source), enabled: enabled, now: now)
    }

    public func activeRecordCount(now: Date) -> Int {
        guard Self.validDate(now) else { return 0 }
        return records.lazy.filter { Self.score($0, at: now) >= Self.minimumScore }.count
    }

    private func rankedTarget(source: String?, excluding excluded: String?, enabled: [String], now: Date) -> String? {
        guard Self.validDate(now) else { return nil }
        var totals: [String: (weight: Double, lastChosenAt: Date)] = [:]
        for record in records where source == nil || record.source == source {
            guard record.target != excluded else { continue }
            let score = Self.score(record, at: now)
            guard score >= Self.minimumScore else { continue }
            let prior = totals[record.target]
            totals[record.target] = (
                score + (prior?.weight ?? 0), max(record.lastChosenAt, prior?.lastChosenAt ?? record.lastChosenAt)
            )
        }
        var best: (id: String, weight: Double, lastChosenAt: Date)?
        var seen = Set<String>()
        // Iteration order provides the last tie-break: the user's language order.
        for raw in enabled {
            guard let id = Self.languageID(raw), id != excluded, seen.insert(id).inserted,
                let candidate = totals[id]
            else { continue }
            if let previous = best,
                candidate.weight < previous.weight
                    || (candidate.weight == previous.weight && candidate.lastChosenAt <= previous.lastChosenAt)
            {
                continue
            }
            best = (id, candidate.weight, candidate.lastChosenAt)
        }
        return best?.id
    }

    private static func score(_ record: Record, at now: Date) -> Double {
        let age = max(0, now.timeIntervalSince(record.lastChosenAt))
        guard age <= retention else { return 0 }
        return record.decayedWeight * pow(0.5, age / halfLife)
    }

    private static func languageID(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Language codes may carry one script subtag. Keep the script distinct
        // so a preference for Traditional Chinese is not merged with Chinese.
        // Region tags, display names and arbitrary text are not learning IDs.
        guard value.range(of: "^[a-z]{2,3}(?:-[a-z]{4})?$", options: .regularExpression) != nil else { return nil }
        let components = value.split(separator: "-")
        let language = String(components[0])
        guard !["und", "mul", "zxx"].contains(language) else { return nil }
        let base: String
        switch language {
        case "cmn": base = "zh"
        case "no": base = "nb"
        case "tl": base = "fil"
        case "iw": base = "he"
        case "in": base = "id"
        default: base = language
        }
        guard components.count == 2 else { return base }
        let script = components[1]
        return base + "-" + script.prefix(1).uppercased() + script.dropFirst()
    }

    private static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite && date >= .distantPast && date <= .distantFuture
    }

    private static func compacted(_ input: [Record], at now: Date) -> [Record] {
        input.filter { score($0, at: now) >= minimumScore }.enumerated().sorted {
            let left = score($0.element, at: now), right = score($1.element, at: now)
            if left != right { return left > right }
            if $0.element.lastChosenAt != $1.element.lastChosenAt {
                return $0.element.lastChosenAt > $1.element.lastChosenAt
            }
            return $0.offset < $1.offset
        }.prefix(maximumRecords).map(\.element)
    }

    private enum CodingKeys: String, CodingKey { case records }
    public init(from decoder: Decoder) throws {
        guard let container = try? decoder.container(keyedBy: CodingKeys.self),
            let decoded = try? container.decode([Record].self, forKey: .records)
        else { return }
        var unique: [String: Record] = [:]
        var order: [String] = []
        for value in decoded {
            guard let source = Self.languageID(value.source), let target = Self.languageID(value.target),
                source != target,
                Self.validDate(value.lastChosenAt), value.decayedWeight.isFinite, value.decayedWeight > 0,
                value.count > 0
            else { continue }
            let record = Record(
                source: source, target: target, decayedWeight: min(Self.maximumWeight, value.decayedWeight),
                lastChosenAt: value.lastChosenAt, count: min(Self.maximumCount, value.count))
            let key = source + ":" + target
            if let previous = unique[key] {
                // Duplicated/corrupt stored pairs never count as extra choices.
                if record.lastChosenAt > previous.lastChosenAt
                    || (record.lastChosenAt == previous.lastChosenAt && record.decayedWeight > previous.decayedWeight)
                {
                    unique[key] = record
                }
            } else {
                unique[key] = record
                order.append(key)
            }
        }
        let valid = order.compactMap { unique[$0] }
        // Decoding has no trusted clock. Preserve a bounded history's order;
        // age-based expiry waits for an operation with an explicit now.
        guard valid.count > Self.maximumRecords else {
            records = valid
            return
        }
        records = valid.enumerated().sorted {
            if $0.element.decayedWeight != $1.element.decayedWeight {
                return $0.element.decayedWeight > $1.element.decayedWeight
            }
            if $0.element.lastChosenAt != $1.element.lastChosenAt {
                return $0.element.lastChosenAt > $1.element.lastChosenAt
            }
            return $0.offset < $1.offset
        }.prefix(Self.maximumRecords).map(\.element)
    }
}
