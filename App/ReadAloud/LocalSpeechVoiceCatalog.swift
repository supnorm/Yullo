import Foundation

// Curated preset metadata only. Configuration, migration and synthesis share
// these IDs without loading a model, importing audio frameworks or probing I/O.
enum LocalSpeechVoiceCatalog {
    private static let kokoroIDs =
        "af_alloy af_aoede af_bella af_heart af_jessica af_kore af_nicole af_nova af_river af_sarah af_sky am_adam am_echo am_eric am_fenrir am_liam am_michael am_onyx am_puck am_santa bf_alice bf_emma bf_isabella bf_lily bm_daniel bm_fable bm_george bm_lewis ef_dora em_alex em_santa ff_siwis hf_alpha hf_beta hm_omega hm_psi if_sara im_nicola pf_dora pm_alex pm_santa zf_xiaobei zf_xiaoni zf_xiaoxiao zf_xiaoyi zm_yunjian zm_yunxi zm_yunxia zm_yunyang"
        .split(separator: " ").map(String.init)
    private static let kokoroLanguages = [
        "a": "en", "b": "en", "e": "es", "f": "fr", "h": "hi", "i": "it", "p": "pt", "z": "zh"
    ]
    private static let qwenIDs = ["Vivian", "Serena", "Uncle_Fu", "Dylan", "Eric", "Ryan", "Aiden", "Ono_Anna", "Sohee"]
    static func voiceIDs(modelID: String, language: String) -> [String] {
        let family = Language.speechCode(language)
        let code = family == "zh-Hant" ? "zh" : family
        switch modelID {
        case "kokoro-82m-q8":
            // The pinned compact artifact omits Japanese's UniDic resources.
            var selected = kokoroIDs.filter { kokoroLanguages[String($0.prefix(1))] == code }
            if let preferred = ["en": "af_heart", "zh": "zf_xiaobei"][code],
                let index = selected.firstIndex(of: preferred)
            {
                selected.remove(at: index)
                selected.insert(preferred, at: 0)
            }
            return selected
        case "qwen3-tts-customvoice-q8":
            guard ["zh", "en", "ja", "ko", "de", "fr", "ru", "pt", "es", "it"].contains(code) else { return [] }
            let preferred = code == "zh" ? "Vivian" : code == "ja" ? "Ono_Anna" : code == "ko" ? "Sohee" : "Ryan"
            return [preferred] + qwenIDs.filter { $0 != preferred }
        default: return []
        }
    }
    // Published voice descriptions. Kokoro IDs encode them: the first letter
    // is the language or accent, the second the voice's gender. Qwen's come
    // from its model card. A voice outside these lists gets no invented detail.
    enum Gender: String, Sendable { case female, male }
    struct Details: Equatable, Sendable {
        let variety: String
        let gender: Gender
    }
    private static let kokoroVarieties = [
        "a": "en-US", "b": "en-GB", "e": "es", "f": "fr", "h": "hi", "i": "it", "p": "pt-BR", "z": "cmn"
    ]
    private static let qwenDetails: [String: Details] = [
        "Vivian": .init(variety: "zh", gender: .female), "Serena": .init(variety: "zh", gender: .female),
        "Uncle_Fu": .init(variety: "zh", gender: .male), "Dylan": .init(variety: "zh-beijing", gender: .male),
        "Eric": .init(variety: "zh-sichuan", gender: .male), "Ryan": .init(variety: "en", gender: .male),
        "Aiden": .init(variety: "en-US", gender: .male), "Ono_Anna": .init(variety: "ja", gender: .female),
        "Sohee": .init(variety: "ko", gender: .female)
    ]
    static func details(for voiceID: String, modelID: String) -> Details? {
        switch modelID {
        case "kokoro-82m-q8":
            guard kokoroIDs.contains(voiceID), let variety = kokoroVarieties[String(voiceID.prefix(1))] else {
                return nil
            }
            let gender = voiceID.dropFirst().prefix(1)
            return gender == "f"
                ? .init(variety: variety, gender: .female)
                : gender == "m" ? .init(variety: variety, gender: .male) : nil
        case "qwen3-tts-customvoice-q8": return qwenDetails[voiceID]
        default: return nil
        }
    }
    // Kokoro checks that a voice's own language code matches the request, and
    // reads plain English as American. British voices need their variant.
    static func requestLanguage(_ language: String, voiceID: String, modelID: String) -> String {
        modelID == "kokoro-82m-q8" && language == "en" && voiceID.hasPrefix("b") ? "en-gb" : language
    }
    static func varietyName(_ variety: String) -> String {
        switch variety {
        case "en-US": return L10n.tr("American English")
        case "en-GB": return L10n.tr("British English")
        case "en": return L10n.tr("English")
        case "es": return L10n.tr("Spanish")
        case "fr": return L10n.tr("French")
        case "hi": return L10n.tr("Hindi")
        case "it": return L10n.tr("Italian")
        case "pt-BR": return L10n.tr("Brazilian Portuguese")
        case "cmn": return L10n.tr("Mandarin")
        case "zh": return L10n.tr("Chinese")
        case "zh-beijing": return L10n.tr("Chinese, Beijing dialect")
        case "zh-sichuan": return L10n.tr("Chinese, Sichuan dialect")
        case "ja": return L10n.tr("Japanese")
        case "ko": return L10n.tr("Korean")
        default: return variety
        }
    }
    static func genderName(_ gender: Gender) -> String {
        gender == .female ? L10n.tr("Female") : L10n.tr("Male")
    }
    // "American English · Female"
    static func detail(for voiceID: String, modelID: String) -> String {
        guard let details = details(for: voiceID, modelID: modelID) else { return "" }
        return varietyName(details.variety) + " · " + genderName(details.gender)
    }
    static func name(for voiceID: String, modelID: String) -> String {
        modelID == "kokoro-82m-q8"
            ? String(voiceID.dropFirst(3)).capitalized : voiceID.replacingOccurrences(of: "_", with: " ")
    }
    static func validLegacySelections(_ selections: [String: String], modelID: String) -> [String: String] {
        selections.reduce(into: [:]) { result, entry in
            let voice = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if voiceIDs(modelID: modelID, language: entry.key).contains(voice) { result[entry.key] = voice }
        }
    }
}
