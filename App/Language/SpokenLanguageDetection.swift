import Foundation
import NaturalLanguage

// The recording indicator's spoken-language tag. Live words are provisional:
// a tag needs script evidence or a confident hypothesis among the person's own
// languages, so one short or borrowed word ("OK", "taxi") never names a language.
// Language IDs are catalog IDs: "zh" is Simplified and "zh-Hant" Traditional Chinese.
enum SpokenLanguageDetection {
    nonisolated static func detect(_ text: String, among languages: [String]) -> String? {
        var kana = 0, hangul = 0, han = 0, other = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: kana += 1
            case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: hangul += 1
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FFFF: han += 1
            default: other += 1
            }
        }
        // One CJK character carries about as much as a short word of letters.
        let dense = kana + hangul + han
        if dense > 0, dense * 4 >= other {
            if kana > 0 { return "ja" }
            if hangul > 0 { return "ko" }
            // Two characters can be the recognizer's guess at a short foreign word.
            guard han >= 3 else { return nil }
            guard languages.contains("ja") else { return chinese(text, among: languages) }
            // Han without kana may still be Japanese: wait for kana or confidence.
            let japanese = hypotheses(text, among: [.japanese, .simplifiedChinese, .traditionalChinese])[.japanese] ?? 0
            if japanese >= 0.8 { return "ja" }
            return japanese <= 0.2 ? chinese(text, among: languages) : nil
        }
        let words = wordCount(text)
        guard words >= 2 else { return nil }
        let cjk: Set<String> = ["zh", "zh-Hant", "ja", "ko"]
        let ranked = hypotheses(text, among: languages.filter { !cjk.contains($0) }.map { NLLanguage(rawValue: $0) })
            .sorted { $0.value > $1.value }
        guard let top = ranked.first else { return nil }
        let second = ranked.dropFirst().first?.value ?? 0
        // Two words only with near certainty; three or more with a clear lead.
        let accepted = words == 2 ? top.value >= 0.98 : top.value >= 0.8 || top.value - second >= 0.5
        return accepted ? Language.canonicalCode(top.key.rawValue) : nil
    }
    // Simplified or Traditional follows the person's languages, else confidence.
    nonisolated private static func chinese(_ text: String, among languages: [String]) -> String {
        let simplified = languages.firstIndex(of: "zh"), traditional = languages.firstIndex(of: "zh-Hant")
        switch (simplified, traditional) {
        case (.some, nil): return "zh"
        case (nil, .some): return "zh-Hant"
        default: break
        }
        let scripts = hypotheses(text, among: [.simplifiedChinese, .traditionalChinese])
        if let traditional = scripts[.traditionalChinese], traditional >= 0.8 { return "zh-Hant" }
        if let simplified = scripts[.simplifiedChinese], simplified >= 0.8 { return "zh" }
        return (traditional ?? .max) < (simplified ?? .max) ? "zh-Hant" : "zh"
    }
    nonisolated private static func hypotheses(_ text: String, among constraints: [NLLanguage]) -> [NLLanguage: Double]
    {
        let recognizer = NLLanguageRecognizer()
        if !constraints.isEmpty { recognizer.languageConstraints = constraints }
        recognizer.processString(text)
        return recognizer.languageHypotheses(withMaximum: 3)
    }
    nonisolated private static func wordCount(_ text: String) -> Int {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if text[range].contains(where: \.isLetter) { count += 1 }
            return true
        }
        return count
    }
}

// Starts from the most likely language and keeps re-detecting as live text
// grows; two detections in a row that agree settle the tag for the recording.
// A recognizer-reported language bypasses it (VoiceInputCoordinator.recognizerLanguage).
struct SpokenLanguageTag: Equatable {
    private(set) var shown: String?
    private(set) var settled: Bool
    private var previous: String?
    init(likely: String?) {
        shown = likely
        settled = false
    }
    /// True when the shown tag changed.
    mutating func accept(_ detected: String?) -> Bool {
        guard !settled, let detected else { return false }
        if detected == previous { settled = true }
        previous = detected
        guard detected != shown else { return false }
        shown = detected
        return true
    }
}
