import Foundation

/// Conservative evidence for short, separated Romanized phrases. This is not a
/// transliterator: it never rewrites text, reconstructs characters, or guesses
/// an isolated name. Unrecognized and ambiguous input keeps normal detection.
public enum CoreRomanizedInput {
    public static let maximumUTF8Bytes = 2048
    public static let maximumTokens = 64
    private static let maximumTokenScalars = 48

    public static func language(in text: String) -> String? {
        guard !Task.isCancelled, let tokens = tokens(in: text), tokens.count >= 2 else { return nil }
        let words = tokens.map(\.word)
        guard !words.contains(where: ordinaryTextMarkers.contains) else { return nil }
        var candidates: [String] = []
        if pinyin(tokens) { candidates.append("zh") }
        if !tokens.contains(where: \.numberedTone) {
            if japanese(words) { candidates.append("ja") }
            if korean(words) { candidates.append("ko") }
            if hindi(words) { candidates.append("hi") }
        }
        return !Task.isCancelled && candidates.count == 1 ? candidates[0] : nil
    }

    private struct Token {
        let word: String
        let markedTone: Bool
        let numberedTone: Bool
    }

    private static func tokens(in text: String) -> [Token]? {
        // Prefix admission bounds work before normalization or token allocation.
        var bytes = 0
        for _ in text.utf8 {
            bytes += 1
            if bytes > maximumUTF8Bytes || Task.isCancelled { return nil }
        }
        var result: [Token] = []
        var pending = String.UnicodeScalarView()
        func append() -> Bool {
            guard !pending.isEmpty else { return true }
            guard result.count < maximumTokens else { return false }
            let raw = String(pending).lowercased().decomposedStringWithCanonicalMapping
            var word = ""
            var marked = false
            var number = false
            var previous: UInt32 = 0
            for scalar in raw.unicodeScalars {
                switch scalar.value {
                case 97...122:
                    guard !number else { return false }
                    word.unicodeScalars.append(scalar)
                    previous = scalar.value
                case 49...53:
                    guard !word.isEmpty, !number else { return false }
                    number = true
                case 0x300, 0x301, 0x304, 0x30C:
                    guard [97, 101, 105, 111, 117].contains(previous) else { return false }
                    marked = true
                case 0x302:
                    guard [97, 101, 105, 111, 117].contains(previous) else { return false }
                case 0x308:
                    guard previous == 117 else { return false }
                    // v is the common keyboard spelling of Pinyin ü.
                    word.removeLast()
                    word.append("v")
                default: return false
                }
            }
            guard !word.isEmpty else { return false }
            result.append(Token(word: word, markedTone: marked, numberedTone: number))
            pending = String.UnicodeScalarView()
            return true
        }
        for scalar in text.unicodeScalars {
            if Task.isCancelled { return nil }
            switch scalar.value {
            case 9, 10, 13, 32, 33, 39, 44, 45, 46, 59, 63, 0x2019:
                guard append() else { return nil }
            default:
                guard pending.count < maximumTokenScalars else { return nil }
                pending.append(scalar)
            }
        }
        guard append() else { return nil }
        return result
    }

    // Shared English/technical markers prevent a few quoted Romanized words
    // inside an ordinary sentence from replacing its established language.
    private static let ordinaryTextMarkers = Set(
        "the this that these those please with from into for your our hello world return func let var class import print select where http https function enum struct protocol"
            .split(separator: " ").map(String.init))

    private static let pinyinSyllables = Set(
        "a ai an ang ao ba bai ban bang bao bei ben beng bi bian biao bie bin bing bo bu ca cai can cang cao ce cen ceng cha chai chan chang chao che chen cheng chi chong chou chu chua chuai chuan chuang chui chun chuo ci cong cou cu cuan cui cun cuo da dai dan dang dao de dei den deng di dia dian diao die ding diu dong dou du duan dui dun duo e ei en eng er fa fan fang fei fen feng fo fou fu ga gai gan gang gao ge gei gen geng gong gou gu gua guai guan guang gui gun guo ha hai han hang hao he hei hen heng hong hou hu hua huai huan huang hui hun huo ji jia jian jiang jiao jie jin jing jiong jiu ju juan jue jun ka kai kan kang kao ke kei ken keng kong kou ku kua kuai kuan kuang kui kun kuo la lai lan lang lao le lei leng li lia lian liang liao lie lin ling liu lo long lou lu luan lun luo lv lve ma mai man mang mao me mei men meng mi mian miao mie min ming miu mo mou mu na nai nan nang nao ne nei nen neng ni nian niang niao nie nin ning niu nong nou nu nuan nuo nv nve o ou pa pai pan pang pao pei pen peng pi pian piao pie pin ping po pou pu qi qia qian qiang qiao qie qin qing qiong qiu qu quan que qun ran rang rao re ren reng ri rong rou ru ruan rui run ruo sa sai san sang sao se sen seng sha shai shan shang shao she shei shen sheng shi shou shu shua shuai shuan shuang shui shun shuo si song sou su suan sui sun suo ta tai tan tang tao te teng ti tian tiao tie ting tong tou tu tuan tui tun tuo wa wai wan wang wei wen weng wo wu xi xia xian xiang xiao xie xin xing xiong xiu xu xuan xue xun ya yan yang yao ye yi yin ying yo yong you yu yuan yue yun za zai zan zang zao ze zei zen zeng zha zhai zhan zhang zhao zhe zhei zhen zheng zhi zhong zhou zhu zhua zhuai zhuan zhuang zhui zhun zhuo zi zong zou zu zuan zui zun zuo"
            .split(separator: " ").map(String.init))
    private static let pinyinSubjects: Set<String> = ["wo", "ni", "nin", "ta", "women", "nimen", "tamen", "zanmen"]
    private static let pinyinPredicates: Set<String> = [
        "shi", "yao", "xiang", "you", "meiyou", "mei", "keyi", "neng", "hui", "ai", "xihuan", "qu", "lai", "kan", "he",
        "chi", "zhidao", "renshi", "zai"
    ]
    private static let pinyinGrammar: Set<String> = [
        "de", "le", "ma", "ne", "ba", "zai", "ye", "dou", "bu", "hen", "hao", "shenme", "zenme", "weishenme", "nali",
        "nar", "duoshao"
    ]

    private static func pinyin(_ tokens: [Token]) -> Bool {
        let words = tokens.map(\.word)
        guard words.allSatisfy(pinyinWord), Set(words).count >= 2 else { return false }
        if tokens.filter({ $0.markedTone || $0.numberedTone }).count >= 2 { return true }
        guard words.count >= 3 else { return false }
        let subjects = words.filter(pinyinSubjects.contains).count
        let predicates = words.filter(pinyinPredicates.contains).count
        let grammar = words.filter(pinyinGrammar.contains).count
        return subjects >= 1 && predicates >= 1 && (words.count >= 4 || subjects + predicates + grammar >= 3)
            || subjects >= 1 && grammar >= 2 || pinyinDeicticQuestion(words)
    }

    private static func pinyinDeicticQuestion(_ words: [String]) -> Bool {
        var start = 0
        if ["nihao", "ninhao"].contains(words[0]) {
            start = 1
        } else if words.count >= 2, ["ni", "nin"].contains(words[0]), words[1] == "hao" {
            start = 2
        }
        guard start < words.count,
            ["zhe", "zhei", "na", "nei", "zhege", "nage", "zhexie", "naxie"].contains(words[start])
        else { return false }
        var predicate = start + 1
        if predicate < words.count, ["ge", "xie"].contains(words[predicate]) { predicate += 1 }
        guard predicate < words.count, words[predicate] == "shi" else { return false }
        let complement = Array(words.dropFirst(predicate + 1))
        return complement.contains(where: { ["shenme", "shei", "nali", "nar", "duoshao"].contains($0) })
            || zip(complement, complement.dropFirst()).contains { $0 == "shen" && $1 == "me" }
    }

    private static func pinyinWord(_ word: String) -> Bool {
        if pinyinSyllables.contains(word) { return true }
        // Admit common joined words without trying to infer a sentence from an
        // unspaced string. Each word is bounded and needs independent cues.
        let bytes = Array(word.utf8)
        guard bytes.count <= 32 else { return false }
        var reachable = Array(repeating: false, count: bytes.count + 1)
        reachable[0] = true
        for start in bytes.indices where reachable[start] {
            for end in (start + 1)...min(bytes.count, start + 6) {
                if pinyinSyllables.contains(String(decoding: bytes[start..<end], as: UTF8.self)) {
                    reachable[end] = true
                }
            }
        }
        return reachable[bytes.count]
    }

    private static let japaneseSubjects: Set<String> = [
        "watashi", "watasi", "watashitachi", "boku", "ore", "anata", "kore", "sore", "are", "kono", "sono", "doko",
        "nani", "dare"
    ]
    private static let japaneseParticles: Set<String> = ["wa", "ga", "wo", "o", "ni", "de", "to", "no", "mo", "e"]
    private static let japaneseEndings: Set<String> = [
        "desu", "desuka", "deshita", "desita", "masu", "masuka", "masen", "kudasai", "kudasaru"
    ]
    private static let japaneseGreetings: Set<String> = [
        "arigatou", "arigato", "ohayou", "ohayo", "gozaimasu", "gozaimashita", "gozaimasita", "doumo", "domo"
    ]

    private static let japaneseTemporal: Set<String> = [
        "ashita", "asu", "kyou", "kyo", "kinou", "kino", "konban", "raishuu", "raishu", "ima"
    ]
    private static let japaneseQuestions: Set<String> = [
        "nanji", "nani", "doko", "itsu", "dare", "ikutsu", "dore", "donna"
    ]
    private static func japanese(_ words: [String]) -> Bool {
        if words.count == 2, words.allSatisfy(japaneseGreetings.contains), Set(words).count == 2 { return true }
        var clause = words
        if ["konnichiwa", "konnichiha", "konbanwa", "konbanha"].contains(clause[0]) {
            clause.removeFirst()
        } else if clause.count >= 2, clause[0] == "konnichi", ["wa", "ha"].contains(clause[1]) {
            clause.removeFirst(2)
        }
        guard clause.count >= 3 else { return false }
        let endingIndex = clause.last == "ka" ? clause.count - 2 : clause.count - 1
        let ending = clause[endingIndex]
        guard
            japaneseEndings.contains(ending)
                || ending.count >= 5 && (ending.hasSuffix("masu") || ending.hasSuffix("masen"))
        else { return false }
        let body = Array(clause.prefix(endingIndex))
        if body.contains(where: japaneseSubjects.contains), body.contains(where: japaneseParticles.contains) {
            return true
        }
        guard let first = body.first, japaneseTemporal.contains(first) || japaneseQuestions.contains(first) else {
            return false
        }
        let topic = body.contains("wa") || body.contains("ga")
        let question = body.contains(where: japaneseQuestions.contains)
        return japaneseTemporal.contains(first) && (topic || question) || japaneseQuestions.contains(first) && topic
    }

    private static let koreanSubjects: Set<String> = [
        "jeoneun", "naneun", "neoneun", "urineun", "jega", "naega", "dangshineun", "dangsin", "jeo", "uri"
    ]
    private static let koreanGrammar: Set<String> = [
        "eodi", "eotteoke", "mueot", "mwo", "wae", "jigeum", "jeongmal", "aju", "neomu", "jom", "jebal", "eul", "reul",
        "e", "eseo"
    ]
    private static let koreanGreetings: Set<String> = [
        "annyeong", "annyeonghi", "haseyo", "gamsa", "hamnida", "gomawo", "gomawoyo"
    ]
    private static let koreanTemporal: Set<String> = ["oneul", "naeil", "eoje", "jigeum", "ije"]
    private static func korean(_ words: [String]) -> Bool {
        if words.count == 2, words.allSatisfy(koreanGreetings.contains), Set(words).count == 2 { return true }
        guard words.count >= 3, let last = words.last,
            last.count >= 4 && ["nida", "seyo", "eoyo", "ayo", "eyo", "haeyo", "woyo"].contains(where: last.hasSuffix)
        else { return false }
        if words.contains(where: koreanSubjects.contains),
            words.contains(where: koreanGrammar.contains) || words.count >= 4
        {
            return true
        }
        var clause = words
        if clause[0] == "annyeonghaseyo" {
            clause.removeFirst()
        } else if clause.count >= 2, clause[0] == "annyeong", clause[1] == "haseyo" {
            clause.removeFirst(2)
        }
        guard clause.count >= 3, let first = clause.first, koreanTemporal.contains(first), last.count >= 5 else {
            return false
        }
        let body = clause.dropFirst().dropLast()
        let marked = body.contains { word in
            ["ga", "i", "eun", "neun", "eul", "reul"].contains(word)
                || ["ga", "neun", "eun", "eul", "reul"].contains { word.count >= $0.count + 3 && word.hasSuffix($0) }
        }
        let context = body.contains { ["jeongmal", "neomu", "eotteoke", "eodi"].contains($0) }
        return marked || context
    }

    private static let hindiSubjects: Set<String> = [
        "main", "mein", "mai", "hum", "ham", "aap", "tum", "mujhe", "mujhko", "hame", "hume", "mera", "meri", "hamara",
        "aapka", "tumhara"
    ]
    private static let hindiGrammar: Set<String> = [
        "ka", "ki", "ke", "ko", "se", "mein", "me", "aur", "nahi", "nahin", "kya", "kyun", "kyon", "kaise", "kahan",
        "yahan", "bahut", "abhi", "yeh", "yah", "woh", "vah"
    ]
    private static let hindiPredicates: Set<String> = [
        "hai", "hain", "ho", "hoon", "hun", "hota", "hoti", "chahiye", "chaahiye", "karo", "karna", "chahta", "chahata",
        "chahti", "pasand", "raha", "rahi", "rahe", "baithiye", "bataiye"
    ]
    private static let hindiLexicalCues: Set<String> = ["kripaya", "kripya", "dhanyavaad", "dhanyavad"]
    private static func hindi(_ words: [String]) -> Bool {
        // Shared Hindustani grammar alone cannot distinguish Hindi and Urdu.
        // Require a Hindi-leaning lexical cue plus independent clause context.
        guard words.count >= 3, Set(words).count >= 3,
            words.contains(where: hindiSubjects.contains), words.contains(where: hindiPredicates.contains),
            words.contains(where: hindiLexicalCues.contains)
        else { return false }
        let cues = words.filter {
            hindiSubjects.contains($0) || hindiGrammar.contains($0) || hindiPredicates.contains($0)
                || hindiLexicalCues.contains($0)
        }
        return cues.count >= 3 && cues.count * 2 >= words.count
    }
}
