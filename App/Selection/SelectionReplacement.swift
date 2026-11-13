import Foundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CryptoKit
import OSLog

private let selectionReplacementLogger = Logger(subsystem: "me.yullo.app", category: "SelectionReplacement")

// Replacing text is deliberately narrower than pasting. It can write only the
// exact selection captured by SelectionReader. Native controls use AXSelectedText;
// web editors use the shared verified paste route, chosen before any mutation.
// Unsupported destinations receive a copy-only fallback in the UI.
enum SelectionReplacement {
    // `notAnswering`: the app didn't answer within the read timeout. After a quiet spell a
    // browser rebuilds its accessibility tree on the next request, so the first reply can be
    // late. Replacement asks again before any write; it never leaves `replace`.
    enum Issue: Error, Equatable {
        case staleSelection, unsupported, permission, failed, uncertain, focusUnavailable, notAnswering
        // Failures that may pass on another try of the same selection. Before the write they leave
        // the lease in place; once the write has begun, the lease is consumed and no try can follow.
        // A changed selection is not one: selecting it again means leaving the review.
        static let retryable: Set<Issue?> = [.focusUnavailable, .failed]
    }

    private static let worker = DispatchQueue(label: "yullo.selection-accessibility", qos: .userInitiated)
    private static let backend = AXSelectionReplacementBackend()
    private static let session = SelectionReplacementSession(backend: backend)
    // A late-copy watch ends as soon as Yullo reads, replaces or inserts again.
    private static let lateCopyWatch = SelectionLateCopyWatch()
    static func endLateCopyWatch() { lateCopyWatch.end() }

    // Await a GCD worker without occupying a cooperative Swift task thread.
    static func capture(in processID: Int32? = nil) async -> SelectionReader.Result? {
        await captureOutcome(in: processID).selection
    }
    // Empty only when the focused text says nothing is selected; anything Yullo can't
    // read is unreadable, so "Select text first" never shows while text is selected.
    static func captureOutcome(in processID: Int32? = nil) async -> SelectionReader.Outcome {
        lateCopyWatch.end()
        await CommandKeyCodes.refresh()
        return await SelectionCaptureWorker.run(on: worker) { cancellation -> SelectionReader.Outcome? in
            session.invalidate()
            defer { if cancellation.isCancelled { session.invalidate() } }
            guard !cancellation.isCancelled, backend.isTrusted else { return nil }
            // Failure-only category; never log captured text or identifiers.
            var stage = "focus"
            var focused: AXUIElement?
            do {
                let element = try SelectionCaptureTarget.resolve(
                    in: processID, backend: backend, cancellation: cancellation)
                focused = element
                stage = "protection"
                guard !cancellation.isCancelled, try !backend.isProtected(element) else { return nil }
                stage = "selected-text"
                let selection = try SelectionCaptureText.read(
                    selectedText: { try backend.selectedText(element) },
                    markerText: {
                        stage = "marker-text"
                        return try backend.selectedMarkerText(element)
                    })
                guard !cancellation.isCancelled,
                    !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    guard !cancellation.isCancelled else { return nil }
                    selectionReplacementLogger.notice("Capture found stage=empty-selection")
                    let range = try? backend.selectedRange(element, allowCaret: true)
                    return .forEmptyText(selectedLength: range?.length)
                }
                // Marker text is a read-only page selection: translate it, never
                // replace it, unless the page is an editable document (Mail's body).
                let delivery = AXTextDeliveryBackend()
                let editableDocument = !selection.replaceable && delivery.isEditableWebArea(element)
                // Readable but known read-only text (a chat answer, a page) is
                // never offered for replacement: it carries no write token.
                // The text shown and sent keeps its lines; the write lease keeps
                // the exact published selection it validates against.
                func readable(_ range: NSRange?) -> String {
                    func blocks() -> String {
                        backend.selectionWithBlockBreaks(element, selected: selection.text, cancellation: cancellation)
                            ?? selection.text
                    }
                    guard selection.replaceable, let range else { return blocks() }
                    let lined = backend.selectionWithLineBreaks(element, selected: selection.text, range: range)
                    // Chrome leaves a code editor's blank lines out of both texts, and
                    // CodeMirror (Overleaf) shows some source as widgets; the editor's
                    // own Copy has the source. Used only when it is this selection.
                    guard lined != nil || backend.isCodeEditor(element), let target = try? backend.processID(element),
                        case .text(let copied) = borrowCopy(from: target, cancellation: cancellation),
                        SelectionCaptureText.editorCopy(copied, matches: selection.text)
                    else { return lined ?? blocks() }
                    return copied
                }
                if selection.replaceable, backend.writable(element) == false {
                    let range = try? backend.selectedRange(element)
                    let bounds = backend.bounds(element, range: range)
                    guard !cancellation.isCancelled else { return nil }
                    return .selection(SelectionReader.Result(text: readable(range), bounds: bounds))
                }
                guard selection.replaceable || editableDocument else {
                    let bounds = backend.selectedMarkerBounds(element)
                    let text = readable(nil)
                    guard !cancellation.isCancelled else { return nil }
                    return .selection(SelectionReader.Result(text: text, bounds: bounds))
                }
                let range =
                    editableDocument
                    ? (try? delivery.caretRange(of: element)) ?? nil : try? backend.selectedRange(element)
                guard !cancellation.isCancelled else { return nil }
                let bounds = backend.bounds(element, range: range)
                guard !cancellation.isCancelled else { return nil }
                var token: UUID?
                if let range, let processID = try? backend.processID(element) {
                    token = session.remember(element: element, processID: processID, text: selection.text, range: range)
                }
                let text = readable(range)
                return .selection(
                    SelectionReader.Result(
                        text: text, bounds: bounds, replacementToken: token,
                        endBounds: range.flatMap { backend.endBounds(element, range: $0) }))
            } catch {
                guard !cancellation.isCancelled, !(error is CancellationError) else { return nil }
                let issue = (error as? Issue).map { "\($0)" } ?? "failed"
                selectionReplacementLogger.error(
                    "Capture failed stage=\(stage, privacy: .public) issue=\(issue, privacy: .public)")
                // No published selection (PDFs in Safari and Chrome, an empty Preview
                // page): ask the app itself to copy it. Never after a protection
                // check failed, a permission change or a stale handle.
                guard let copy = SelectionCopyCapture.permission(afterStage: stage, issue: error as? Issue),
                    focused.map({ SelectionCopyCapture.copies(fromRole: backend.role($0)) }) ?? true
                else { return nil }
                return copiedOutcome(
                    in: processID, emptyMeansNothingSelected: copy.emptyMeansNothingSelected, cancellation: cancellation
                )
            }
        } ?? .unreadable
    }

    // Read-only text from the app's own Copy command. It never carries a write token.
    private static func copiedOutcome(
        in processID: Int32?, emptyMeansNothingSelected: Bool, cancellation: SelectionReplacementCancellation
    ) -> SelectionReader.Outcome? {
        guard let target = processID ?? (try? backend.frontmostProcessID()) else { return nil }
        let result = borrowCopy(from: target, cancellation: cancellation)
        guard !cancellation.isCancelled else { return nil }
        switch result {
        case .text(let text): return .selection(SelectionReader.Result(text: text, bounds: nil))
        case .nothingCopied:
            selectionReplacementLogger.notice("Capture found stage=copy-empty")
            return emptyMeansNothingSelected ? .empty : nil
        case .unavailable:
            selectionReplacementLogger.error("Capture failed stage=copy issue=unavailable")
            return nil
        }
    }

    // The app's own Copy, with the owner's clipboard put back. Only the app's
    // own late copy is undone: the watch ends once that app leaves the front
    // (the owner may copy elsewhere), once the owner presses a key or clicks
    // (their own Copy is theirs), or when Yullo acts again.
    private static func borrowCopy(from target: Int32, cancellation: SelectionReplacementCancellation)
        -> SelectionCopyCapture.Result
    {
        let watch = lateCopyWatch.current
        let owner = OwnerInputWatch()
        return SelectionCopyCapture.run(
            clipboard: SelectionCopySystemClipboard(), cancellation: cancellation,
            watchLate: { worker.async(execute: $0) },
            keepWatching: {
                lateCopyWatch.current == watch
                    && NSWorkspace.shared.frontmostApplication?.processIdentifier == target
                    && !owner.acted()
            }, prepare: { backend.canPostCopy(to: target) },
            copy: { backend.postCopy(to: target) })
    }

    static func replace(
        token: UUID, with text: String,
        restoreFocus: @escaping @MainActor @Sendable (Int32) async -> Bool = { await restoreApplicationFocus($0) }
    ) async throws -> Int32 {
        lateCopyWatch.end()
        await CommandKeyCodes.refresh()
        let cancellation = SelectionReplacementCancellation(cancelled: Task.isCancelled)
        return try await withTaskCancellationHandler(
            operation: {
                do {
                    return try await SelectionReplacementFocusRecovery.run(
                        cancellation: cancellation, readinessTimeout: replacementReadiness,
                        attempt: { restoringFocus in
                            try await withCheckedThrowingContinuation { continuation in
                                worker.async {
                                    continuation.resume(
                                        with: Result {
                                            try session.replace(
                                                token: token, with: text, cancellation: cancellation,
                                                requireFrontmostApplication: restoringFocus)
                                        })
                                }
                            }
                        },
                        capturedProcessID: {
                            await withCheckedContinuation { continuation in
                                worker.async {
                                    continuation.resume(returning: session.recoverableProcessID(for: token))
                                }
                            }
                        }, restoreFocus: restoreFocus)
                } catch {
                    // A check that failed before the write keeps the lease: Replace can be pressed
                    // again, and every try re-checks the exact selection first. Anything else ends it.
                    if !Issue.retryable.contains(error as? Issue) {
                        await withCheckedContinuation { continuation in
                            worker.async {
                                session.invalidate(if: token)
                                continuation.resume()
                            }
                        }
                    }
                    if error as? Issue == .focusUnavailable {
                        selectionReplacementLogger.error("Replacement failed stage=focus-unavailable")
                    }
                    throw error
                }
            }, onCancel: { cancellation.cancel() })
    }

    // An app waking its accessibility tree can take more than one 0.5 s read to answer.
    static let replacementReadiness: TimeInterval = 2

    @MainActor static func restoreApplicationFocus(_ processID: Int32) async -> Bool {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard !Task.isCancelled, processID > 0,
            front == ProcessInfo.processInfo.processIdentifier || front == processID,
            let application = NSRunningApplication(processIdentifier: processID), !application.isTerminated
        else { return false }
        return application.activate()
    }

    static func invalidate() { worker.async { session.invalidate() } }
    static func invalidate(if token: UUID) { worker.async { session.invalidate(if: token) } }
    // A review still in use keeps its lease; the exact selection is still checked at the write.
    static func renew(_ token: UUID) { worker.async { session.renew(token) } }
    // Whether the lease can still be written: not consumed, invalidated or expired.
    static func holds(_ token: UUID) async -> Bool {
        await withCheckedContinuation { continuation in
            worker.async { continuation.resume(returning: session.recoverableProcessID(for: token) != nil) }
        }
    }
}

// Missing background-app focus is recoverable before a write. Activation is not
// evidence of a destination: every retry runs the original exact validation.
enum SelectionReplacementFocusRecovery {
    static func run<Value>(
        cancellation: SelectionReplacementCancellation,
        readinessTimeout: TimeInterval = 0.5,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        pause: (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000))
        },
        attempt: (Bool) async throws -> Value,
        capturedProcessID: () async -> Int32?,
        restoreFocus: @MainActor (Int32) async -> Bool
    ) async throws -> Value {
        try cancellation.check()
        do { return try await attempt(false) } catch SelectionReplacement.Issue.focusUnavailable {}
        try cancellation.check()
        // A consumed/expired target cannot regain authority through activation.
        guard let processID = await capturedProcessID() else { throw SelectionReplacement.Issue.focusUnavailable }
        try cancellation.check()
        guard await restoreFocus(processID) else { throw SelectionReplacement.Issue.focusUnavailable }
        try cancellation.check()
        let deadline = now() + max(0, readinessTimeout)
        var firstRead = true
        while firstRead || now() < deadline {
            firstRead = false
            try cancellation.check()
            do { return try await attempt(true) } catch SelectionReplacement.Issue.focusUnavailable {}
            try cancellation.check()
            guard await capturedProcessID() == processID else { throw SelectionReplacement.Issue.focusUnavailable }
            let remaining = deadline - now()
            guard remaining > 0 else { break }
            try await pause(min(0.025, remaining))
        }
        throw SelectionReplacement.Issue.focusUnavailable
    }
}

// These small types are independent of AX so the checks can be tested without
// permission, real documents, a pasteboard, or synthetic keyboard events.
struct SelectionReplacementState {
    var processID: Int32
    var selectedText: String
    var range: NSRange
    var isProtected = false
    var isEditable = true
    var isEnabled = true
    var supportsReplacement = true
    var prefersPaste = false
    // Recovery-only guard; the normal background-capable AX path is unchanged.
    var requiresFrontmostApplication = false
}

protocol SelectionReplacementBackend {
    associatedtype Element
    var isTrusted: Bool { get }
    func focusedElement(in processID: Int32) throws -> Element
    func frontmostProcessID() throws -> Int32?
    func matches(_ lhs: Element, _ rhs: Element) -> Bool
    func state(of element: Element) throws -> SelectionReplacementState
    func selection(of element: Element) throws -> (text: String, range: NSRange)
    func write(_ text: String, to element: Element, expected: SelectionReplacementState) throws
}

extension SelectionReplacementBackend {
    func frontmostProcessID() throws -> Int32? { nil }
}

// An AX setter can return success without changing an editor. Confirm the
// exact bounded result in the captured field before dismissing the translation.
// Post-write caret normalization or a missing caret does not invalidate text.
// Whole-field text stays on the AX worker for this single operation only.
struct SelectionReplacementAcknowledgement {
    struct Receipt {
        let processID: Int32
        let valueFingerprint: Data
    }
    let processID: Int32
    let range: NSRange
    let valueFingerprint: Data
    static func fingerprint(_ value: String) -> Data { Data(SHA256.hash(data: Data(value.utf8))) }

    init(text: String, original: String, expected: SelectionReplacementState) throws {
        guard expected.processID > 0, !text.isEmpty, text.utf8.count <= 256 * 1_024,
            original.utf8.count <= 256 * 1_024, expected.range.location != NSNotFound,
            expected.range.location >= 0, expected.range.length > 0,
            expected.range.location <= Int.max - expected.range.length,
            let selection = TextMutationRange.validated(expected.range, in: original),
            TextMutationRange.identical(String(original[selection]), expected.selectedText),
            expected.range.location <= Int.max - text.utf16.count
        else {
            throw SelectionReplacement.Issue.unsupported
        }
        let result = (original as NSString).replacingCharacters(in: expected.range, with: text)
        guard !TextMutationRange.identical(result, original), result.utf8.count <= 256 * 1_024 else {
            throw SelectionReplacement.Issue.unsupported
        }
        processID = expected.processID
        range = NSRange(location: expected.range.location + text.utf16.count, length: 0)
        valueFingerprint = Self.fingerprint(result)
    }

    func wait(
        timeout: TimeInterval = 1.2, now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        read: () throws -> Receipt
    ) throws {
        let deadline = now() + timeout
        // As in TextDelivery, the budget stops new polls, not an exact
        // captured-field receipt from a read already in flight.
        while now() < deadline {
            if let receipt = try? read(), receipt.processID == processID,
                receipt.valueFingerprint == valueFingerprint
            {
                return
            }
            let remaining = deadline - now()
            if remaining <= 0 { break }
            pause(min(0.025, remaining))  // Serial AX worker only.
        }
        // The editor may still apply a delayed write. Never try another method.
        throw SelectionReplacement.Issue.uncertain
    }
}

protocol SelectionCaptureBackend {
    associatedtype Element
    func systemFocusedElement() throws -> Element
    func focusedElement(in processID: Int32) throws -> Element
    func processID(_ element: Element) throws -> Int32
}

enum SelectionCaptureTarget {
    // WebKit builds a process's accessibility tree on its first request and
    // briefly reports no focused element (measured at about 40-60 ms). Only that
    // reply is retried, within a short bound, for the same requested process.
    static func resolve<Backend: SelectionCaptureBackend>(
        in processID: Int32?, backend: Backend, cancellation: SelectionReplacementCancellation = .init(),
        readinessTimeout: TimeInterval = 0.25, now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }  // Serial AX worker only.
    ) throws -> Backend.Element {
        guard let processID else { return try backend.systemFocusedElement() }
        guard processID > 0 else { throw SelectionReplacement.Issue.staleSelection }
        let deadline = now() + max(0, readinessTimeout)
        while true {
            try cancellation.check()
            do {
                let element = try backend.focusedElement(in: processID)
                guard try backend.processID(element) == processID else {
                    throw SelectionReplacement.Issue.staleSelection
                }
                return element
            } catch SelectionReplacement.Issue.focusUnavailable {
                try cancellation.check()
                let remaining = deadline - now()
                guard remaining > 0 else { throw SelectionReplacement.Issue.focusUnavailable }
                pause(min(0.025, remaining))
            }
        }
    }
}

// Text controls publish AXSelectedText. A web document's ordinary page
// selection (a mail body or browser page) is published only as a text-marker
// range. That marker string is the selection itself, never whole-field text,
// and it has no UTF-16 field range, so it carries no replacement authority.
enum SelectionCaptureText {
    // Whether a selection can be written back, decided when it is captured:
    // false when its text is known not to be settable or the element says it
    // isn't editable; nil when the app doesn't say (a failed write then copies).
    static func writable(selectedTextSettable: Bool?, editable: Bool?) -> Bool? {
        if selectedTextSettable == false || editable == false { return false }
        return selectedTextSettable
    }
    // When the full state can't be read: whether the element is somewhere one
    // types at all. A web page's own area (Chrome publishes its selected text)
    // is not, unless it is an editable document.
    static func typable(role: String?, editable: Bool?, insideEditor: Bool, editableDocument: Bool, settable: Bool)
        -> Bool
    {
        if editable == false { return false }
        if editable == true || insideEditor || editableDocument || settable { return true }
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"].contains(role ?? "")
    }
    static func read(selectedText: () throws -> String, markerText: () throws -> String) throws
        -> (text: String, replaceable: Bool)
    {
        do { return (try selectedText(), true) } catch SelectionReplacement.Issue.unsupported {
            return (try markerText(), false)
        }
    }
    // The editor's own copy of a selection: the text shown, with at most
    // source the editor shows another way (a widget) or line breaks added.
    static func editorCopy(_ copied: String, matches shown: String) -> Bool {
        let copy = Array(TextDeliveryAcknowledgement.unbroken(copied).unicodeScalars)
        let seen = Array(TextDeliveryAcknowledgement.unbroken(shown).unicodeScalars)
        guard !seen.isEmpty, copy.count <= seen.count + max(64, seen.count / 2) else { return false }
        var index = 0
        for scalar in copy where index < seen.count && scalar == seen[index] { index += 1 }
        return index == seen.count
    }
    // Chrome publishes a code editor's selection (CodeMirror, Overleaf) in its
    // text-marker space, which has no line breaks between the editor's line
    // blocks; the field's AXValue has them. Read the selection back out of
    // AXValue so it keeps its lines. Nil when the two already agree, or when
    // AXValue is not the marker text plus line breaks.
    static func withLineBreaks(selected: String, range: NSRange, value: String, markers: String) -> String? {
        func holds(_ text: String) -> Bool {
            guard let span = TextMutationRange.validated(range, in: text) else { return false }
            return TextMutationRange.identical(String(text[span]), selected)
        }
        guard range.length > 0, !holds(value), holds(markers) else { return nil }
        let field = Array(value.utf16), marked = Array(markers.utf16)
        var offsets = [Int](repeating: 0, count: marked.count)
        var index = 0
        for (position, unit) in marked.enumerated() {
            while index < field.count, field[index] != unit, field[index] == 10 { index += 1 }
            guard index < field.count, field[index] == unit else { return nil }
            offsets[position] = index
            index += 1
        }
        guard field[index...].allSatisfy({ $0 == 10 }) else { return nil }
        let lower = offsets[range.location], upper = offsets[NSMaxRange(range) - 1] + 1
        return String(utf16CodeUnits: Array(field[lower..<upper]), count: upper - lower)
    }
}

// Chrome and apps built on it publish a page selection as the bare text of its
// pieces: a heading runs into the paragraph under it, list items, table cells
// and lines that wrap lose the space or break between them. Each piece's own
// layout still says where it ends, so put back the break the page shows.
// WebKit's string already carries them and is left as it is.
struct SelectionTextRun: Equatable {
    var text: String
    // The paragraph ends with this piece (a heading, list item, cell or any
    // other block, however the page draws it); nil when that can't be told.
    var endsParagraph: Bool?
    var cell: Int?
    var row: Int?
    // Where the piece starts and ends on screen, when known.
    var top: Double?
    var bottom: Double?
}

enum SelectionBlockText {
    // The selection with its breaks, or nil when the pieces don't spell out
    // the selected text or nothing is missing. selectionOffset is where the
    // selection starts in the pieces as the app counts it; a line break the
    // app already published (a <br>) is in the selection but in no piece.
    static func separated(_ selected: String, runs: [SelectionTextRun], selectionOffset: Int) -> String? {
        let whole = Array(runs.map(\.text).joined().utf16)
        let chosen = Array(selected.utf16)
        guard !chosen.isEmpty, selectionOffset >= 0 else { return nil }
        func align(from lower: Int) -> [Int?]? {
            var index = lower
            var mapping: [Int?] = []
            mapping.reserveCapacity(chosen.count)
            for unit in chosen {
                if index < whole.count, whole[index] == unit {
                    mapping.append(index)
                    index += 1
                } else if unit == 10 {
                    mapping.append(nil)
                } else {
                    return nil
                }
            }
            return mapping
        }
        let highest = min(selectionOffset, whole.count)
        guard
            let mapping = stride(from: highest, through: max(0, highest - 64), by: -1).lazy.compactMap(align).first,
            mapping.contains(where: { $0 != nil })
        else { return nil }
        var starts: [Int: Int] = [:]
        var position = 0
        for (index, run) in runs.enumerated() {
            if index > 0 { starts[position] = index }
            position += run.text.utf16.count
        }
        var result: [UInt16] = []
        result.reserveCapacity(chosen.count + 16)
        for (index, unit) in chosen.enumerated() {
            if index > 0, let at = mapping[index], mapping[index - 1] != nil, let following = starts[at],
                let separator = separator(after: runs[following - 1], before: runs[following], whole: whole, at: at)
            {
                result.append(contentsOf: separator.utf16)
            }
            result.append(unit)
        }
        guard result.count != chosen.count else { return nil }
        return String(utf16CodeUnits: result, count: result.count)
    }

    private static func separator(
        after run: SelectionTextRun, before next: SelectionTextRun, whole: [UInt16], at position: Int
    ) -> String? {
        let before = String(utf16CodeUnits: [whole[position - 1]], count: 1)
        let after = String(utf16CodeUnits: [whole[position]], count: 1)
        let spaced = { (text: String) in
            text.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
        }
        guard !spaced(before), !spaced(after), let endsParagraph = run.endsParagraph else { return nil }
        if endsParagraph {
            if let cell = run.cell, let following = next.cell, cell != following, run.row != nil, run.row == next.row {
                return "\t"
            }
            return "\n"
        }
        // Same paragraph: only a line that wrapped here lost its space.
        guard let top = next.top, let bottom = run.bottom, top >= bottom - 1 else { return nil }
        let unspaced = { (text: String) in text.unicodeScalars.allSatisfy(writesWithoutSpaces) }
        return unspaced(before) && unspaced(after) ? nil : " "
    }

    // Scripts that wrap between characters with no space: Chinese, Japanese,
    // Thai, Lao, Khmer and Myanmar.
    static func writesWithoutSpaces(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF, 0x2E80...0x2FDF, 0x3000...0x30FF,
            0x3100...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF,
            0x20000...0x3FFFF:
            return true
        default: return false
        }
    }
}

// Some document viewers show a selection they never publish to Accessibility
// (PDFs in Safari and Chrome). Their own Copy command still has it: copy once,
// read the text, then put the clipboard back unless something newer replaced it.
protocol SelectionCopyClipboard {
    associatedtype Snapshot
    var changeCount: Int { get }
    // Plain text only: copied files (Finder) and concealed items (passwords) are
    // never a text selection.
    var copiedText: String? { get }
    func snapshot() throws -> Snapshot
    func restore(_ snapshot: Snapshot) throws
}
// The owner's clipboard is written back marked transient (see SystemDeliveryClipboard).
struct SelectionCopySystemClipboard: SelectionCopyClipboard {
    private let system = SystemDeliveryClipboard()
    var changeCount: Int { system.changeCount }
    var copiedText: String? { system.copiedText }
    func snapshot() throws -> SystemDeliveryClipboard.Snapshot { try system.snapshot() }
    func restore(_ snapshot: SystemDeliveryClipboard.Snapshot) throws { try system.restore(snapshot) }
}

enum SelectionCopyCapture {
    enum Result: Equatable { case text(String), nothingCopied, unavailable }

    struct Permission: Equatable { let emptyMeansNothingSelected: Bool }
    // Only "no selection published" may copy: no focused element, no selected text
    // or marker range, or a viewer that answers no queries at all (Quick Look).
    // Protection, permission and stale-handle failures never do. Nothing copied is
    // "nothing selected" only when the app itself answered.
    static func permission(afterStage stage: String, issue: SelectionReplacement.Issue?) -> Permission? {
        switch (stage, issue) {
        case ("focus", .focusUnavailable?), ("selected-text", .unsupported?), ("marker-text", .unsupported?):
            Permission(emptyMeansNothingSelected: true)
        case ("focus", .failed?), ("focus", .notAnswering?): Permission(emptyMeansNothingSelected: false)
        default: nil
        }
    }
    // A focused list, table or grid holds items, not text: Command-C there copies
    // files (Finder) or cells (Numbers), so it is never sent.
    static func copies(fromRole role: String?) -> Bool {
        let collections: Set<String> = [
            kAXOutlineRole, kAXListRole, kAXTableRole, kAXBrowserRole, kAXGridRole, kAXRowRole, kAXColumnRole,
            kAXCellRole
        ]
        return role.map { !collections.contains($0) } ?? true
    }

    // `prepare` confirms the app may be sent Command-C before the owner's
    // clipboard is read at all; `copy` sends it. Once it is sent, a busy app can
    // still copy after the wait or a cancel: `watchLate` keeps watching for a
    // while (on the caller's worker) and puts the owner's clipboard back then.
    static func run<Clipboard: SelectionCopyClipboard>(
        clipboard: Clipboard, cancellation: SelectionReplacementCancellation = .init(), timeout: TimeInterval = 0.6,
        lateWait: TimeInterval = 1.5, settle: TimeInterval = 0.15, settleLimit: TimeInterval = 0.6,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        pause: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },  // Serial AX worker only.
        watchLate: (@escaping () -> Void) -> Void = { $0() }, keepWatching: @escaping () -> Bool = { true },
        prepare: () -> Bool = { true }, copy: () -> Bool
    ) -> Result {
        guard !cancellation.isCancelled, prepare() else { return .unavailable }
        let before = clipboard.changeCount
        // A clipboard that can't be restored exactly is never borrowed.
        guard let snapshot = try? clipboard.snapshot(), clipboard.changeCount == before,
            !cancellation.isCancelled, copy()
        else { return .unavailable }
        let deadline = now() + timeout
        while clipboard.changeCount == before, now() < deadline, !cancellation.isCancelled {
            pause(min(0.02, max(0, deadline - now())))
        }
        guard clipboard.changeCount != before else {
            let lateDeadline = now() + lateWait
            watchLate {
                while clipboard.changeCount == before, now() < lateDeadline, keepWatching() {
                    pause(min(0.02, max(0, lateDeadline - now())))
                }
                guard clipboard.changeCount != before else { return }
                let copied = settled(clipboard, settle: settle, limit: settleLimit, now: now, pause: pause)
                // A copy the owner made meanwhile is theirs to keep.
                if clipboard.changeCount == copied, keepWatching() { try? clipboard.restore(snapshot) }
            }
            return .nothingCopied
        }
        let copied = settled(clipboard, settle: settle, limit: settleLimit, now: now, pause: pause)
        let text = clipboard.copiedText
        if clipboard.changeCount == copied, keepWatching() { try? clipboard.restore(snapshot) }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .nothingCopied }
        return .text(text)
    }
    // Some apps write a copy in several steps (Quick Look writes twice). Restore
    // only once the clipboard has been still for a moment, or a late write
    // would replace the owner's restored clipboard.
    private static func settled<Clipboard: SelectionCopyClipboard>(
        _ clipboard: Clipboard, settle: TimeInterval, limit: TimeInterval, now: () -> TimeInterval,
        pause: (TimeInterval) -> Void
    ) -> Int {
        var copied = clipboard.changeCount, still = now()
        let deadline = now() + limit
        while now() < deadline, now() - still < settle {
            pause(min(0.02, max(0, deadline - now())))
            if clipboard.changeCount != copied { (copied, still) = (clipboard.changeCount, now()) }
        }
        return copied
    }
}

final class SelectionLateCopyWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    var current: Int { lock.withLock { generation } }
    func end() { lock.withLock { generation += 1 } }
}

final class SelectionReplacementCancellation: @unchecked Sendable {
    private enum State { case pending, cancelled, committed }
    private let lock = NSLock()
    private var state: State
    init(cancelled: Bool = false) { state = cancelled ? .cancelled : .pending }
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .cancelled
    }
    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        if state == .pending { state = .cancelled }
    }
    func check() throws {
        if isCancelled { throw CancellationError() }
    }
    func performMutation(_ body: () throws -> Void) throws {
        // Cancellation and the start of the single write have one ordering. An
        // AX write already in flight cannot be undone, so its outcome is returned.
        lock.lock()
        let mayStart = state == .pending
        if mayStart { state = .committed }
        lock.unlock()
        guard mayStart else { throw CancellationError() }
        // Never hold the lock during an AX round trip: cancelling from the main
        // thread must not wait for another app to answer.
        try body()
    }
}

enum SelectionCaptureWorker {
    static func run<Value>(on worker: DispatchQueue, _ body: @escaping (SelectionReplacementCancellation) -> Value?)
        async -> Value?
    {
        let cancellation = SelectionReplacementCancellation(cancelled: Task.isCancelled)
        return await withTaskCancellationHandler(
            operation: {
                await withCheckedContinuation { continuation in
                    enqueue(
                        on: worker, cancellation: cancellation, body, completion: { continuation.resume(returning: $0) }
                    )
                }
            }, onCancel: { cancellation.cancel() })
    }

    static func enqueue<Value>(
        on worker: DispatchQueue, cancellation: SelectionReplacementCancellation,
        _ body: @escaping (SelectionReplacementCancellation) -> Value?, completion: @escaping (Value?) -> Void
    ) {
        worker.async {
            guard !cancellation.isCancelled else {
                completion(nil)
                return
            }
            let result = body(cancellation)
            completion(cancellation.isCancelled ? nil : result)
        }
    }
}

final class SelectionReplacementSession<Backend: SelectionReplacementBackend> {
    private struct Target {
        let token: UUID
        let element: Backend.Element
        let processID: Int32
        let text: String
        let range: NSRange
        let created: TimeInterval
    }
    private let backend: Backend
    private let now: () -> TimeInterval
    private let lifetime: TimeInterval
    private var target: Target?
    // Limit temporary retained source and replacement text to 256 KiB each.
    static var maximumBytes: Int { 256 * 1_024 }

    init(
        backend: Backend, lifetime: TimeInterval = 600,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.backend = backend
        self.lifetime = lifetime
        self.now = now
    }

    func invalidate() { target = nil }
    func invalidate(if token: UUID) { if target?.token == token { target = nil } }
    // The lifetime counts from the latest use of the lease, not from the capture.
    func renew(_ token: UUID) {
        guard let current = target, current.token == token, now() >= current.created,
            now() - current.created <= lifetime
        else { return }
        target = Target(
            token: token, element: current.element, processID: current.processID, text: current.text,
            range: current.range, created: now())
    }

    func recoverableProcessID(for token: UUID) -> Int32? {
        guard let target, target.token == token,
            now() >= target.created, now() - target.created <= lifetime
        else { return nil }
        return target.processID
    }

    func remember(element: Backend.Element, processID: Int32, text: String, range: NSRange) -> UUID? {
        target = nil
        guard processID > 0, !text.isEmpty, text.utf8.count <= Self.maximumBytes,
            range.location != NSNotFound, range.location >= 0, range.length > 0,
            range.location <= Int.max - range.length, text.utf16.count == range.length
        else { return nil }
        let token = UUID()
        target = Target(token: token, element: element, processID: processID, text: text, range: range, created: now())
        return token
    }

    // A read the app didn't answer, before any write, is asked again as missing focus is,
    // within the same bound and with the same validation; during the write it is a failure.
    func replace(
        token: UUID, with text: String, cancellation: SelectionReplacementCancellation = .init(),
        requireFrontmostApplication: Bool = false
    ) throws -> Int32 {
        var writing = false
        do {
            return try replaceOnce(
                token: token, with: text, cancellation: cancellation,
                requireFrontmostApplication: requireFrontmostApplication, writing: &writing)
        } catch SelectionReplacement.Issue.notAnswering {
            throw writing ? SelectionReplacement.Issue.failed : SelectionReplacement.Issue.focusUnavailable
        }
    }

    private func replaceOnce(
        token: UUID, with text: String, cancellation: SelectionReplacementCancellation,
        requireFrontmostApplication: Bool, writing: inout Bool
    ) throws -> Int32 {
        // Failure-only metadata; never log captured text, ranges, identifiers or hashes.
        var failureStage = "token"
        var pidMatch = false
        var rangeMatch = false
        var selectedTextMatch = false
        var completed = false
        defer {
            // The AX backend owns diagnostics after the single mutation starts.
            if !completed, failureStage != "write", failureStage != "focus-unavailable", !cancellation.isCancelled {
                if failureStage == "state-match" {
                    selectionReplacementLogger.error(
                        "Replacement failed stage=state-match pidMatch=\(pidMatch, privacy: .public) rangeMatch=\(rangeMatch, privacy: .public) selectedTextMatch=\(selectedTextMatch, privacy: .public)"
                    )
                } else if failureStage == "final-selection-match" {
                    selectionReplacementLogger.error(
                        "Replacement failed stage=final-selection-match rangeMatch=\(rangeMatch, privacy: .public) selectedTextMatch=\(selectedTextMatch, privacy: .public)"
                    )
                } else {
                    selectionReplacementLogger.error("Replacement failed stage=\(failureStage, privacy: .public)")
                }
            }
        }
        try cancellation.check()
        guard let captured = target, captured.token == token else {
            throw SelectionReplacement.Issue.staleSelection
        }
        failureStage = "expiry"
        guard now() >= captured.created, now() - captured.created <= lifetime else {
            target = nil
            throw SelectionReplacement.Issue.staleSelection
        }
        failureStage = "replacement-input"
        guard !text.isEmpty, text.utf8.count <= Self.maximumBytes else { throw SelectionReplacement.Issue.unsupported }
        failureStage = "permission"
        guard backend.isTrusted else { throw SelectionReplacement.Issue.permission }
        func readFocusedElement() throws -> Backend.Element {
            do { return try backend.focusedElement(in: captured.processID) } catch SelectionReplacement.Issue
                .focusUnavailable
            {
                failureStage = "focus-unavailable"
                throw SelectionReplacement.Issue.focusUnavailable
            }
        }
        if requireFrontmostApplication {
            failureStage = "recovery-foreground"
            let front = try backend.frontmostProcessID()
            try cancellation.check()
            if front != captured.processID {
                if front == nil || front == ProcessInfo.processInfo.processIdentifier {
                    failureStage = "focus-unavailable"
                    throw SelectionReplacement.Issue.focusUnavailable
                }
                throw SelectionReplacement.Issue.staleSelection
            }
        }
        failureStage = "focus-read"
        let focused = try readFocusedElement()
        try cancellation.check()
        failureStage = "focused-handle"
        guard backend.matches(focused, captured.element) else { throw SelectionReplacement.Issue.staleSelection }
        failureStage = "state-read"
        var state = try backend.state(of: captured.element)
        state.requiresFrontmostApplication = requireFrontmostApplication || state.prefersPaste
        try cancellation.check()
        failureStage = "state-match"
        pidMatch = state.processID == captured.processID
        rangeMatch = state.range == captured.range
        selectedTextMatch = TextMutationRange.identical(state.selectedText, captured.text)
        guard pidMatch else { throw SelectionReplacement.Issue.staleSelection }
        failureStage = "capability"
        guard !state.isProtected, state.isEnabled, state.isEditable, state.supportsReplacement else {
            throw SelectionReplacement.Issue.unsupported
        }
        func waitForSettlingSelection(text: String, range: NSRange) throws {
            guard requireFrontmostApplication, text.isEmpty, range.location >= 0,
                range.location != NSNotFound, range.length == 0,
                try backend.frontmostProcessID() == captured.processID
            else { return }
            try cancellation.check()
            failureStage = "focus-unavailable"
            throw SelectionReplacement.Issue.focusUnavailable
        }
        failureStage = "state-match"
        guard rangeMatch, selectedTextMatch else {
            try waitForSettlingSelection(text: state.selectedText, range: state.range)
            throw SelectionReplacement.Issue.staleSelection
        }
        // A web paste needs actual keyboard focus even when the app publishes
        // a readable background AX selection. Request the same bounded recovery
        // before consuming the token; never post keys into another foreground app.
        if state.prefersPaste {
            failureStage = "paste-foreground"
            let front = try backend.frontmostProcessID()
            try cancellation.check()
            if front != captured.processID {
                if front == nil || front == ProcessInfo.processInfo.processIdentifier {
                    failureStage = "focus-unavailable"
                    throw SelectionReplacement.Issue.focusUnavailable
                }
                throw SelectionReplacement.Issue.staleSelection
            }
        }
        // A new focus change during the state reads must not redirect the write.
        failureStage = "final-focus-read"
        let stillFocused = try readFocusedElement()
        try cancellation.check()
        failureStage = "final-focused-handle"
        guard backend.matches(stillFocused, captured.element) else { throw SelectionReplacement.Issue.staleSelection }
        failureStage = "final-selection-read"
        let selection = try backend.selection(of: captured.element)
        try cancellation.check()
        failureStage = "final-selection-match"
        selectedTextMatch = TextMutationRange.identical(selection.text, captured.text)
        rangeMatch = selection.range == captured.range
        guard selectedTextMatch, rangeMatch else {
            try waitForSettlingSelection(text: selection.text, range: selection.range)
            throw SelectionReplacement.Issue.staleSelection
        }
        failureStage = "final-expiry"
        guard now() >= captured.created, now() - captured.created <= lifetime else {
            target = nil
            throw SelectionReplacement.Issue.staleSelection
        }
        failureStage = "write"
        writing = true
        try cancellation.performMutation {
            // Consume before the call: an AX timeout can mean that the remote app
            // wrote successfully but its reply was lost. Retrying must never write twice.
            target = nil
            try backend.write(text, to: captured.element, expected: state)
        }
        completed = true
        return captured.processID
    }
}

private final class AXSelectionReplacementBackend: SelectionReplacementBackend, SelectionCaptureBackend {
    typealias Element = AXUIElement
    var isTrusted: Bool { AXIsProcessTrusted() }
    private let timeout: Float = 0.5

    private func configure(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    private func read(_ element: AXUIElement, _ attribute: String) throws -> CFTypeRef {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success, let value else { throw issue(error) }
        return value
    }

    private func issue(_ error: AXError) -> SelectionReplacement.Issue {
        switch error {
        case .apiDisabled: return .permission
        case .attributeUnsupported, .parameterizedAttributeUnsupported, .notImplemented, .noValue: return .unsupported
        case .invalidUIElement: return .staleSelection
        case .cannotComplete: return .notAnswering
        default: return .failed
        }
    }

    private func element(_ value: CFTypeRef) throws -> AXUIElement {
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw SelectionReplacement.Issue.staleSelection }
        return configure(unsafeBitCast(value, to: AXUIElement.self))
    }

    func systemFocusedElement() throws -> AXUIElement {
        try element(read(configure(AXUIElementCreateSystemWide()), kAXFocusedUIElementAttribute))
    }

    func focusedElement(in processID: Int32) throws -> AXUIElement {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            configure(AXUIElementCreateApplication(processID)), kAXFocusedUIElementAttribute as CFString, &value)
        if error == .noValue || error == .attributeUnsupported || error == .notImplemented
            || (error == .success && value == nil)
        {
            throw SelectionReplacement.Issue.focusUnavailable
        }
        guard error == .success, let value else { throw issue(error) }
        return try element(value)
    }

    func frontmostProcessID() throws -> Int32? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            configure(AXUIElementCreateSystemWide()), kAXFocusedApplicationAttribute as CFString, &value)
        if error == .noValue || (error == .success && value == nil) { return nil }
        guard error == .success, let value else { throw issue(error) }
        return try processID(element(value))
    }

    func matches(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool { AXFieldIdentity.matches(lhs, rhs) }

    // Asked of the app itself: the system-wide focused application is not always answered.
    private func isFrontmost(_ processID: Int32) -> Bool {
        var value: CFTypeRef?
        let app = configure(AXUIElementCreateApplication(processID))
        guard AXUIElementCopyAttributeValue(app, kAXFrontmostAttribute as CFString, &value) == .success else {
            // Quick Look's panel answers no queries; the workspace still knows who is in front.
            return NSWorkspace.shared.frontmostApplication?.processIdentifier == processID
        }
        return value as? Bool == true
    }

    // Command-C goes only to the app the shortcut was pressed in, while it is in
    // front and no password field holds secure input. Checked before the owner's
    // clipboard is read, after the shortcut's own modifiers are released so the
    // app sees plain Command-C.
    func canPostCopy(to processID: Int32) -> Bool {
        let held: CGEventFlags = [.maskControl, .maskShift, .maskAlternate, .maskCommand]
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        while !CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty,
            ProcessInfo.processInfo.systemUptime < deadline
        {
            Thread.sleep(forTimeInterval: 0.02)  // AX worker only.
        }
        return processID > 0 && processID != ProcessInfo.processInfo.processIdentifier
            && !IsSecureEventInputEnabled() && isFrontmost(processID)
    }
    // Secure input is checked again right before posting.
    func postCopy(to processID: Int32) -> Bool {
        let key = CommandKeyCodes.copy
        guard !IsSecureEventInputEnabled(),
            let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(processID)
        up.postToPid(processID)
        return true
    }

    func processID(_ element: AXUIElement) throws -> Int32 {
        var pid: pid_t = 0
        let error = AXUIElementGetPid(element, &pid)
        guard error == .success, pid > 0 else { throw issue(error) }
        return pid
    }

    // The same state the replacement itself checks, read at capture.
    // Replace is offered only where one can type: a page, a chat answer or a
    // document viewer that publishes its selection is never written to.
    func writable(_ element: AXUIElement) -> Bool? {
        guard let state = try? state(of: element) else {
            return SelectionCaptureText.typable(
                role: role(element), editable: try? optionalBool(element, kAXIsEditableAttribute),
                insideEditor: (try? optionalRead(element, "AXEditableAncestor")) != nil,
                editableDocument: AXTextDeliveryBackend().isEditableWebArea(element),
                settable: [kAXSelectedTextAttribute, kAXValueAttribute].contains { name in
                    var settable = DarwinBoolean(false)
                    return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success
                        && settable.boolValue
                }) ? nil : false
        }
        return SelectionCaptureText.writable(
            selectedTextSettable: state.supportsReplacement, editable: state.isEditable && state.isEnabled)
    }

    func selectedText(_ element: AXUIElement) throws -> String {
        guard let text = try read(element, kAXSelectedTextAttribute) as? String else {
            throw SelectionReplacement.Issue.unsupported
        }
        return text
    }

    func selectedMarkerText(_ element: AXUIElement) throws -> String {
        let range = try read(element, "AXSelectedTextMarkerRange")
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element, "AXStringForTextMarkerRange" as CFString, range, &value)
        guard error == .success else { throw issue(error) }
        guard let text = value as? String else { throw SelectionReplacement.Issue.unsupported }
        return text
    }

    // CodeMirror's editing surface (Overleaf, many web code editors).
    func isCodeEditor(_ element: AXUIElement) -> Bool {
        ((try? read(element, "AXDOMClassList")) as? [String])?.contains("cm-content") == true
    }

    func selectionWithLineBreaks(_ element: AXUIElement, selected: String, range: NSRange) -> String? {
        guard let field = try? value(element) else { return nil }
        var full: CFTypeRef?, text: CFTypeRef?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                element, "AXTextMarkerRangeForUIElement" as CFString, element, &full) == .success, let full,
            AXUIElementCopyParameterizedAttributeValue(element, "AXStringForTextMarkerRange" as CFString, full, &text)
                == .success, let markers = text as? String, markers.utf8.count <= 256 * 1_024
        else { return nil }
        return SelectionCaptureText.withLineBreaks(selected: selected, range: range, value: field, markers: markers)
    }

    // The breaks between the blocks of a page selection, read from the pieces
    // under the closest element that holds both of its ends. Bounded: a slow
    // or very large page keeps the text as published.
    func selectionWithBlockBreaks(
        _ element: AXUIElement, selected: String, cancellation: SelectionReplacementCancellation
    ) -> String? {
        guard !selected.isEmpty, selected.utf16.count <= 64 * 1_024,
            let marked = try? optionalRead(element, "AXSelectedTextMarkerRange"),
            CFGetTypeID(marked) == AXTextMarkerRangeGetTypeID()
        else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.4
        func parameterized(_ name: String, _ parameter: CFTypeRef) -> CFTypeRef? {
            var result: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &result) == .success
            else { return nil }
            return result
        }
        func node(_ value: CFTypeRef?) -> AXUIElement? {
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return configure(unsafeBitCast(value, to: AXUIElement.self))
        }
        func length(_ from: CFTypeRef, _ to: CFTypeRef) -> Int? {
            if CFEqual(from, to) { return 0 }
            guard let range = parameterized("AXTextMarkerRangeForUnorderedTextMarkers", [from, to] as CFArray),
                let count = parameterized("AXLengthForTextMarkerRange", range) as? NSNumber
            else { return nil }
            return count.intValue
        }
        func attribute(_ item: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(item, name as CFString, &value) == .success ? value : nil
        }
        let selection = marked as! AXTextMarkerRange
        let start = AXTextMarkerRangeCopyStartMarker(selection), end = AXTextMarkerRangeCopyEndMarker(selection)
        guard let first = node(parameterized("AXUIElementForTextMarker", start)),
            let last = node(parameterized("AXUIElementForTextMarker", end))
        else { return nil }
        var lineage: [AXUIElement] = []
        var cursor: AXUIElement? = first
        while let current = cursor, lineage.count < 64 {
            lineage.append(current)
            if CFEqual(current, element) { break }
            cursor = node(attribute(current, kAXParentAttribute))
        }
        var holder: AXUIElement?
        cursor = last
        for _ in 0..<64 {
            guard let current = cursor else { break }
            if lineage.contains(where: { CFEqual($0, current) }) {
                holder = current
                break
            }
            cursor = node(attribute(current, kAXParentAttribute))
        }
        guard let holder, let span = parameterized("AXTextMarkerRangeForUIElement", holder),
            CFGetTypeID(span) == AXTextMarkerRangeGetTypeID(),
            let offset = length(AXTextMarkerRangeCopyStartMarker(span as! AXTextMarkerRange), start)
        else { return nil }
        // The pieces in reading order. A table also lists its cells by column;
        // those repeat the rows and are skipped.
        struct Piece {
            let element: AXUIElement
            let text: String
            let start: CFTypeRef
            let cell: Int?
            let row: Int?
        }
        var pieces: [Piece] = []
        var visited = 0, cells = 0, rows = 0
        func walk(_ item: AXUIElement, cell: Int?, row: Int?) -> Bool {
            visited += 1
            guard visited <= 4_000, ProcessInfo.processInfo.systemUptime < deadline, !cancellation.isCancelled
            else { return false }
            let role = attribute(item, kAXRoleAttribute) as? String
            if role == kAXColumnRole { return true }
            var cell = cell, row = row
            if role == kAXRowRole {
                rows += 1
                row = rows
            } else if role == kAXCellRole {
                cells += 1
                cell = cells
            }
            let children = (attribute(item, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            guard children.isEmpty else {
                return children.allSatisfy { walk(configure($0), cell: cell, row: row) }
            }
            guard let range = parameterized("AXTextMarkerRangeForUIElement", item),
                CFGetTypeID(range) == AXTextMarkerRangeGetTypeID(),
                let text = parameterized("AXStringForTextMarkerRange", range) as? String, !text.isEmpty
            else { return true }
            pieces.append(
                Piece(
                    element: item, text: text, start: AXTextMarkerRangeCopyStartMarker(range as! AXTextMarkerRange),
                    cell: cell, row: row))
            return true
        }
        guard walk(holder, cell: nil, row: nil), pieces.count > 1 else { return nil }
        // Layout is read only for the pieces the selection touches.
        let upper = offset + selected.utf16.count
        var position = 0
        var runs: [SelectionTextRun] = []
        for piece in pieces {
            let count = piece.text.utf16.count
            defer { position += count }
            var run = SelectionTextRun(
                text: piece.text, endsParagraph: nil, cell: piece.cell, row: piece.row)
            if position + count >= offset, position <= upper {
                guard ProcessInfo.processInfo.systemUptime < deadline, !cancellation.isCancelled else { return nil }
                if let close = parameterized("AXNextParagraphEndTextMarkerForTextMarker", piece.start),
                    let reach = length(piece.start, close)
                {
                    run.endsParagraph = reach <= count
                }
                var origin = CGPoint.zero, size = CGSize.zero
                if let position = attribute(piece.element, kAXPositionAttribute),
                    CFGetTypeID(position) == AXValueGetTypeID(),
                    let extent = attribute(piece.element, kAXSizeAttribute), CFGetTypeID(extent) == AXValueGetTypeID(),
                    AXValueGetValue(position as! AXValue, .cgPoint, &origin),
                    AXValueGetValue(extent as! AXValue, .cgSize, &size)
                {
                    run.top = origin.y
                    run.bottom = origin.y + size.height
                }
            }
            runs.append(run)
        }
        return SelectionBlockText.separated(selected, runs: runs, selectionOffset: offset)
    }

    func selectedRange(_ element: AXUIElement, allowCaret: Bool = false) throws -> NSRange {
        let value = try read(element, kAXSelectedTextRangeAttribute)
        guard CFGetTypeID(value) == AXValueGetTypeID() else { throw SelectionReplacement.Issue.unsupported }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range),
            range.location >= 0, range.length >= 0, allowCaret || range.length > 0,
            range.location <= Int.max - range.length
        else { throw SelectionReplacement.Issue.unsupported }
        return NSRange(location: range.location, length: range.length)
    }

    func selection(of element: AXUIElement) throws -> (text: String, range: NSRange) {
        do {
            return try (selectedText(element), selectedRange(element, allowCaret: true))
        } catch SelectionReplacement.Issue.unsupported {
            // Editable web documents (Mail's body) select through text markers.
            let delivery = AXTextDeliveryBackend()
            guard delivery.isEditableWebArea(element), let range = try? delivery.caretRange(of: element) else {
                throw SelectionReplacement.Issue.unsupported
            }
            return (try selectedMarkerText(element), range)
        }
    }

    private func optionalRead(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
        do { return try read(element, name) } catch SelectionReplacement.Issue.unsupported {
            return nil
        }  // A missing optional attribute is normal. A timeout, stale handle or
        // permission change must never be interpreted as "not protected".
        catch { throw error }
    }

    private func optionalBool(_ element: AXUIElement, _ name: String) throws -> Bool? {
        guard let value = try optionalRead(element, name) else { return nil }
        guard let result = value as? Bool else { throw SelectionReplacement.Issue.failed }
        return result
    }

    func role(_ element: AXUIElement) -> String? { (try? read(element, kAXRoleAttribute)) as? String }

    func isProtected(_ element: AXUIElement) throws -> Bool {
        guard let role = try read(element, kAXRoleAttribute) as? String else {
            throw SelectionReplacement.Issue.unsupported
        }
        let subrole = try optionalRead(element, kAXSubroleAttribute) as? String
        return try role == kAXSecureTextFieldSubrole || subrole == kAXSecureTextFieldSubrole
            || optionalBool(element, "AXProtectedContent") == true
    }

    func state(of element: AXUIElement) throws -> SelectionReplacementState {
        // Do not read protected content merely to validate a previous selection.
        guard try !isProtected(element) else {
            throw SelectionReplacement.Issue.unsupported
        }
        let process = try processID(element)
        let delivery = AXTextDeliveryBackend()
        if delivery.isWebEditor(element, processID: process) || delivery.isMobileApp(processID: process) {
            do {
                let state = try delivery.state(of: element)
                if TextDeliveryMutation.prefersPaste(in: state) {
                    return SelectionReplacementState(
                        processID: state.processID, selectedText: state.selectedText, range: state.range,
                        isProtected: state.isProtected, isEditable: state.isEditable, isEnabled: state.isEnabled,
                        supportsReplacement: true, prefersPaste: true)
                }
            } catch let error as TextDelivery.Issue { throw selectionIssue(error) }
        }
        var settable = DarwinBoolean(false)
        let capability = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        guard capability == .success else { throw issue(capability) }
        let editable = try optionalBool(element, kAXIsEditableAttribute) ?? settable.boolValue
        let enabled = try optionalBool(element, kAXEnabledAttribute) ?? true
        // Noncontiguous selections do not have a single unambiguous target.
        let ranges = try optionalRead(element, kAXSelectedTextRangesAttribute) as? [Any]
        return try SelectionReplacementState(
            processID: process, selectedText: selectedText(element), range: selectedRange(element, allowCaret: true),
            isEditable: editable, isEnabled: enabled,
            supportsReplacement: settable.boolValue && (ranges?.count ?? 1) == 1)
    }

    // Placement only: a missing rectangle falls back to the pointer.
    func bounds(_ element: AXUIElement, range: NSRange?) -> CGRect? {
        guard let range else { return nil }
        func rect(_ location: Int, _ length: Int) -> CGRect? {
            var cfRange = CFRange(location: location, length: length)
            guard let axRange = AXValueCreate(.cfRange, &cfRange) else { return nil }
            return parameterizedRect(element, kAXBoundsForRangeParameterizedAttribute, axRange)
        }
        // Some editors answer only for short ranges; the last line is still beside the selection.
        let whole = rect(range.location, range.length) ?? (range.length > 1 ? rect(NSMaxRange(range) - 1, 1) : nil)
        return SelectionGeometry.visible(whole, within: visibleFrames(element))
    }

    // The selection's last character, when it is in view.
    func endBounds(_ element: AXUIElement, range: NSRange) -> CGRect? {
        guard range.length > 0 else { return nil }
        var cfRange = CFRange(location: NSMaxRange(range) - 1, length: 1)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else { return nil }
        return SelectionGeometry.visible(
            parameterizedRect(element, kAXBoundsForRangeParameterizedAttribute, axRange), within: visibleFrames(element)
        )
    }

    func selectedMarkerBounds(_ element: AXUIElement) -> CGRect? {
        guard let range = try? read(element, "AXSelectedTextMarkerRange") else { return nil }
        return SelectionGeometry.visible(
            parameterizedRect(element, "AXBoundsForTextMarkerRange", range), within: visibleFrames(element))
    }

    // The field, the scroll area showing it and its window bound what is visible.
    private func visibleFrames(_ element: AXUIElement) -> [CGRect] {
        func frame(_ element: AXUIElement) -> CGRect? {
            var point = CGPoint.zero, size = CGSize.zero
            guard let position = try? read(element, kAXPositionAttribute),
                let dimensions = try? read(element, kAXSizeAttribute),
                CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(dimensions) == AXValueGetTypeID(),
                AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
                AXValueGetValue(unsafeBitCast(dimensions, to: AXValue.self), .cgSize, &size)
            else { return nil }
            return CGRect(origin: point, size: size)
        }
        func related(_ name: String) -> AXUIElement? {
            guard let value = try? read(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return nil
            }
            return configure(unsafeBitCast(value, to: AXUIElement.self))
        }
        let parent = related(kAXParentAttribute).flatMap { parent in
            (try? read(parent, kAXRoleAttribute)) as? String == kAXScrollAreaRole ? parent : nil
        }
        return [frame(element), parent.flatMap(frame), related(kAXWindowAttribute).flatMap(frame)].compactMap { $0 }
    }

    private func parameterizedRect(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef) -> CGRect? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success,
            let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgRect, &rect),
            rect.width > 0, rect.height > 0, rect.origin.x.isFinite, rect.origin.y.isFinite,
            rect.width.isFinite, rect.height.isFinite
        else { return nil }
        return rect
    }

    private func value(_ element: AXUIElement) throws -> String {
        guard let value = try read(element, kAXValueAttribute) as? String,
            value.utf8.count <= 256 * 1_024
        else { throw SelectionReplacement.Issue.unsupported }
        return value
    }

    private func selectionIssue(_ error: TextDelivery.Issue) -> SelectionReplacement.Issue {
        switch error {
        case .permission: return .permission
        case .unsupported: return .unsupported
        case .staleDestination: return .staleSelection
        case .failed: return .failed
        case .uncertain: return .uncertain
        }
    }

    func write(_ text: String, to element: AXUIElement, expected: SelectionReplacementState) throws {
        var failureStage = "write-protection-read"
        var pidMatch = false
        var rangeMatch = false
        var selectedTextMatch = false
        var completed = false
        defer {
            if !completed {
                if failureStage == "write-selection-match" {
                    selectionReplacementLogger.error(
                        "Replacement failed stage=write-selection-match pidMatch=\(pidMatch, privacy: .public) rangeMatch=\(rangeMatch, privacy: .public) selectedTextMatch=\(selectedTextMatch, privacy: .public)"
                    )
                } else {
                    selectionReplacementLogger.error("Replacement failed stage=\(failureStage, privacy: .public)")
                }
            }
        }
        guard try !isProtected(element) else { throw SelectionReplacement.Issue.unsupported }
        failureStage = "write-value-read"
        if expected.prefersPaste {
            // Editable web documents (Mail's message body) expose their text
            // through markers rather than AXValue.
            let original: String
            do {
                guard let text = try AXTextDeliveryBackend().fieldValue(element, processID: expected.processID) else {
                    throw SelectionReplacement.Issue.unsupported
                }
                original = text
            } catch let error as TextDelivery.Issue { throw selectionIssue(error) }
            failureStage = "web-paste"
            do {
                try AXTextDeliveryBackend().pasteReplacement(text, to: element, expected: expected, original: original)
            } catch let error as TextDelivery.Issue { throw selectionIssue(error) }
            completed = true
            return
        }
        let original = try value(element)
        failureStage = "write-expected-value"
        let acknowledgement = try SelectionReplacementAcknowledgement(
            text: text, original: original, expected: expected)
        failureStage = "write-focus-read"
        let focused = try focusedElement(in: expected.processID)
        failureStage = "write-selection-read"
        let latest = try selection(of: element)
        failureStage = "write-focused-handle"
        guard matches(focused, element) else { throw SelectionReplacement.Issue.staleSelection }
        failureStage = "write-pid-read"
        pidMatch = try processID(element) == expected.processID
        selectedTextMatch = TextMutationRange.identical(latest.text, expected.selectedText)
        rangeMatch = latest.range == expected.range
        failureStage = "write-selection-match"
        guard pidMatch, selectedTextMatch, rangeMatch else { throw SelectionReplacement.Issue.staleSelection }
        if expected.requiresFrontmostApplication {
            failureStage = "write-recovery-foreground"
            guard try frontmostProcessID() == expected.processID else {
                throw SelectionReplacement.Issue.staleSelection
            }
        }
        failureStage = "write-setter"
        let error = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
        guard error == .success else {
            if [.attributeUnsupported, .notImplemented, .apiDisabled].contains(error) { throw issue(error) }
            throw SelectionReplacement.Issue.uncertain
        }
        failureStage = "acknowledgement"
        try acknowledgement.wait {
            SelectionReplacementAcknowledgement.Receipt(
                processID: try self.processID(element),
                valueFingerprint: SelectionReplacementAcknowledgement.fingerprint(try self.value(element)))
        }
        completed = true
    }
}

// Whether the owner has pressed a key or clicked since a borrowed Copy began,
// from input timings only (nothing is posted or recorded). A shortcut key still
// held from the press that started it, and its repeats, never count: while a
// key was down at the start, a key counts only once one has been let go.
// Yullo's own Copy goes to the app directly and never counts.
final class OwnerInputWatch: @unchecked Sendable {
    // Seconds since the last input event of a type.
    typealias Since = (CGEventType) -> TimeInterval
    private let lock = NSLock()
    private let now: () -> TimeInterval
    private let since: Since
    private let start: TimeInterval
    private let heldAtStart: Bool
    private var released: TimeInterval?
    private var owned = false

    init(
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        since: @escaping Since = { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
    ) {
        self.now = now
        self.since = since
        start = now()
        heldAtStart = since(.keyDown) < since(.keyUp)
    }

    func acted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !owned else { return true }
        let time = now()
        func last(_ type: CGEventType) -> TimeInterval { time - since(type) }
        if last(.leftMouseDown) > start || last(.rightMouseDown) > start {
            owned = true
        } else if !heldAtStart {
            owned = last(.keyDown) > start
        } else {
            if released == nil, last(.keyUp) > start { released = last(.keyUp) }
            if let released, last(.keyDown) > released { owned = true }
        }
        return owned
    }
}
