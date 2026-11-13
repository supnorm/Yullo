import AppKit

// The app that opens mailto: links, offered for the one-click email preference.
// Identity and display name only; nothing about its windows or mail is read.
struct MailApplication: Equatable {
    let bundleID: String
    let name: String
}

@MainActor enum DefaultMailApplication {
    // Generated checks inject a fake; they never look up the real mail app.
    #if YULLO_TESTING
        static var resolve: () -> MailApplication? = { nil }
    #else
        static var resolve: () -> MailApplication? = live
    #endif
    static func live() -> MailApplication? {
        guard let mailto = URL(string: "mailto:"),
            let url = NSWorkspace.shared.urlForApplication(toOpen: mailto), let bundle = Bundle(url: url),
            let identifier = bundle.bundleIdentifier, identifier != Bundle.main.bundleIdentifier
        else { return nil }
        let name =
            (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let application = MailApplication(bundleID: identifier, name: boundedApplicationName(name))
        return application.name.isEmpty ? nil : application
    }
    // At most 128 scalars, without control or line-separator characters.
    private static func boundedApplicationName(_ value: String) -> String {
        String(
            String.UnicodeScalarView(
                value.unicodeScalars.prefix(128).filter {
                    $0.properties.generalCategory != .control && $0.properties.generalCategory != .lineSeparator
                        && $0.properties.generalCategory != .paragraphSeparator
                }))
    }
}
