import Foundation

// Interface language is independent of translation languages and model prompts.
enum L10n {
    static let choices: [(id: String, name: String)] = [
        ("system", "System"), ("de", "Deutsch"), ("en", "English"), ("es", "Español"),
        ("fr", "Français"), ("it", "Italiano"), ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文")
    ]
    private static let supported = Set(choices.map(\.id).filter { $0 != "system" })
    private static let lock = NSLock()
    private static var current = resolve("system")
    private static var bundles: [String: Bundle] = [:]
    static func resolve(_ setting: String, preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        if supported.contains(setting) { return setting }
        for identifier in preferredLanguages {
            let language = Locale.Language(identifier: identifier.replacingOccurrences(of: "_", with: "-"))
            guard let base = language.languageCode?.identifier else { continue }
            // Foundation resolves likely scripts for region-only Chinese tags,
            // while an explicit Hans/Hant script takes precedence over region.
            if base == "zh" { return language.script?.identifier == "Hant" ? "zh-Hant" : "zh-Hans" }
            if supported.contains(base) { return base }
        }
        return "en"
    }
    static func configure(_ setting: String) {
        lock.lock()
        current = resolve(setting)
        lock.unlock()
    }
    static var language: String {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
    static var locale: Locale { Locale(identifier: language) }
    // File sizes as the interface language writes them ("1.71 GB", "1,71 GB").
    static func size(_ bytes: Int64) -> String { bytes.formatted(.byteCount(style: .file).locale(locale)) }
    // The interface language's own list separator: "、" in Chinese, ", " elsewhere.
    static var listSeparator: String {
        let formatter = ListFormatter()
        formatter.locale = locale
        return formatter.string(from: ["a", "b", "c"]).map { String($0.dropFirst().prefix { $0 != "b" }) } ?? ", "
    }
    // Sentences joined as the interface language writes them: no space after "。"
    // in Chinese, one space elsewhere.
    static func sentences(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: language.hasPrefix("zh") ? "" : " ")
    }
    // A format's translated template and numeric locale must describe the same
    // interface selection even if another thread changes it during lookup.
    private static func resources() -> (bundle: Bundle, language: String) {
        lock.lock()
        let code = current
        let bundle: Bundle
        if let cached = bundles[code] {
            bundle = cached
        } else {
            bundle = Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? Bundle.main
            bundles[code] = bundle
        }
        lock.unlock()
        return (bundle, code)
    }
    static func tr(_ key: String) -> String {
        resources().bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
    // A string as one of Yullo's own languages writes it, whatever the interface language.
    static func tr(_ key: String, in language: String) -> String {
        lock.lock()
        let bundle =
            bundles[language]
            ?? Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? Bundle.main
        bundles[language] = bundle
        lock.unlock()
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }
    static func format(_ key: String, _ values: CVarArg...) -> String {
        let snapshot = resources()
        let template = snapshot.bundle.localizedString(forKey: key, value: key, table: "Localizable")
        return String(format: template, locale: Locale(identifier: snapshot.language), arguments: values)
    }
}
