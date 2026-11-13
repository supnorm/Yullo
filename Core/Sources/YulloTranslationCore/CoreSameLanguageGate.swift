import Foundation

// Text already in the output language goes in unchanged, on every engine. When
// unsure it translates: a skipped translation the person needed is worse than
// one request too many. Detection results come from the app's recognizer.
public enum CoreSameLanguageGate {
    public enum Decision: Equatable, Sendable { case unchanged, translate }

    // detected: languages found in the text, in order (several means mixed text).
    // confidence: the whole-text recognizer's confidence in its top language.
    public static func decide(text: String, target: String, detected: [String], confidence: Double) -> Decision {
        let content = stripLiterals(text)
        let letters = content.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return .unchanged }
        guard detected.count == 1, let language = detected.first, same(language, target) else { return .translate }

        let han = letters.filter { $0.properties.isIdeographic }.count
        let kana = letters.filter { (0x3040...0x30FF).contains($0.value) }.count
        let hangul = letters.filter { (0xAC00...0xD7AF).contains($0.value) || (0x1100...0x11FF).contains($0.value) }
            .count
        let cjk = han + kana + hangul
        let family = target.split(separator: "-").first.map(String.init) ?? target
        switch family {
        case "zh", "yue": if han == 0 || kana > 0 || hangul > 0 { return .translate }
        case "ja": if kana == 0 && han == 0 { return .translate }
        case "ko": if hangul == 0 { return .translate }
        default:
            let foreignScript =
                letters.contains(where: isCyrillicOrArabic) && !["ru", "uk", "ar", "fa"].contains(family)
            if cjk >= 2 || foreignScript { return .translate }
        }

        let words = content.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: \.isLetter) }.count
        let long = cjk >= 6 || (cjk == 0 && words >= 3)
        if long { return confidence >= 0.85 ? .unchanged : .translate }
        // Short text: only a script that belongs to one language is proof enough.
        if family == "ja" && kana > 0 { return .unchanged }
        if family == "ko" && hangul == letters.count { return .unchanged }
        return .translate
    }

    public static func same(_ detected: String, _ target: String) -> Bool {
        func norm(_ value: String) -> String {
            switch value {
            case "zh-Hans", "zh-CN": return "zh"
            case "zh-TW", "zh-HK": return "zh-Hant"
            default: return value
            }
        }
        let a = norm(detected), b = norm(target)
        if a == b { return true }
        // Regional variants of one language with one script count as the same.
        let scriptVariant = ["zh", "zh-Hant", "yue"]
        if scriptVariant.contains(a) || scriptVariant.contains(b) { return false }
        return a.split(separator: "-").first == b.split(separator: "-").first
    }

    static func isCyrillicOrArabic(_ scalar: Unicode.Scalar) -> Bool {
        (0x0400...0x04FF).contains(scalar.value) || (0x0600...0x06FF).contains(scalar.value)
    }

    // URLs, email addresses, @handles, code spans and numbers say nothing about the language.
    static func stripLiterals(_ text: String) -> String {
        var value = text
        for pattern in [
            "`[^`]*`", "https?://\\S+", "\\S+@\\S+\\.\\S+", "@\\w+", "\\b[\\w./-]*[/\\\\][\\w./-]+", "\\d+([.,:]\\d+)*"
        ] {
            value = value.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return value
    }
}
