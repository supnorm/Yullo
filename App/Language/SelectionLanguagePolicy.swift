import Foundation

// Fresh-context direction rules use language codes only. Current-draft manual
// choices are guarded by Model; automatic suggestions never train themselves.
enum SelectionLanguagePolicy {
    static func personalizedTarget(
        detected: [String], enabled: [String], sourceSpecific: String?, global: String?,
        currentTarget: String, preferredTarget: String, interfaceLanguage: String
    ) -> String {
        let allowed = Set(enabled)
        let current = allowed.contains(currentTarget) ? currentTarget : (enabled.first ?? currentTarget)
        guard detected.count == 1, let source = detected.first else { return current }
        // A deliberate learned script conversion is meaningful. Ordinary
        // fallbacks prefer another language before another Chinese script.
        if let learned = sourceSpecific, learned != source, allowed.contains(learned) { return learned }
        // Then Your languages, top first.
        let choices = [current, global, preferredTarget, interfaceLanguage].compactMap { $0 } + enabled
        let differentLanguage = choices.first { !sameLanguageFamily($0, source) && allowed.contains($0) }
        return differentLanguage ?? choices.first { $0 != source && allowed.contains($0) } ?? current
    }
    private static func sameLanguageFamily(_ first: String, _ second: String) -> Bool {
        first == second || (["zh", "zh-Hant"].contains(first) && ["zh", "zh-Hant"].contains(second))
    }
}
