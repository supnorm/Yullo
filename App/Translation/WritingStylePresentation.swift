import Foundation

enum WritingStylePresentation {
    static func title(_ style: RewriteStyle) -> String {
        switch style {
        case .professional: return L10n.tr("Professional")
        case .email: return L10n.tr("Email")
        case .concise: return L10n.tr("Concise")
        case .light: return L10n.tr("Light edit")
        case .casual: return L10n.tr("Casual message")
        case .polite: return L10n.tr("Polite reply")
        case .formal: return L10n.tr("Formal letter")
        case .plain: return L10n.tr("Plain language")
        case .bullets: return L10n.tr("Bullet notes")
        case .social: return L10n.tr("Social post")
        case .commit: return L10n.tr("Commit message")
        case .learner: return L10n.tr("Language learner")
        case .academic: return L10n.tr("Academic")
        case .instructed: return L10n.tr("Your instructions")
        }
    }

    static func detail(_ style: RewriteStyle) -> String {
        switch style {
        case .professional: return L10n.tr("Clear, professional wording.")
        case .email: return L10n.tr("Organized as an email body.")
        case .concise: return L10n.tr("Fewer words, same meaning.")
        case .light: return L10n.tr("Removes filler words and fixes grammar, keeping your meaning and tone.")
        case .casual: return L10n.tr("Relaxed and friendly, like a chat.")
        case .polite: return L10n.tr("Warmer wording, just as firm.")
        case .formal: return L10n.tr("Respectful wording for official messages.")
        case .plain: return L10n.tr("Short sentences and common words.")
        case .bullets: return L10n.tr("One bullet point per idea.")
        case .social: return L10n.tr("A short post in your own voice.")
        case .commit: return L10n.tr("A short imperative summary for code.")
        case .learner: return L10n.tr("Corrected as a native speaker would say it.")
        case .academic: return L10n.tr("Formal and precise, with citations and terms kept exactly.")
        case .instructed: return L10n.tr("Written the way your instructions describe.")
        }
    }
}
