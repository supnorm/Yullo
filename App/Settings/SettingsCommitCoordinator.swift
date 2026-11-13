import Foundation
import AppKit

// Every way out of Settings uses this owner. Finishing the native field editor
// first gives the same draft to Done, the red close button and global actions.
@MainActor final class SettingsCommitCoordinator {
    var finishEditing: (() -> Void)?
    var commitDraft: (() -> Bool)?
    var focusSearch: (() -> Void)?
    var isPresented: () -> Bool = { true }
    private var committing = false

    @discardableResult func commit() -> Bool {
        guard !committing else { return true }
        committing = true
        defer { committing = false }
        finishEditing?()
        return commitDraft?() ?? true
    }

    @discardableResult func perform(_ transition: () -> Void) -> Bool {
        guard commit() else { return false }
        transition()
        return true
    }

    func reset() {
        finishEditing = nil
        commitDraft = nil
        focusSearch = nil
        isPresented = { true }
    }

    // Closing or ordering out an NSWindow retains its hosting view. Detach it
    // after a successful commit so existing onDisappear owners cancel samples,
    // connection tests and pending setup application before the next session.
    func discardContent(in window: NSWindow) {
        window.contentView = nil
        reset()
    }
    func requestSearchFocus() -> Bool {
        guard isPresented(), let focusSearch else { return false }
        focusSearch()
        return true
    }
}

enum SettingsSearchShortcut {
    static func handle(_ event: NSEvent, settingsWindow: NSWindow?, keyWindow: NSWindow?, focus: () -> Bool) -> Bool {
        guard event.type == .keyDown, let settingsWindow, keyWindow === settingsWindow,
            event.window === settingsWindow,
            (settingsWindow.firstResponder as? ShortcutRecorder.KeyView)?.recording != true,
            event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command],
            event.charactersIgnoringModifiers?.lowercased() == "f"
        else { return false }
        return focus()
    }
}

struct SettingsCredential: Equatable {
    let account: String
    let value: String
}

// Never reads Keychain. The short-lived cache only remembers writes made by
// this Settings session, including writes completed before a later write fails.
// Retrying that commit therefore doesn't prompt/write again for unchanged keys.
@MainActor final class SettingsCredentialCommitter {
    private let write: (String, String) throws -> Void
    private var written: [String: String] = [:]

    init(
        write: @escaping (String, String) throws -> Void = { account, value in
            try KeyStore.write(value, endpoint: account)
        }
    ) { self.write = write }

    func commit(_ credentials: [SettingsCredential]) throws {
        for credential in credentials {
            let value = credential.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, written[credential.account] != value else { continue }
            try write(credential.account, value)
            written[credential.account] = value
        }
    }

    func forget(account: String) { written.removeValue(forKey: account) }

    func hasWritten(_ credential: SettingsCredential) -> Bool {
        written[credential.account] == credential.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
