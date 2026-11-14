import Foundation

// Curated product notes, shipped with the exact app build. Add a new entry and
// its seven-language resources when a build changes; never reuse older notes
// for an unknown version or invent a release date. The first version introduces
// the product instead of listing changes, so its link reads "Introducing Yullo".
enum ReleaseNotes {
    struct Feature: Equatable, Identifiable {
        let titleKey: String
        let detailKey: String
        var id: String { titleKey }
    }
    struct Entry: Equatable {
        let version: String
        let build: String
        let isPreview: Bool
        let titleKey: String
        let leadKey: String
        let features: [Feature]
        let closingKey: String
        var localizationKeys: [String] {
            [titleKey, leadKey, closingKey] + features.flatMap { [$0.titleKey, $0.detailKey] }
        }
    }
    static let entries: [Entry] = [
        .init(
            version: "1.0.1", build: "2", isPreview: false,
            titleKey: "What’s new",
            leadKey: "Yullo now works in more apps, and on a new Mac from the first launch.",
            features: [
                .init(
                    titleKey: "Replace in more apps",
                    detailKey:
                        "Replace now works in Chrome, Google Docs and Slides, Obsidian and other apps built on Chrome."),
                .init(
                    titleKey: "Codex and Claude Code",
                    detailKey:
                        "They work however you installed them, and your own instructions for them stay out of Yullo’s requests."
                ),
                .init(
                    titleKey: "Clearer messages",
                    detailKey:
                        "When something needs your help, Yullo says what to do, with a command to copy where one helps."
                ),
                .init(
                    titleKey: "Fix it where it stops",
                    detailKey:
                        "When something isn’t set up or allowed yet, one press takes you straight to the fix, such as allowing access to a saved key or downloading a model."
                ),
                .init(titleKey: "Your Mac’s language", detailKey: "A new install starts in your Mac’s language."),
                .init(
                    titleKey: "Apple Speech in Quick setup",
                    detailKey: "Quick setup downloads the language Apple Speech needs, without leaving the page."),
                .init(
                    titleKey: "A guide that sets you up",
                    detailKey:
                        "The first-run guide now takes you through translation, writing, permissions and dictation, lets you try them as you go, and reopens from the menu where you left off."
                )
            ],
            closingKey: "Your settings and history stay as they were."),
        .init(
            version: "1.0", build: "1", isPreview: false,
            titleKey: "Introducing Yullo",
            leadKey:
                "Yullo lives in your menu bar and helps you write, in any app, without leaving your work.",
            // What matters most first; the lead already says it works in any app.
            features: [
                .init(
                    titleKey: "Dictate",
                    detailKey: "Speak into any app, word for word or as an email, a note or a format of your own."),
                .init(
                    titleKey: "Refine",
                    detailKey: "Polish a draft or a translation in the style you choose, then compare before and after."
                ),
                .init(
                    titleKey: "Edit with voice or text",
                    detailKey: "Select text in any app, press a shortcut and say or type what to change."),
                .init(
                    titleKey: "Translate",
                    detailKey: "Type or paste in Yullo, or select text in any app, and replace it where you can type."),
                .init(
                    titleKey: "Read aloud",
                    detailKey: "Listen to any result with a Mac voice or a voice service you choose."),
                .init(
                    titleKey: "Where Yullo works",
                    detailKey: "Keep every task on this Mac, or allow the online services you choose.")
            ],
            closingKey: "Quick setup in Settings walks you through languages, voice access and a first dictation.")
    ]
    static func entry(version: String, build: String) -> Entry? {
        entries.first { $0.version == version && $0.build == build }
    }
}
