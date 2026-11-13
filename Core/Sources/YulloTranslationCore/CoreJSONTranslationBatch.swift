import Foundation

/// Transport batches contain text values and bounded field context. The original document remains owned by
/// CoreJSONTranslationPlan; neither provider IDs nor response order change it.
public enum CoreJSONTranslationBatch {
    public typealias Issue = CoreJSONTranslationPlan.Issue
    public struct Entry: Sendable {
        public let id: String
        public let text: String
        public let context: [String]?
        public fileprivate(set) var leafIDs: [Int]
    }
    public enum Job: Sendable { case batch(Batch), single(Entry) }
    public struct Plan: Sendable { public let jobs: [Job] }
    public struct Batch: Sendable {
        public let entries: [Entry]
        public let input: Data
        public func addingTerms(_ terms: [CoreVocabularyTranslationTerm], maximumInputBytes: Int = 49_152) throws
            -> Batch
        {
            try Task.checkCancellation()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard terms.count <= 16, try encoder.encode(terms).count <= 512,
                (1...131_072).contains(maximumInputBytes)
            else { throw Issue.tooComplex }
            let data = try encoder.encode(
                Input(entries: entries.map { .init(id: $0.id, text: $0.text, context: $0.context) }, terms: terms))
            guard data.count <= maximumInputBytes else { throw Issue.tooComplex }
            return .init(entries: entries, input: data)
        }
        public func decode(_ data: Data) throws -> [String: String] {
            try Task.checkCancellation()
            guard data.count <= CoreJSONTranslationPlan.maximumOutputBytes else { throw Issue.outputTooLong }
            guard let rows = try? JSONSerialization.jsonObject(with: data) as? [Any], rows.count == entries.count else {
                throw Issue.incomplete
            }
            let owned = Set(entries.map(\.id))
            var result: [String: String] = [:]
            var bytes = 0
            for row in rows {
                try Task.checkCancellation()
                guard let pair = row as? [Any], pair.count == 2,
                    let id = pair[0] as? String, owned.contains(id), result[id] == nil,
                    let text = pair[1] as? String,
                    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { throw Issue.incomplete }
                guard text.utf8.count <= CoreJSONTranslationPlan.maximumOutputBytes - bytes else {
                    throw Issue.outputTooLong
                }
                bytes += text.utf8.count
                result[id] = text
            }
            guard result.count == owned.count else { throw Issue.incomplete }
            return result
        }
        public func encodedResponse(_ values: [String: String]) throws -> Data {
            try Task.checkCancellation()
            guard Set(values.keys) == Set(entries.map(\.id)) else { throw Issue.incomplete }
            var totalBytes = 0
            for value in values.values {
                try Task.checkCancellation()
                guard value.utf8.count <= CoreJSONTranslationPlan.maximumOutputBytes - totalBytes else {
                    throw Issue.outputTooLong
                }
                totalBytes += value.utf8.count
            }
            let rows = entries.map { [$0.id, values[$0.id]!] }
            let data = try JSONSerialization.data(withJSONObject: rows, options: [.fragmentsAllowed])
            _ = try decode(data)
            return data
        }
    }
    private struct Input: Encodable {
        struct Value: Encodable {
            let id: String
            let text: String
            let context: [String]?
        }
        let entries: [Value]
        let terms: [CoreVocabularyTranslationTerm]
    }
    public static func make(
        _ document: CoreJSONTranslationPlan,
        maximumItems: Int = 128, maximumInputBytes: Int = 49_152,
        maximumJobs: Int = 1_024, terms: [CoreVocabularyTranslationTerm] = []
    ) throws -> Plan {
        try Task.checkCancellation()
        guard (1...128).contains(maximumItems), (1...131_072).contains(maximumInputBytes),
            (1...1_024).contains(maximumJobs)
        else { throw Issue.tooComplex }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func encode(_ entries: [Entry]) throws -> Data {
            try encoder.encode(
                Input(entries: entries.map { .init(id: $0.id, text: $0.text, context: $0.context) }, terms: terms))
        }
        guard terms.count <= 16, try encoder.encode(terms).count <= 512,
            try encode([]).count <= maximumInputBytes
        else { throw Issue.tooComplex }
        var entries: [Entry] = []
        var dedup: [Data: Int] = [:]
        for leaf in document.leaves {
            try Task.checkCancellation()
            // A missing context means its bounded path was incomplete. Such
            // occurrences remain separate instead of guessing semantic identity.
            let key = try leaf.context.map { try encoder.encode([$0, [leaf.source]]) }
            if let key, let existing = dedup[key] {
                entries[existing].leafIDs.append(leaf.id)
            } else {
                if let key { dedup[key] = entries.count }
                entries.append(
                    .init(id: "v\(entries.count)", text: leaf.source, context: leaf.context, leafIDs: [leaf.id]))
            }
        }
        var jobs: [Job] = [], pending: [Entry] = []
        func append(_ job: Job) throws {
            guard jobs.count < maximumJobs else { throw Issue.tooComplex }
            jobs.append(job)
        }
        func flush() throws {
            guard !pending.isEmpty else { return }
            try append(.batch(.init(entries: pending, input: try encode(pending))))
            pending.removeAll(keepingCapacity: true)
        }
        for entry in entries {
            try Task.checkCancellation()
            let alone = try encode([entry])
            if alone.count > maximumInputBytes {
                try flush()
                try append(.single(entry))
                continue
            }
            if pending.count == maximumItems { try flush() }
            if !pending.isEmpty, try encode(pending + [entry]).count > maximumInputBytes { try flush() }
            pending.append(entry)
        }
        try flush()
        try Task.checkCancellation()
        return Plan(jobs: jobs)
    }
}
