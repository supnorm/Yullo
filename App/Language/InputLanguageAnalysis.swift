import Foundation
import NaturalLanguage

struct InputAnalysis {
    let languages: [String]
    let words: Int
}

// Vocabulary lookup is local and never requests a model download. Keep only two
// system embeddings, and serialize access across cancelled analysis workers.
private final class ShortInputVocabulary: @unchecked Sendable {
    private let lock = NSLock()
    private var embeddings: [String: NLEmbedding] = [:]
    private var recent: [String] = []
    private var unavailable = Set<String>()
    func contains(_ words: [String], language: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        // A newer edit may cancel this worker while another lookup owns the
        // lock. Do not load or touch embeddings for that superseded analysis.
        guard !Task.isCancelled else { return false }
        guard !unavailable.contains(language) else { return false }
        let embedding: NLEmbedding
        if let existing = embeddings[language] {
            embedding = existing
        } else {
            guard let installed = NLEmbedding.wordEmbedding(for: NLLanguage(rawValue: language)) else {
                unavailable.insert(language)
                return false
            }
            if recent.count == 2 { embeddings.removeValue(forKey: recent.removeFirst()) }
            embeddings[language] = installed
            embedding = installed
        }
        recent.removeAll { $0 == language }
        recent.append(language)
        return words.allSatisfy { embedding.contains($0) }
    }
}

enum InputLanguageAnalysis {
    // Keep kana with adjacent Han characters. Splitting Japanese into Kanji-only
    // fragments can otherwise report Chinese alongside a clearly Japanese sentence.
    nonisolated private static let scriptRegex = try! NSRegularExpression(
        pattern: "[\\p{Han}\\p{Hiragana}\\p{Katakana}ー]+|[\\p{Latin}][\\p{Latin}\\s’',.!?-]*")
    nonisolated private static let hanRegex = try! NSRegularExpression(pattern: "[\\p{Han}]")
    nonisolated private static let shortInputVocabulary = ShortInputVocabulary()
    nonisolated static func analyzeInput(_ text: String) -> InputAnalysis {
        guard !Task.isCancelled else { return InputAnalysis(languages: [], words: 0) }
        return InputAnalysis(languages: detectLanguages(text), words: wordCount(text))
    }
    nonisolated static func wordCount(_ text: String) -> Int {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            guard !Task.isCancelled else { return false }
            if text[range].contains(where: { $0.isLetter || $0.isNumber }) { count += 1 }
            return true
        }
        return count
    }
    // Text already in the output language goes in unchanged (CoreSameLanguageGate).
    nonisolated static func isAlready(in target: String, text: String) -> Bool {
        let sample = String(text.prefix(4000))
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        var confidence = 0.0
        for (language, value) in recognizer.languageHypotheses(withMaximum: 3)
        where CoreSameLanguageGate.same(Language.canonicalCode(language.rawValue), target) {
            confidence += value
        }
        return CoreSameLanguageGate.decide(
            text: sample, target: target, detected: detectLanguages(sample), confidence: confidence) == .unchanged
    }
    nonisolated static func detectLanguages(_ text: String) -> [String] {
        guard !Task.isCancelled else { return [] }
        do {
            if let document = try CoreJSONTranslationPlan.make(source: text) {
                return detectLanguages(inValues: document.leaves.map(\.source))
            }
        } catch {
            // A cancelled or over-budget document provides no language cue.
            // Never replace that absence with a guess from structural keys.
            return []
        }
        return detectPlainLanguages(text)
    }
    // The caller already owns the parsed document. Do not parse its joined
    // values as another task envelope or repeat the structure scan.
    nonisolated static func detectLanguages(inValues values: [String]) -> [String] {
        guard !Task.isCancelled else { return [] }
        let text = values.joined(separator: "\n")
        guard !Task.isCancelled else { return [] }
        return detectPlainLanguages(text)
    }
    nonisolated private static func detectPlainLanguages(_ text: String) -> [String] {
        if let romanized = CoreRomanizedInput.language(in: text) { return [romanized] }
        let sample = String(text.prefix(12000))
        guard !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var fragments = [sample]
        sample.enumerateSubstrings(in: sample.startIndex..<sample.endIndex, options: .bySentences) { part, _, _, stop in
            if let part { fragments.append(part) }
            if fragments.count >= 16 || Task.isCancelled { stop = true }
        }
        var scriptMatchCount = 0
        scriptRegex.enumerateMatches(in: sample, range: NSRange(sample.startIndex..., in: sample)) { match, _, stop in
            guard let match else { return }
            if let range = Range(match.range, in: sample) { fragments.append(String(sample[range])) }
            scriptMatchCount += 1
            if scriptMatchCount == 16 { stop.pointee = true }
        }
        let componentSeparators = CharacterSet(charactersIn: ",;:，；：\n")
        // The extra split keeps the sixteenth component separate from an unused tail.
        fragments += sample.unicodeScalars.split(
            maxSplits: 16, omittingEmptySubsequences: false, whereSeparator: componentSeparators.contains
        ).prefix(16).map(String.init)
        var result: [String] = []
        var seen = Set<String>()
        let recognizer = NLLanguageRecognizer()
        for raw in fragments.prefix(40) {
            if Task.isCancelled { break }
            let fragment = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard seen.insert(fragment).inserted else { continue }
            let letters = fragment.lazy.filter({ $0.isLetter }).prefix(3).count
            let shortHan =
                letters == 2
                && hanRegex.firstMatch(in: fragment, range: NSRange(fragment.startIndex..., in: fragment)) != nil
            guard letters == 3 || shortHan else { continue }
            recognizer.reset()
            recognizer.processString(fragment)
            // Keep the winning Chinese script, but combine Chinese confidence
            // for shared Han text whose hypotheses split across both scripts.
            var hypotheses: [String: Double] = [:]
            for (language, confidence) in recognizer.languageHypotheses(withMaximum: 3) {
                hypotheses[Language.canonicalCode(language.rawValue), default: 0] += confidence
            }
            let ranked = hypotheses.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            guard let guess = ranked.first, Language.catalog.contains(where: { $0.id == guess.key }) else { continue }
            let confidence =
                ["zh", "zh-Hant"].contains(guess.key)
                ? (hypotheses["zh"] ?? 0) + (hypotheses["zh-Hant"] ?? 0) : guess.value
            let confident = confidence >= (shortHan ? 0.8 : 0.65)
            guard confident || (!shortHan && recognizesShortInput(fragment, ranked: ranked)) else { continue }
            let ambiguousChineseScript =
                ["zh", "zh-Hant"].contains(guess.key)
                && (hypotheses["zh"] ?? 0) >= 0.1 && (hypotheses["zh-Hant"] ?? 0) >= 0.1
            // Shared Han words inherit a script already established by the
            // sentence; otherwise keep the existing generic Chinese default.
            let code =
                ambiguousChineseScript
                ? result.first(where: { ["zh", "zh-Hant"].contains($0) }) ?? "zh" : guess.key
            guard !result.contains(code) else { continue }
            result.append(code)
        }
        return result
    }
    // A blanket sentence-level cutoff hides short words such as “hello”. A
    // lower-confidence guess is usable only for a short phrase with clear local
    // vocabulary evidence and no similarly plausible lexical competitor.
    nonisolated private static func recognizesShortInput(_ text: String, ranked: [(key: String, value: Double)]) -> Bool
    {
        guard text.count <= 80, let first = ranked.first, first.value >= 0.1 else { return false }
        let second = ranked.dropFirst().first?.value ?? 0
        guard first.value - second >= 0.02, first.value >= second * 1.2 else { return false }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var words: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range]).lowercased()
            guard word.allSatisfy(\.isLetter), words.count < 4 else {
                words = []
                return false
            }
            words.append(word)
            return !Task.isCancelled
        }
        guard !Task.isCancelled, !words.isEmpty, words.joined().count >= 3,
            shortInputVocabulary.contains(words, language: first.key)
        else { return false }
        return !ranked.dropFirst().contains { candidate in
            candidate.value >= max(0.1, first.value * 0.5)
                && shortInputVocabulary.contains(words, language: candidate.key)
        }
    }
}
