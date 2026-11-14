import Foundation
import Combine

@MainActor struct SelectionVoiceEditBackend {
    var edit: (String, String, TranslationSettings) async throws -> String
    var replace: (UUID, String) async throws -> Int32
    // Keeps a lease alive while its review is in use.
    var keep: (UUID) -> Void = { _ in }
    // Whether a lease can still be written after an attempt that failed.
    var holds: (UUID) async -> Bool = { _ in false }
    // The system route also says when the backup writer made the edit instead of Apple's model.
    var editNoted: ((String, String, TranslationSettings) async throws -> (text: String, note: String?))? = nil
    static var system: Self {
        .init(
            edit: { try await VoiceEditService.shared.edit(source: $0, instruction: $1, settings: $2) },
            replace: { try await SelectionReplacement.replace(token: $0, with: $1) },
            keep: { SelectionReplacement.renew($0) }, holds: { await SelectionReplacement.holds($0) },
            editNoted: { try await VoiceEditService.shared.editNoted(source: $0, instruction: $1, settings: $2) })
    }
}

// One explicit selection and one spoken instruction. Capture authority never
// enters a model request, and a reviewed result never writes automatically.
@MainActor final class SelectionVoiceEdit: ObservableObject {
    enum Phase: Equatable { case idle, instruction, processing, review, replacing, finished, error }
    enum Recovery: Equatable {
        case none, recordInstruction, retry, credentials, processing, service, vocabulary, permissions
        // No writer is set up: one is chosen, then the same request runs.
        case writingService
        // Fixed where they are: start Ollama, or sign in to a command-line tool.
        case openOllama, signIn(CLIProvider)
    }
    @Published private(set) var phase = Phase.idle
    @Published private(set) var source = ""
    @Published private(set) var instruction = ""
    @Published private(set) var result = ""
    @Published private(set) var message = ""
    private(set) var id = UUID()
    private(set) var revision = UUID()
    private(set) var recovery = Recovery.none
    var needsKeyAccess: Bool { recovery == .credentials }
    var didChange: (() -> Void)?
    var didReplace: ((Int32) -> Void)?
    var didAcceptResult: ((UUID, String, String, RecentVoiceResultStore.DeliveryOutcome) -> Void)?
    var didAttemptReplacement: ((UUID, UUID, RecentVoiceResultStore.DeliveryOutcome) -> Void)?
    private let backend: SelectionVoiceEditBackend
    private var settings: TranslationSettings?
    private var token: UUID?
    private var sourceIsCurrent: () -> Bool = { false }
    // Replace writes somewhere of its own (the guide's Sample card), not into a selection:
    // notes about the selection or the app in front don't apply.
    private(set) var ownTarget = false
    // The app the selection came from, named when its text can't be written.
    private var sourceApp: String?
    private var operation: Task<Void, Never>?
    private var delivery = RecentVoiceResultStore.DeliveryOutcome.notInserted
    private var replacementAttempt: UUID?
    // Why the selection can no longer be replaced after an attempt, said again with later results.
    private var spent: String?
    // Each further request refines the current result against the same
    // original; Undo steps back through these, newest last.
    private var earlier: [(instruction: String, result: String)] = []

    init(backend: SelectionVoiceEditBackend? = nil) { self.backend = backend ?? .system }
    var canReplace: Bool {
        phase == .review && token != nil && sourceIsCurrent() && !result.isEmpty
            && !TextMutationRange.identical(source, result)
    }
    var canUndo: Bool { phase == .review && !earlier.isEmpty }
    // A further request is in progress while its earlier result stays shown.
    var isRefiningResult: Bool { (phase == .instruction || phase == .processing) && !result.isEmpty }
    // The selection can still be written once the result is ready.
    var hasReplacementTarget: Bool { token != nil && sourceIsCurrent() }
    var canRestoreOriginal: Bool {
        phase == .review && !result.isEmpty && !TextMutationRange.identical(source, result)
    }
    var isBusy: Bool { phase == .instruction || phase == .processing || phase == .replacing }
    var deliveryOutcome: RecentVoiceResultStore.DeliveryOutcome { delivery }
    func prepare(
        source: String, token: UUID?, settings: TranslationSettings, sourceIsCurrent: @escaping () -> Bool,
        ownTarget: Bool = false, sourceApp: String? = nil
    ) throws -> UUID {
        guard
            source.utf8.prefix(CoreVoiceEditPrompt.maximumSourceBytes + 1).count
                <= CoreVoiceEditPrompt.maximumSourceBytes
        else {
            throw VoiceEditIssue.validation(.sourceTooLong)
        }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceEditIssue.validation(.emptySource)
        }
        cancel()
        self.source = source
        self.token = token
        self.settings = settings
        self.sourceIsCurrent = sourceIsCurrent
        self.ownTarget = ownTarget
        self.sourceApp = sourceApp
        phase = .instruction
        // Apple's model loads while the request is still being spoken.
        if settings.engine == "apple" { AppleWriterWarmSession.shared.prewarm(CoreVoiceEditPrompt.localInstruction) }
        return id
    }
    // Open in Yullo after an in-place edit: the finished edit to read, copy or
    // edit again, with no write lease of its own.
    func showEdited(
        source: String, instruction: String, result: String, settings: TranslationSettings, ownTarget: Bool = false
    ) {
        cancel()
        self.source = source
        self.instruction = instruction
        self.result = result
        self.settings = settings
        // Nothing is selected elsewhere: no earlier selection's check carries over.
        token = nil
        sourceIsCurrent = { true }
        self.ownTarget = ownTarget
        phase = .review
        changed()
    }
    // `base` asks again from an earlier text (Try Again); otherwise a further
    // request edits the current result, and the first edits the original.
    func acceptInstruction(_ text: String, for expected: UUID, base: String? = nil) {
        guard id == expected, phase == .instruction, let settings else { return }
        do { try CoreVoiceEditPrompt.validateInputs(source: source, instruction: text) } catch {
            message =
                (error as? CoreVoiceEditValidationError).map { VoiceEditIssue.validation($0).localizedDescription }
                ?? error.localizedDescription
            // A further request that can't be used leaves the result as it was.
            if !result.isEmpty {
                phase = .review
                changed()
                return
            }
            recovery = .recordInstruction
            phase = .error
            changed()
            return
        }
        let previous = (instruction: instruction, result: result)
        // A result still equal to the original (a review opened on unedited text) is not
        // a result to refine: the first request edits the original.
        let refining = !previous.result.isEmpty && previous.result != source
        if !refining { instruction = text }
        recovery = .none
        message = ""
        phase = .processing
        let source = base ?? (refining ? previous.result : source), backend = backend
        operation = Task { @MainActor [weak self] in
            do {
                let output: String, standIn: String?
                if let editNoted = backend.editNoted {
                    (output, standIn) = try await editNoted(source, text, settings)
                } else {
                    (output, standIn) = (try await backend.edit(source, text, settings), nil)
                }
                try Task.checkCancellation()
                try CoreVoiceEditPrompt.validateResult(source: source, instruction: text, result: output)
                let review = try await WritingReview.inspect(
                    source: source, result: output, vocabulary: settings.personalVocabulary)
                guard let self, self.id == expected, self.phase == .processing, !Task.isCancelled else { return }
                self.operation = nil
                self.phase = .review
                // A further request that changed nothing keeps the result and its Undo.
                if refining, TextMutationRange.identical(source, output) {
                    self.message = L10n.tr("Nothing changed.")
                    self.changed()
                    return
                }
                if refining { self.earlier.append(previous) }
                self.instruction = text
                self.result = output
                self.message = [standIn, review.notice].compactMap { $0 }.joined(separator: "\n")
                // A request that changed nothing says so instead of offering a replace.
                if TextMutationRange.identical(source, output) {
                    self.message = [L10n.tr("Nothing changed."), self.message].filter { !$0.isEmpty }
                        .joined(separator: "\n")
                }
                if self.ownTarget {
                } else if !self.sourceIsCurrent() {
                    self.token = nil
                    self.message = [
                        self.message, L10n.tr("The selected text changed, so it can’t be replaced.")
                    ]
                    .filter { !$0.isEmpty }.joined(separator: "\n")
                } else if self.token == nil {
                    let issue = self.spent ?? Self.cannotReplace(in: self.sourceApp)
                    self.message = [self.message, issue].filter { !$0.isEmpty }.joined(separator: "\n")
                }
                self.didAcceptResult?(expected, self.source, output, self.delivery)
                self.changed()
            } catch {
                guard let self, self.id == expected, !Task.isCancelled else { return }
                self.operation = nil
                // A further request that fails keeps the result it would have refined.
                if refining {
                    self.message =
                        (error as? CoreVoiceEditValidationError)
                        .map { VoiceEditIssue.validation($0).localizedDescription } ?? error.localizedDescription
                    self.phase = .review
                    self.changed()
                    return
                }
                self.recovery = Self.recovery(for: error)
                self.message =
                    (error as? CoreVoiceEditValidationError)
                    .map { VoiceEditIssue.validation($0).localizedDescription } ?? error.localizedDescription
                self.phase = .error
                self.changed()
            }
        }
        changed()
    }
    func restoreOriginal() {
        guard canRestoreOriginal else { return }
        result = source
        message = [
            L10n.tr("Original restored. Other apps are unchanged."),
            delivery == .uncertain
                ? L10n.tr("Check the original app before inserting again.")
                : delivery == .inserted
                    ? L10n.tr("Earlier output was inserted. Check the original app before pasting.") : nil
        ].compactMap { $0 }.joined(separator: "\n")
        // Restoring is local. It never grants another external write lease.
        didAcceptResult?(id, source, result, delivery)
        changed()
    }
    func retry() {
        guard phase == .error, recovery == .retry, !instruction.isEmpty else { return }
        phase = .instruction
        acceptInstruction(instruction, for: id)
    }
    // After a refusal: the same original, a new instruction. From the review:
    // a further request that refines the current result.
    func prepareAnotherInstruction() -> UUID? {
        guard phase == .review || (phase == .error && recovery == .recordInstruction), !source.isEmpty else {
            return nil
        }
        if phase == .error {
            instruction = ""
            result = ""
        }
        message = ""
        recovery = .none
        phase = .instruction
        changed()
        return id
    }
    // A typed request, or one of the review's quick requests.
    func request(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .review, !text.isEmpty, prepareAnotherInstruction() != nil else { return }
        acceptInstruction(text, for: id)
    }
    // A writer was just set up: the request that needed one runs with it.
    func retry(with settings: TranslationSettings) {
        guard phase == .error, recovery == .writingService, !instruction.isEmpty else { return }
        self.settings = settings
        recovery = .none
        message = ""
        phase = .instruction
        acceptInstruction(instruction, for: id)
    }
    // A typed first request (Edit with text), or one typed again after it failed.
    func ask(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, result.isEmpty, phase == .instruction || phase == .error, !source.isEmpty else { return }
        recovery = .none
        message = ""
        phase = .instruction
        acceptInstruction(text, for: id)
    }
    // The same request again, from the text it was made on.
    var canTryAgain: Bool { phase == .review && !instruction.isEmpty && !result.isEmpty }
    func tryAgain() {
        guard canTryAgain else { return }
        let base = earlier.last?.result ?? source
        message = ""
        phase = .instruction
        changed()
        acceptInstruction(instruction, for: id, base: base)
    }
    func undo() {
        guard canUndo, let last = earlier.popLast() else { return }
        instruction = last.instruction
        result = last.result
        message = ""
        if !sourceIsCurrent() { token = nil }
        changed()
    }
    // Esc while a further request is in progress: back to the result it refines.
    func cancelRequest() -> Bool {
        guard isRefiningResult else { return false }
        operation?.cancel()
        operation = nil
        message = ""
        phase = .review
        changed()
        return true
    }
    func replaceReviewedResult() {
        guard phase == .review else { return }
        guard sourceIsCurrent() else {
            token = nil
            message = L10n.tr("The selected text changed, so it can’t be replaced.")
            changed()
            return
        }
        guard canReplace, let token else { return }
        self.token = nil  // Claim once, before any asynchronous work.
        let expected = id, output = result, backend = backend, attempt = UUID()
        replacementAttempt = attempt
        phase = .replacing
        message = L10n.tr("Replacing selection…")
        delivery = .uncertain
        didAttemptReplacement?(expected, attempt, .uncertain)
        changed()
        operation = Task { @MainActor [weak self] in
            do {
                try Task.checkCancellation()
                guard self?.id == expected, self?.sourceIsCurrent() == true else {
                    throw SelectionReplacement.Issue.staleSelection
                }
                let pid = try await backend.replace(token, output)
                guard let self else { return }
                self.didAttemptReplacement?(expected, attempt, .inserted)
                guard self.id == expected else { return }
                if Task.isCancelled {
                    self.acceptLateReceipt(.inserted, attempt: attempt)
                    return
                }
                self.operation = nil
                self.delivery = .inserted
                self.phase = .finished
                self.message = L10n.tr("Selection replaced")
                self.changed()
                self.didReplace?(pid)
            } catch {
                let issue = error as? SelectionReplacement.Issue
                let outcome: RecentVoiceResultStore.DeliveryOutcome =
                    issue != nil && issue != .uncertain ? .notInserted : .uncertain
                // Nothing written and the lease still held: Replace stays, re-checking the selection first.
                var again = false
                if outcome == .notInserted, SelectionReplacement.Issue.retryable.contains(issue), !Task.isCancelled {
                    again = await backend.holds(token)
                }
                guard let self else { return }
                self.didAttemptReplacement?(expected, attempt, outcome)
                guard self.id == expected else { return }
                if Task.isCancelled {
                    self.acceptLateReceipt(outcome, attempt: attempt)
                    return
                }
                self.operation = nil
                self.delivery = outcome
                self.phase = .review
                self.recovery = issue == .permission ? .permissions : .none
                if again, let retry = Self.retryMessage(issue) {
                    // What happened; Replace stays for another try, Copy beside it.
                    self.token = token
                    self.spent = nil
                    self.message = retry
                } else if issue == .staleSelection {
                    // Copy is the way on; nothing goes on the clipboard until it is pressed.
                    self.message = L10n.tr("The selected text changed, so nothing was replaced.")
                } else if outcome == .notInserted, issue != .permission, DeliveryFallback.copy(output) {
                    // Nothing was written and it can't be tried again: the result goes on the
                    // clipboard, and the notice says so. Permission keeps its own way to fix it.
                    self.message = L10n.tr("Couldn’t replace the text. Result copied.")
                } else {
                    self.message = Self.replacementMessage(issue)
                }
                if !again { self.spent = Self.spentMessage(issue, outcome) }
                self.changed()
            }
        }
    }
    func invalidateTargetIfChanged() {
        guard phase != .idle, !sourceIsCurrent() else { return }
        token = nil
        if phase == .replacing {
            operation?.cancel()
            operation = nil
            phase = .review
            delivery = .uncertain
            message = L10n.tr("Check the original app before inserting again.")
            changed()
            return
        }
        if phase == .review {
            message = L10n.tr("The selected text changed, so it can’t be replaced.")
            changed()
        }
    }
    func suspendForSettings() {
        guard phase == .review || phase == .error else { return }
        // Repair navigation keeps the accepted text, never an old write lease.
        token = nil
        revision = UUID()
    }
    func resumeAfterSettings(_ settings: TranslationSettings) {
        guard phase == .review || phase == .error else { return }
        self.settings = settings
        if phase == .error, !instruction.isEmpty {
            recovery = .retry
        } else if phase == .review {
            recovery = .none
            if !ownTarget { message = Self.cannotReplace(in: sourceApp) }
        }
        changed()
    }
    func cancel() {
        operation?.cancel()
        operation = nil
        id = UUID()
        revision = UUID()
        token = nil
        sourceIsCurrent = { false }
        settings = nil
        source = ""
        instruction = ""
        result = ""
        message = ""
        recovery = .none
        delivery = .notInserted
        replacementAttempt = nil
        spent = nil
        earlier = []
        phase = .idle
    }
    private func acceptLateReceipt(_ outcome: RecentVoiceResultStore.DeliveryOutcome, attempt: UUID) {
        guard replacementAttempt == attempt, phase == .review else { return }
        delivery = outcome
        message = L10n.tr(
            outcome == .inserted
                ? "Earlier output was inserted. Check the original app before pasting."
                : outcome == .uncertain
                    ? "Check the original app before inserting again."
                    : "Couldn’t replace the selection.")
        changed()
    }
    private func changed() {
        revision = UUID()
        // However many rounds a review takes, its lease counts from the latest one.
        if phase == .review, let token { backend.keep(token) }
        didChange?()
    }
    private static func recovery(for error: Error) -> Recovery {
        if error is ProcessingPolicyIssue { return .processing }
        // A writer on this Mac that can't run now names its setup; a declined
        // edit can be said another way.
        if let issue = error as? OllamaIssue {
            switch issue {
            case .notRunning: return .openOllama
            case .notInstalled, .noModel, .modelMissing: return .service
            default: return .retry
            }
        }
        if let issue = error as? AppleWriterIssue {
            switch issue {
            case .unavailable, .unsupportedLanguage: return .service
            case .declined: return .recordInstruction
            case .tooLong: return .none
            case .failed: return .retry
            }
        }
        if let issue = error as? APIError {
            switch issue {
            case .keychain where issue.needsKeyPermission: return .credentials
            case .keychain where issue.isKeychainBusy: return .retry
            case .keychain: return .service
            case .invalidEndpoint, .missingModel, .http(401), .http(403), .http(404): return .service
            case .refused: return .recordInstruction
            default: return .retry
            }
        }
        if let issue = error as? CLIError {
            switch issue {
            case .signedOut(let provider): return .signIn(provider)
            case .codexSignInFileMissing: return .signIn(.codex)
            case .invalidExecutable, .unavailable, .unsupportedVersion, .invalidModel, .missingModel,
                .modelUnavailable:
                return .service
            case .usageLimit: return .writingService
            default: return .retry
            }
        }
        let validation: CoreVoiceEditValidationError?
        if let issue = error as? VoiceEditIssue {
            switch issue {
            case .connectionRequired: return .writingService
            case .refused: return .recordInstruction
            case .offline, .truncated: return .retry
            case .validation(let reason): validation = reason
            }
        } else {
            validation = error as? CoreVoiceEditValidationError
        }
        switch validation {
        case .emptyInstruction, .instructionTooLong, .instructionEcho: return .recordInstruction
        case .emptySource, .sourceTooLong, .resultTooLong: return .none
        case .invalidTerms: return .vocabulary
        case .emptyResult, nil: return .retry
        }
    }
    // After an attempt that wrote nothing and can run again.
    // No dead end: what to do instead, with the app named when it is known.
    static func cannotReplace(in app: String?) -> String {
        app.map {
            L10n.format("%@ doesn’t let Yullo edit this text. Paste the result there with ⌘V.", $0)
        }
            ?? L10n.tr("This app doesn’t let Yullo edit this text. Paste the result there with ⌘V.")
    }
    private static func retryMessage(_ issue: SelectionReplacement.Issue?) -> String? {
        switch issue {
        case .focusUnavailable: return L10n.tr("The app didn’t respond, so nothing was replaced.")
        case .failed: return L10n.tr("Couldn’t replace the text, so nothing changed.")
        default: return nil
        }
    }
    // With later results, once an attempt has used up the selection.
    private static func spentMessage(
        _ issue: SelectionReplacement.Issue?, _ outcome: RecentVoiceResultStore.DeliveryOutcome
    ) -> String {
        if outcome == .uncertain { return L10n.tr("Check the original app before inserting again.") }
        switch issue {
        case .permission:
            return AccessibilityGrant.current().message
                ?? L10n.tr("Allow Accessibility access, then select the text again.")
        case .unsupported: return cannotReplace(in: nil)
        case .staleSelection: return L10n.tr("The selected text changed, so it can’t be replaced.")
        default: return L10n.tr("Couldn’t access the original selection. Select it again.")
        }
    }
    private static func replacementMessage(_ issue: SelectionReplacement.Issue?) -> String {
        switch issue {
        case .permission:
            return AccessibilityGrant.current().message
                ?? L10n.tr("Allow Accessibility access, then select the text again.")
        case .unsupported: return cannotReplace(in: nil)
        case .focusUnavailable: return L10n.tr("Couldn’t access the original selection. Select it again.")
        case .staleSelection: return L10n.tr("The selected text changed, so it can’t be replaced.")
        case .failed, .notAnswering: return L10n.tr("Couldn’t replace the selection.")
        case .uncertain, nil: return L10n.tr("Check the original app before inserting again.")
        }
    }
}
