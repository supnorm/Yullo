import Foundation

// What a writer must never add to what someone said: a header (To:,
// Subject:), a placeholder ([Name], 【姓名】, ___), or a greeting, closing or
// signature nobody spoke. The person's own "Sign letters as" name is the one
// signature allowed. Only what the input didn't contain is removed, so a
// spoken "Subject:", a real [link] or a said "thanks" stays.
public enum CoreLetterScaffold {
    public enum Invention: String, Sendable, CaseIterable {
        case header, placeholder, greeting, closing
        // The addressee signing, or the sender greeted.
        case roleSwap = "role-swap"
        // "Hi Mark" written as "Mark,".
        case droppedGreeting = "dropped-greeting"
        // "… thanks" or "… viele grüße jonas" said at the end, missing from the result.
        case droppedClosing = "dropped-closing"
    }

    static let headerKeys = [
        "to", "subject", "re", "from", "cc", "bcc", "date", "an", "betreff", "von", "objet", "à", "de", "para",
        "asunto", "oggetto", "a", "da", "收件人", "发件人", "主题", "主旨", "收件者", "寄件者", "日期", "件名", "宛先", "差出人"
    ]
    // A greeting word and the roots that show it was said.
    static let greetings: [(word: String, roots: [String])] = [
        ("to whom it may concern", ["concern"]), ("dear", ["dear"]), ("hello", ["hello"]), ("hi", ["hi"]),
        ("hey", ["hey"]), ("good morning", ["morning"]), ("sehr geehrte", ["geehrt"]), ("sehr geehrter", ["geehrt"]),
        ("liebe", ["lieb"]), ("lieber", ["lieb"]), ("hallo", ["hallo"]), ("guten tag", ["guten tag"]),
        ("bonjour", ["bonjour"]), ("madame", ["madame"]), ("monsieur", ["monsieur"]), ("chère", ["cher"]),
        ("cher", ["cher"]), ("salut", ["salut"]), ("estimado", ["estimad"]), ("estimada", ["estimad"]),
        ("querido", ["querid"]), ("querida", ["querid"]), ("hola", ["hola"]), ("gentile", ["gentil"]),
        ("caro", ["caro", "cara"]), ("cara", ["caro", "cara"]), ("ciao", ["ciao"]), ("buongiorno", ["buongiorno"]),
        ("尊敬的", ["尊敬"]), ("您好", ["您好", "你好"]), ("你好", ["您好", "你好"]), ("亲爱的", ["亲爱"]), ("親愛的", ["親愛"]), ("拝啓", ["拝啓"])
    ]
    // A closing and the roots that show it was said.
    static let closings: [(phrase: String, roots: [String])] = [
        ("Thank you", ["thank"]), ("thanks", ["thank"]), ("Many thanks", ["thank"]),
        // Longer spoken thanks, so "thank you so much" is never "Thank you," signed "So Much".
        ("Thank you so much", ["thank"]), ("Thanks so much", ["thank"]), ("Thank you very much", ["thank"]),
        ("Thanks a lot", ["thank"]), ("Thanks again", ["thank"]), ("Thanks in advance", ["thank"]),
        ("Best regards", ["regard"]), ("Kind regards", ["regard"]), ("regards", ["regard"]), ("best", ["best"]),
        ("sincerely", ["sincere"]), ("Yours sincerely", ["sincere"]), ("cheers", ["cheers"]),
        ("All the best", ["all the best"]), ("Mit freundlichen Grüßen", ["grüß", "gruss", "gruß"]),
        ("Viele Grüße", ["grüß", "gruss", "gruß"]), ("Beste Grüße", ["grüß", "gruss", "gruß"]),
        ("Liebe Grüße", ["grüß", "gruss", "gruß"]), ("Danke", ["dank"]), ("Vielen Dank", ["dank"]),
        ("cordialement", ["cordial"]), ("Bien à vous", ["bien à vous"]), ("Bien cordialement", ["cordial"]),
        ("merci", ["merci"]), ("salutations", ["salutation"]), ("atentamente", ["atentamente"]),
        ("Un saludo", ["salud"]), ("saludos", ["salud"]), ("gracias", ["gracias"]),
        ("Cordiali saluti", ["salut"]), ("Distinti saluti", ["salut"]), ("saluti", ["salut"]),
        ("grazie", ["grazie"]), ("此致敬礼", ["此致", "敬礼"]), ("此致", ["此致"]), ("敬礼", ["敬礼"]),
        ("此致敬禮", ["此致", "敬禮"]), ("敬禮", ["敬禮"]), ("谢谢", ["谢"]), ("謝謝", ["謝"]), ("祝好", ["祝"]),
        ("敬具", ["敬具"]), ("よろしくお願いいたします", ["よろしく"]), ("よろしくお願いします", ["よろしく"])
    ]

    static func folded(_ text: String) -> String {
        text.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
    }
    static func said(_ roots: [String], in input: String) -> Bool {
        let heard = folded(input)
        return roots.contains { heard.contains(folded($0)) }
    }
    static func bare(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ",，、.。!！:：;；")))
    }

    // The output is a rewrite of what was said: a third or more of the speech's words
    // (characters, for Chinese and Japanese) are in it. Only then is a dropped closing restored.
    static func rewrites(_ input: String, as output: String) -> Bool {
        let heard = folded(input), written = folded(output)
        let units: [String]
        if heard.unicodeScalars.contains(where: CoreLanguageConventions.isCJK) {
            units = heard.filter { $0.unicodeScalars.allSatisfy(CoreLanguageConventions.isCJK) }.map(String.init)
        } else {
            units = heard.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 }
        }
        guard !units.isEmpty else { return false }
        return Double(units.filter { written.contains($0) }.count) >= Double(units.count) / 3
    }

    // The closing the speech ends with, and a name of one or two words after it.
    static func spokenClosing(_ input: String) -> (closing: (phrase: String, roots: [String]), name: String?)? {
        let heard = folded(input).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        for closing in closings.sorted(by: { $0.phrase.count > $1.phrase.count }) {
            guard let range = heard.range(of: folded(closing.phrase), options: .backwards) else { continue }
            let rest = heard[range.upperBound...].trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
            let words = rest.split(separator: " ")
            guard words.count <= 2 else { continue }
            // The original spelling of the name, with a capital.
            let name =
                words.isEmpty ? nil : words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
            return (closing, name)
        }
        return nil
    }

    // A whole word at the start: "hi Anna" but not "hier"; CJK words need no space.
    static func starts(_ line: String, with word: String) -> Bool {
        guard line.hasPrefix(word) else { return false }
        let next = line.dropFirst(word.count).first
        return next == nil || !(next!.isLetter) || word.unicodeScalars.contains { CoreLanguageConventions.isCJK($0) }
    }

    // Placeholder tokens the input doesn't have: [Name], 【姓名】, <recipient>, {name}, ___, XXX.
    static func placeholders(in text: String, input: String) -> [Range<String.Index>] {
        let patterns = [
            #"\[[^\]\n]{1,40}\](?!\()"#, #"【[^】\n]{1,20}】"#, #"<[^<>\n]{1,30}>"#, #"\{[^{}\n]{1,30}\}"#, #"_{3,}"#,
            #"\bX{3,}\b"#, #"＿{2,}"#, #"〇〇|○○"#
        ]
        var found: [Range<String.Index>] = []
        for pattern in patterns {
            var start = text.startIndex
            while let range = text.range(of: pattern, options: .regularExpression, range: start..<text.endIndex) {
                let token = String(text[range])
                // A tag with its closing tag (<b>…</b>) or a closing tag is markup, not a placeholder.
                let markup =
                    token.hasPrefix("</")
                    || (token.hasPrefix("<")
                        && text.contains("</" + token.dropFirst().prefix { $0 != ">" && $0 != " " }))
                if !input.contains(token), !markup { found.append(range) }
                start = range.upperBound
            }
        }
        return found
    }

    // What was invented, for checks and evaluation.
    public static func inventions(_ output: String, input: String, signOffName: String?) -> [Invention] {
        let result = removingInvented(output, input: input, signOffName: signOffName, report: true)
        return result.found
    }

    // unsigned: the "Sign letters as" name in a format that isn't a letter; a last line
    // that is only that name, never spoken, goes.
    public static func removingInvented(
        _ output: String, input: String, signOffName: String?, unsigned: String? = nil
    ) -> String {
        var text = removingInvented(output, input: input, signOffName: signOffName, report: false).text
        if let unsigned, !folded(input).contains(folded(unsigned)) {
            var lines = text.components(separatedBy: "\n")
            if let last = lines.lastIndex(where: { !bare($0).isEmpty }), folded(bare(lines[last])) == folded(unsigned) {
                lines.remove(at: last)
                while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
                text = lines.joined(separator: "\n")
            }
        }
        return text
    }

    // A letter's spoken greeting and closing on their own lines, as every writer is asked to set
    // them: "Hello Mr Okafor, the premium…" or "Hi Priya" directly above the body becomes the
    // greeting, a blank line, then the body with a capital (German keeps lower case after a
    // comma); a closing above a name gets a blank line before it. Lines lose trailing spaces
    // (Markdown breaks) in every format. Only what was said is moved; nothing is added but
    // the greeting's comma and the blank lines.
    public static func laidOut(_ output: String, input: String, style: RewriteStyle, languageID: String?) -> String {
        // Typed Markdown keeps its own trailing-space breaks.
        let marked = input.contains("  \n")
        var lines = output.components(separatedBy: "\n").map {
            marked ? $0 : String($0.reversed().drop { $0 == " " || $0 == "\t" }.reversed())
        }
        let dense = output.unicodeScalars.contains(where: CoreLanguageConventions.isCJK)
        if style == .bullets { return withoutGreetedPoint(lines, input: input).joined(separator: "\n") }
        guard CoreLanguageConventions.isLetter(style), style != .professional, !dense,
            let first = lines.firstIndex(where: { !bare($0).isEmpty })
        else { return lines.joined(separator: "\n") }
        let german = CoreLanguageConventions.key(languageID) == "de"
        func capitalized(_ text: String) -> String {
            guard !german, let letter = text.first, letter.isLowercase else { return text }
            return letter.uppercased() + text.dropFirst()
        }
        let line = lines[first]
        let lowered = folded(line)
        if let greeting = greetings.sorted(by: { $0.word.count > $1.word.count }).first(where: {
            starts(lowered, with: folded($0.word))
        }), said(greeting.roots, in: input) {
            // "hey team," opens a letter as "Hey team,".
            if let letter = line.first, letter.isLowercase {
                lines[first] = letter.uppercased() + line.dropFirst()
            }
            let line = lines[first]
            let head = line.prefix { $0 != "," && $0 != ":" }
            let greeted = head.split(separator: " ").count - greeting.word.split(separator: " ").count
            let rest = line.dropFirst(head.count).dropFirst().trimmingCharacters(in: .whitespaces)
            if head.count < line.count, (1...3).contains(greeted), !rest.isEmpty,
                !head.contains(where: { ".!?".contains($0) })
            {
                lines[first] = String(head) + String(line[head.endIndex])
                lines.insert(contentsOf: ["", capitalized(rest)], at: first + 1)
            } else if rest.isEmpty, (1...3).contains(greeted),
                !line.contains(where: { ".!?".contains($0) }),
                first + 1 < lines.count, !lines[first + 1].trimmingCharacters(in: .whitespaces).isEmpty
            {
                // The greeting alone on its line ("Hi Priya" or "Dear Ms Lindqvist,") right above the body.
                if head.count == line.count { lines[first] = line + "," }
                lines[first + 1] = capitalized(lines[first + 1])
                lines.insert("", at: first + 1)
            }
        }
        // A closing line right under the body, before a name, gets its blank line.
        if let last = lines.lastIndex(where: { !bare($0).isEmpty }), last > first + 1 {
            let closingAt =
                closings.contains(where: { folded(bare(lines[last])) == folded($0.phrase) })
                ? last : last - 1
            if closingAt > first, closings.contains(where: { folded(bare(lines[closingAt])) == folded($0.phrase) }) {
                // "Best regards," above the name; German closings take no comma ("Viele Grüße").
                if closingAt < last, !german, let end = lines[closingAt].last, end.isLetter {
                    lines[closingAt] += ","
                }
                if !lines[closingAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.insert("", at: closingAt)
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    // Notes are points, not a letter: the person greeted ("hi priya", "张老师您好") is never a point
    // of its own ("- 张老师。") nor the opening of one ("- Priya, the call is…").
    static func withoutGreetedPoint(_ lines: [String], input: String) -> [String] {
        guard let first = lines.firstIndex(where: { !bare($0).isEmpty }), lines[first].hasPrefix("- ") else {
            return lines
        }
        let heard = folded(input).trimmingCharacters(in: .whitespaces)
        let point = String(lines[first].dropFirst(2))
        let head = String(point.prefix { !",，:：.。".contains($0) })
        let name = folded(head).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.split(separator: " ").count <= 3, head.count <= 24 else { return lines }
        // Said first, or right after a spoken greeting word.
        let opener = greetings.filter { !$0.word.contains(" ") }.first { starts(heard, with: folded($0.word)) }
        let start = opener.map { String(heard.dropFirst($0.word.count)).trimmingCharacters(in: .whitespaces) }
        // A greeting before the name ("hi priya") or right after it ("张老师您好").
        let greetedAfter =
            heard.hasPrefix(name)
            && greetings.contains {
                starts(String(heard.dropFirst(name.count)).trimmingCharacters(in: .whitespaces), with: folded($0.word))
            }
        guard start?.hasPrefix(name) == true || greetedAfter else { return lines }
        var result = lines
        let rest = point.dropFirst(head.count).drop { ",，:：.。 ".contains($0) }
        if rest.isEmpty {
            result.remove(at: first)
        } else {
            result[first] = "- " + rest.prefix(1).uppercased() + rest.dropFirst()
        }
        return result
    }

    static func removingInvented(_ output: String, input: String, signOffName: String?, report: Bool) -> (
        text: String, found: [Invention]
    ) {
        var found: [Invention] = []
        var text = output
        // Placeholders: the token goes; a line left with nothing but punctuation goes too.
        let tokens = placeholders(in: text, input: input)
        if !tokens.isEmpty {
            found.append(.placeholder)
            for range in tokens.sorted(by: { $0.lowerBound > $1.lowerBound }) { text.removeSubrange(range) }
            text = text.replacingOccurrences(of: #"[ \t]+([,.!?;:，。！？])"#, with: "$1", options: .regularExpression)
                // "感謝您的協助，[姓名]。" without the placeholder ends on one mark, not "，。".
                .replacingOccurrences(of: #"[,，、]+([.!?。！？])"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        }
        var lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        func firstContent() -> Int? { lines.firstIndex { !bare($0).isEmpty } }
        func lastContent() -> Int? { lines.lastIndex { !bare($0).isEmpty } }
        // Headers at the top.
        while let index = firstContent() {
            let line = lines[index]
            guard let colon = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else { break }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            // "Subject" said aloud allows a subject line; short keys like "to" need the colon itself.
            let heard = folded(input)
            let spoken =
                heard.contains(folded(key) + ":") || heard.contains(folded(key) + "：")
                || (key.count > 3 && heard.contains(folded(key)))
            guard headerKeys.contains(key), !spoken else { break }
            found.append(.header)
            lines.remove(at: index)
        }
        // A greeting nobody said, unless it names someone the speech named.
        if let index = firstContent() {
            let line = bare(lines[index])
            let lowered = folded(line)
            if line.count <= 40,
                let greeting = greetings.first(where: { starts(lowered, with: folded($0.word)) }),
                !said(greeting.roots, in: input)
            {
                let rest = bare(String(line.dropFirst(greeting.word.count)))
                let lastWord = folded(rest).split(separator: " ").last.map(String.init) ?? ""
                let named = !lastWord.isEmpty && folded(input).contains(lastWord)
                // "您好，本次預算超支了…": only the greeting goes; the message after it stays.
                let content =
                    rest.split(separator: " ").count > 3
                    || rest.unicodeScalars.filter(CoreLanguageConventions.isCJK).count > 6
                if content {
                    found.append(.greeting)
                    let message = String(lines[index].dropFirst(greeting.word.count))
                        .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ",，、!！:：")))
                    lines[index] = message.prefix(1).uppercased() + message.dropFirst()
                } else if !named {
                    found.append(.greeting)
                    lines.remove(at: index)
                }
            }
        }
        // A closing nobody said, before an optional signature line.
        if var last = lastContent() {
            let signature = bare(lines[last])
            let isOwnName = signOffName.map { folded(signature) == folded($0) } ?? false
            let isSpokenName =
                signature.count <= 30 && folded(input).contains(folded(signature))
                && signature.split(separator: " ").count <= 3
            if (isOwnName || isSpokenName), let previous = lines[..<last].lastIndex(where: { !bare($0).isEmpty }) {
                last = previous
            }
            let candidate = folded(bare(lines[last]))
            if candidate.count <= 40,
                let closing = closings.first(where: { candidate == folded($0.phrase) }),
                !said(closing.roots, in: input)
            {
                found.append(.closing)
                lines.remove(at: last)
            }
        }
        // Any other line that is only an unspoken greeting or closing word ("拝啓", "Cordialement"),
        // and "Danke, Jan": an unspoken closing before a name keeps only the name.
        for index in lines.indices.reversed() {
            let line = folded(bare(lines[index]))
            guard !line.isEmpty, line.count <= 40 else { continue }
            if let closing = closings.first(where: { line == folded($0.phrase) }), !said(closing.roots, in: input) {
                found.append(.closing)
                lines.remove(at: index)
                continue
            }
            if let greeting = greetings.first(where: { line == folded($0.word) }), !said(greeting.roots, in: input) {
                found.append(.greeting)
                lines.remove(at: index)
                continue
            }
            let parts = bare(lines[index]).split(separator: ",", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 2, let closing = closings.first(where: { folded(parts[0]) == folded($0.phrase) }),
                !said(closing.roots, in: input),
                folded(input).contains(folded(parts[1])) || signOffName.map({ folded($0) == folded(parts[1]) }) == true
            {
                found.append(.closing)
                lines[index] = parts[1]
            }
        }
        // Who is who: a name said in the opening words is the addressee, one said in the
        // closing words or set as "Sign letters as" is the sender. Neither swaps roles.
        // What was said, without filler sounds before the first word ("um hey mike …").
        let spokenWords = Array(
            folded(input).split { !$0.isLetter && !$0.isNumber }.map(String.init)
                .drop { CoreSpokenFiller.sounds.contains($0) })
        // By position in what was said: said once, near the start or the end and nearer it than the other.
        let heard = folded(input)
        func place(_ name: String) -> (first: Int, last: Int, once: Bool)? {
            let key = folded(name).split(separator: " ").first.map(String.init) ?? ""
            guard !key.isEmpty, let first = heard.range(of: key), let last = heard.range(of: key, options: .backwards)
            else { return nil }
            return (
                heard.distance(from: heard.startIndex, to: first.lowerBound),
                heard.distance(from: last.upperBound, to: heard.endIndex), first == last
            )
        }
        func opening(_ name: String) -> Bool {
            guard let at = place(name) else { return false }
            return at.once && at.first < 12 && at.first < at.last
        }
        func closingName(_ name: String) -> Bool {
            if let signOffName, folded(signOffName) == folded(name) { return true }
            guard let at = place(name) else { return false }
            return at.once && at.last < 12 && at.last < at.first
        }
        func nameLike(_ line: String) -> Bool {
            let words = line.split(separator: " ")
            // A short run of CJK characters (王经理, 山本) is a name line too; they have no capitals.
            let cjk = line.count <= 6 && line.unicodeScalars.allSatisfy { CoreLanguageConventions.isCJK($0) }
            return !line.isEmpty && (cjk || words.count <= 3 && words.allSatisfy { $0.first?.isUppercase == true })
                && !line.contains(where: { ".!?。！？".contains($0) })
        }
        if let last = lastContent(), let first = firstContent(), last != first {
            let signature = bare(lines[last])
            if nameLike(signature), opening(signature), !closingName(signature) {
                found.append(.roleSwap)
                lines.remove(at: last)
            }
        }
        if let first = firstContent() {
            let line = bare(lines[first])
            let greeted =
                greetings.first(where: { starts(folded(line), with: folded($0.word)) }).map {
                    bare(String(line.dropFirst($0.word.count)))
                } ?? (nameLike(line) && line.split(separator: " ").count <= 2 ? line : nil)
            if let greeted, !greeted.isEmpty, closingName(greeted), !opening(greeted) {
                found.append(.roleSwap)
                lines.remove(at: first)
            }
        }
        // A greeting the speaker didn't say, swapped in for one they did ("hallo frau becker"
        // written "Sehr geehrte Frau Becker,"), goes back to theirs; one opening the body line
        // ("Madame, je vous…") with nothing of it said goes.
        if let first = firstContent(), let opener = spokenWords.first {
            let line = lines[first]
            let lowered = folded(line)
            if let written = greetings.first(where: { starts(lowered, with: folded($0.word)) }),
                !said(written.roots, in: input)
            {
                if let spokenGreeting = greetings.first(where: {
                    !$0.word.contains(" ") && folded($0.word) == opener
                }) {
                    let word = spokenGreeting.word.prefix(1).uppercased() + spokenGreeting.word.dropFirst()
                    lines[first] = word + line.dropFirst(written.word.count)
                    found.append(.droppedGreeting)
                } else if let comma = line.firstIndex(where: { ",:：，".contains($0) }) {
                    let rest = line[line.index(after: comma)...].trimmingCharacters(in: .whitespaces)
                    let greeted = bare(String(line[..<comma].dropFirst(written.word.count)))
                    let named =
                        !greeted.isEmpty
                        && heard.contains(folded(greeted).split(separator: " ").last.map(String.init) ?? "")
                    if !named, !rest.isEmpty {
                        lines[first] = rest.prefix(1).uppercased() + rest.dropFirst()
                        found.append(.greeting)
                    }
                }
            }
        }
        // "hey jordan can you…" written "Jordan, can you…": the greeting word comes back.
        if let first = firstContent(), let opener = spokenWords.first, spokenWords.count > 2,
            let greeting = greetings.first(where: { !$0.word.contains(" ") && folded($0.word) == opener })
        {
            let line = lines[first]
            // The words said between the greeting and the line's first comma: "mr okafor" too.
            let greeted = folded(line).prefix { $0 != "," }.split { !$0.isLetter && !$0.isNumber }.map(String.init)
            if line.contains(","), !greeted.isEmpty, greeted.count <= 3,
                folded(line).hasPrefix(greeted.joined(separator: " ")),
                Array(spokenWords.dropFirst().prefix(greeted.count)) == greeted,
                !greetings.contains(where: { starts(folded(line), with: folded($0.word)) })
            {
                let word = greeting.word.prefix(1).uppercased() + greeting.word.dropFirst()
                lines[first] = word + " " + line
                found.append(.droppedGreeting)
            }
        }
        // A name already in the body, set again alone at the end, is the body's, not a signature
        // ("…en el restaurante Casa Lucía." then "Casa Lucía").
        if let last = lastContent(), let first = firstContent(), last != first {
            let signature = bare(lines[last])
            let body = lines[first..<last].joined(separator: " ")
            let isOwn = signOffName.map { folded($0) == folded(signature) } ?? false
            // "it's alex … thanks alex": the name said after the closing signs, even when the body has it.
            let signs = spokenClosing(input)?.name.map { folded($0) == folded(signature) } ?? false
            if !isOwn, !signs, nameLike(signature), folded(body).contains(folded(signature)) {
                lines.remove(at: last)
                found.append(.roleSwap)
            }
        }
        // A closing said at the end stays: "… thanks" or "… viele grüße jonas" comes back,
        // with the name said after it, on its own closing lines.
        if let spoken = spokenClosing(input), !said(spoken.closing.roots, in: lines.joined(separator: " ")),
            rewrites(input, as: lines.joined(separator: " "))
        {
            let phrase = spoken.closing.phrase
            var closing = [phrase.prefix(1).uppercased() + phrase.dropFirst()]
            // A comma after a Latin closing ("Viele Grüße,"); a Chinese or Japanese one stands alone.
            let comma = phrase.unicodeScalars.contains(where: CoreLanguageConventions.isCJK) ? "" : ","
            if let name = spoken.name, !folded(lines.joined(separator: " ")).contains(folded(name)) {
                closing = [closing[0] + comma, name]
            }
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            // Before a signature the result already has, else at the end.
            if spoken.name != nil, closing.count == 1, let last = lines.last,
                folded(bare(last)) == folded(spoken.name ?? "")
            {
                lines.insert(closing[0] + comma, at: lines.count - 1)
            } else {
                lines += [""] + closing
            }
            found.append(.droppedClosing)
        }
        // A spoken greeting word stays: "hi mark …" is "Hi Mark,", never "Mark,".
        if let first = firstContent(), let opener = spokenWords.first,
            let greeting = greetings.first(where: { !$0.word.contains(" ") && folded($0.word) == opener }),
            spokenWords.count > 1
        {
            let line = bare(lines[first])
            let named = folded(line).split { !$0.isLetter && !$0.isNumber }.map(String.init)
            if !named.isEmpty, named.count <= 3, Array(spokenWords.dropFirst().prefix(named.count)) == named {
                found.append(.droppedGreeting)
                let word = greeting.word.prefix(1).uppercased() + greeting.word.dropFirst()
                lines[first] = word + " " + line + (lines[first].hasSuffix(":") ? ":" : ",")
            }
        }
        // Blank lines at either end, and runs of them, from what was taken out.
        var tidy: [String] = []
        for line in lines {
            if line.isEmpty, tidy.last?.isEmpty ?? true { continue }
            tidy.append(line)
        }
        while tidy.last?.isEmpty == true { tidy.removeLast() }
        let result = tidy.joined(separator: "\n")
        return (found.isEmpty ? output : result, report ? found : [])
    }
}
