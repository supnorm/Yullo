import AppKit

// Global actions must not replace a surface while its modal interaction owns
// the user's focus. Menu tracking and text composition are separate concerns.
enum AppModalPolicy {
    @MainActor static func blocksNewAction(modalWindow: NSWindow?, ownedWindows: [NSWindow?]) -> Bool {
        windowToRaise(modalWindow: modalWindow, ownedWindows: ownedWindows) != nil
    }

    // Show may raise an existing interaction without replacing it. Prefer the
    // actual app-modal owner, otherwise the deepest owned sheet.
    @MainActor static func windowToRaise(modalWindow: NSWindow?, ownedWindows: [NSWindow?]) -> NSWindow? {
        if let modalWindow { return modalWindow }
        for owner in ownedWindows {
            guard var sheet = owner?.attachedSheet else { continue }
            var seen = Set([ObjectIdentifier(sheet)])
            while let nested = sheet.attachedSheet, seen.insert(ObjectIdentifier(nested)).inserted { sheet = nested }
            return sheet
        }
        return nil
    }
}
