import Foundation
import NaturalLanguage

// A single trusted catalog feeds menus, voice locale mapping and model metadata.
// Users choose which entries appear; editable prose never becomes instructions.
struct Language: Identifiable, Equatable {
    let id: String
    let name: String
    let subtitle: String
    let locale: String
    let azureVoice: String?
    var appleCode: String? { id == "yue" ? nil : (id == "zh" ? "zh-Hans" : id) }
    func displayName(localized: Bool, locale: Locale) -> String {
        guard localized else { return name }
        guard let shown = locale.localizedString(forIdentifier: appleCode ?? id) else { return name }
        // One form everywhere: "Chinese (Simplified)", not Apple's "Chinese, Simplified".
        guard let comma = shown.range(of: ", ") else { return shown }
        return shown[..<comma.lowerBound] + " (" + shown[comma.upperBound...] + ")"
    }
    static func displayName(for id: String, localized: Bool, locale: Locale) -> String {
        catalog.first { $0.id == id }?.displayName(localized: localized, locale: locale) ?? id
    }
    // Lists to pick from read alphabetically by the name shown, collated for the
    // interface language, as the Mac's own language lists do.
    static func sorted(_ languages: [Language], localized: Bool, locale: Locale) -> [Language] {
        sorted(languages, locale: locale) { $0.displayName(localized: localized, locale: locale) }
    }
    static func sorted(_ languages: [Language], locale: Locale, name: (Language) -> String) -> [Language] {
        languages.map { ($0, name($0)) }.sorted {
            let order = $0.1.compare($1.1, options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
            return order == .orderedSame ? $0.0.id < $1.0.id : order == .orderedAscending
        }.map(\.0)
    }
    // Only when nothing else is known; a new installation starts from the Mac's languages.
    static let fallbackIDs = ["en"]
    // The list earlier versions started with. Read only to migrate untouched old settings.
    static let legacyDefaultIDs = ["en", "fr", "zh"]
    static let maximumSystemCount = 4
    // This Mac's languages, read once at launch; "Reset to defaults" returns to them.
    static var systemDefaultIDs = fallbackIDs
    // The Mac's languages, in its order: preferred languages first, then the languages
    // of turned-on input methods (Pinyin, Kana…). Unsupported ones are skipped; an
    // empty result means none matched.
    static func systemIDs(preferred: [String], inputSources: [String]) -> [String] {
        let available = Set(catalog.map(\.id))
        var seen = Set<String>()
        var result: [String] = []
        for code in preferred + inputSources {
            let id = canonicalCode(code)
            guard available.contains(id), seen.insert(id).inserted else { continue }
            result.append(id)
            if result.count == maximumSystemCount { break }
        }
        return result
    }
    // The recording window's language switch holds up to three languages.
    static let maximumSwitchCount = 3
    static func switchIDs(_ ids: [String]) -> [String] {
        let available = Set(catalog.map(\.id))
        var seen = Set<String>()
        return Array(ids.filter { available.contains($0) && seen.insert($0).inserted }.prefix(maximumSwitchCount))
    }
    // The list with `first` moved to the top, in its order. Known languages only
    // lead; every entry of `ids` stays, so nothing is lost.
    static func leading(_ first: [String], in ids: [String]) -> [String] {
        let available = Set(catalog.map(\.id))
        var seen = Set<String>()
        let lead = first.map(canonicalCode).filter { available.contains($0) && seen.insert($0).inserted }
        return lead + ids.filter { !seen.contains(canonicalCode($0)) }
    }
    // The switch's short label: the code in capitals for most languages ("EN", "FR"),
    // so "IT" or "DE" never reads as a word; Chinese, Japanese and Korean keep their
    // short native names, which read at a glance. Stored IDs stay lowercase.
    static func shortLabel(for id: String) -> String {
        switch id {
        case "zh": return "简体中文"
        case "zh-Hant", "yue", "ja", "ko": return catalog.first { $0.id == id }?.name ?? id
        default: return id.uppercased()
        }
    }
    static let catalog: [Language] = [
        .init(id: "de", name: "Deutsch", subtitle: "German", locale: "de-DE", azureVoice: "de-DE-KatjaNeural"),
        .init(id: "en", name: "English", subtitle: "English", locale: "en-US", azureVoice: "en-US-JennyNeural"),
        .init(id: "es", name: "Español", subtitle: "Spanish", locale: "es-ES", azureVoice: "es-ES-ElviraNeural"),
        .init(id: "fr", name: "Français", subtitle: "French", locale: "fr-FR", azureVoice: "fr-FR-DeniseNeural"),
        .init(id: "it", name: "Italiano", subtitle: "Italian", locale: "it-IT", azureVoice: "it-IT-ElsaNeural"),
        .init(id: "zh", name: "中文", subtitle: "Mandarin Chinese", locale: "zh-CN", azureVoice: "zh-CN-XiaoxiaoNeural"),
        .init(
            id: "zh-Hant", name: "繁體中文", subtitle: "Traditional Chinese", locale: "zh-TW",
            azureVoice: "zh-TW-HsiaoChenNeural"),
        .init(id: "yue", name: "粵語", subtitle: "Cantonese", locale: "zh-HK", azureVoice: "zh-HK-HiuMaanNeural"),
        .init(id: "nl", name: "Nederlands", subtitle: "Dutch", locale: "nl-NL", azureVoice: "nl-NL-ColetteNeural"),
        .init(
            id: "pt", name: "Português", subtitle: "Portuguese", locale: "pt-BR", azureVoice: "pt-BR-FranciscaNeural"),
        .init(id: "ja", name: "日本語", subtitle: "Japanese", locale: "ja-JP", azureVoice: "ja-JP-NanamiNeural"),
        .init(id: "ko", name: "한국어", subtitle: "Korean", locale: "ko-KR", azureVoice: "ko-KR-SunHiNeural"),
        .init(id: "ar", name: "العربية", subtitle: "Arabic", locale: "ar-SA", azureVoice: "ar-SA-ZariyahNeural"),
        .init(id: "hi", name: "हिन्दी", subtitle: "Hindi", locale: "hi-IN", azureVoice: "hi-IN-SwaraNeural"),
        .init(id: "ru", name: "Русский", subtitle: "Russian", locale: "ru-RU", azureVoice: "ru-RU-SvetlanaNeural"),
        .init(id: "uk", name: "Українська", subtitle: "Ukrainian", locale: "uk-UA", azureVoice: "uk-UA-PolinaNeural"),
        .init(id: "pl", name: "Polski", subtitle: "Polish", locale: "pl-PL", azureVoice: "pl-PL-ZofiaNeural"),
        .init(id: "sv", name: "Svenska", subtitle: "Swedish", locale: "sv-SE", azureVoice: "sv-SE-SofieNeural"),
        .init(id: "da", name: "Dansk", subtitle: "Danish", locale: "da-DK", azureVoice: "da-DK-ChristelNeural"),
        .init(id: "fi", name: "Suomi", subtitle: "Finnish", locale: "fi-FI", azureVoice: "fi-FI-NooraNeural"),
        .init(
            id: "nb", name: "Norsk bokmål", subtitle: "Norwegian Bokmål", locale: "nb-NO",
            azureVoice: "nb-NO-PernilleNeural"),
        .init(id: "tr", name: "Türkçe", subtitle: "Turkish", locale: "tr-TR", azureVoice: "tr-TR-EmelNeural"),
        .init(id: "vi", name: "Tiếng Việt", subtitle: "Vietnamese", locale: "vi-VN", azureVoice: "vi-VN-HoaiMyNeural"),
        .init(id: "th", name: "ไทย", subtitle: "Thai", locale: "th-TH", azureVoice: "th-TH-PremwadeeNeural"),
        .init(
            id: "id", name: "Bahasa Indonesia", subtitle: "Indonesian", locale: "id-ID", azureVoice: "id-ID-GadisNeural"
        ),
        .init(id: "el", name: "Ελληνικά", subtitle: "Greek", locale: "el-GR", azureVoice: "el-GR-AthinaNeural"),
        .init(id: "he", name: "עברית", subtitle: "Hebrew", locale: "he-IL", azureVoice: "he-IL-HilaNeural"),
        // Available for API/model routing; provider support is checked separately.
        .init(id: "af", name: "Afrikaans", subtitle: "Afrikaans", locale: "af-ZA", azureVoice: nil),
        .init(id: "sq", name: "Shqip", subtitle: "Albanian", locale: "sq-AL", azureVoice: nil),
        .init(id: "am", name: "አማርኛ", subtitle: "Amharic", locale: "am-ET", azureVoice: nil),
        .init(id: "hy", name: "Հայերեն", subtitle: "Armenian", locale: "hy-AM", azureVoice: nil),
        .init(id: "az", name: "Azərbaycan", subtitle: "Azerbaijani", locale: "az-AZ", azureVoice: nil),
        .init(id: "eu", name: "Euskara", subtitle: "Basque", locale: "eu-ES", azureVoice: nil),
        .init(id: "bn", name: "বাংলা", subtitle: "Bengali", locale: "bn-BD", azureVoice: nil),
        .init(id: "bs", name: "Bosanski", subtitle: "Bosnian", locale: "bs-BA", azureVoice: nil),
        .init(id: "bg", name: "Български", subtitle: "Bulgarian", locale: "bg-BG", azureVoice: nil),
        .init(id: "ca", name: "Català", subtitle: "Catalan", locale: "ca-ES", azureVoice: nil),
        .init(id: "hr", name: "Hrvatski", subtitle: "Croatian", locale: "hr-HR", azureVoice: nil),
        .init(id: "cs", name: "Čeština", subtitle: "Czech", locale: "cs-CZ", azureVoice: nil),
        .init(id: "et", name: "Eesti", subtitle: "Estonian", locale: "et-EE", azureVoice: nil),
        .init(id: "fil", name: "Filipino", subtitle: "Filipino (Tagalog)", locale: "fil-PH", azureVoice: nil),
        .init(id: "gl", name: "Galego", subtitle: "Galician", locale: "gl-ES", azureVoice: nil),
        .init(id: "ka", name: "ქართული", subtitle: "Georgian", locale: "ka-GE", azureVoice: nil),
        .init(id: "gu", name: "ગુજરાતી", subtitle: "Gujarati", locale: "gu-IN", azureVoice: nil),
        .init(id: "hu", name: "Magyar", subtitle: "Hungarian", locale: "hu-HU", azureVoice: nil),
        .init(id: "is", name: "Íslenska", subtitle: "Icelandic", locale: "is-IS", azureVoice: nil),
        .init(id: "ga", name: "Gaeilge", subtitle: "Irish", locale: "ga-IE", azureVoice: nil),
        .init(id: "kk", name: "Қазақша", subtitle: "Kazakh", locale: "kk-KZ", azureVoice: nil),
        .init(id: "lv", name: "Latviešu", subtitle: "Latvian", locale: "lv-LV", azureVoice: nil),
        .init(id: "lt", name: "Lietuvių", subtitle: "Lithuanian", locale: "lt-LT", azureVoice: nil),
        .init(id: "mk", name: "Македонски", subtitle: "Macedonian", locale: "mk-MK", azureVoice: nil),
        .init(id: "ms", name: "Bahasa Melayu", subtitle: "Malay", locale: "ms-MY", azureVoice: nil),
        .init(id: "mt", name: "Malti", subtitle: "Maltese", locale: "mt-MT", azureVoice: nil),
        .init(id: "mr", name: "मराठी", subtitle: "Marathi", locale: "mr-IN", azureVoice: nil),
        .init(id: "mn", name: "Монгол", subtitle: "Mongolian", locale: "mn-MN", azureVoice: nil),
        .init(id: "ne", name: "नेपाली", subtitle: "Nepali", locale: "ne-NP", azureVoice: nil),
        .init(id: "fa", name: "فارسی", subtitle: "Persian (Farsi)", locale: "fa-IR", azureVoice: nil),
        .init(id: "pa", name: "ਪੰਜਾਬੀ", subtitle: "Punjabi", locale: "pa-IN", azureVoice: nil),
        .init(id: "ro", name: "Română", subtitle: "Romanian", locale: "ro-RO", azureVoice: nil),
        .init(id: "sr", name: "Српски", subtitle: "Serbian", locale: "sr-RS", azureVoice: nil),
        .init(id: "si", name: "සිංහල", subtitle: "Sinhala", locale: "si-LK", azureVoice: nil),
        .init(id: "sk", name: "Slovenčina", subtitle: "Slovak", locale: "sk-SK", azureVoice: nil),
        .init(id: "sl", name: "Slovenščina", subtitle: "Slovenian", locale: "sl-SI", azureVoice: nil),
        .init(id: "sw", name: "Kiswahili", subtitle: "Swahili", locale: "sw-KE", azureVoice: nil),
        .init(id: "ta", name: "தமிழ்", subtitle: "Tamil", locale: "ta-IN", azureVoice: nil),
        .init(id: "te", name: "తెలుగు", subtitle: "Telugu", locale: "te-IN", azureVoice: nil),
        .init(id: "ur", name: "اردو", subtitle: "Urdu", locale: "ur-PK", azureVoice: nil),
        .init(id: "uz", name: "Oʻzbekcha", subtitle: "Uzbek", locale: "uz-UZ", azureVoice: nil),
        .init(id: "cy", name: "Cymraeg", subtitle: "Welsh", locale: "cy-GB", azureVoice: nil)
    ].sorted {
        let a = $0.name.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let b = $1.name.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return a < b
    }
    var speechSample: String {
        switch id {
        case "zh": return "你好，这是语音试听。"
        case "zh-Hant": return "你好，這是語音試聽。"
        case "yue": return "你好，呢個係語音試聽。"
        case "fr": return "Bonjour, voici un aperçu de la voix."
        case "de": return "Hallo, dies ist eine Sprachprobe."
        case "es": return "Hola, esta es una prueba de voz."
        case "it": return "Ciao, questa è una prova della voce."
        case "nl": return "Hallo. Dit is een stemtest."
        case "pt": return "Olá. Este é um teste de voz."
        case "ja": return "こんにちは。音声テストです。"
        case "ko": return "안녕하세요. 음성 테스트입니다."
        case "ar": return "مرحباً. هذا اختبار للصوت."
        case "hi": return "नमस्ते। यह आवाज़ का परीक्षण है।"
        case "ru": return "Здравствуйте. Это проверка голоса."
        case "uk": return "Вітаю. Це перевірка голосу."
        case "pl": return "Cześć. To jest test głosu."
        case "sv": return "Hej. Det här är ett röstprov."
        case "da": return "Hej. Dette er en stemmeprøve."
        case "fi": return "Hei. Tämä on äänikoe."
        case "nb": return "Hei. Dette er en stemmeprøve."
        case "tr": return "Merhaba. Bu bir ses denemesidir."
        case "vi": return "Xin chào. Đây là thử giọng nói."
        case "th": return "สวัสดี นี่คือการทดสอบเสียง"
        case "id": return "Halo. Ini adalah tes suara."
        case "el": return "Γεια σας. Αυτή είναι μια δοκιμή φωνής."
        case "he": return "שלום. זוהי בדיקת קול."
        case "en": return "Hello. This is your voice preview."
        case "af": return "Hallo. Dit is 'n stemtoets."
        case "sq": return "Përshëndetje. Kjo është një provë zëri."
        case "am": return "ሰላም። ይህ የድምፅ ሙከራ ነው።"
        case "hy": return "Բարև։ Սա ձայնի փորձարկում է։"
        case "az": return "Salam. Bu, səs nümunəsidir."
        case "eu": return "Kaixo. Hau ahots proba bat da."
        case "bn": return "নমস্কার। এটি একটি কণ্ঠস্বরের পরীক্ষা।"
        case "bs": return "Zdravo. Ovo je glasovna proba."
        case "bg": return "Здравейте. Това е гласова проба."
        case "ca": return "Hola. Aquesta és una prova de veu."
        case "hr": return "Pozdrav. Ovo je test glasa."
        case "cs": return "Dobrý den. Toto je hlasová ukázka."
        case "et": return "Tere. See on hääleproov."
        case "fil": return "Kumusta. Ito ay pagsubok ng boses."
        case "gl": return "Ola. Esta é unha proba de voz."
        case "ka": return "გამარჯობა. ეს ხმის საცდელი ნიმუშია."
        case "gu": return "નમસ્તે. આ અવાજનું પરીક્ષણ છે."
        case "hu": return "Helló. Ez egy hangpróba."
        case "is": return "Halló. Þetta er raddprófun."
        case "ga": return "Dia duit. Is sampla gutha é seo."
        case "kk": return "Сәлем. Бұл дауысты тексеру."
        case "lv": return "Sveiki. Šis ir balss paraugs."
        case "lt": return "Sveiki. Tai balso pavyzdys."
        case "mk": return "Здраво. Ова е гласовен примерок."
        case "ms": return "Helo. Ini ialah ujian suara."
        case "mt": return "Bongu. Dan huwa test tal-vuċi."
        case "mr": return "नमस्कार. ही आवाजाची चाचणी आहे."
        case "mn": return "Сайн байна уу. Энэ бол дуу хоолойн туршилт."
        case "ne": return "नमस्ते। यो आवाजको परीक्षण हो।"
        case "fa": return "سلام. این یک نمونه صدا است."
        case "pa": return "ਸਤ ਸ੍ਰੀ ਅਕਾਲ। ਇਹ ਆਵਾਜ਼ ਦੀ ਜਾਂਚ ਹੈ।"
        case "ro": return "Bună. Aceasta este o probă vocală."
        case "sr": return "Здраво. Ово је проба гласа."
        case "si": return "ආයුබෝවන්. මෙය හඬ පරීක්ෂණයකි."
        case "sk": return "Dobrý deň. Toto je hlasová ukážka."
        case "sl": return "Pozdravljeni. To je glasovni vzorec."
        case "sw": return "Habari. Hili ni jaribio la sauti."
        case "ta": return "வணக்கம். இது ஒரு குரல் சோதனை."
        case "te": return "నమస్కారం. ఇది స్వర పరీక్ష."
        case "ur": return "سلام۔ یہ آواز کا نمونہ ہے۔"
        case "uz": return "Salom. Bu ovoz namunasi."
        case "cy": return "Helo. Dyma brawf llais."
        default: return "Hello. This is your voice preview."
        }
    }
    static func enabled(_ ids: [String]) -> [Language] {
        let lookup = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        var seen = Set<String>()
        let result = ids.compactMap { storedID -> Language? in
            let id = canonicalCode(storedID)
            guard let language = lookup[id], seen.insert(id).inserted else { return nil }
            return language
        }
        return result.isEmpty ? fallbackIDs.compactMap { lookup[$0] } : result
    }
    static func canonicalCode(_ code: String) -> String {
        let parts = code.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-")
        let base = parts.first.map(String.init) ?? code
        switch base {
        case "zh", "cmn":
            // Explicit script wins over region. Chinese text in Hong Kong is
            // not by itself evidence that its spoken language is Cantonese.
            if parts.contains("hant") { return "zh-Hant" }
            if parts.contains("hans") { return "zh" }
            return parts.contains(where: { ["tw", "hk", "mo"].contains($0) }) ? "zh-Hant" : "zh"
        case "no": return "nb"
        case "tl": return "fil"
        case "iw": return "he"
        case "in": return "id"
        default: return base
        }
    }

    // Speech services and macOS use zh-HK/zh-MO for Cantonese voices. Keep this
    // voice-locale convention separate from translation's script identifiers.
    static func speechCode(_ code: String) -> String {
        let parts = code.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-")
        if parts.first == "zh", parts.contains("hk") || parts.contains("mo") { return "yue" }
        return canonicalCode(code)
    }
}

import SwiftUI

extension EnvironmentValues {
    // Names in English, for views whose owner sets it once (Settings, setup).
    @Entry var localizedLanguageNames = true
}

extension Language {
    // The text's own language as an ID and its name, for prompts that name it.
    static func detected(in text: String) -> (id: String, name: String)? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2_000)))
        guard let code = recognizer.dominantLanguage?.rawValue else { return nil }
        let id = canonicalCode(code)
        return (
            id,
            catalog.first { $0.id == id }?.subtitle ?? Locale(identifier: "en").localizedString(forIdentifier: id) ?? id
        )
    }
}
