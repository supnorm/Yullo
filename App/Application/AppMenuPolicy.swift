import AppKit

// These commands publish their enabled state in menuNeedsUpdate. AppKit's
// automatic validation must not enable them again just because a target exists.
// The native Edit menu retains its separate automatic responder validation.
@MainActor enum AppMenuPolicy {
    static func managedMenu(title: String, delegate: any NSMenuDelegate) -> NSMenu {
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        menu.delegate = delegate
        return menu
    }
}
