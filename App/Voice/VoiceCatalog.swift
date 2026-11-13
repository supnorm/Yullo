import Foundation
import AVFoundation

// A fetched catalog's language labels describe relevance, not a guarantee that
// a particular service/model will synthesize every voice in that language.
// Build once per catalog/locale; filtering never rediscovers voices or accounts.
struct SpeechVoiceCatalogPresentation: Sendable {
    struct Voice: Identifiable, Sendable {
        let value: SpeechVoice
        let name: String
        let detail: String
        let families: Set<String>
        let languageDescription: String
        let searchable: String
        var id: String { value.id }
    }
    struct Group: Identifiable, Sendable {
        let id: String
        let language: String?
        let voices: [Voice]
    }
    let voices: [Voice]
    private let languageNames: [String: String]

    init(_ values: [SpeechVoice], locale: Locale, localizedLanguageNames: Bool) {
        struct Metadata {
            let family: String
            let name: String
            let searchable: String
        }
        var metadata: [String: Metadata] = [:], rejected: Set<String> = [], names: [String: String] = [:]
        var seen: Set<String> = [], rows: [Voice] = []
        for voice in values {
            if Task.isCancelled { break }
            guard seen.insert(voice.id).inserted else { continue }
            var languages: [String] = [], families: Set<String> = [], search: [String] = []
            for code in voice.languageCodes.prefix(128) where code.utf8.count <= 35 {
                let normalized = code.replacingOccurrences(of: "_", with: "-").lowercased()
                if metadata[normalized] == nil, !rejected.contains(normalized) {
                    let parts = normalized.split(separator: "-", omittingEmptySubsequences: false)
                    let alphabetic: (UInt8) -> Bool = { (97...122).contains($0) }
                    let valid =
                        parts.count <= 4
                        && parts.first.map {
                            (2...3).contains($0.utf8.count) && $0.utf8.allSatisfy(alphabetic)
                        } == true
                        && parts.dropFirst().allSatisfy {
                            (2...8).contains($0.utf8.count)
                                && $0.utf8.allSatisfy { alphabetic($0) || (48...57).contains($0) }
                        }
                    let family = Language.speechCode(normalized)
                    let catalog = Language.catalog.first { $0.id == family }
                    let known =
                        catalog != nil || locale.localizedString(forLanguageCode: String(parts.first ?? "")) != nil
                    if valid, known, !["und", "mul", "zxx"].contains(family) {
                        let displayLocale = localizedLanguageNames ? locale : Locale(identifier: family)
                        let name = displayLocale.localizedString(forIdentifier: normalized) ?? code
                        let familyName =
                            catalog?.displayName(localized: localizedLanguageNames, locale: locale)
                            ?? displayLocale.localizedString(forLanguageCode: family) ?? family
                        names[family] = familyName
                        metadata[normalized] = Metadata(
                            family: family, name: name,
                            searchable: [code, family, name, familyName, catalog?.name ?? "", catalog?.subtitle ?? ""]
                                .joined(separator: " "))
                    } else {
                        rejected.insert(normalized)
                    }
                }
                if let value = metadata[normalized] {
                    families.insert(value.family)
                    if !languages.contains(value.name) { languages.append(value.name) }
                    search.append(value.searchable)
                }
            }
            func bounded(_ value: String) -> String {
                String(String.UnicodeScalarView(value.unicodeScalars.prefix(256)))
            }
            let name = bounded(voice.name)
            let accent = Self.accentName(voice.accent).map(bounded), gender = Self.genderName(voice.gender).map(bounded)
            let detail = [accent, gender, name == voice.id ? nil : bounded(voice.id)]
                .compactMap { $0 }.joined(separator: " · ")
            rows.append(
                Voice(
                    value: voice, name: name, detail: detail, families: families,
                    languageDescription: languages.joined(separator: " · "),
                    searchable: ([
                        bounded(voice.id), name, bounded(voice.gender ?? ""), bounded(voice.accent ?? ""),
                        accent ?? "", gender ?? ""
                    ] + search).joined(separator: " ")))
        }
        voices = rows.sorted {
            let result = $0.name.localizedStandardCompare($1.name)
            return result == .orderedSame ? $0.id < $1.id : result == .orderedAscending
        }
        languageNames = names
    }

    // Providers report gender as Female, FEMALE or female, and Google adds an
    // unspecified value. Known values read in the interface language; other
    // reported values stay as given, and nothing is inferred from a name.
    static func genderName(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        switch value.lowercased() {
        case "female": return LocalSpeechVoiceCatalog.genderName(.female)
        case "male": return LocalSpeechVoiceCatalog.genderName(.male)
        case "neutral": return L10n.tr("Neutral")
        case "ssml_voice_gender_unspecified", "unspecified", "unknown", "none": return nil
        default: return value
        }
    }
    // ElevenLabs accents are lowercase labels such as "american".
    static func accentName(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value.prefix(1).uppercased() + value.dropFirst()
    }

    func groups(language: String, allLanguages: Bool, query: String) -> [Group] {
        let family = Language.speechCode(language)
        let query = String(String.UnicodeScalarView(query.unicodeScalars.prefix(256)))
        let terms = query.split(whereSeparator: \.isWhitespace).prefix(16).map(String.init)
        let matches = voices.filter { voice in
            (allLanguages || voice.families.isEmpty || voice.families.contains(family))
                && terms.allSatisfy { voice.searchable.localizedStandardContains($0) }
        }
        let grouped = Dictionary(grouping: matches) { voice in
            voice.families.isEmpty
                ? "unknown" : voice.families.count > 1 ? "multilingual" : "language/" + voice.families.first!
        }
        return grouped.map { key, values in
            Group(id: key, language: key.hasPrefix("language/") ? String(key.dropFirst(9)) : nil, voices: values)
        }.sorted { first, second in
            func rank(_ group: Group) -> Int {
                if group.language == family { return 0 }
                if group.id == "multilingual" { return 1 }
                return group.id == "unknown" ? 3 : 2
            }
            if rank(first) != rank(second) { return rank(first) < rank(second) }
            return name(for: first).localizedStandardCompare(name(for: second)) == .orderedAscending
        }
    }
    func name(for group: Group) -> String {
        if let language = group.language { return languageNames[language] ?? language }
        if group.id == "multilingual" { return L10n.tr("Multilingual voices") }
        return L10n.tr("Language not specified")
    }
}

// Native voice discovery can load hundreds of descriptors. Keep it out of every
// settings redraw and playback, while still noticing installed/removed voices.
enum MacVoiceCatalog {
    private static let lock = NSLock()
    private static var cached: [String: [AVSpeechSynthesisVoice]]?
    private static var revision = 0
    private static let observer = NotificationCenter.default.addObserver(
        forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification, object: nil, queue: nil
    ) { _ in
        invalidate()
    }

    static func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
        revision &+= 1
    }

    static func voices(for language: String) -> [AVSpeechSynthesisVoice] {
        let language = SpeechLanguagePolicy.canonicalCode(language)
        guard !language.isEmpty else { return [] }
        _ = observer
        lock.lock()
        if let cached {
            lock.unlock()
            return cached[language] ?? []
        }
        let startingRevision = revision
        lock.unlock()
        let voices = AVSpeechSynthesisVoice.speechVoices()
        // Build from the voices macOS actually exposes, including languages
        // outside the translation menu. Keep the established locale preference
        // for menu languages and keep Cantonese separate from Mandarin.
        let grouped = Dictionary(grouping: voices) { SpeechLanguagePolicy.canonicalCode($0.language) }
        let locales = Dictionary(uniqueKeysWithValues: Language.catalog.map { ($0.id, $0.locale) })
        let catalog = grouped.reduce(into: [String: [AVSpeechSynthesisVoice]]()) { result, entry in
            let (code, candidates) = entry
            guard !code.isEmpty else { return }
            let exact = candidates.filter {
                code == "yue" ? ["zh-HK", "yue-HK"].contains($0.language) : $0.language == locales[code]
            }
            let matching: [AVSpeechSynthesisVoice]
            if !exact.isEmpty { matching = exact } else { matching = candidates }
            result[code] = matching.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        lock.lock()
        if revision == startingRevision { cached = catalog }
        lock.unlock()
        return catalog[language] ?? []
    }
}
