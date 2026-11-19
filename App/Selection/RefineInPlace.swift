import AppKit
import SwiftUI

// Refine in place: select text in any app, press a row's key, and the selection
// is rewritten where it is. Nothing is written unless the chip says so; ⌘Z in
// the app undoes it. Pressing the same key again cancels.
@MainActor final class RefineInPlaceController {
    private var task: Task<Void, Never>?
    private var runningRow: Int?
    // Identifies the current row run; a cancelled run that unwinds later must
    // not clear a newer run of the same row.
    private var runID: UUID?
    private let chip = RefineChip()
    #if YULLO_TESTING
        var testCapture: ((Int32?) async -> SelectionReader.Outcome)?
        var testRewrite: ((String) async throws -> String)?
        var testRewriteNote: String?
        var testReplace: ((UUID, String) async throws -> Void)?
        var testHolds: ((UUID) async -> Bool)?
        var testChip: RefineChip { chip }
    #endif
    var openInYullo: ((String) -> Void)?
    var openSetup: (() -> Void)?
    // The one fix for a setup problem (Ollama not running, key access…), the same as the translator's.
    var openFix: ((TranslationRecoveryAction) -> Void)?
    // Edit with voice in place records its instruction through the voice
    // pipeline (nil when cancelled) and opens its review on Open in Yullo.
    var recordInstruction: (() async -> String?)?
    var openReview: ((_ original: String, _ instruction: String, _ result: String) -> Void)?
    private(set) var isEditing = false
    var isBusy: Bool { isEditing || runningRow != nil }
    // The key that started Edit with voice, named on the working chip's Cancel.
    var editKeyLabel: String?
    // Set while the spoken change is being written ("Editing…").
    private(set) var isWriting = false
    // The same key during "Editing…" cancels, as Refine's key does; nothing is written.
    // The chip says so at once and the selection's write lease goes; a writer
    // still finishing can't write, and a new edit can start straight away.
    @discardableResult func cancelEditing() -> Bool {
        guard isEditing, isWriting, let task else { return false }
        task.cancel()
        self.task = nil
        editID = nil
        isEditing = false
        isWriting = false
        if let token = editToken { SelectionReplacement.invalidate(if: token) }
        editToken = nil
        chip.show(L10n.tr("Nothing changed."), near: editBounds, for: 1.5)
        return true
    }
    private var editID: UUID?
    private var editToken: UUID?
    private var editBounds: CGRect?
    #if YULLO_TESTING
        var testEdit: ((String, String) async throws -> String)?
    #endif

    func run(row index: Int, preferences: Preferences, sourcePID: Int32?) {
        // An edit with voice in progress owns the selection until it ends.
        guard !isEditing else { return }
        if runningRow == index, let task {
            task.cancel()
            self.task = nil
            runningRow = nil
            runID = nil
            chip.show(L10n.tr("Nothing changed."), near: nil, for: 1.5)
            return
        }
        task?.cancel()
        guard preferences.outputs.refineInPlace.indices.contains(index) else { return }
        let row = preferences.outputs.refineInPlace[index]
        runningRow = index
        let id = UUID()
        runID = id
        task = Task { [weak self] in
            await self?.perform(output: row.output, preferences: preferences, sourcePID: sourcePID)
            guard let self, self.runID == id else { return }
            self.runID = nil
            self.runningRow = nil
            self.task = nil
        }
    }

    // Edit with voice in place: capture the selection first, then hear what
    // to change, then replace the selection where it is. A result that can't
    // be written is copied, never lost and never written elsewhere.
    func editWithVoice(preferences: Preferences, sourcePID: Int32?) {
        guard !isBusy else { return }
        isEditing = true
        let id = UUID()
        editID = id
        task = Task { [weak self] in
            await self?.performEdit(preferences: preferences, sourcePID: sourcePID)
            // A cancelled edit that unwinds late leaves a newer one alone.
            guard let self, self.editID == id else { return }
            self.editID = nil
            self.task = nil
            self.isEditing = false
            self.isWriting = false
            self.editToken = nil
        }
    }

    // Edit with voice, reviewed first: the selection it will edit, with its write
    // lease, or nil after the chip has said why there is nothing to edit.
    func captureForReview(preferences: Preferences, sourcePID: Int32?) async -> SelectionReader.Result? {
        guard !isBusy else { return nil }
        isEditing = true
        defer { isEditing = false }
        guard VoiceEditService.isConfigured(preferences) else {
            chip.show(
                L10n.tr("Needs setup"), near: nil, for: 5,
                action: (L10n.tr("Set up…"), { [weak self] in self?.openSetup?() }))
            return nil
        }
        let outcome = await captureSelection(in: sourcePID)
        guard let selection = outcome.selection else {
            showSelectionHint(for: outcome)
            return nil
        }
        guard !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            selection.text.utf8.count <= CoreVoiceEditPrompt.maximumSourceBytes
        else {
            if let token = selection.replacementToken { SelectionReplacement.invalidate(if: token) }
            if selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                showSelectionHint(for: .empty, near: selection.bounds)
            } else {
                chip.show(L10n.tr("That selection is too long to edit."), near: selection.bounds, for: 5)
            }
            return nil
        }
        // Apple's model loads while the request is still being spoken.
        if preferences.voiceRefinementEngine == "apple" {
            AppleWriterWarmSession.shared.prewarm(CoreVoiceEditPrompt.localInstruction)
        }
        return selection
    }

    private func performEdit(preferences: Preferences, sourcePID: Int32?) async {
        guard VoiceEditService.isConfigured(preferences) else {
            chip.show(
                L10n.tr("Needs setup"), near: nil, for: 5,
                action: (L10n.tr("Set up…"), { [weak self] in self?.openSetup?() }))
            return
        }
        let outcome = await captureSelection(in: sourcePID)
        guard !Task.isCancelled else { return }
        guard let selection = outcome.selection else {
            showSelectionHint(for: outcome)
            return
        }
        let bounds = selection.bounds, original = selection.text
        // The lease ends with this edit, whichever way it ends; a written one is already spent.
        defer { if let token = selection.replacementToken { SelectionReplacement.invalidate(if: token) } }
        guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showSelectionHint(for: .empty, near: bounds)
            return
        }
        guard original.utf8.count <= CoreVoiceEditPrompt.maximumSourceBytes else {
            chip.show(L10n.tr("That selection is too long to edit."), near: bounds, for: 5)
            return
        }
        // Apple's model loads while the request is still being spoken.
        if preferences.voiceRefinementEngine == "apple" {
            AppleWriterWarmSession.shared.prewarm(CoreVoiceEditPrompt.localInstruction)
        }
        // Esc in the recording indicator cancels with nothing changed.
        guard let instruction = await recordInstruction?(), !Task.isCancelled else { return }
        do {
            try CoreVoiceEditPrompt.validateInputs(source: original, instruction: instruction)
        } catch {
            showFailure(Self.editMessage(for: error), error: error, near: bounds)
            return
        }
        isWriting = true
        editToken = selection.replacementToken
        editBounds = bounds
        chip.show(
            L10n.tr("Editing…"), near: bounds, for: nil, status: .working,
            action: (L10n.tr("Cancel"), { [weak self] in self?.cancelEditing() }),
            actionHelp: editKeyLabel.map { L10n.tr("Cancel") + " · " + $0 })
        let settings = TranslationSettings(preferences, engine: preferences.voiceRefinementEngine)
        let result: String
        var standIn: String?
        do {
            #if YULLO_TESTING
                if let testEdit {
                    result = try await testEdit(original, instruction)
                } else {
                    (result, standIn) = try await VoiceEditService.shared.editNoted(
                        source: original, instruction: instruction, settings: settings)
                }
            #else
                (result, standIn) = try await VoiceEditService.shared.editNoted(
                    source: original, instruction: instruction, settings: settings)
            #endif
            try CoreVoiceEditPrompt.validateResult(source: original, instruction: instruction, result: result)
            try Task.checkCancellation()
        } catch {
            // Cancelled by its key or Cancel, which already said Nothing changed.
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            showFailure(Self.editMessage(for: error), error: error, near: bounds)
            return
        }
        if TextMutationRange.identical(result, original) {
            chip.show(L10n.tr("Nothing changed."), near: bounds, for: 2.5)
            return
        }
        await writeBack(
            result, over: selection,
            done: standIn ?? L10n.tr(selection.pastes ? "Pasted · ⌘Z to undo" : "Edited · ⌘Z to undo"),
            lingering: standIn != nil, open: { [weak self] in self?.openReview?(original, instruction, result) })
    }

    private func showFailure(_ message: String, error: Error, near bounds: CGRect?) {
        guard let fix = TranslationRecoveryAction.fixing(error, writing: true) else {
            chip.show(message, near: bounds, for: 5)
            return
        }
        chip.show(
            message, near: bounds, for: 8, action: (L10n.tr(fix.titleKey()), { [weak self] in self?.openFix?(fix) }))
    }

    private static func copy(_ text: String) { DeliveryFallback.copy(text) }
    private func replaceSelection(_ token: UUID, with text: String) async throws {
        #if YULLO_TESTING
            if let testReplace { return try await testReplace(token, text) }
        #endif
        _ = try await SelectionReplacement.replace(token: token, with: text)
    }
    // No write lease: the result is on the clipboard, and the reason told apart
    // as the review tells it (ReplacementNotice.cannotReplace).
    static func cannotEdit(_ limit: SelectionReader.WriteLimit?) -> String {
        if let message = AccessibilityGrant.current().message {
            return L10n.sentences([message, L10n.tr("Result copied.")])
        }
        switch limit {
        // Read-only text is never told to be pasted into: the same line as a write refused.
        case .readOnly: return L10n.tr("This text is read-only. Result copied.")
        case .unreachable, nil:
            return L10n.tr("Yullo couldn’t reach this text field. Result copied: paste it with ⌘V.")
        }
    }

    static func editMessage(for error: Error) -> String {
        if let reason = error as? CoreVoiceEditValidationError {
            return VoiceEditIssue.validation(reason).localizedDescription
        }
        return (error as? LocalizedError)?.errorDescription ?? L10n.tr("Couldn’t edit this text.")
    }

    private func captureSelection(in sourcePID: Int32?) async -> SelectionReader.Outcome {
        #if YULLO_TESTING
            if let testCapture { return await testCapture(sourcePID) }
        #endif
        return await SelectionReplacement.captureOutcome(in: sourcePID)
    }

    // Every selection shortcut answers the same way when it has nothing to work on:
    // a short hint at the pointer, never an empty window. Text Yullo can't read is
    // never called empty.
    func showSelectionHint(for outcome: SelectionReader.Outcome, near bounds: CGRect? = nil) {
        switch outcome {
        case .selection: return
        case .empty: chip.show(L10n.tr("Select text first."), near: bounds, for: 1.5)
        case .passwordField: chip.show(L10n.tr("Yullo doesn’t edit password fields."), near: bounds, for: 2.5)
        case .unreadable:
            // Every read refused is Yullo's permission, not the app: say how to fix it.
            if let message = AccessibilityGrant.checked("read-selection").message {
                chip.show(
                    message, near: bounds, for: 10,
                    action: (L10n.tr("Allow Accessibility…"), { AccessibilityGrant.openSettings() }))
            } else {
                chip.show(L10n.tr("Couldn’t read the selection."), near: bounds, for: 2.5)
            }
        }
    }

    private func perform(output: CoreOutput, preferences: Preferences, sourcePID: Int32?) async {
        let outcome = await captureSelection(in: sourcePID)
        guard !Task.isCancelled else { return }
        guard let selection = outcome.selection else {
            showSelectionHint(for: outcome)
            return
        }
        let bounds = selection.bounds
        // The lease ends with this run, whichever way it ends; a written one is already spent.
        defer { if let token = selection.replacementToken { SelectionReplacement.invalidate(if: token) } }
        guard selection.text.utf8.count <= 262_144 else {
            chip.show(L10n.tr("That selection is too long to replace."), near: bounds, for: 5)
            return
        }
        let plan = CoreOutputPlan.make(
            for: output, presets: preferences.dictationPresets,
            defaultStyle: RewriteStyle(rawValue: preferences.voiceRefinementStyle) ?? .professional,
            fallbackLanguage: Language.enabled(preferences.enabledLanguages).first?.id ?? "en")
        if case .write = plan.task, !VoiceWritingConnection.isConfigured(preferences) {
            chip.show(
                L10n.tr("Needs setup"), near: bounds, for: 5,
                action: (L10n.tr("Set up…"), { [weak self] in self?.openSetup?() }))
            return
        }
        // Appears only if the work takes a moment, so fast results don't flash.
        let working = Task { [chip] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !Task.isCancelled { chip.show(Self.verb(for: output), near: bounds, for: nil, status: .working) }
        }
        defer { working.cancel() }
        let result: String
        let note: String?
        do {
            // Cancelling this run also stops the pending working chip, which
            // would otherwise replace "Nothing changed." and never time out.
            (result, note) = try await withTaskCancellationHandler {
                #if YULLO_TESTING
                    if let testRewrite { return (try await testRewrite(selection.text), testRewriteNote) }
                #endif
                return try await Self.rewriteNoted(selection.text, plan: plan, preferences: preferences)
            } onCancel: {
                working.cancel()
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            working.cancel()
            showFailure(
                L10n.sentences([Self.message(for: error), L10n.tr("Nothing changed.")]), error: error, near: bounds)
            return
        }
        guard !Task.isCancelled else { return }
        working.cancel()
        if TextMutationRange.identical(result, selection.text) {
            chip.show(L10n.tr("Already reads well"), near: bounds, for: 2.5, status: .done)
            return
        }
        let original = selection.text
        // A stand-in's result says which one wrote it, for as long as a message stays.
        await writeBack(
            result, over: selection,
            done: note ?? L10n.tr(selection.pastes ? "Pasted · ⌘Z to undo" : "Refined · ⌘Z to undo"),
            lingering: note != nil, open: { [weak self] in self?.openInYullo?(original) })
    }

    // Every in-place result goes back the one way the review's Replace does: the shared
    // capture lease, written with read-back, the clipboard put back, a paste only in front.
    // A try the app didn't answer, with nothing written and the lease still held, is made
    // once more, as Replace would be pressed again in the review. A result that can't go
    // back where it came from is kept on the clipboard, with the same reason the review
    // gives. True when the text was written, or may have been.
    @discardableResult private func writeBack(
        _ result: String, over selection: SelectionReader.Result, done: String, lingering: Bool,
        open: @escaping () -> Void
    ) async -> Bool {
        let bounds = selection.bounds
        guard let token = selection.replacementToken else {
            // Read-only text (a web page or PDF), or a field Yullo couldn't reach.
            Self.copy(result)
            chip.show(Self.cannotEdit(selection.limit), near: bounds, for: 6, status: .copied)
            return false
        }
        var issue: SelectionReplacement.Issue?
        for attempt in 0..<2 {
            do {
                try await replaceSelection(token, with: result)
                chip.show(
                    done, near: bounds, for: lingering ? 5 : 3, status: .done, action: (L10n.tr("Open in Yullo"), open))
                return true
            } catch SelectionReplacement.Issue.uncertain {
                chip.show(L10n.tr("Check the text. Yullo couldn’t confirm the change."), near: bounds, for: 5)
                return true
            } catch {
                issue = error as? SelectionReplacement.Issue
                guard attempt == 0, !Task.isCancelled, SelectionReplacement.Issue.retryable.contains(issue),
                    await holds(token)
                else { break }
                try? await Task.sleep(nanoseconds: Self.retryPause)
                guard !Task.isCancelled else { break }
            }
        }
        SelectionReplacement.invalidate(if: token)
        // Cancelled by its key or Cancel, which already said Nothing changed.
        guard !Task.isCancelled else { return false }
        Self.copy(result)
        let message = ReplacementNotice.copiedAfterAttempt(issue)
        if issue == .permission {
            chip.show(
                message, near: bounds, for: 10, status: .copied,
                action: (L10n.tr("Allow Accessibility…"), { AccessibilityGrant.openSettings() }))
        } else {
            chip.show(message, near: bounds, for: 6, status: .copied)
        }
        return false
    }
    static let retryPause: UInt64 = 300_000_000
    private func holds(_ token: UUID) async -> Bool {
        #if YULLO_TESTING
            if let testHolds { return await testHolds(token) }
        #endif
        return await SelectionReplacement.holds(token)
    }

    static func rewrite(_ text: String, plan: CoreOutputPlan, preferences: Preferences) async throws -> String {
        try await rewriteNoted(text, plan: plan, preferences: preferences).text
    }
    // The rewrite, and when a stand-in produced it (Apple's translation, the backup writer), the words that say so.
    static func rewriteNoted(_ text: String, plan: CoreOutputPlan, preferences: Preferences) async throws
        -> (text: String, note: String?)
    {
        switch plan.task {
        case .asSpoken:
            return (text, nil)
        case .translate(let target):
            var settings = TranslationSettings(preferences)
            settings.presetInstructions = plan.instructions
            let result = try await TranslationService.shared.translate(
                text: text, source: "auto", target: target, settings: settings)
            let standIn = result.usedAnyApple && settings.engine != "apple"
            return (try result.finished(), standIn ? result.appleFallbackNotice : nil)
        case .write(let style, let language):
            var settings = TranslationSettings(preferences, engine: preferences.voiceRefinementEngine)
            settings.presetInstructions = plan.instructions
            settings.preserveTechnicalLiterals = plan.preserveTechnicalLiterals
            if let language {
                let name = Language.catalog.first(where: { $0.id == language })?.subtitle ?? language
                settings.writingRequirements = settings.writingRequirements.writing(in: name)
            }
            return try await RefinementService.shared.refineNoted(text: text, style: style, settings: settings)
        }
    }

    static func verb(for output: CoreOutput) -> String {
        if output.isSpoken { return L10n.tr("Translating…") }
        switch output.style {
        case .email: return L10n.tr("Writing email…")
        case .light: return L10n.tr("Cleaning up…")
        default: return L10n.tr("Refining…")
        }
    }

    static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? L10n.tr("Couldn’t refine this text.")
    }
}

// A small status chip under the selection, drawn as the recording indicator's
// compact HUD. It never takes focus; VoiceOver announces each final state.
@MainActor final class RefineChip {
    // `copied`: nothing was written; the result is on the clipboard (never the ✓ of a write).
    enum Status { case plain, working, done, copied }

    private let panel: NSPanel
    private let model = Model()
    private var hide: Task<Void, Never>?
    private var escapeMonitors: [Any] = []
    // A timed chip that ran out or was dismissed with Esc, not one replaced
    // by another message or closed by its own action.
    var didExpire: (() -> Void)?

    final class Model: ObservableObject {
        @Published var text = ""
        @Published var status = Status.plain
        @Published var action: (title: String, run: () -> Void)?
        // Names the key that does the same as the action, when there is one.
        @Published var actionHelp: String?
    }

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: RefineChipView.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        // Its rounded corners stay part of the chip rather than passing a press to the app beneath.
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: RefineChipView(model: model))
    }

    #if YULLO_TESTING
        // Records each chip instead of ordering a panel on screen.
        var testShown: ((String, Status, Double?) -> Void)?
        private(set) var testAction: (() -> Void)?
        private(set) var testActionHelp: String?
        private(set) var testActionTitle: String?
    #endif

    func show(
        _ text: String, near bounds: CGRect?, for seconds: Double?, status: Status = .plain,
        action: (String, () -> Void)? = nil, actionHelp: String? = nil
    ) {
        #if YULLO_TESTING
            testAction = action?.1
            testActionTitle = action?.0
            testActionHelp = actionHelp
            if let testShown {
                testShown(text, status, seconds)
                return
            }
        #endif
        hide?.cancel()
        model.text = text
        model.status = status
        model.actionHelp = actionHelp
        model.action = action.map { title, run in
            (
                title,
                { [weak self] in
                    // The action may show the next chip; it must survive.
                    self?.dismiss()
                    run()
                }
            )
        }
        let size = panel.contentView?.fittingSize ?? NSSize(width: 280, height: RefineChipView.height)
        panel.setContentSize(size)
        panel.setFrameOrigin(Self.origin(for: size, below: bounds))
        panel.orderFrontRegardless()
        if status != .working {
            NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [.announcement: text])
        }
        removeEscapeMonitors()
        if let seconds {
            hide = Task { [weak self] in
                var left = seconds
                while left > 0 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard let self, !Task.isCancelled else { return }
                    // A pointer on its way to the fix pauses the countdown.
                    if !self.panel.frame.contains(NSEvent.mouseLocation) { left -= 0.25 }
                }
                self?.expire()
            }
            let escape: (NSEvent) -> Bool = { [weak self] event in
                guard event.keyCode == 53 else { return false }
                self?.expire()
                return true
            }
            escapeMonitors = [
                NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { _ = escape($0) },
                NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    // In a Yullo window, Esc first cancels an input method's composition.
                    if (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true {
                        return event
                    }
                    return escape(event) ? nil : event
                }
            ].compactMap { $0 }
        }
    }

    func dismiss() {
        hide?.cancel()
        removeEscapeMonitors()
        panel.orderOut(nil)
    }

    private func expire() {
        guard panel.isVisible else { return }
        dismiss()
        didExpire?()
    }

    private func removeEscapeMonitors() {
        escapeMonitors.forEach(NSEvent.removeMonitor)
        escapeMonitors = []
    }

    static func origin(for size: NSSize, below bounds: CGRect?) -> NSPoint {
        SelectionGeometry.chipOrigin(
            size: size, below: bounds,
            screens: NSScreen.screens.map { .init(frame: $0.frame, visible: $0.visibleFrame) },
            mouse: NSEvent.mouseLocation)
    }
}

// The recording indicator's completion notice: 14 × 10 padding, 12 pt text,
// a 16 pt status glyph 8 pt before it, plain accent actions at 11 pt medium.
struct RefineChipView: View {
    static let height: CGFloat = 35
    static let textLimit: CGFloat = 300
    @ObservedObject var model: RefineChip.Model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var textWidth: CGFloat {
        ceil((model.text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width)
    }

    var body: some View {
        // One line keeps the compact HUD's 23 pt corners; a wrapped message
        // takes the result card's 16 pt corners.
        let shape = RoundedRectangle(cornerRadius: textWidth > Self.textLimit ? 16 : 23)
        HStack(spacing: 8) {
            glyph
            Text(model.text).font(.system(size: 12)).lineLimit(2)
                .frame(width: min(textWidth, Self.textLimit), alignment: .leading)
            if let action = model.action {
                Button(action.title, action: action.run)
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.accent)
                    .padding(.leading, 7).help(model.actionHelp ?? action.title)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .foregroundStyle(Color.white)
        .environment(\.colorScheme, .dark)
        .background(
            VoiceHUDFill.color(dark: colorScheme == .dark, opaque: reduceTransparency || contrast == .increased),
            in: shape
        )
        .overlay { shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5) }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var glyph: some View {
        switch model.status {
        case .plain:
            EmptyView()
        case .done:
            Image(systemName: "checkmark").font(.system(size: 11, weight: .medium))
                .frame(width: 16).accessibilityHidden(true)
        case .copied:
            // The review's Copy glyph, in the same ink as the ✓.
            Image(systemName: "doc.on.doc").font(.system(size: 11, weight: .medium))
                .frame(width: 16).accessibilityHidden(true)
        case .working:
            TimelineView(.animation(minimumInterval: 0.35, paused: reduceMotion)) { context in
                let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.35) % 3
                HStack(spacing: 3) {
                    ForEach(0..<3) { index in
                        Circle().fill(Color.white.opacity(reduceMotion || tick == index ? 0.85 : 0.3))
                            .frame(width: 3, height: 3)
                    }
                }.frame(width: 16, height: 18)
            }.accessibilityHidden(true)
        }
    }
}
