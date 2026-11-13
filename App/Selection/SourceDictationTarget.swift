import AppKit

enum SourceVoiceState: Equatable { case idle, recording, paused, processing }
enum SourceDictationDelivery: Equatable { case inserted, stale, uncertain }
struct SourceDictationSnapshot {
    let text: String
    let revision: UInt64
    let context: UUID
}

// This destination never leaves the main actor or enters recognition/model
// inputs. It uses the app's native editor, without AX, key events or clipboard.
@MainActor final class SourceDictationTarget {
    private weak var model: Model?
    private weak var editor: NSTextView?
    private weak var window: NSWindow?
    private let snapshot: SourceDictationSnapshot
    private let selection: NSRange?
    private let hadEditor: Bool
    private let allowAppend: Bool
    private let available: () -> Bool
    private var claimed = false
    // Screen metadata is used only to position the HUD; it is never sent to
    // recognition, translation or the text-delivery worker.
    let caretBounds: CGRect?
    var currentCaretBounds: CGRect? {
        guard !claimed, let model, available(), let editor, let window,
            editor.window === window, editor.isEditable
        else { return nil }
        let current = model.captureSourceDictation()
        guard current.revision == snapshot.revision, current.context == snapshot.context,
            TextMutationRange.identical(current.text, snapshot.text)
        else { return nil }
        return Self.caretBounds(editor)
    }
    init(model: Model, editor: NSTextView?, allowAppend: Bool = false, available: @escaping () -> Bool) {
        self.model = model
        self.editor = editor
        self.window = editor?.window
        snapshot = model.captureSourceDictation()
        selection = editor?.selectedRange()
        hadEditor = editor != nil
        self.allowAppend = allowAppend
        self.available = available
        caretBounds = editor.flatMap(Self.caretBounds)
    }
    private static func caretBounds(_ editor: NSTextView) -> CGRect? {
        guard let window = editor.window else { return nil }
        let range = editor.selectedRange()
        guard TextMutationRange.validated(NSRange(location: range.location, length: 0), in: editor.string) != nil else {
            return nil
        }
        editor.layoutManager?.ensureLayout(forCharacterRange: NSRange(location: range.location, length: 0))
        var rect = editor.firstRect(forCharacterRange: NSRange(location: range.location, length: 0), actualRange: nil)
        if !VoiceCaretCoordinates.isValid(rect) {
            // A newly created/empty SwiftUI editor can defer its text layout.
            // Stay beside that input field instead of using the bottom bar.
            rect = window.convertToScreen(editor.convert(editor.visibleRect, to: nil))
        }
        return VoiceCaretCoordinates.accessibilityRect(
            fromAppKit: rect, primaryScreenTop: NSScreen.screens.first?.frame.maxY ?? 0)
    }
    func insert(_ text: String) -> SourceDictationDelivery {
        guard !claimed else { return .stale }
        claimed = true
        guard let model, available(), model.matchesSourceDictation(snapshot), !text.isEmpty,
            text.utf8.count <= 262_144
        else { return .stale }
        if hadEditor {
            guard let editor, let window, editor.window === window, editor.isEditable, editor.isEnabledForDictation,
                !editor.hasMarkedText(), TextMutationRange.identical(editor.string, snapshot.text), let selection,
                editor.selectedRange() == selection, TextMutationRange.validated(selection, in: snapshot.text) != nil
            else { return .stale }
            let expected = (snapshot.text as NSString).replacingCharacters(in: selection, with: text)
            guard expected.utf8.count <= 524_288 else { return .stale }
            let undo = editor.allowsUndo ? editor.undoManager : nil
            let registrationEnabled = undo?.isUndoRegistrationEnabled == true
            if registrationEnabled { undo?.disableUndoRegistration() }
            editor.insertText(text, replacementRange: selection)
            if registrationEnabled { undo?.enableUndoRegistration() }
            // A changed exact value confirms this owned editor's write even
            // when its caret lags or normalizes to a composed boundary. For an
            // unchanged replacement, retain the original caret evidence.
            guard editor.window === window, TextMutationRange.identical(editor.string, expected),
                !TextMutationRange.identical(expected, snapshot.text)
                    || editor.selectedRange() == NSRange(location: selection.location + text.utf16.count, length: 0)
            else { return .uncertain }
            // The SwiftUI delegate normally updates the binding synchronously.
            // Synchronize only the verified editor value if it is deferred.
            guard model.synchronizeSourceDictation(snapshot, expected: expected) else { return .uncertain }
            if registrationEnabled, let undo {
                SourceDictationUndo.register(
                    on: undo, model: model, editor: editor, snapshot: snapshot,
                    beforeRange: selection, inserted: text, after: expected, undoing: true)
            }
            return .inserted
        }
        // No native caret was available. Appending is the sole model fallback;
        // any intervening edit/context/window transition has already rejected it.
        guard allowAppend else { return .stale }
        let expected = snapshot.text + text
        guard expected.utf8.count <= 524_288 else { return .stale }
        model.source = expected
        return .inserted
    }
    static func editor(in window: NSWindow, matching text: String) -> NSTextView? {
        if let focused = window.firstResponder as? NSTextView, focused.isEditable,
            TextMutationRange.identical(focused.string, text), focused.window === window
        {
            return focused
        }
        var pending = window.contentView.map { [$0] } ?? [], matches: [NSTextView] = [], visited = 0
        while let view = pending.popLast(), visited < 4_096 {
            visited += 1
            if let editor = view as? NSTextView, editor.isEditable, TextMutationRange.identical(editor.string, text) {
                matches.append(editor)
            }
            pending.append(contentsOf: view.subviews)
        }
        return matches.count == 1 ? matches[0] : nil
    }
    static func hasEditableEditor(in window: NSWindow) -> Bool {
        var pending = window.contentView.map { [$0] } ?? [], visited = 0
        while let view = pending.popLast(), visited < 4_096 {
            visited += 1
            if let editor = view as? NSTextView, editor.isEditable { return true }
            pending.append(contentsOf: view.subviews)
        }
        return visited >= 4_096  // Unknown large hierarchy cannot authorize append.
    }
}

// A native programmatic edit does not reliably publish its binding on Undo.
// Own the whole transaction so a context change cannot leave an unguarded
// native undo action which edits the next draft behind the model's back.
@MainActor private final class SourceDictationUndo {
    private weak var manager: UndoManager?
    private weak var model: Model?
    private weak var editor: NSTextView?
    private weak var window: NSWindow?
    private let snapshot: SourceDictationSnapshot
    private let beforeRange: NSRange
    private let inserted: String
    private let after: String
    private let undoing: Bool
    private init(
        manager: UndoManager, model: Model, editor: NSTextView, snapshot: SourceDictationSnapshot,
        beforeRange: NSRange, inserted: String, after: String, undoing: Bool
    ) {
        self.manager = manager
        self.model = model
        self.editor = editor
        window = editor.window
        self.snapshot = snapshot
        self.beforeRange = beforeRange
        self.inserted = inserted
        self.after = after
        self.undoing = undoing
    }
    static func register(
        on manager: UndoManager, model: Model, editor: NSTextView, snapshot: SourceDictationSnapshot,
        beforeRange: NSRange, inserted: String, after: String, undoing: Bool
    ) {
        let action = SourceDictationUndo(
            manager: manager, model: model, editor: editor, snapshot: snapshot,
            beforeRange: beforeRange, inserted: inserted, after: after, undoing: undoing)
        // The app owns this NSObject target for its lifetime; the handler owns
        // its transaction. A temporary Swift-only target must not be passed as
        // Cocoa's weak undo target and released before the action is invoked.
        manager.registerUndo(withTarget: model) { _ in action.apply() }
        manager.setActionName(L10n.tr("Dictation"))
    }
    private func apply() {
        let current = undoing ? after : snapshot.text
        let expected = undoing ? snapshot.text : after
        guard let manager, let model, let editor, let window, editor.window === window,
            editor.isEditable, !editor.hasMarkedText(), model.hasSourceDictationContext(snapshot),
            TextMutationRange.identical(model.source, current), TextMutationRange.identical(editor.string, current)
        else { return }
        let replacementRange =
            undoing ? NSRange(location: beforeRange.location, length: inserted.utf16.count) : beforeRange
        let replacement = undoing ? (snapshot.text as NSString).substring(with: beforeRange) : inserted
        let selection =
            undoing ? beforeRange : NSRange(location: beforeRange.location + inserted.utf16.count, length: 0)
        let registrationEnabled = manager.isUndoRegistrationEnabled
        if registrationEnabled { manager.disableUndoRegistration() }
        editor.insertText(replacement, replacementRange: replacementRange)
        editor.setSelectedRange(selection)
        if registrationEnabled { manager.enableUndoRegistration() }
        guard TextMutationRange.identical(editor.string, expected),
            model.synchronizeSourceDictation(snapshot, from: current, expected: expected)
        else { return }
        Self.register(
            on: manager, model: model, editor: editor, snapshot: snapshot, beforeRange: beforeRange,
            inserted: inserted, after: after, undoing: !undoing)
    }
}

private extension NSTextView {
    var isEnabledForDictation: Bool { isSelectable && !isFieldEditor }
}
