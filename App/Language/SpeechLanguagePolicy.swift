import Foundation
import NaturalLanguage

// Read the current text, not the translation menu or a voice editor's preview
// language. Hints only resolve short/ambiguous text and the Han dialect ambiguity.
enum SpeechLanguagePolicy {
    static func canonicalCode(_ locale: String) -> String {
        let value = locale.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-").lowercased()
        guard value.range(of: "^[a-z]{2,3}(?:-[a-z0-9]{2,8}){0,3}$", options: .regularExpression) != nil else {
            return ""
        }
        let parts = value.split(separator: "-")
        guard let base = parts.first.map(String.init), !["und", "mul", "zxx"].contains(base) else { return "" }
        return Language.speechCode(value)
    }

    static func language(for text: String, hint: String? = nil) -> String {
        let fallback = canonicalCode(hint ?? "")
        let sample = String(text.prefix(12_000))
        let letters = sample.unicodeScalars.lazy.filter(CharacterSet.letters.contains).prefix(3).count
        let shortHan = letters == 2 && sample.unicodeScalars.contains(where: isHan)
        guard letters >= 3 || shortHan else { return fallback.isEmpty ? "en" : fallback }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        var hypotheses: [String: Double] = [:]
        for (language, confidence) in recognizer.languageHypotheses(withMaximum: 5) {
            let code = canonicalCode(language.rawValue)
            if !code.isEmpty { hypotheses[code, default: 0] += confidence }
        }
        guard let detected = hypotheses.max(by: { $0.value < $1.value }) else {
            return fallback.isEmpty ? "en" : fallback
        }
        // Shared Han words can split confidence across the two scripts. Combine
        // their evidence for confidence only; keep the winning script identity.
        let confidence =
            ["zh", "zh-Hant"].contains(detected.key)
            ? (hypotheses["zh"] ?? 0) + (hypotheses["zh-Hant"] ?? 0) : detected.value
        guard confidence >= (shortHan ? 0.8 : 0.65) else { return fallback.isEmpty ? "en" : fallback }
        // A recognizer can identify Han text without distinguishing Mandarin
        // from Cantonese. Respect that explicit hint only for a Han result.
        if fallback == "yue", ["zh", "zh-Hant", "yue"].contains(detected.key) { return "yue" }
        if shortHan, ["zh", "zh-Hant"].contains(fallback),
            (hypotheses["zh"] ?? 0) >= 0.1, (hypotheses["zh-Hant"] ?? 0) >= 0.1
        {
            return fallback
        }
        return detected.key
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF: return true
        default: return false
        }
    }
}
