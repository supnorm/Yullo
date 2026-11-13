import Foundation

// How each language writes: the register a courteous text uses, punctuation
// and typography, numbers, letters and names. One table feeds every writer's
// prompt (only the target language's lines, so a small model's prompt stays
// short) and the output checks.
public enum CoreLanguageConventions {
    // Without a known language: the general formal-"you" rules.
    public static let formalYou =
        " In languages with a formal and an informal \"you\", use the formal one (vous, Sie, usted, Lei, 您 where natural, polite Japanese) unless the message is clearly informal."
    public static let formalYouUnlessCasual =
        "When the target language has a formal and an informal \"you\" and the source doesn't show which, use the formal one (vous, Sie, usted, Lei, 您 where natural) unless the message is clearly casual."

    public enum Register: Sendable, Equatable {
        // Polite, formal, email, professional, academic: the formal "you".
        case courteous
        // Casual and social: the informal "you".
        case casual
        // A translation: courteous unless the message is clearly casual.
        case courteousUnlessCasual
        // Everything else keeps the text's own register.
        case asWritten
    }

    struct Entry {
        var courteous: String
        var casual: String? = nil
        var writing: String
        var letter: String? = nil
        // The part of the letter line that names no form to copy.
        var letterRule: String? = nil
    }

    static let entries: [String: Entry] = [
        "en": .init(
            courteous: "Use courteous wording (please, could you).",
            writing: "Keep numbers, dates and times as given.",
            letter: "Write a supplied greeting as Dear Ms X, or Hi Anna,."),
        "fr": .init(
            courteous: "Address the reader as vous (vous pouvez, votre), never tu.",
            casual: "Address a friend as tu.",
            writing:
                "French typography: a space before ? ! : ; and quotes « like this »; spoken numbers written the French way (1,5; 14 h 30); words agree with each person's gender (Chère Anne, la directrice).",
            letter: "Write a supplied greeting the French way (Madame, / Bonjour Anne,)."
        ),
        "de": .init(
            courteous: "Address the reader as Sie (Ihnen, Ihr), never du or ihr.",
            casual: "Address a friend as du.",
            writing:
                "Capitalize every noun; quotes „like this“; spoken numbers written the German way (1,5; 14:30 Uhr); words agree with each person's gender (Liebe Anna, die Direktorin).",
            letter:
                "Write a supplied greeting the German way (Sehr geehrte Frau X, / Liebe Anna,); the line after it starts lowercase unless it begins with a noun or Sie.",
            letterRule: "The line after a greeting starts lowercase unless it begins with a noun or Sie."
        ),
        "es": .init(
            courteous:
                "Address the reader as usted (usted puede, ¿podría…?) and a group as ustedes, never tú or vosotros.",
            casual: "Address a friend as tú.",
            writing:
                "Open questions and exclamations with ¿ and ¡; spoken numbers written the Spanish way (1,5; 14:30); words agree with each person's gender (Estimada Ana, la directora).",
            letter: "Write a supplied greeting the Spanish way (Estimada Sra. X: / Hola, Ana:)."
        ),
        "it": .init(
            courteous: "Address the reader as Lei (Le, Suo), never tu.",
            casual: "Address a friend as tu.",
            writing:
                "Quotes «like this»; spoken numbers written the Italian way (1,5; 14:30); words agree with each person's gender (Cara Anna, la direttrice).",
            letter: "Write a supplied greeting the Italian way (Gentile Sig.ra X, / Ciao Anna,)."
        ),
        "pt": .init(
            courteous: "Address the reader formally (o senhor, a senhora, or você with a courteous tone), never tu.",
            writing:
                "Spoken numbers written the Portuguese way (1,5; 14h30); words agree with each person's gender (Prezada Ana, a diretora).",
            letter: "Write a supplied greeting as Prezada Sra. X, / Olá Ana,."),
        "nl": .init(
            courteous: "Address the reader as u, never je or jij.", casual: "Address a friend as je.",
            writing: "Spoken numbers written the Dutch way (1,5; 14.30 uur).",
            letter: "Write a supplied greeting as Geachte mevrouw X, / Beste Anna,."),
        "ru": .init(
            courteous: "Address the reader as Вы, never ты.", casual: "Address a friend as ты.",
            writing:
                "Quotes «like this»; spoken numbers written the Russian way (1,5; 14:30); words agree with each person's gender (дорогая Анна).",
            letter: "Write a supplied greeting as Уважаемая Анна Петровна,."),
        "ja": .init(
            courteous:
                "Use polite Japanese, the です/ます forms, with respectful keigo toward a client or superior.",
            casual: "Plain forms are fine among friends.",
            writing:
                "Full-width punctuation (、。？！) and quotes 「like this」, no spaces between Japanese characters; keep family name first (山田太郎).",
            letter: "Keep 様 or さん after a name."),
        "ko": .init(
            courteous: "Use 존댓말, the -습니다 and -요 endings, never 반말.", casual: "반말 is fine among friends.",
            writing: "Follow Korean word spacing; keep family name first (김민수).",
            letter: "Keep 님 after a name or title."),
        "zh": .init(
            courteous: "Address the reader as 您, with polite words (请、麻烦您).",
            casual: "你 is fine among friends.",
            writing:
                "Simplified characters only; full-width punctuation (，。？！：；) and quotes “like this”, no spaces between Chinese characters; keep family name first (王小明).",
            letter: "Write a supplied greeting the Chinese way (尊敬的王经理： / 王经理，您好！)."
        ),
        "zh-Hant": .init(
            courteous: "Address the reader as 您, with polite words (請、麻煩您).",
            casual: "你 is fine among friends.",
            writing:
                "Traditional characters only; full-width punctuation (，。？！：；) and quotes 「like this」, no spaces between Chinese characters; keep family name first (王小明).",
            letter: "Write a supplied greeting the Chinese way (敬愛的王經理： / 王經理，您好！)."
        )
    ]

    // The table's key for a language ID: zh-Hant, zh-TW, zh-HK and Cantonese
    // write traditional characters; other IDs reduce to their base language.
    public static func key(_ id: String?) -> String? {
        guard let id = id?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { return nil }
        let lowered = id.lowercased()
        if lowered == "yue" || (lowered.hasPrefix("zh") && ["hant", "tw", "hk", "mo"].contains(where: lowered.contains))
        {
            return "zh-Hant"
        }
        // A language's English name, as translation targets are often given.
        let names = [
            "english": "en", "french": "fr", "german": "de", "spanish": "es", "italian": "it", "portuguese": "pt",
            "dutch": "nl", "russian": "ru", "japanese": "ja", "korean": "ko", "chinese": "zh",
            "mandarin chinese": "zh", "simplified chinese": "zh", "traditional chinese": "zh-Hant",
            "cantonese": "zh-Hant"
        ]
        if let named = names[lowered] { return named }
        let base = String(lowered.prefix { $0 != "-" && $0 != "_" })
        return entries[base] == nil ? nil : base
    }

    // A format's register; a format written into another language reads as a
    // translation, courteous unless the speech is casual.
    public static func register(for style: RewriteStyle, translating: Bool = false) -> Register {
        switch style {
        case .polite, .formal, .email, .professional, .academic: return .courteous
        case .casual, .social: return .casual
        default: return translating ? .courteousUnlessCasual : .asWritten
        }
    }
    public static func isLetter(_ style: RewriteStyle) -> Bool {
        [.polite, .formal, .email, .professional].contains(style)
    }

    // The lines for one language, empty when it has none. Without a language
    // the courteous register still gets the general formal-"you" rule.
    // examples: whether letter lines may show greeting forms. A small model copies any
    // form it is shown ("Madame,", "Sehr geehrte Frau X,") into text that never had one.
    public static func rule(
        languageID: String?, register: Register, letter: Bool = false, examples: Bool = true
    ) -> String {
        guard let key = key(languageID), let entry = entries[key] else {
            switch register {
            case .courteous: return formalYou
            case .courteousUnlessCasual: return " " + formalYouUnlessCasual
            case .casual, .asWritten: return ""
            }
        }
        var parts: [String] = []
        switch register {
        // Without examples the courteous line loses its samples too: Apple's model wrote
        // "Usted puede reservar…" from "(usted puede, ¿podría…?)".
        case .courteous: parts.append(examples ? entry.courteous : withoutSamples(entry.courteous))
        case .courteousUnlessCasual:
            let line = examples ? entry.courteous : withoutSamples(entry.courteous)
            parts.append(String(line.dropLast()) + ", unless the message is clearly casual.")
        // Apple's model pasted "Address a friend as tú" in as "Tú, …": casual lines only where samples may show.
        case .casual: if examples, let casual = entry.casual { parts.append(casual) }
        case .asWritten: break
        }
        // Without examples, the writing line keeps its rules and loses the samples in
        // parentheses (王小明, "Chère Anne, la directrice"), which a small model pastes in.
        parts.append(examples ? entry.writing : withoutSamples(entry.writing))
        if !entry.writing.contains("family name first") { parts.append("Keep each person's name in the order given.") }
        if letter, let line = examples ? entry.letter : entry.letterRule { parts.append(line) }
        return " " + parts.joined(separator: " ")
    }

    // The formal "you" for one language, alone: what an edit of already written text
    // needs when its request asks for courtesy. Writing lines (numbers, name order)
    // made Apple's model spell out "9:30" and invent family names in finished text.
    public static func courtesy(languageID: String?) -> String {
        guard let key = key(languageID), let entry = entries[key] else { return formalYou }
        return " " + withoutSamples(entry.courteous)
    }

    static func withoutSamples(_ line: String) -> String {
        line.replacingOccurrences(of: #" ?\([^()]*\)"#, with: "", options: .regularExpression)
    }

    // MARK: Checks

    public enum Issue: String, Sendable, CaseIterable {
        case informalYou = "register"
        case typography
        case fullWidth = "full-width"
        case spacedCJK = "cjk-space"
        case mixedScript = "script"
        case letterCase = "letter-case"
    }

    static let informal: [String: [String]] = [
        "fr": ["tu", "toi", "ta", "tes", "t'"],
        "de": ["du", "dich", "dir", "dein", "deine", "deinen", "deinem", "deiner", "euch", "euer", "eure"],
        "es": [
            "tú", "vosotros", "vosotras", "os", "puedes", "podrías", "tienes", "quieres", "sabes", "eres", "estás",
            "tu", "tus"
        ],
        "it": ["tu", "ti", "tuo", "tua", "tuoi", "tue", "puoi", "potresti", "vuoi", "sai", "hai"],
        "nl": ["je", "jij", "jou", "jouw"],
        "ru": ["ты", "тебя", "тебе", "твой", "твоя", "твои"],
        "pt": ["tu", "teu", "tua"]
    ]
    // Characters written differently in simplified and traditional Chinese.
    static let scriptPairs: [(simplified: Character, traditional: Character)] = zip(
        "们这说时会为对过个么来国学发后还请应关开经问题实点电话当无与将让从谢议见间资体级给东车长门网买卖钱图书写读语认识备务总负责须预约邮件",
        "們這說時會為對過個麼來國學發後還請應關開經問題實點電話當無與將讓從謝議見間資體級給東車長門網買賣錢圖書寫讀語認識備務總負責須預約郵件"
    ).filter { $0.0 != $0.1 }.map { ($0.0, $0.1) }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: return true
        default: return false
        }
    }
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && $0 != "'" && $0 != "’" }.map {
            String($0).replacingOccurrences(of: "’", with: "'")
        }
    }

    // What the output gets wrong for its language and register. Only what the
    // input didn't already do counts, so a speaker's own choices stay theirs.
    public static func issues(output: String, input: String, languageID: String?, register: Register) -> [Issue] {
        guard let key = key(languageID) else { return [] }
        var found: [Issue] = []
        if register == .courteous {
            let said = Set(words(input))
            if let markers = informal[key] {
                let written = words(output)
                let elided = key == "fr" && written.contains { $0.hasPrefix("t'") && !said.contains($0) }
                if elided || written.contains(where: { markers.contains($0) && !said.contains($0) }) {
                    found.append(.informalYou)
                }
            }
            if key.hasPrefix("zh"), output.contains("你"), !output.contains("您") { found.append(.informalYou) }
            if key == "ja", !["です", "ます", "ました", "ません", "でした", "ください", "ございます"].contains(where: output.contains) {
                found.append(.informalYou)
            }
            if key == "ko", !["니다", "요"].contains(where: output.contains) { found.append(.informalYou) }
        }
        let quotes: [String: String] = ["fr": "«", "de": "„", "ja": "「", "zh-Hant": "「"]
        if let opening = quotes[key], !output.contains(opening),
            ["\"", "“"].contains(where: { output.contains($0) && !input.contains($0) })
        {
            found.append(.typography)
        }
        if key == "fr" {
            let scalars = Array(output.unicodeScalars)
            for (index, scalar) in scalars.enumerated().dropFirst() where "?!;".unicodeScalars.contains(scalar) {
                if CharacterSet.letters.contains(scalars[index - 1]) {
                    found.append(.typography)
                    break
                }
            }
        }
        if key == "es", output.contains("?"), !output.contains("¿") { found.append(.typography) }
        if key == "zh" || key == "zh-Hant" || key == "ja" {
            if hasHalfWidthAfterCJK(output), !hasHalfWidthAfterCJK(input) { found.append(.fullWidth) }
            if hasSpaceBetweenCJK(output), !hasSpaceBetweenCJK(input) { found.append(.spacedCJK) }
        }
        if key == "zh",
            scriptPairs.contains(where: { output.contains($0.traditional) && !input.contains($0.traditional) })
        {
            found.append(.mixedScript)
        }
        if key == "zh-Hant",
            scriptPairs.contains(where: { output.contains($0.simplified) && !input.contains($0.simplified) })
        {
            found.append(.mixedScript)
        }
        if key == "de", germanLineAfterGreetingCapitalized(output) { found.append(.letterCase) }
        return found
    }

    static func hasHalfWidthAfterCJK(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        for index in scalars.indices.dropFirst() where ",?!;:".unicodeScalars.contains(scalars[index]) {
            if isCJK(scalars[index - 1]) { return true }
        }
        for index in scalars.indices.dropFirst() where scalars[index] == "." && isCJK(scalars[index - 1]) {
            if index + 1 == scalars.count || CharacterSet.whitespacesAndNewlines.contains(scalars[index + 1]) {
                return true
            }
        }
        return false
    }
    static func hasSpaceBetweenCJK(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count >= 3 else { return false }
        for index in 1..<(scalars.count - 1) where scalars[index] == " " {
            if isCJK(scalars[index - 1]), isCJK(scalars[index + 1]) { return true }
        }
        return false
    }
    // "Sehr geehrte Frau Weber," then "Ich …": the word after a German greeting is lowercase.
    static func germanLineAfterGreetingCapitalized(_ text: String) -> Bool {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = lines.first, first.hasSuffix(","), lines.count > 1,
            ["sehr geehrte", "liebe", "hallo", "guten tag", "hi "].contains(where: first.lowercased().hasPrefix)
        else { return false }
        let next = lines[1].split(separator: " ").first.map(String.init) ?? ""
        return [
            "Ich", "Wir", "Vielen", "Gerne", "Gern", "Leider", "Anbei", "Hiermit", "Wie", "Danke", "Bitte", "Mit",
            "Es", "Das", "Da", "Kurz", "Nur", "Ich’", "Hier", "Schön", "Herzlichen", "Besten"
        ].contains(next)
    }

    // MARK: Repairs

    // Safe repairs for CJK text, where the right form is unambiguous: ASCII
    // punctuation after a Chinese or Japanese character becomes full-width,
    // and a space between two such characters goes. Text whose input already
    // wrote it that way (code, a speaker's own style) is left alone.
    public static func repaired(_ output: String, input: String) -> String {
        var text = output
        if hasHalfWidthAfterCJK(text), !hasHalfWidthAfterCJK(input) {
            let wide: [Unicode.Scalar: Unicode.Scalar] = [",": "，", "?": "？", "!": "！", ";": "；", ":": "：", ".": "。"]
            var scalars = Array(text.unicodeScalars)
            for index in scalars.indices.dropFirst() {
                guard let replacement = wide[scalars[index]], isCJK(scalars[index - 1]) else { continue }
                // A full stop only at a sentence end; "版本2.0" never matches, a digit isn't CJK.
                if scalars[index] == ".", index + 1 < scalars.count,
                    !CharacterSet.whitespacesAndNewlines.contains(scalars[index + 1])
                {
                    continue
                }
                scalars[index] = replacement
                // The space an ASCII mark brought with it goes too.
                if index + 2 < scalars.count, scalars[index + 1] == " ", isCJK(scalars[index + 2]) {
                    scalars[index + 1] = "\u{0}"
                }
            }
            text = String(String.UnicodeScalarView(scalars.filter { $0 != "\u{0}" }))
        }
        if hasSpaceBetweenCJK(text), !hasSpaceBetweenCJK(input) {
            let scalars = Array(text.unicodeScalars)
            var kept = String.UnicodeScalarView()
            for (index, scalar) in scalars.enumerated() {
                if scalar == " ", index > 0, index + 1 < scalars.count, isCJK(scalars[index - 1]),
                    isCJK(scalars[index + 1])
                {
                    continue
                }
                kept.append(scalar)
            }
            text = String(kept)
        }
        return lowercasedAfterGermanGreeting(apostrophesInInputStyle(text, input: input))
    }

    // "I’ll" stays curly when the input wrote its apostrophes as ’ and never as ':
    // only an apostrophe between two letters changes, so quotes and code stay.
    static func apostrophesInInputStyle(_ text: String, input: String) -> String {
        guard input.contains("’"), !input.contains("'"), text.contains("'") else { return text }
        let characters = Array(text)
        var result = ""
        for (index, character) in characters.enumerated() {
            let between =
                character == "'" && index > 0 && index + 1 < characters.count && characters[index - 1].isLetter
                && characters[index + 1].isLetter
            result.append(between ? "’" : character)
        }
        return result
    }

    // "Sehr geehrte Frau Weber," then "Vielen Dank…": the first word after a
    // German greeting is lowercase; only function words, never nouns, are lowered.
    static func lowercasedAfterGermanGreeting(_ text: String) -> String {
        guard germanLineAfterGreetingCapitalized(text) else { return text }
        var lines = text.components(separatedBy: "\n")
        guard
            let next = lines.indices.dropFirst().first(where: {
                !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty
            })
        else { return text }
        let line = lines[next]
        let start = line.firstIndex { !$0.isWhitespace } ?? line.startIndex
        let word = line[start...].prefix { $0.isLetter }
        // "Ihr"/"Ihre" (your, formal) stay capitalized.
        guard !["Ihr", "Ihre"].contains(String(word)) else { return text }
        lines[next] = String(line[..<start]) + word.lowercased() + line[start...].dropFirst(word.count)
        return lines.joined(separator: "\n")
    }
}
