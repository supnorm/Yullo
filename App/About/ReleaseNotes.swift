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
