import Foundation

// Websites as dictation sees them: a host, read for one recording and never kept.
public enum CoreWebsite {
    // The browsers whose page address is read through Accessibility.
    public static let browserBundleIDs: Set<String> = [
        "com.apple.safari", "com.google.chrome", "company.thebrowser.browser", "com.microsoft.edgemac",
        "com.brave.browser", "org.mozilla.firefox"
    ]
    // Chromium browsers expose their pages to Accessibility only when asked.
    public static let chromiumBundleIDs: Set<String> = [
        "com.google.chrome", "company.thebrowser.browser", "com.microsoft.edgemac", "com.brave.browser"
    ]
    public static func isBrowser(_ bundleID: String?) -> Bool {
        bundleID.map { browserBundleIDs.contains($0.lowercased()) } ?? false
    }

    // A lowercase domain from what a person types or a page address: the host
    // only, without scheme, port, path, query, a leading "www." or a trailing dot.
    public static func domain(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, text.count <= 300 else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let components = URLComponents(string: text), let scheme = components.scheme,
            scheme == "http" || scheme == "https", var host = components.host, !host.isEmpty
        else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, host.count <= 253,
            labels.allSatisfy({ label in
                !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                    && label.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
            })
        else { return nil }
        return host
    }

    // A rule for a domain also covers its subdomains.
    public static func covers(_ domain: String, host: String) -> Bool {
        host == domain || host.hasSuffix("." + domain)
    }
}

// The app or website a rule is for.
public enum CoreOutputPlace: Hashable, Sendable {
    case app(String)
    case website(String)

    public init(_ rule: CoreOutputRule) {
        if let website = rule.website {
            self = .website(CoreWebsite.domain(website) ?? website.lowercased())
        } else {
            self = .app(rule.applicationBundleID.lowercased())
        }
    }
}

// "Made to fit you": a format for each kind of common app and website. Nothing
// is on until the person adds it; each place becomes an ordinary rule.
public enum CoreOutputKind: String, CaseIterable, Sendable {
    case chat, workChat, mail, notes, writing, code
    public var format: String {
        switch self {
        case .chat: return "casual"
        case .workChat: return "professional"
        case .mail: return "email"
        case .notes: return "bullets"
        case .writing: return "light"
        case .code: return "spoken"
        }
    }
}

public struct CoreOutputSuggestion: Equatable, Identifiable, Sendable {
    public enum Place: Equatable, Sendable {
        // Any one of these bundle identifiers; the first installed one is used.
        case app(name: String, bundleIDs: [String])
        case website(String)
    }
    public let kind: CoreOutputKind
    public let place: Place
    public var format: String { kind.format }
    public var id: String {
        switch place {
        case .app(_, let ids): return "app:" + (ids.first ?? "")
        case .website(let domain): return "site:" + domain
        }
    }

    // In each kind, apps first, then websites.
    public static let all: [Self] = [
        app(.chat, "Messages", ["com.apple.MobileSMS"]),
        app(.chat, "WhatsApp", ["net.whatsapp.WhatsApp", "desktop.WhatsApp"]),
        app(.chat, "Telegram", ["ru.keepcoder.Telegram", "org.telegram.desktop"]),
        app(.chat, "WeChat", ["com.tencent.xinWeChat"]),
        app(.chat, "Signal", ["org.whispersystems.signal-desktop"]),
        app(.chat, "Discord", ["com.hnc.Discord"]),
        site(.chat, "web.whatsapp.com"), site(.chat, "web.telegram.org"),
        app(.workChat, "Slack", ["com.tinyspeck.slackmacgap"]),
        app(.workChat, "Microsoft Teams", ["com.microsoft.teams2", "com.microsoft.teams"]),
        site(.workChat, "app.slack.com"), site(.workChat, "teams.microsoft.com"),
        app(.mail, "Mail", ["com.apple.mail"]),
        app(.mail, "Microsoft Outlook", ["com.microsoft.Outlook"]),
        app(.mail, "Spark", ["com.readdle.SparkDesktop", "com.readdle.smartemail-Mac"]),
        app(.mail, "Mimestream", ["com.mimestream.Mimestream"]),
        site(.mail, "mail.google.com"), site(.mail, "outlook.office.com"), site(.mail, "outlook.live.com"),
        app(.notes, "Notes", ["com.apple.Notes"]),
        app(.notes, "Notion", ["notion.id"]),
        app(.notes, "Obsidian", ["md.obsidian"]),
        app(.notes, "Bear", ["net.shinyfrog.bear"]),
        app(.writing, "Pages", ["com.apple.iWork.Pages"]),
        app(.writing, "Microsoft Word", ["com.microsoft.Word"]),
        site(.writing, "docs.google.com"), site(.writing, "notion.so"),
        app(.code, "Xcode", ["com.apple.dt.Xcode"]),
        app(.code, "Visual Studio Code", ["com.microsoft.VSCode"]),
        app(.code, "Terminal", ["com.apple.Terminal"]),
        app(.code, "Cursor", ["com.todesktop.230313mzl4w4u92"])
    ]

    private static func app(_ kind: CoreOutputKind, _ name: String, _ ids: [String]) -> Self {
        .init(kind: kind, place: .app(name: name, bundleIDs: ids))
    }
    private static func site(_ kind: CoreOutputKind, _ domain: String) -> Self {
        .init(kind: kind, place: .website(domain))
    }
}

extension CoreOutputSettings {
    // An installed suggestion's place: the app's identifier as found on this Mac, or the domain.
    public func isOn(_ place: CoreOutputPlace) -> Bool { rule(for: place)?.enabled == true }

    // Turning a suggestion on adds its rule, or turns on the row already there;
    // turning it off removes the row. Other rows stay as they are.
    public func setting(
        _ suggestion: CoreOutputSuggestion, place: CoreOutputPlace, name: String, on: Bool
    ) -> Self {
        var value = self
        if !on {
            value.rules.removeAll { CoreOutputPlace($0) == place }
            return value
        }
        if let index = value.rules.firstIndex(where: { CoreOutputPlace($0) == place }) {
            value.rules[index].enabled = true
            return value
        }
        let output = CoreOutput(format: suggestion.format)
        switch place {
        case .app(let id):
            value.rules.append(.init(applicationBundleID: id, applicationName: name, output: output))
        case .website(let domain):
            value.rules.append(.website(domain, output: output))
        }
        return value
    }
}

// The recording window's short format menu: What I say, Cleaned up, the
// format this recording resolved to, then the two most recent picks; More
// holds every other format, in the menu bar's groups.
public enum CorePillFormats {
    public static let pinned = ["spoken", "light"]
    public static let shownRecents = 2
    public static let keptRecents = 6

    public static func menu(
        resolved: String, recents: [String], groups: [[String]]
    ) -> (top: [String], more: [[String]]) {
        var top = pinned
        if !top.contains(resolved) { top.append(resolved) }
        let known = Set(groups.joined())
        top += recents.filter { known.contains($0) && !top.contains($0) }.reduce(into: [String]()) {
            if $0.count < shownRecents, !$0.contains($1) { $0.append($1) }
        }
        let more = groups.map { $0.filter { !top.contains($0) } }.filter { !$0.isEmpty }
        return (top, more)
    }

    // Most recent first, each format once.
    public static func remembering(_ format: String, in recents: [String]) -> [String] {
        Array(([format] + recents.filter { $0 != format }).prefix(keptRecents))
    }
}
