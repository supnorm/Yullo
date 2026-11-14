import Foundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CryptoKit
import OSLog

private let textDeliveryLogger = Logger(subsystem: "me.yullo.app", category: "TextDelivery")
enum TextDeliveryFocusIssue: Error { case unavailable }

// Some apps (Mac Catalyst ones such as WhatsApp) hand out a new accessibility
// handle for the same text field on every query, so handle equality alone
// rejects the field that was captured. The same process, role, identifier and
// on-screen frame name the same field; the exact selection, range and receipt
// checks that follow still guard every write.
struct AXFieldIdentity: Equatable {
    let processID: Int32
    let role: String
    let identifier: String?
    let frame: CGRect
    static func same(_ lhs: Self?, _ rhs: Self?) -> Bool {
        guard let lhs, let rhs, lhs.processID > 0, lhs.frame.width > 0, lhs.frame.height > 0 else { return false }
        return lhs == rhs
    }
    static func matches(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        CFEqual(lhs, rhs) || same(read(lhs), read(rhs))
    }
    static func read(_ element: AXUIElement) -> Self? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0,
            let role = attribute(element, kAXRoleAttribute) as? String,
            let position = point(attribute(element, kAXPositionAttribute)),
            let size = size(attribute(element, kAXSizeAttribute))
        else { return nil }
        return .init(
            processID: pid, role: role, identifier: attribute(element, "AXIdentifier") as? String,
            frame: CGRect(origin: position, size: size))
    }
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private static func point(_ value: CFTypeRef?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgPoint, &point) ? point : nil
    }
    private static func size(_ value: CFTypeRef?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgSize, &size) ? size : nil
    }
}

private enum TextDeliveryPreparationFailure: String {
    case invalidInput, snapshotMismatch, unchangedResult, resultTooLarge
    case clipboardItemLimit, clipboardTypeLimit, clipboardPromisedData, clipboardDataUnavailable, clipboardByteLimit

    var issue: TextDelivery.Issue {
        textDeliveryLogger.error("Delivery preparation failed reason=\(rawValue, privacy: .public)")
        switch self {
        case .clipboardItemLimit, .clipboardTypeLimit, .clipboardPromisedData, .clipboardDataUnavailable,
            .clipboardByteLimit:
            return .failed  // No paste was posted; leave an unpreservable clipboard intact.
        default: return .unsupported
        }
    }
}

// A result that can't be written where the person asked is kept on the
// clipboard, and the notice says so. One helper for dictation, Refine in
// place and Edit with voice; test builds never reach the owner's clipboard.
enum DeliveryFallback {
    @discardableResult static func copy(_ text: String) -> Bool {
        clipboard.clearContents()
        return clipboard.setString(text, forType: .string)
    }
    #if YULLO_TESTING
        static let clipboard = NSPasteboard(name: .init("local.yullo.testing.delivery-fallback"))
    #else
        static var clipboard: NSPasteboard { .general }
    #endif
}

enum TextDeliveryClipboardBudget {
    // A Retina image commonly has both a large bitmap and a compressed flavor.
    // Bound retained payloads without spooling private clipboard data to disk.
    static let maximumBytes = 64 * 1_024 * 1_024

    static func appending(_ bytes: Int, to accumulated: Int) throws -> Int {
        guard accumulated >= 0, bytes >= 0, accumulated <= maximumBytes, bytes <= maximumBytes - accumulated else {
            throw TextDeliveryPreparationFailure.clipboardByteLimit.issue
        }
        return accumulated + bytes
    }
}

// Destination state stays on this worker. No selected text, field value,
// clipboard item or AX handle is passed to a model or the recording coordinator.
enum TextDelivery {
    struct Capture {
        let token: UUID
        let processID: Int32
        let caretBounds: CGRect?
    }
    // Public insertion failures other than uncertain are known not to have
    // changed the document. A write without a confirmed result must be
    // reported as uncertain, including errors while reading its receipt.
    enum Issue: Error, Equatable { case permission, unsupported, staleDestination, failed, uncertain }
    private static let worker = DispatchQueue(label: "yullo.voice-text-delivery", qos: .userInitiated)
    private static let session = TextDeliverySession(backend: AXTextDeliveryBackend())

    static func capture(in processID: Int32) async throws -> Capture {
        defer { worker.async { AccessibilityTreeWake.release() } }
        return try await recoveringFocus(capturedProcessID: { processID }) { restoring, cancellation in
            try session.capture(in: processID, cancellation: cancellation, requireFrontmostApplication: restoring)
        }
    }
    static func insert(_ text: String, token: UUID) async throws -> Int32 {
        defer { worker.async { AccessibilityTreeWake.release() } }
        SelectionReplacement.endLateCopyWatch()
        await CommandKeyCodes.refresh()
        do {
            return try await recoveringFocus(capturedProcessID: {
                await withCheckedContinuation { continuation in
                    worker.async { continuation.resume(returning: session.recoverableProcessID(for: token)) }
                }
            }) { restoring, cancellation in
                try session.insert(
                    text, token: token, cancellation: cancellation, requireFrontmostApplication: restoring)
            }
        } catch {
            await withCheckedContinuation { continuation in
                worker.async {
                    session.invalidate(if: token)
                    continuation.resume()
                }
            }
            throw error
        }
    }
    static func caretBounds(token: UUID) async -> CGRect? {
        try? await run { cancellation in try session.caretBounds(token: token, cancellation: cancellation) }
    }
    static func invalidate() { worker.async { session.invalidate() } }
    private static func recoveringFocus<Value>(
        capturedProcessID: @escaping () async -> Int32?,
        attempt: @escaping (Bool, SelectionReplacementCancellation) throws -> Value
    ) async throws -> Value {
        let cancellation = SelectionReplacementCancellation(cancelled: Task.isCancelled)
        return try await withTaskCancellationHandler(
            operation: {
                do {
                    return try await SelectionReplacementFocusRecovery.run(
                        cancellation: cancellation,
                        attempt: { restoring in
                            try await withCheckedThrowingContinuation { continuation in
                                worker.async {
                                    continuation.resume(
                                        with: Result {
                                            do {
                                                return try attempt(restoring, cancellation)
                                            } catch TextDeliveryFocusIssue.unavailable {
                                                throw SelectionReplacement.Issue.focusUnavailable
                                            }
                                        })
                                }
                            }
                        }, capturedProcessID: capturedProcessID,
                        restoreFocus: { await SelectionReplacement.restoreApplicationFocus($0) })
                } catch SelectionReplacement.Issue.focusUnavailable {
                    throw Issue.staleDestination
                }
            }, onCancel: { cancellation.cancel() })
    }
    private static func run<Value>(_ body: @escaping (SelectionReplacementCancellation) throws -> Value) async throws
        -> Value
    {
        let cancellation = SelectionReplacementCancellation(cancelled: Task.isCancelled)
        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    worker.async { continuation.resume(with: Result { try body(cancellation) }) }
                }
            }, onCancel: { cancellation.cancel() })
    }
}

struct TextDeliveryState: Equatable {
    var processID: Int32
    var range: NSRange
    var selectedText: String
    var valueFingerprint: Data? = nil
    var markerFingerprint: Data? = nil
    var isProtected = false
    var isEditable = true
    var isEnabled = true
    var supportsNativeInsertion = true
    var supportsPaste = false
    var prefersPaste = false
    // An empty field that reports its placeholder as its value.
    var showsPlaceholder = false
    var writable: Bool { !isProtected && isEditable && isEnabled && (supportsNativeInsertion || supportsPaste) }
    func sameDestination(as other: TextDeliveryState) -> Bool {
        processID == other.processID && range == other.range
            && TextMutationRange.identical(selectedText, other.selectedText)
            && sameContent(as: other)
    }
    func sameContent(as other: TextDeliveryState) -> Bool {
        markerFingerprint.flatMap { marker in other.markerFingerprint.map { marker == $0 } }
            ?? (valueFingerprint == nil || valueFingerprint == other.valueFingerprint)
    }
}

protocol TextDeliveryBackend {
    associatedtype Element
    var isTrusted: Bool { get }
    func focusedElement() throws -> Element
    func matches(_ lhs: Element, _ rhs: Element) -> Bool
    func state(of element: Element) throws -> TextDeliveryState
    func bounds(of element: Element, range: NSRange) -> CGRect?
    func caretRange(of element: Element) throws -> NSRange?
    func write(_ text: String, to element: Element, expected: TextDeliveryState) throws
    func processID(of element: Element) throws -> Int32?
    func frontmostProcessID() -> Int32?
    func canRestoreFocus(to processID: Int32, from element: Element?) -> Bool
}
extension TextDeliveryBackend {
    func caretRange(of element: Element) throws -> NSRange? { nil }
    func processID(of element: Element) throws -> Int32? { nil }
    func frontmostProcessID() -> Int32? { nil }
    func canRestoreFocus(to processID: Int32, from element: Element?) -> Bool { false }
}

// Some web/Electron editors reject a zero-length AXBoundsForRange request.
// Nearby glyph bounds are still a useful caret anchor; the focused field is
// the last resort. No field text is needed for these geometry-only queries.
enum TextDeliveryCaretBounds {
    static func resolve(
        range: NSRange, characterCount: Int?,
        readRange: (NSRange) -> CGRect?, readFrame: () -> CGRect?
    ) -> CGRect? {
        func valid(_ rect: CGRect?) -> CGRect? {
            guard let rect, rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite,
                rect.height.isFinite, rect.width >= 0, rect.height > 0, !rect.isNull
            else { return nil }
            return rect
        }
        guard range.location != NSNotFound, range.location >= 0 else { return nil }
        if let rect = valid(readRange(NSRange(location: range.location, length: 0))) { return rect }
        if range.location < Int.max, characterCount.map({ range.location < $0 }) ?? true,
            let rect = valid(readRange(NSRange(location: range.location, length: 1)))
        {
            return rect
        }
        if range.location > 0, let rect = valid(readRange(NSRange(location: range.location - 1, length: 1))) {
            return rect
        }
        return valid(readFrame())
    }
}

final class TextDeliverySession<Backend: TextDeliveryBackend> {
    private struct Target {
        let token: UUID
        let element: Backend.Element
        let state: TextDeliveryState
        let created: TimeInterval
    }
    private let backend: Backend
    private let now: () -> TimeInterval
    private let lifetime: TimeInterval
    private var target: Target?
    static var maximumBytes: Int { 256 * 1_024 }
    // Cover the 30-minute recording and bounded recognition/translation time.
    // A longer lifetime never permits a different editor or changed text state.
    init(
        backend: Backend, lifetime: TimeInterval = 3600,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.backend = backend
        self.lifetime = lifetime
        self.now = now
    }
    func invalidate() { target = nil }
    func invalidate(if token: UUID) { if target?.token == token { target = nil } }
    func recoverableProcessID(for token: UUID) -> Int32? {
        guard let captured = target, captured.token == token, now() >= captured.created,
            now() - captured.created <= lifetime
        else { return nil }
        return captured.state.processID
    }
    private func focusedElement(
        for processID: Int32, matching element: Backend.Element? = nil,
        requireFrontmostApplication: Bool = false
    ) throws -> Backend.Element {
        if let front = backend.frontmostProcessID(), front != processID {
            if backend.canRestoreFocus(to: processID, from: nil) { throw TextDeliveryFocusIssue.unavailable }
            throw stale("frontmost")
        }
        if requireFrontmostApplication, backend.frontmostProcessID() != processID {
            throw TextDeliveryFocusIssue.unavailable
        }
        let focused: Backend.Element
        do { focused = try backend.focusedElement() } catch {
            if let issue = error as? TextDelivery.Issue, issue == .permission { throw issue }
            if backend.canRestoreFocus(to: processID, from: nil) { throw TextDeliveryFocusIssue.unavailable }
            throw error
        }
        // Validate owner metadata before reading any field text. System focus
        // can briefly lag behind an application activation.
        if let owner = try backend.processID(of: focused), owner != processID {
            if backend.canRestoreFocus(to: processID, from: focused) { throw TextDeliveryFocusIssue.unavailable }
            throw stale("focus-process")
        }
        if let element, !backend.matches(focused, element) {
            if backend.canRestoreFocus(to: processID, from: focused) { throw TextDeliveryFocusIssue.unavailable }
            throw stale("element")
        }
        return focused
    }
    private func stale(
        _ stage: String, expected: TextDeliveryState? = nil,
        observed: TextDeliveryState? = nil
    ) -> TextDelivery.Issue {
        let difference: String
        if let expected, let observed {
            if expected.processID != observed.processID {
                difference = "process"
            } else if expected.range != observed.range {
                difference = "selection-range"
            } else if !TextMutationRange.identical(expected.selectedText, observed.selectedText) {
                difference = "selected-text"
            } else if let marker = expected.markerFingerprint, marker != observed.markerFingerprint {
                difference = "field-marker-value"
            } else if expected.valueFingerprint != observed.valueFingerprint {
                difference = "field-value"
            } else {
                difference = "capability"
            }
        } else {
            difference = "unavailable"
        }
        textDeliveryLogger.error(
            "Delivery target changed stage=\(stage, privacy: .public) difference=\(difference, privacy: .public)")
        return .staleDestination
    }
    // Geometry refresh never reads the field value or changes the captured
    // insertion state. A moved caret can move the HUD, but delivery still
    // rejects that changed destination instead of silently retargeting it.
    func caretBounds(token: UUID, cancellation: SelectionReplacementCancellation = .init()) throws -> CGRect? {
        try cancellation.check()
        guard let captured = target, captured.token == token, backend.isTrusted,
            now() >= captured.created, now() - captured.created <= lifetime
        else { return nil }
        let focused = try backend.focusedElement()
        try cancellation.check()
        guard backend.matches(focused, captured.element) else { return nil }
        let range = try backend.caretRange(of: captured.element) ?? captured.state.range
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
            range.location <= Int.max - range.length
        else { return nil }
        let bounds = backend.bounds(of: captured.element, range: range)
        try cancellation.check()
        let latest = try backend.focusedElement()
        guard backend.matches(latest, captured.element) else { return nil }
        return bounds
    }
    func capture(
        in processID: Int32, cancellation: SelectionReplacementCancellation = .init(),
        requireFrontmostApplication: Bool = false
    ) throws
        -> TextDelivery.Capture
    {
        target = nil
        try cancellation.check()
        guard backend.isTrusted else { throw TextDelivery.Issue.permission }
        guard processID > 0 else { throw TextDelivery.Issue.staleDestination }
        let element = try focusedElement(for: processID, requireFrontmostApplication: requireFrontmostApplication)
        try cancellation.check()
        let state = try backend.state(of: element)
        guard state.processID == processID else { throw stale("capture-process") }
        guard Self.valid(state), state.writable else {
            textDeliveryLogger.error(
                "Delivery capture unsupported valid=\(Self.valid(state), privacy: .public) native=\(state.supportsNativeInsertion, privacy: .public) paste=\(state.supportsPaste, privacy: .public) editable=\(state.isEditable, privacy: .public)"
            )
            throw TextDelivery.Issue.unsupported
        }
        let bounds = backend.bounds(of: element, range: state.range)
        try cancellation.check()
        let focused = try focusedElement(
            for: processID, matching: element,
            requireFrontmostApplication: requireFrontmostApplication)
        guard backend.matches(element, focused) else { throw stale("capture-element") }
        let latest = try backend.state(of: element)
        try cancellation.check()
        guard state.sameDestination(as: latest), latest.writable else {
            throw stale("capture-state", expected: state, observed: latest)
        }
        let token = UUID()
        target = Target(token: token, element: element, state: state, created: now())
        return TextDelivery.Capture(token: token, processID: processID, caretBounds: bounds)
    }
    func insert(
        _ text: String, token: UUID, cancellation: SelectionReplacementCancellation = .init(),
        requireFrontmostApplication: Bool = false
    ) throws -> Int32 {
        guard let captured = target, captured.token == token else { throw TextDelivery.Issue.staleDestination }
        var retainForFocusRecovery = false
        var mutationStarted = false
        defer { if !retainForFocusRecovery { target = nil } }
        do {
            try cancellation.check()
            guard !text.isEmpty, text.utf8.count <= Self.maximumBytes else { throw TextDelivery.Issue.unsupported }
            guard backend.isTrusted else { throw TextDelivery.Issue.permission }
            guard now() >= captured.created, now() - captured.created <= lifetime else {
                throw TextDelivery.Issue.staleDestination
            }
            let focused = try focusedElement(
                for: captured.state.processID, matching: captured.element,
                requireFrontmostApplication: requireFrontmostApplication)
            try cancellation.check()
            guard backend.matches(focused, captured.element) else { throw stale("insert-element") }
            let state = try backend.state(of: captured.element)
            try cancellation.check()
            guard state.writable else { throw TextDelivery.Issue.unsupported }
            func waitForSettlingSelection(_ observed: TextDeliveryState) throws {
                guard requireFrontmostApplication, Self.valid(observed), observed.writable,
                    observed.processID == captured.state.processID,
                    observed.range.length == 0, observed.selectedText.isEmpty,
                    captured.state.valueFingerprint != nil
                        || (captured.state.markerFingerprint != nil && observed.markerFingerprint != nil),
                    captured.state.sameContent(as: observed),
                    backend.frontmostProcessID() == captured.state.processID
                else { return }
                try cancellation.check()
                throw TextDeliveryFocusIssue.unavailable
            }
            guard Self.valid(state) else { throw stale("insert-state", expected: captured.state, observed: state) }
            // The person may click elsewhere in the same field or keep typing
            // while Yullo works. The same field with a collapsed caret takes the
            // text at that caret, as typing would; a new selection, another
            // field or another app never does.
            let followsCaret = !captured.state.sameDestination(as: state)
            if followsCaret {
                try waitForSettlingSelection(state)
                guard state.processID == captured.state.processID, Self.isCaret(state) else {
                    throw stale("insert-state", expected: captured.state, observed: state)
                }
            }
            let latestFocus = try focusedElement(
                for: captured.state.processID, matching: captured.element,
                requireFrontmostApplication: requireFrontmostApplication)
            try cancellation.check()
            guard backend.matches(latestFocus, captured.element) else { throw stale("prewrite-element") }
            let latest = try backend.state(of: captured.element)
            try cancellation.check()
            guard state.sameDestination(as: latest), followsCaret || captured.state.sameDestination(as: latest),
                latest.writable, now() >= captured.created, now() - captured.created <= lifetime
            else {
                if now() >= captured.created, now() - captured.created <= lifetime {
                    try waitForSettlingSelection(latest)
                }
                throw stale("prewrite-state", expected: state, observed: latest)
            }
            var admitted = latest
            // Content authority remains the original capture, even if a later
            // AXValue representation changed while the full marker text stayed exact.
            // A followed caret has only its two agreeing current reads.
            if !followsCaret {
                admitted.valueFingerprint = captured.state.valueFingerprint
                admitted.markerFingerprint = captured.state.markerFingerprint
            }
            try cancellation.performMutation {
                mutationStarted = true
                try backend.write(text, to: captured.element, expected: admitted)
            }
            return captured.state.processID
        } catch TextDeliveryFocusIssue.unavailable {
            if mutationStarted { throw TextDelivery.Issue.uncertain }
            retainForFocusRecovery = true
            throw TextDeliveryFocusIssue.unavailable
        }
    }
    // A caret to follow needs readable field content, so its receipt can be exact.
    private static func isCaret(_ state: TextDeliveryState) -> Bool {
        state.range.length == 0 && state.selectedText.isEmpty && state.writable
            && (state.valueFingerprint != nil || state.markerFingerprint != nil)
    }
    private static func valid(_ state: TextDeliveryState) -> Bool {
        state.processID > 0 && state.range.location != NSNotFound && state.range.location >= 0
            && state.range.length >= 0
            && state.range.location <= Int.max - state.range.length
            && state.selectedText.utf16.count == state.range.length
            && state.selectedText.utf8.count <= maximumBytes
    }
}

// Clipboard ownership is independent of AX and testable without touching the
// user's real clipboard. Restoration must never overwrite a newer user copy.
protocol TextDeliveryClipboard {
    associatedtype Snapshot
    var changeCount: Int { get }
    func snapshot() throws -> Snapshot
    func setText(_ text: String) throws
    func restore(_ snapshot: Snapshot) throws
}
struct TextDeliveryClipboardLease<Clipboard: TextDeliveryClipboard> {
    let clipboard: Clipboard
    let snapshot: Clipboard.Snapshot
    let ownedChange: Int
    init(clipboard: Clipboard, text: String) throws {
        self.clipboard = clipboard
        let originalChange = clipboard.changeCount
        snapshot = try clipboard.snapshot()
        guard clipboard.changeCount == originalChange else { throw TextDelivery.Issue.failed }
        try clipboard.setText(text)
        ownedChange = clipboard.changeCount
    }
    // Recheck after potentially slow AX validation, immediately before
    // queueing CmdV. This is a last ownership guard, not a global clipboard lock.
    func performIfOwned(validating: () throws -> Void = {}, _ action: () -> Void) throws {
        guard clipboard.changeCount == ownedChange else { throw TextDelivery.Issue.failed }
        try validating()
        guard clipboard.changeCount == ownedChange else { throw TextDelivery.Issue.failed }
        action()
    }
    func restoreIfOwned() throws {
        if clipboard.changeCount == ownedChange { try clipboard.restore(snapshot) }
    }
}

// AX success means that the application accepted a request, not that its editor
// changed. The ordinary receipt requires the exact complete captured-field
// value. Preferred web pastes also admit two bounded paragraph representations,
// each requiring its exact complete body and collapsed insertion caret.
struct TextDeliveryAcknowledgement {
    struct Receipt {
        let processID: Int32
        let valueFingerprint: Data
        // Only the final bounded read may be retained for failure diagnostics.
        // Never logged and never used as a weaker acknowledgement condition.
        var diagnosticValue: String? = nil
    }
    struct CaretReceipt {
        let processID: Int32
        let range: NSRange
    }
    let processID: Int32
    let range: NSRange
    let valueFingerprint: Data
    private let originalFingerprint: Data
    private let expectedValue: String
    private let insertedText: String
    private let webParagraphFingerprint: Data?
    private let webParagraphShape: String
    private let alternateValueFingerprint: Data?
    // Chrome's marker text has no line breaks between an editor's line blocks,
    // so pasted lines read back without the breaks they were pasted with. For a
    // preferred paste, marker text equal to the expected result apart from line
    // breaks, and different from the original apart from them, is this paste.
    private let alternateUnbroken: (expected: String, original: String)?
    // A field that showed only its placeholder holds exactly the inserted
    // text afterwards; the placeholder was never content.
    private let placeholderResultFingerprint: Data?
    // Web and Electron editors read back with invisible characters (U+FFFC
    // object markers, zero-width formatting) and reshaped whitespace. For a
    // preferred paste, a read whose visible text equals the requested result,
    // and differs from the original, is positive evidence of this one paste.
    private let visibleExpected: String?
    private let visibleOriginal: String
    private static let maximumBytes = 256 * 1_024
    static func fingerprint(_ value: String) -> Data { Data(SHA256.hash(data: Data(value.utf8))) }
    init(text: String, original: String, expected: TextDeliveryState, alternateOriginal: String? = nil) throws {
        guard expected.processID > 0, original.utf8.count <= 256 * 1_024, !text.isEmpty, text.utf8.count <= 256 * 1_024
        else { throw TextDeliveryPreparationFailure.invalidInput.issue }
        let originalFingerprint = Self.fingerprint(original)
        guard originalFingerprint == expected.valueFingerprint,
            let selection = TextMutationRange.validated(expected.range, in: original),
            TextMutationRange.identical(String(original[selection]), expected.selectedText),
            expected.range.location <= Int.max - text.utf16.count
        else { throw TextDeliveryPreparationFailure.snapshotMismatch.issue }
        let result = (original as NSString).replacingCharacters(in: expected.range, with: text)
        // An unchanged value cannot acknowledge a queued paste reliably.
        guard !TextMutationRange.identical(result, original) else {
            throw TextDeliveryPreparationFailure.unchangedResult.issue
        }
        guard result.utf8.count <= 256 * 1_024 else { throw TextDeliveryPreparationFailure.resultTooLarge.issue }
        self.originalFingerprint = originalFingerprint
        insertedText = text
        expectedValue = result
        processID = expected.processID
        range = NSRange(location: expected.range.location + text.utf16.count, length: 0)
        valueFingerprint = Self.fingerprint(result)
        // Some composers (Codex, ChatGPT) report their grey hint as the value
        // without marking it. A paste at the very start cannot remove real
        // text, so a field holding exactly the inserted text afterwards had
        // only a hint before it.
        let unmarkedHint =
            TextDeliveryMutation.prefersPaste(in: expected) && expected.range == NSRange(location: 0, length: 0)
            && !Self.visible(original).isEmpty
        placeholderResultFingerprint =
            (expected.showsPlaceholder || unmarkedHint) && expected.range.length == 0
                && !TextMutationRange.identical(text, original)
            ? Self.fingerprint(text) : nil
        if let alternateOriginal, let marker = expected.markerFingerprint,
            alternateOriginal.utf8.count <= Self.maximumBytes,
            Self.fingerprint(alternateOriginal) == marker,
            let alternateSelection = TextMutationRange.validated(expected.range, in: alternateOriginal),
            TextMutationRange.identical(String(alternateOriginal[alternateSelection]), expected.selectedText)
        {
            let alternateResult = (alternateOriginal as NSString).replacingCharacters(in: expected.range, with: text)
            alternateValueFingerprint =
                alternateResult.utf8.count <= Self.maximumBytes
                    && !TextMutationRange.identical(alternateOriginal, alternateResult)
                ? Self.fingerprint(alternateResult) : nil
            let unbroken = (Self.unbroken(alternateResult), Self.unbroken(alternateOriginal))
            alternateUnbroken =
                TextDeliveryMutation.prefersPaste(in: expected) && alternateValueFingerprint != nil
                    && unbroken.0 != unbroken.1 ? unbroken : nil
        } else {
            alternateValueFingerprint = nil
            alternateUnbroken = nil
        }
        let visibleResult = Self.visible(result)
        visibleOriginal = Self.visible(original)
        visibleExpected =
            TextDeliveryMutation.prefersPaste(in: expected) && !Self.visible(text).isEmpty
                && visibleResult != visibleOriginal ? visibleResult : nil
        // Empty web paragraphs can omit their sole inherited LF after an
        // insertion. Accept only the entire requested body with its exact
        // insertion caret; requested newlines and nonempty original text stay exact.
        if TextDeliveryMutation.prefersPaste(in: expected), original == "\n",
            expected.range == NSRange(location: 0, length: 0),
            text.utf16.last != 10, text.utf16.last != 13
        {
            webParagraphFingerprint = Self.fingerprint(text)
            webParagraphShape = "empty-paragraph-lf"
        } else if TextDeliveryMutation.prefersPaste(in: expected),
            expected.range.location + expected.range.length == original.utf16.count,
            text.utf16.last != 10, text.utf16.last != 13,
            expected.selectedText.utf16.last != 10, expected.selectedText.utf16.last != 13,
            result.utf8.count < 256 * 1_024
        {
            let candidate = Self.fingerprint(result + "\n")
            webParagraphFingerprint = candidate == originalFingerprint ? nil : candidate
            webParagraphShape = "extra-final-lf"
        } else {
            webParagraphFingerprint = nil
            webParagraphShape = "exact-only"
        }
    }
    static func prepared(
        text: String, original: String, alternateOriginal: String?, expected: TextDeliveryState
    ) throws -> TextDeliveryAcknowledgement {
        var baseline = expected
        var alternate: String?
        if let marker = expected.markerFingerprint {
            if let current = alternateOriginal {
                guard Self.fingerprint(current) == marker else { throw TextDelivery.Issue.staleDestination }
                alternate = current
                // Chrome reports a code editor's selection (CodeMirror, Overleaf)
                // in its text-marker space, which has no line breaks between the
                // editor's line blocks, while AXValue has them. When only the
                // marker text holds the selection at its range, it is the field
                // text: the expected result and its receipt come from markers.
                if !Self.holds(expected, in: original), Self.holds(expected, in: current) {
                    baseline.valueFingerprint = marker
                    return try TextDeliveryAcknowledgement(
                        text: text, original: current, expected: baseline, alternateOriginal: current)
                }
                // Keep the complete content lease while AXValue changes representation.
                // Selection and field identity are revalidated before the single mutation.
                baseline.valueFingerprint = Self.fingerprint(original)
            } else {
                guard Self.fingerprint(original) == expected.valueFingerprint else {
                    throw TextDelivery.Issue.staleDestination
                }
                baseline.markerFingerprint = nil
            }
        }
        return try TextDeliveryAcknowledgement(
            text: text, original: original, expected: baseline, alternateOriginal: alternate)
    }
    static func unbroken(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter { $0 != "\n" && $0 != "\r" }))
    }
    private static func holds(_ expected: TextDeliveryState, in value: String) -> Bool {
        guard let selection = TextMutationRange.validated(expected.range, in: value) else { return false }
        return TextMutationRange.identical(String(value[selection]), expected.selectedText)
    }

    // The text a person sees: no format or object-replacement characters,
    // whitespace runs (including NBSP and line breaks) as one space, trimmed.
    static func visible(_ value: String) -> String {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in value.precomposedStringWithCanonicalMapping.unicodeScalars {
            if scalar.properties.generalCategory == .format || scalar.value == 0xFFFC { continue }
            if scalar.properties.isWhitespace {
                pendingSpace = !scalars.isEmpty
                continue
            }
            if pendingSpace { scalars.append(" ") }
            pendingSpace = false
            scalars.append(scalar)
        }
        return String(scalars)
    }
    func acceptsVisible(_ observed: String) -> Bool {
        // The bounded web paragraph shapes keep their own caret evidence; any
        // other representation of the requested text is judged by what shows.
        guard let visibleExpected, Self.fingerprint(observed) != webParagraphFingerprint else { return false }
        let visibleObserved = Self.visible(observed)
        return visibleObserved == visibleExpected && visibleObserved != visibleOriginal
    }

    // Called only after the exact receipt deadline fails. These categories
    // diagnose serialization; none of them authorizes an insertion success.
    func diagnosticDifference(_ observed: String) -> String {
        if Self.fingerprint(observed) == originalFingerprint { return "original-unchanged" }
        if TextMutationRange.identical(observed, expectedValue) { return "exact" }
        if TextMutationRange.identical(
            observed.precomposedStringWithCanonicalMapping, expectedValue.precomposedStringWithCanonicalMapping)
        {
            return "nfc-only"
        }
        func lineEndings(_ value: String) -> String {
            value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }
        if TextMutationRange.identical(lineEndings(observed), lineEndings(expectedValue)) { return "line-endings-only" }
        if TextMutationRange.identical(observed, expectedValue + "\n") { return "terminal-lf-extra" }
        if TextMutationRange.identical(observed + "\n", expectedValue) { return "terminal-lf-missing" }
        if TextMutationRange.identical(
            observed.replacingOccurrences(of: "\u{00A0}", with: " "),
            expectedValue.replacingOccurrences(of: "\u{00A0}", with: " "))
        {
            return "nbsp-only"
        }
        let visibleObserved = Self.visible(observed)
        if visibleObserved == Self.visible(expectedValue) { return "visible-equal" }
        if visibleObserved == visibleOriginal { return "visible-original" }
        let visibleInserted = Self.visible(insertedText)
        if !visibleInserted.isEmpty, visibleObserved == visibleInserted { return "inserted-only" }
        if !visibleInserted.isEmpty, visibleObserved.components(separatedBy: visibleInserted).count > 2 {
            return "inserted-repeated"
        }
        if !visibleInserted.isEmpty, visibleObserved.contains(visibleInserted) {
            return visibleObserved.count > Self.visible(expectedValue).count ? "contains-longer" : "contains-shorter"
        }
        return "other"
    }

    func wait(
        timeout: TimeInterval = 1.2, now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        readAlternate: (() throws -> Receipt)? = nil,
        readCaret: (() throws -> CaretReceipt)? = nil,
        read: () throws -> Receipt
    ) throws {
        let deadline = now() + timeout
        // The budget limits new reads. A read started within it can return
        // the exact captured-field result after the deadline; that is still
        // positive evidence of this one mutation, not permission to retry it.
        var lastOutcome = "no-read"
        var lastObservedValue: String?
        var caretOutcome = "not-read"
        var alternateOutcome = "not-read"
        while now() < deadline {
            caretOutcome = "not-read"
            do {
                let receipt = try read()
                if receipt.processID != processID {
                    lastOutcome = "pid-mismatch"
                    lastObservedValue = nil
                } else if receipt.valueFingerprint != valueFingerprint {
                    if let placeholderResultFingerprint,
                        receipt.valueFingerprint == placeholderResultFingerprint
                            || receipt.diagnosticValue.map({ Self.visible($0) == Self.visible(insertedText) }) == true
                    {
                        textDeliveryLogger.info("Delivery acknowledgement accepted shape=placeholder-field")
                        return
                    }
                    if let observed = receipt.diagnosticValue, acceptsVisible(observed) {
                        textDeliveryLogger.info("Delivery acknowledgement accepted shape=visible-text")
                        return
                    }
                    lastOutcome = "value-mismatch"
                    lastObservedValue = receipt.diagnosticValue
                    if let webParagraphFingerprint, receipt.valueFingerprint == webParagraphFingerprint,
                        now() < deadline,
                        let readCaret
                    {
                        do {
                            let caret = try readCaret()
                            if caret.processID == processID, caret.range == range {
                                textDeliveryLogger.info(
                                    "Delivery acknowledgement accepted shape=\(webParagraphShape, privacy: .public)")
                                return
                            }
                            caretOutcome = caret.processID == processID ? "range-mismatch" : "pid-mismatch"
                        } catch {
                            caretOutcome = "read-error"
                        }
                    }
                } else {
                    return
                }
            } catch {
                lastOutcome = "read-error"
                lastObservedValue = nil
            }
            if let alternateValueFingerprint, let readAlternate, now() < deadline {
                do {
                    let alternate = try readAlternate()
                    if alternate.processID == processID, alternate.valueFingerprint == alternateValueFingerprint {
                        textDeliveryLogger.info("Delivery acknowledgement accepted source=field-text-range")
                        return
                    }
                    if alternate.processID == processID, let alternateUnbroken,
                        let observed = alternate.diagnosticValue.map(Self.unbroken),
                        observed == alternateUnbroken.expected, observed != alternateUnbroken.original
                    {
                        textDeliveryLogger.info("Delivery acknowledgement accepted source=field-text-lines")
                        return
                    }
                    alternateOutcome = alternate.processID == processID ? "value-mismatch" : "pid-mismatch"
                } catch {
                    alternateOutcome = "unavailable"
                }
            }
            let remaining = deadline - now()
            if remaining <= 0 { break }
            pause(min(0.025, remaining))  // AX worker only; never the main thread.
        }
        // A late application response can still change the field. Never retry
        // a mutation whose result is unconfirmed, even if it looks like a no-op.
        let difference = lastObservedValue.map(diagnosticDifference) ?? "unavailable"
        textDeliveryLogger.error(
            "Delivery acknowledgement failed outcome=\(lastOutcome, privacy: .public) difference=\(difference, privacy: .public) caret=\(caretOutcome, privacy: .public) shape=\(webParagraphShape, privacy: .public) alternate=\(alternateOutcome, privacy: .public)"
        )
        throw TextDelivery.Issue.uncertain
    }
}

enum TextDeliveryMutation {
    static func prefersPaste(in state: TextDeliveryState) -> Bool { state.prefersPaste && state.supportsPaste }
    enum NativeResult { case accepted, unsupported }
    static func prefersPaste(attributeNames: Set<String>, principalClass: String?, hasElectronFramework: Bool) -> Bool {
        !attributeNames.isDisjoint(with: ["AXDOMIdentifier", "AXDOMClassList", "AXARIARole", "AXDOMTagName"])
            || principalClass == "BrowserCrApplication" || hasElectronFramework
    }
    static func perform(
        preferPaste: Bool, supportsNativeInsertion: Bool,
        native: () throws -> NativeResult, paste: () throws -> Void,
        acknowledge: () throws -> Void
    ) throws {
        if supportsNativeInsertion && !preferPaste, try native() == .accepted {
            try acknowledge()
            return
        }
        try paste()
    }
}

// Read one complete, caller-captured field without a legacy character-count prefix.
// Two complete text reads must agree; opaque marker identity is not a revision.
// Terminals take typed input through paste. Line breaks would run commands,
// so dictated text arrives as one line; nothing is ever submitted.
enum TerminalDelivery {
    static let bundleIdentifiers: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp",
        "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty", "co.zeit.hyper",
        "com.github.wez.wezterm", "org.tabby", "com.panic.Prompt3"
    ]
    static func isTerminal(processID: Int32) -> Bool {
        NSRunningApplication(processIdentifier: processID)?.bundleIdentifier.map(bundleIdentifiers.contains) ?? false
    }
    static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
    // Terminals wrap long lines and pad them, even inside a word, so compare
    // the visible characters without any whitespace.
    static func occurrences(of line: String, in text: String) -> Int {
        func compact(_ value: String) -> String {
            String(TextDeliveryAcknowledgement.visible(value).unicodeScalars.filter { !$0.properties.isWhitespace })
        }
        let needle = compact(line)
        guard !needle.isEmpty else { return 0 }
        return compact(text).components(separatedBy: needle).count - 1
    }
}

struct FieldMarkerReader {
    static let byteLimit = 256 * 1024
    var pid: () -> pid_t?
    var fullRange: () -> CFTypeRef?
    var length: (CFTypeRef) -> Int?
    var string: (CFTypeRef) -> String?
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var checkCancellation: () throws -> Void = { try Task.checkCancellation() }

    func read(expectedPID: pid_t, knownValue: String? = nil) throws -> String? {
        let deadline = now() + 0.100
        func admitted() throws -> Bool {
            try checkCancellation()
            return now() < deadline
        }
        func call<T>(_ operation: () -> T?) throws -> T? {
            guard try admitted() else { return nil }
            let value = operation()
            guard try admitted() else { return nil }
            return value
        }
        func completeText() throws -> String? {
            guard let range = try call(fullRange),
                let count = try call({ length(range) }), count >= 0, count <= Self.byteLimit,
                let body = try call({ string(range) }),
                body.utf16.count == count, body.utf8.count <= Self.byteLimit
            else { return nil }
            return body
        }
        guard expectedPID > 0, try call(pid) == expectedPID,
            let first = try completeText(), try call(pid) == expectedPID,
            let second = try completeText(), try call(pid) == expectedPID,
            first.utf8.elementsEqual(second.utf8)
        else { return nil }
        // Native web controls may expose their host as one replacement object,
        // not its text value. Only an equal primary value establishes this as
        // literal field content; embedded replacement characters remain text.
        guard second != "\u{fffc}" || knownValue == second else { return nil }
        return second
    }
}

final class AXTextDeliveryBackend: TextDeliveryBackend {
    typealias Element = AXUIElement
    private var markerCapability: (element: AXUIElement, supported: Bool)?
    var isTrusted: Bool { AXIsProcessTrusted() }
    func processID(of element: AXUIElement) throws -> Int32? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else {
            throw TextDelivery.Issue.staleDestination
        }
        return pid
    }
    func frontmostProcessID() -> Int32? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    func canRestoreFocus(to processID: Int32, from element: AXUIElement?) -> Bool {
        let own = ProcessInfo.processInfo.processIdentifier
        guard processID > 0, let front = frontmostProcessID(), front == own || front == processID else { return false }
        if front == own || element == nil { return true }
        var focusedPID: pid_t = 0
        return AXUIElementGetPid(element!, &focusedPID) == .success && focusedPID == own
    }
    private func configured(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }
    private func issue(_ error: AXError) -> TextDelivery.Issue {
        switch error {
        case .apiDisabled: return .permission
        case .attributeUnsupported, .parameterizedAttributeUnsupported, .notImplemented, .noValue: return .unsupported
        case .invalidUIElement: return .staleDestination
        default: return .failed
        }
    }
    private func read(_ element: AXUIElement, _ name: String) throws -> CFTypeRef {
        var result: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &result)
        guard error == .success, let result else { throw issue(error) }
        return result
    }
    private func optional(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
        do { return try read(element, name) } catch TextDelivery.Issue.unsupported { return nil }
    }
    private func boolean(_ element: AXUIElement, _ name: String) throws -> Bool? {
        guard let value = try optional(element, name) else { return nil }
        guard let result = value as? Bool else { throw TextDelivery.Issue.failed }
        return result
    }
    // A Chromium or Electron app with no focused element yet is woken first (AccessibilityTreeWake).
    func focusedElement() throws -> AXUIElement {
        let result: CFTypeRef
        do {
            result = try AccessibilityTreeWake.focusedElement(
                in: nil, missing: { $0 is TextDeliveryFocusIssue }
            ) {
                var value: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(
                    configured(AXUIElementCreateSystemWide()), kAXFocusedUIElementAttribute as CFString, &value)
                if error == .noValue || (error == .success && value == nil) { throw TextDeliveryFocusIssue.unavailable }
                guard error == .success, let value else { throw issue(error) }
                return value
            }
        } catch is TextDeliveryFocusIssue {
            throw issue(.noValue)
        }
        guard CFGetTypeID(result) == AXUIElementGetTypeID() else { throw TextDelivery.Issue.staleDestination }
        return configured(unsafeBitCast(result, to: AXUIElement.self))
    }
    func matches(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool { AXFieldIdentity.matches(lhs, rhs) }
    private func range(_ element: AXUIElement) throws -> NSRange {
        let value = try read(element, kAXSelectedTextRangeAttribute)
        guard CFGetTypeID(value) == AXValueGetTypeID() else { throw TextDelivery.Issue.unsupported }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range), range.location >= 0,
            range.length >= 0,
            range.location <= Int.max - range.length
        else { throw TextDelivery.Issue.unsupported }
        return NSRange(location: range.location, length: range.length)
    }
    func caretRange(of element: AXUIElement) throws -> NSRange? { try selection(element) }
    private func value(_ element: AXUIElement) throws -> String? {
        guard let value = try optional(element, kAXValueAttribute) as? String else { return nil }
        guard value.utf8.count <= 256 * 1_024 else { return nil }
        return value
    }
    private func fingerprint(_ value: String) -> Data { TextDeliveryAcknowledgement.fingerprint(value) }
    // Mail's message body and other editable web documents are the web area
    // itself, with no AXValue or AXSelectedTextRange: only text markers.
    func isEditableWebArea(_ element: AXUIElement) -> Bool {
        guard (try? optional(element, kAXRoleAttribute)) as? String == "AXWebArea" else { return false }
        if (try? boolean(element, kAXIsEditableAttribute)) == true { return true }
        if (try? optional(element, "AXEditableAncestor")) != nil { return true }
        // Mail's body reports AXFocused false; what marks it editable is a
        // settable value beside a text-marker selection. Read-only pages
        // have neither a settable value nor an insertion point.
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success,
            let attributes = names as? [String], attributes.contains("AXSelectedTextMarkerRange")
        else { return false }
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
            && settable.boolValue
    }
    func fieldValue(_ element: AXUIElement, processID: Int32) throws -> String? {
        // An editable web document's AXValue can stay empty; its markers hold the text.
        if isEditableWebArea(element) { return try markerValue(element, processID: processID) }
        if let field = try value(element) { return field }
        // An empty Messages composer has no AXValue at all, yet its value is
        // settable and it holds no characters: that is an empty field.
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
            settable.boolValue,
            ((try? optional(element, kAXNumberOfCharactersAttribute)) as? NSNumber)?.intValue ?? 0 == 0,
            (try? optional(element, kAXSelectedTextAttribute)) as? String == ""
        else { return nil }
        return ""
    }
    private func selection(_ element: AXUIElement) throws -> NSRange {
        do {
            return try range(element)
        } catch TextDelivery.Issue.unsupported {
            guard isEditableWebArea(element), let range = markerSelection(element) else {
                throw TextDelivery.Issue.unsupported
            }
            return range
        }
    }
    private func markerSelection(_ element: AXUIElement) -> NSRange? {
        func parameterized(_ name: String, _ parameter: CFTypeRef) -> CFTypeRef? {
            var result: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &result) == .success
            else { return nil }
            return result
        }
        func length(_ range: CFTypeRef) -> Int? {
            guard let raw = parameterized("AXLengthForTextMarkerRange", range), CFGetTypeID(raw) == CFNumberGetTypeID(),
                let value = (raw as? NSNumber)?.intValue, value >= 0, value <= FieldMarkerReader.byteLimit
            else { return nil }
            return value
        }
        guard let selected = try? optional(element, "AXSelectedTextMarkerRange") else { return nil }
        if CFGetTypeID(selected) == AXTextMarkerRangeGetTypeID(),
            let index = parameterized(
                "AXIndexForTextMarker", AXTextMarkerRangeCopyStartMarker(selected as! AXTextMarkerRange)),
            let location = (index as? NSNumber)?.intValue, location >= 0, let count = length(selected)
        {
            return NSRange(location: location, length: count)
        }
        guard let full = parameterized("AXTextMarkerRangeForUIElement", element),
            let start = parameterized("AXStartTextMarkerForTextMarkerRange", full),
            let caret = parameterized("AXStartTextMarkerForTextMarkerRange", selected),
            let prefix = parameterized("AXTextMarkerRangeForUnorderedTextMarkers", [start, caret] as CFArray),
            let location = length(prefix), let count = length(selected)
        else { return nil }
        return NSRange(location: location, length: count)
    }
    private func selectedText(_ element: AXUIElement, range: NSRange, field: String?) throws -> String? {
        if let text = try optional(element, kAXSelectedTextAttribute) as? String { return text }
        if range.length == 0 { return "" }
        guard let field, let selection = TextMutationRange.validated(range, in: field) else { return nil }
        return String(field[selection])
    }
    private func markerValue(_ element: AXUIElement, processID: Int32, knownValue: String? = nil) throws -> String? {
        let supported: Bool
        if let cached = markerCapability, matches(cached.element, element) {
            supported = cached.supported
        } else {
            var attributes: CFArray?
            let result = AXUIElementCopyParameterizedAttributeNames(element, &attributes)
            // A failed round trip says nothing about the field's capabilities.
            guard result == .success, let names = attributes as? [String] else { return nil }
            let required: Set<String> = [
                "AXTextMarkerRangeForUIElement", "AXLengthForTextMarkerRange", "AXStringForTextMarkerRange"
            ]
            supported = required.isSubset(of: Set(names))
            markerCapability = (element, supported)
        }
        guard supported else { return nil }
        func parameterized(_ name: String, _ parameter: CFTypeRef) -> CFTypeRef? {
            var result: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &result) == .success
            else { return nil }
            return result
        }
        return try FieldMarkerReader(
            pid: {
                var pid: pid_t = 0
                return AXUIElementGetPid(element, &pid) == .success ? pid : nil
            },
            fullRange: { parameterized("AXTextMarkerRangeForUIElement", element) },
            length: { range in
                guard let raw = parameterized("AXLengthForTextMarkerRange", range),
                    CFGetTypeID(raw) == CFNumberGetTypeID()
                else { return nil }
                let number = raw as! CFNumber
                var value: Int64 = 0
                guard !CFNumberIsFloatType(number), CFNumberGetValue(number, .sInt64Type, &value),
                    value >= 0, value <= Int64(FieldMarkerReader.byteLimit)
                else { return nil }
                return Int(value)
            },
            string: { range in parameterized("AXStringForTextMarkerRange", range) as? String }
        ).read(expectedPID: processID, knownValue: knownValue)
    }
    func isWebEditor(_ element: AXUIElement, processID: Int32) -> Bool {
        // Attribute names and framework presence are local capability evidence;
        // no DOM contents, clipboard contents or application history is read.
        if isEditableWebArea(element) { return true }
        var attributes: CFArray?
        let attributesResult = AXUIElementCopyAttributeNames(element, &attributes)
        let names = attributesResult == .success ? Set(attributes as? [String] ?? []) : []
        let bundle = NSRunningApplication(processIdentifier: processID)?.bundleURL
        let principalClass = bundle.flatMap {
            Bundle(url: $0)?.object(forInfoDictionaryKey: "NSPrincipalClass") as? String
        }
        let electron =
            bundle.map {
                FileManager.default.fileExists(
                    atPath: $0.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
            } ?? false
        return TextDeliveryMutation.prefersPaste(
            attributeNames: names, principalClass: principalClass, hasElectronFramework: electron)
    }
    // iPhone and iPad apps running on the Mac (Mac Catalyst, or unmodified
    // iOS apps) bridge text fields to accessibility loosely: setters may be
    // missing or acknowledge without editing. A verified paste works there,
    // as in Electron and web editors.
    func isMobileApp(processID: Int32) -> Bool {
        guard let bundle = NSRunningApplication(processIdentifier: processID)?.bundleURL else { return false }
        if bundle.pathComponents.contains("Wrapper") { return true }
        let info = Bundle(url: bundle)?.infoDictionary ?? [:]
        let families = info["UIDeviceFamily"] as? [Int] ?? []
        return !families.isEmpty || info["LSRequiresIPhoneOS"] as? Bool == true
    }
    func state(of element: AXUIElement) throws -> TextDeliveryState {
        guard let role = try read(element, kAXRoleAttribute) as? String else {
            textDeliveryLogger.error("Delivery field unsupported reason=no-role")
            throw TextDelivery.Issue.unsupported
        }
        let subrole = try optional(element, kAXSubroleAttribute) as? String
        guard role != kAXSecureTextFieldSubrole, subrole != kAXSecureTextFieldSubrole,
            try boolean(element, "AXProtectedContent") != true
        else { throw TextDelivery.Issue.unsupported }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { throw TextDelivery.Issue.staleDestination }
        // A terminal's text area is read-only output; typing goes to the shell
        // through paste. Its content keeps changing, so it is not fingerprinted.
        if role == kAXTextAreaRole, TerminalDelivery.isTerminal(processID: pid) {
            return TextDeliveryState(
                processID: pid, range: NSRange(location: 0, length: 0), selectedText: "",
                valueFingerprint: nil, markerFingerprint: nil, isEditable: true, isEnabled: true,
                supportsNativeInsertion: false, supportsPaste: true, prefersPaste: true, showsPlaceholder: false)
        }
        var settable = DarwinBoolean(false)
        let capability = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        guard capability == .success || capability == .attributeUnsupported else { throw issue(capability) }
        let explicitEditable = try boolean(element, kAXIsEditableAttribute)
        let enabled = try boolean(element, kAXEnabledAttribute) ?? true
        let native = capability == .success && settable.boolValue
        let textRole = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
        let mobile = textRole && isMobileApp(processID: pid)
        var valueSettable = DarwinBoolean(false)
        let valueCapability = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable)
        let valueWritable = valueCapability == .success && valueSettable.boolValue
        let webArea = role == "AXWebArea" && isEditableWebArea(element)
        let editable = webArea || (explicitEditable ?? (native || (textRole && (valueWritable || mobile))))
        guard editable, enabled else {
            // Attribute names only: capability evidence, never field contents.
            var names: CFArray?
            let attributes =
                AXUIElementCopyAttributeNames(element, &names) == .success
                ? (names as? [String] ?? []).filter { $0.hasPrefix("AX") }.sorted().joined(separator: ",") : ""
            textDeliveryLogger.error(
                "Delivery field unsupported reason=\(enabled ? "not-editable" : "disabled", privacy: .public) role=\(role, privacy: .public) native=\(native, privacy: .public) mobile=\(mobile, privacy: .public) attributes=\(attributes, privacy: .public)"
            )
            throw TextDelivery.Issue.unsupported
        }
        let selectedRange = try selection(element)
        let ranges = try optional(element, kAXSelectedTextRangesAttribute) as? [Any]
        guard (ranges?.count ?? 1) == 1 else { throw TextDelivery.Issue.unsupported }
        let field = try fieldValue(element, processID: pid)
        guard let selectedText = try selectedText(element, range: selectedRange, field: field) else {
            throw TextDelivery.Issue.unsupported
        }
        if let field, TextMutationRange.validated(selectedRange, in: field) == nil {
            throw TextDelivery.Issue.unsupported
        }
        let web = webArea || (textRole && isWebEditor(element, processID: pid))
        let pasteFirst = web || mobile
        // Some composers (ChatGPT, WhatsApp) report their grey placeholder as
        // the value of an empty field. Recognize it so the receipt can expect
        // only the inserted text.
        let placeholder = (try? optional(element, kAXPlaceholderValueAttribute)) as? String
        let characters = ((try? optional(element, kAXNumberOfCharactersAttribute)) as? NSNumber)?.intValue
        let showsPlaceholder =
            selectedRange.length == 0
            && field.map { !$0.isEmpty && ($0 == placeholder || characters == 0) } ?? false
        let marker = web && !webArea ? try markerValue(element, processID: pid, knownValue: field) : nil
        let markerFingerprint = marker.flatMap { text -> Data? in
            guard let selection = TextMutationRange.validated(selectedRange, in: text),
                TextMutationRange.identical(String(text[selection]), selectedText)
            else { return nil }
            return fingerprint(text)
        }
        return TextDeliveryState(
            processID: pid, range: selectedRange, selectedText: selectedText,
            valueFingerprint: field.map(fingerprint), markerFingerprint: markerFingerprint,
            isEditable: editable, isEnabled: enabled,
            supportsNativeInsertion: native && field != nil,
            supportsPaste: field != nil
                && (webArea || (textRole && (explicitEditable == true || valueWritable || mobile))),
            prefersPaste: pasteFirst, showsPlaceholder: showsPlaceholder)
    }
    func bounds(of element: AXUIElement, range: NSRange) -> CGRect? {
        let count = (try? optional(element, kAXNumberOfCharactersAttribute)) as? NSNumber
        return TextDeliveryCaretBounds.resolve(
            range: range, characterCount: count?.intValue,
            readRange: { self.rangeBounds(of: element, range: $0) },
            readFrame: {
                guard let position = try? self.optional(element, kAXPositionAttribute),
                    let size = try? self.optional(element, kAXSizeAttribute),
                    CFGetTypeID(position as CFTypeRef) == AXValueGetTypeID(),
                    CFGetTypeID(size as CFTypeRef) == AXValueGetTypeID()
                else { return nil }
                var point = CGPoint.zero, dimensions = CGSize.zero
                guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
                    AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions)
                else { return nil }
                return CGRect(origin: point, size: dimensions)
            })
    }
    private func rangeBounds(of element: AXUIElement, range: NSRange) -> CGRect? {
        var range = CFRange(location: range.location, length: range.length)
        guard let axRange = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, axRange, &value) == .success,
            let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var bounds = CGRect.zero
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cgRect, &bounds), bounds.origin.x.isFinite,
            bounds.origin.y.isFinite, bounds.width.isFinite, bounds.height.isFinite, bounds.width >= 0,
            bounds.height > 0
        else { return nil }
        return bounds
    }
    func write(_ text: String, to element: AXUIElement, expected: TextDeliveryState) throws {
        if TerminalDelivery.isTerminal(processID: expected.processID) {
            try pasteIntoTerminal(text, element: element, expected: expected)
            return
        }
        guard let original = try fieldValue(element, processID: expected.processID) else {
            throw TextDelivery.Issue.unsupported
        }
        let acknowledgement = try prepareAcknowledgement(text, original: original, element: element, expected: expected)
        try TextDeliveryMutation.perform(
            preferPaste: TextDeliveryMutation.prefersPaste(in: expected),
            supportsNativeInsertion: expected.supportsNativeInsertion,
            native: {
                let focused = try self.focusedElement(), latest = try self.state(of: element)
                guard self.matches(focused, element), expected.sameDestination(as: latest), latest.writable else {
                    throw TextDelivery.Issue.staleDestination
                }
                let error = AXUIElementSetAttributeValue(
                    element, kAXSelectedTextAttribute as CFString, text as CFString)
                if error == .success { return .accepted }
                if [.attributeUnsupported, .notImplemented].contains(error) { return .unsupported }
                if error == .apiDisabled { throw TextDelivery.Issue.permission }
                // A failed round trip can follow an editor mutation. Its result
                // is unknown; only explicit unsupported permits a second method.
                throw TextDelivery.Issue.uncertain
            },
            paste: {
                try self.paste(text, to: element, expected: expected, acknowledgement: acknowledgement)
            },
            acknowledge: {
                try self.acknowledge(acknowledgement, element: element)
            })
    }
    // Selected-text replacement shares the proven paste/clipboard owner, but
    // cannot borrow a dictation token or fall back after an uncertain AX write.
    func pasteReplacement(
        _ text: String, to element: AXUIElement, expected: SelectionReplacementState, original: String
    ) throws {
        let current = try state(of: element)
        guard TextDeliveryMutation.prefersPaste(in: current), current.writable,
            current.processID == expected.processID, current.range == expected.range,
            expected.range.length > 0, TextMutationRange.identical(current.selectedText, expected.selectedText),
            current.valueFingerprint == fingerprint(original)
        else { throw TextDelivery.Issue.staleDestination }
        let acknowledgement = try prepareAcknowledgement(text, original: original, element: element, expected: current)
        try paste(text, to: element, expected: current, acknowledgement: acknowledgement)
    }

    private func prepareAcknowledgement(
        _ text: String, original: String, element: AXUIElement, expected: TextDeliveryState
    ) throws -> TextDeliveryAcknowledgement {
        let alternate =
            expected.markerFingerprint == nil
            ? nil : try markerValue(element, processID: expected.processID, knownValue: original)
        return try TextDeliveryAcknowledgement.prepared(
            text: text, original: original, alternateOriginal: alternate, expected: expected)
    }

    private func acknowledge(_ acknowledgement: TextDeliveryAcknowledgement, element: AXUIElement) throws {
        var currentPrimaryValue: String?
        try acknowledgement.wait(
            readAlternate: {
                var pid: pid_t = 0
                guard AXUIElementGetPid(element, &pid) == .success,
                    let text = try self.markerValue(element, processID: pid, knownValue: currentPrimaryValue)
                else { throw TextDelivery.Issue.failed }
                return .init(processID: pid, valueFingerprint: self.fingerprint(text), diagnosticValue: text)
            },
            readCaret: {
                var pid: pid_t = 0
                guard AXUIElementGetPid(element, &pid) == .success else { throw TextDelivery.Issue.failed }
                return .init(processID: pid, range: try self.selection(element))
            }
        ) {
            currentPrimaryValue = nil
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success, let field = try self.fieldValue(element, processID: pid)
            else {
                throw TextDelivery.Issue.failed
            }
            currentPrimaryValue = pid == acknowledgement.processID ? field : nil
            return TextDeliveryAcknowledgement.Receipt(
                processID: pid, valueFingerprint: self.fingerprint(field), diagnosticValue: field)
        }
    }
    private func terminalText(_ element: AXUIElement) -> String? {
        // The visible screen holds the prompt line; scrollback can be huge.
        if let visible = try? optional(element, kAXVisibleCharacterRangeAttribute),
            CFGetTypeID(visible) == AXValueGetTypeID()
        {
            var result: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString, visible, &result) == .success,
                let text = result as? String
            {
                return text
            }
        }
        return try? value(element)
    }
    private func pasteIntoTerminal(_ text: String, element: AXUIElement, expected: TextDeliveryState) throws {
        let line = TerminalDelivery.singleLine(text)
        guard !line.isEmpty, let before = terminalText(element) else { throw TextDelivery.Issue.unsupported }
        let baseline = TerminalDelivery.occurrences(of: line, in: before)
        let lease = try TextDeliveryClipboardLease(clipboard: SystemDeliveryClipboard(), text: line)
        var posted = false
        defer { if !posted { try? lease.restoreIfOwned() } }
        let key = CommandKeyCodes.paste
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
        else { throw TextDelivery.Issue.failed }
        down.flags = .maskCommand
        up.flags = .maskCommand
        try lease.performIfOwned(validating: {
            guard self.matches(try self.focusedElement(), element) else { throw TextDelivery.Issue.staleDestination }
        }) {
            down.postToPid(expected.processID)
            up.postToPid(expected.processID)
            posted = true
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let after = terminalText(element), TerminalDelivery.occurrences(of: line, in: after) > baseline {
                try? lease.restoreIfOwned()
                return
            }
            Thread.sleep(forTimeInterval: 0.03)  // AX worker only.
        }
        textDeliveryLogger.error("Delivery acknowledgement failed outcome=terminal-unchanged")
        throw TextDelivery.Issue.uncertain
    }
    private func paste(
        _ text: String, to element: AXUIElement, expected: TextDeliveryState,
        acknowledgement: TextDeliveryAcknowledgement
    ) throws {
        guard expected.supportsPaste else { throw TextDelivery.Issue.unsupported }
        let lease = try TextDeliveryClipboardLease(clipboard: SystemDeliveryClipboard(), text: text)
        var posted = false
        defer { if !posted { try? lease.restoreIfOwned() } }
        let focused = try focusedElement(), latest = try state(of: element)
        guard matches(focused, element), expected.sameDestination(as: latest), latest.writable else {
            throw TextDelivery.Issue.staleDestination
        }
        let key = CommandKeyCodes.paste
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
        else { throw TextDelivery.Issue.failed }
        down.flags = .maskCommand
        up.flags = .maskCommand
        try lease.performIfOwned(validating: {
            // State reads can take several AX round trips. Verify the current
            // focused handle again after them, then check clipboard ownership.
            guard self.matches(try self.focusedElement(), element) else { throw TextDelivery.Issue.staleDestination }
        }) {
            down.postToPid(expected.processID)
            up.postToPid(expected.processID)
            posted = true
        }
        // A queued paste may still be consumed. Keep its text on the clipboard
        // on failure rather than restore an unrelated private original before
        // it is consumed.
        do {
            try acknowledge(acknowledgement, element: element)
        } catch TextDelivery.Issue.uncertain {
            // Chromium apps occasionally drop a synthesized Command-V. Only a
            // field still exactly as captured, well after the paste, proves it
            // was dropped; then one more paste cannot double the text.
            guard let original = expected.valueFingerprint, unchangedAfterDroppedPaste(original, element: element)
            else { throw TextDelivery.Issue.uncertain }
            try lease.performIfOwned(validating: {
                guard self.matches(try self.focusedElement(), element) else { throw TextDelivery.Issue.uncertain }
            }) {
                down.postToPid(expected.processID)
                up.postToPid(expected.processID)
            }
            textDeliveryLogger.notice("Delivery paste repeated after an unchanged field")
            try acknowledge(acknowledgement, element: element)
        }
        try? lease.restoreIfOwned()
    }
    private func unchangedAfterDroppedPaste(_ original: Data, element: AXUIElement) -> Bool {
        func unchanged() -> Bool {
            var pid: pid_t = 0
            guard AXUIElementGetPid(element, &pid) == .success,
                let field = try? fieldValue(element, processID: pid)
            else { return false }
            return fingerprint(field) == original
        }
        guard unchanged() else { return false }
        Thread.sleep(forTimeInterval: 0.5)  // AX worker only.
        return unchanged()
    }
}

// Command-C and Command-V are posted with the key that types c or v while
// Command is held in the current layout: plain Dvorak moves them, while
// Dvorak-QWERTY keeps the QWERTY keys. Layouts are read on the main thread;
// the Accessibility workers only read the result.
enum CommandKeyCodes {
    static let ansiC: CGKeyCode = 8
    static let ansiV: CGKeyCode = 9
    private static let lock = NSLock()
    nonisolated(unsafe) private static var resolved = (copy: ansiC, paste: ansiV)
    static var copy: CGKeyCode { lock.withLock { resolved.copy } }
    static var paste: CGKeyCode { lock.withLock { resolved.paste } }
    @MainActor static func refresh() {
        var codes = (copy: ansiC, paste: ansiV)
        defer { lock.withLock { resolved = codes } }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return }
        defer { withExtendedLifetime(source) {} }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let keyboard = UInt32(LMGetKbdType())
        let character = { (key: CGKeyCode) -> String? in
            var dead: UInt32 = 0
            var count = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, key, UInt16(kUCKeyActionDown), UInt32(cmdKey) >> 8, keyboard,
                OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, characters.count, &count, &characters)
            return status == noErr && count > 0 ? String(utf16CodeUnits: characters, count: count) : nil
        }
        codes = (
            copy: keyCode(typing: "c", using: character) ?? ansiC,
            paste: keyCode(typing: "v", using: character) ?? ansiV
        )
    }
    static func keyCode(typing letter: String, using character: (CGKeyCode) -> String?) -> CGKeyCode? {
        (CGKeyCode(0)...127).first { character($0)?.lowercased() == letter }
    }
}

final class SystemDeliveryClipboard: TextDeliveryClipboard {
    struct Snapshot { let items: [[NSPasteboard.PasteboardType: Data]] }
    private let pasteboard = NSPasteboard.general
    private var rollback: Snapshot?
    var changeCount: Int { pasteboard.changeCount }
    var copiedText: String? {
        let types = pasteboard.types ?? []
        guard !types.contains(.fileURL), !types.contains(.init("org.nspasteboard.ConcealedType")) else { return nil }
        return pasteboard.string(forType: .string)
    }
    func snapshot() throws -> Snapshot {
        var total = 0, items: [[NSPasteboard.PasteboardType: Data]] = []
        let originals = pasteboard.pasteboardItems ?? []
        guard originals.count <= 32 else { throw TextDeliveryPreparationFailure.clipboardItemLimit.issue }
        for item in originals {
            guard item.types.count <= 64 else { throw TextDeliveryPreparationFailure.clipboardTypeLimit.issue }
            var captured: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard !type.rawValue.lowercased().contains("promise") else {
                    throw TextDeliveryPreparationFailure.clipboardPromisedData.issue
                }
                guard let data = item.data(forType: type) else {
                    throw TextDeliveryPreparationFailure.clipboardDataUnavailable.issue
                }
                total = try TextDeliveryClipboardBudget.appending(data.count, to: total)
                captured[type] = data
            }
            items.append(captured)
        }
        let result = Snapshot(items: items)
        rollback = result
        return result
    }
    // Borrowed writes follow the nspasteboard.org convention: clipboard managers
    // record neither the text pasted for the owner nor their own clipboard put back.
    private static let borrowedTypes: [NSPasteboard.PasteboardType] = [
        .init("org.nspasteboard.TransientType"), .init("org.nspasteboard.AutoGeneratedType")
    ]
    func setText(_ text: String) throws {
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { throw TextDelivery.Issue.failed }
        for type in Self.borrowedTypes { item.setData(Data(), forType: type) }
        let clearedChange = pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            if pasteboard.changeCount == clearedChange, let rollback { try? restore(rollback) }
            throw TextDelivery.Issue.failed
        }
    }
    func restore(_ snapshot: Snapshot) throws {
        let restored = snapshot.items.enumerated().map { index, data -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, value) in data { item.setData(value, forType: type) }
            if index == 0 { item.setData(Data(), forType: Self.borrowedTypes[0]) }
            return item
        }
        pasteboard.clearContents()
        guard restored.isEmpty || pasteboard.writeObjects(restored) else { throw TextDelivery.Issue.failed }
    }
}
