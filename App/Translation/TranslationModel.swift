import SwiftUI
import AppKit
import AVFoundation
import Translation
import NaturalLanguage
import ApplicationServices

// `sample` is the setup guide's read-aloud sample; it never names an editor side.
enum SpeechSide: Equatable { case source, translation, sample }
enum TranslationRecoveryAction: Equatable {
    case keychain, service, writingService, openOllama, appleLanguages, appleIntelligence, accessibility
    case languages, shortcuts, readAloud, systemVoices
    // The service works but can't answer for now (a usage limit): pick another one.
    case anotherService(writing: Bool)

    // The button that does what the message asks, in one or two words.
    func titleKey(writingSetup: Bool = false) -> String {
        switch self {
        case .keychain: return "API key access…"
        case .openOllama: return "Open Ollama"
        case .appleLanguages: return "Download languages…"
        case .appleIntelligence: return "Turn on Apple Intelligence…"
        case .accessibility: return "Allow access…"
        case .languages: return "Edit languages…"
        case .shortcuts: return "Change shortcut…"
        case .readAloud: return "Set up…"
        case .systemVoices: return "Add a voice…"
        case .service, .writingService: return writingSetup ? "Set up a writing service…" : "Service settings…"
        case .anotherService: return "Choose Another Service…"
        }
    }
    // With a button that offers another service, the notice gives only the reason.
    static func notice(_ message: String, fix: TranslationRecoveryAction?) -> String {
        guard case .anotherService = fix else { return message }
        return message.replacingOccurrences(of: L10n.tr("Try again later or choose another service."), with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // The one fix a setup problem points to. Nil when trying again is the answer.
    static func fixing(_ error: Error, writing: Bool) -> TranslationRecoveryAction? {
        let service: TranslationRecoveryAction = writing ? .writingService : .service
        if let failure = error as? TranslationRoute.Failure {
            return fixing(failure.api, writing: writing) ?? fixing(failure.apple, writing: writing)
        }
        switch error {
        case APIError.keychain: return .keychain
        case APIError.invalidEndpoint, APIError.missingModel, APIError.http(401), APIError.http(403),
            APIError.http(404):
            return service
        case CLIError.invalidExecutable, CLIError.unavailable, CLIError.unsupportedVersion, CLIError.invalidModel,
            CLIError.missingModel:
            return service
        case CLIError.usageLimit: return .anotherService(writing: writing)
        case CLIError.modelUnavailable: return service
        case LocalTranslationIssue.unavailable, LocalTranslationIssue.unsupportedLanguage: return service
        case ModelLibraryError.unknownModel, ModelLibraryError.unavailable: return service
        case OllamaIssue.notRunning: return .openOllama
        case OllamaIssue.notInstalled, OllamaIssue.noModel, OllamaIssue.modelMissing: return service
        case AppleTranslationIssue.downloadRequired: return .appleLanguages
        case AppleWriterIssue.unavailable(.intelligenceOff): return .appleIntelligence
        case let issue as ProcessingPolicyIssue where issue == .onDeviceOnly: return service
        case RefinementIssue.connectionRequired: return .writingService
        default: return nil
        }
    }
}

struct TranslationComparisonRequest {
    let snapshot: VoiceComparisonSnapshot
    let isCurrent: () -> Bool
    let restoreOriginal: () -> Void
}

struct TranslatorWritingSelection: Equatable {
    let style: RewriteStyle
    let preset: CoreDictationPresetRecord?
    let preserveTechnicalLiterals: Bool
}

// Scenario mode: a temporary preset described in a sentence. It lives only in
// memory, so it never enters saved preferences and ends at quit. Ending it
// leaves the saved preset selection exactly as it was.
struct DictationScenario: Equatable {
    static let idPrefix = "scenario."
    let record: CoreDictationPresetRecord
    var title: String { DictationPresetPresentation.activeTitle(record) }
    static func make(description: String) -> DictationScenario? {
        guard let proposal = PresetDescribing.localProposal(description) else { return nil }
        let record = CoreDictationPresetRecord(
            id: idPrefix + UUID().uuidString,
            name: String(String.UnicodeScalarView(proposal.name.unicodeScalars.prefix(64))),
            definition: proposal.definition)
        guard (try? CoreDictationPresetsConfiguration(records: []).activatingTemporary(record)) != nil else {
            return nil
        }
        return DictationScenario(record: record)
    }
}

final class Model: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    @Published var scenario: DictationScenario?
    @Published var source = "" {
        didSet {
            if !TextMutationRange.identical(source, oldValue) {
                sourceRevision &+= 1
                sourceCharacterCount = source.count
                if pendingDirectionChoice?.sourceRevision != nil { pendingDirectionChoice = nil }
                if !selectionContext && !Self.hasContent(source) && Self.hasContent(oldValue) {
                    resetNormalDirectionChoice()
                }
                inputChanged(preserveOutput: true)
            }
        }
    }
    private var sourceRevision: UInt64 = 0
    private var sourceContextID = UUID()
    @Published var sourceVoiceState: SourceVoiceState = .idle
    @Published var sourceVoiceUnavailable = false
    var startSourceDictation: (() -> Void)?
    var editSelectionWithVoice: (() -> Void)?
    func captureSourceDictation() -> SourceDictationSnapshot {
        SourceDictationSnapshot(text: source, revision: sourceRevision, context: sourceContextID)
    }
    func matchesSourceDictation(_ snapshot: SourceDictationSnapshot) -> Bool {
        TextMutationRange.identical(snapshot.text, source) && snapshot.revision == sourceRevision
            && snapshot.context == sourceContextID
    }
    func hasSourceDictationContext(_ snapshot: SourceDictationSnapshot) -> Bool { snapshot.context == sourceContextID }
    func synchronizeSourceDictation(_ snapshot: SourceDictationSnapshot, from current: String? = nil, expected: String)
        -> Bool
    {
        guard snapshot.context == sourceContextID,
            TextMutationRange.identical(source, current ?? snapshot.text)
                || TextMutationRange.identical(source, expected)
        else { return false }
        if !TextMutationRange.identical(source, expected) { source = expected }
        return true
    }
    func invalidateSourceDictationTarget() { sourceContextID = UUID() }
    // A non-empty trimmed text, without copying it: an editor's bridged
    // document can make each trimmed copy cost tens of milliseconds.
    var hasSourceText: Bool { Self.hasContent(source) }
    nonisolated static func hasContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) }
    }
    // A fresh main-translator presentation asks its source editor for the caret.
    @Published private(set) var sourceFocusRequest = 0
    func requestSourceFocus() { sourceFocusRequest &+= 1 }
    @Published private(set) var sourceCharacterCount = 0
    @Published private(set) var sourceWordCount = 0
    @Published var detectedLanguages: [String] = []
    @Published var sourceLanguage = "auto" {
        didSet {
            if sourceLanguage != oldValue {
                pendingDirectionChoice = nil
                rememberLanguages()
                inputChanged()
            }
        }
    }
    @Published var targetLanguage = "en" {
        didSet {
            if targetLanguage != oldValue {
                rememberLanguages()
                if !settingTargetWithoutProcessing { inputChanged() }
            }
        }
    }
    private var settingTargetWithoutProcessing = false
    let windowSession: WindowSession
    private var quickReturnExpiryTask: Task<Void, Never>?
    private var quickReturnRequiresManualProcessing = false
    private var applyingPreferences = false
    var openSettings: (() -> Void)?
    var openTranslationRecovery: ((TranslationRecoveryAction) -> Void)?
    var presentTranslationComparison: ((TranslationComparisonRequest) -> Void)?
    var dismissTranslationComparison: (() -> Void)?
    var visibilityChanged: (() -> Void)?
    var interfaceLanguageChanged: (() -> Void)?
    var previewSettingsAppearance: ((String) -> Void)?
    var previewSettingsWindowStyle: ((String) -> Void)?
    @Published var preferences: Preferences
    // Settings previews the Yullo window text size while its slider is dragged;
    // the saved preference changes only on release.
    @Published var previewTextSize: Double?
    var textSize: Double { previewTextSize ?? preferences.textSize }
    @Published var translating = false
    @Published private(set) var isTranslationPending = false
    @Published private(set) var outputIsStale = false
    @Published private(set) var needsTranslationRetry = false
    @Published private(set) var translationRecoveryAction: TranslationRecoveryAction?
    @Published private(set) var canRetryPreferredTranslation = false
    private enum CopyFeedback { case copied, failed }
    @Published private var copyFeedback: CopyFeedback?
    var copyConfirmationVisible: Bool { copyFeedback == .copied }
    var copyFailed: Bool { copyFeedback == .failed }
    private var copyConfirmationID = UUID()
    @Published var translated = "" { didSet { translationIncomplete = false } }
    // Part of the source came back untranslated: shown with a Retry, never
    // written back over the selection or kept in History.
    @Published private(set) var translationIncomplete = false
    @Published private(set) var processingTranslationDraft = ""
    private enum OutputProgressMode: Equatable { case translation, refinement }
    private var outputProgressMode: OutputProgressMode?
    private var outputProgressID = UUID()
    private var outputProgressTask: Task<Void, Never>?
    private var outputProgressContinuation: AsyncStream<TranslationProgress>.Continuation?
    @Published private(set) var refiningTranslation = false
    @Published private(set) var translationWritingSelection: TranslatorWritingSelection?
    var translationWritingStyle: RewriteStyle? { translationWritingSelection?.style }
    @Published private(set) var translationWritingReviewNotice: String?
    private var refinementTask: Task<Void, Never>?
    private var refinementRevision = UUID()
    private var refinementPreviousNotice: String?
    private var refinementPreviousRecoveryAction: TranslationRecoveryAction?
    // The writing choice whose refinement stopped for key access.
    private var refinementStoppedForKey: TranslatorWritingSelection?
    private var translationComparisonTicket: UUID?
    private struct AcceptedTranslation {
        let id: UUID
        let source: String
        let sourceLanguage: String
        let targetLanguage: String
        let text: String
        let historyRecordID: UUID?
        let notice: String
        let canRetryPreferred: Bool
        let recoveryAction: TranslationRecoveryAction?
        var isSource = false
    }
    private var acceptedTranslation: AcceptedTranslation?
    private var translationTask: Task<Void, Never>?
    var resultHistoryStore: ResultHistoryStore?
    var historyWriteFailed: ((Error) -> Void)?
    var historyWriteSucceeded: (() -> Void)?
    private var historyWriteTask: Task<Void, Never>?
    private var outputHistoryRecordID: UUID?
    private var debounceTask: Task<Void, Never>?
    private var detectionTask: Task<Void, Never>?
    private var detectionDelayTask: Task<Void, Never>?
    private var detectionID = UUID()
    private var detectionSource = ""
    private var completedDetectionSource = ""
    private var swappingLanguages = false
    @Published private(set) var selectionRevision = 0
    var selectionContext = false
    // Refine selected text: the selection is rewritten in its own language and
    // never translated, until an explicit language, Swap or Translate choice.
    @Published private(set) var selectionRefinesOnly = false
    private var normalSourceLanguage = "auto"
    private var normalDraftID = UUID()
    private var normalManualTargetContext: UUID?
    private struct PendingDirectionChoice {
        let sourceRevision: UInt64?
        let selectionRevision: Int
        let selection: Bool
        let normalDraft: UUID
        let target: String
    }
    private var pendingDirectionChoice: PendingDirectionChoice?
    @Published private var directionLearning = DirectionLearningHistory()
    private static let directionLearningKey = "yullo.directionLearning.v1"
    private static let directionMigrationKey = "yullo.directionLearningMigrated.v1"
    var learnedDirectionCount: Int { directionLearning.activeRecordCount(now: Date()) }
    private struct NormalContext {
        let source: String
        let output: String
        let sourceLanguage: String
        let targetLanguage: String
        let analysis: InputAnalysis?
        var acceptedTranslation: AcceptedTranslation? = nil
        var writingSelection: TranslatorWritingSelection? = nil
        var writingReviewNotice: String? = nil
        var historyRecordID: UUID? = nil
        var notice = ""
        var recoveryAction: TranslationRecoveryAction? = nil
        var canRetryPreferred = false
    }
    private var normalContext: NormalContext?
    #if YULLO_TESTING
        var testCopyConfirmationReceipt: UUID { copyConfirmationID }
        func testFinishCopyConfirmation(_ receipt: UUID) { finishCopyConfirmation(receipt) }
        var testExecutor: ((String) async throws -> String)?
        var testTranslationService: TranslationService?
        var testInputAnalyzer: (@Sendable (String) -> InputAnalysis)?
        var testLocalPreparation: (@Sendable (String) async -> Void)?
        var testClipboardWriter: ((String) -> Bool)?
        var testReplacementExecutor: ((UUID, String) async throws -> Int32)?
        var testRefinementService: RefinementService?
    #endif
    var selectionReplaced: ((Int32) -> Void)?
    @Published private(set) var replacingSelection = false
    @Published private var replacementToken: UUID?
    // Fixed at capture: read-only page selections never offer Replace, while a
    // failed attempt keeps the unavailable button in place until the session ends.
    @Published private(set) var selectionOffersReplacement = false
    private var selectedOriginalText: String?
    var selectionReplacementTokenForVoiceEdit: UUID? {
        selectionContext && !replacingSelection ? replacementToken : nil
    }
    private var replacementTask: Task<Void, Never>?
    private var replacementID = UUID()
    private var requestID = UUID()
    @Published var notice = ""
    @Published var openKey = Shortcut.open
    @Published var selectionKey = Shortcut.selection
    @Published var inactiveGlobalShortcutIDs: Set<UInt32> = []
    func adoptInitialLanguages(_ ids: [String]) {
        var config = preferences
        config.adoptSystemLanguages(ids)
        apply(config, restartAutomaticTranslation: false)
    }
    @discardableResult func adoptInitialShortcutProfile(_ profile: ShortcutProfile) -> Bool {
        var config = preferences
        guard config.applyRecommendedShortcuts(profile),
            let open = try? JSONEncoder().encode(profile.open),
            let selection = try? JSONEncoder().encode(profile.selection)
        else { return false }
        openKey = profile.open
        selectionKey = profile.selection
        languageDefaults.set(open, forKey: "openShortcut")
        languageDefaults.set(selection, forKey: "selectionShortcut")
        apply(config, restartAutomaticTranslation: false)
        return true
    }
    func canUseBuiltInLocalShortcut(_ command: Shortcut) -> Bool {
        ![
            openKey, selectionKey, preferences.localTranslateShortcut, preferences.copyShortcut,
            preferences.replaceShortcut, preferences.closeShortcut, preferences.dictationShortcut,
            preferences.voiceTranslationShortcut, preferences.scenarioShortcut, preferences.refineSelectionShortcut
        ].contains { $0.conflicts(command) }
    }
    var displayedTranslation: String {
        (isTranslationPending || refiningTranslation) && !processingTranslationDraft.isEmpty
            ? processingTranslationDraft : output
    }
    private struct OutputProgressSubscription {
        let send: @Sendable (TranslationProgress) -> Void
        let finish: () -> Void
    }
    private func endOutputProgress(mode: OutputProgressMode? = nil) {
        guard mode == nil || mode == outputProgressMode else { return }
        outputProgressID = UUID()
        outputProgressContinuation?.finish()
        outputProgressTask?.cancel()
        outputProgressContinuation = nil
        outputProgressTask = nil
        outputProgressMode = nil
        if !processingTranslationDraft.isEmpty { processingTranslationDraft = "" }
    }
    // One latest-value channel per operation keeps provider callbacks off the
    // UI actor without enqueueing a task for every incoming token.
    private func beginOutputProgress(
        mode: OutputProgressMode, isCurrent: @escaping (Model) -> Bool
    ) -> OutputProgressSubscription {
        endOutputProgress()
        let id = UUID()
        outputProgressID = id
        outputProgressMode = mode
        let channel = AsyncStream<TranslationProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        outputProgressContinuation = channel.continuation
        let consumer = Task { @MainActor [weak self] in
            var sequence: UInt64 = 0
            for await update in channel.stream {
                guard !Task.isCancelled, let self, self.outputProgressID == id, isCurrent(self) else { break }
                guard update.sequence > sequence else { continue }
                sequence = update.sequence
                if !TextMutationRange.identical(self.processingTranslationDraft, update.text) {
                    self.processingTranslationDraft = update.text
                }
            }
        }
        outputProgressTask = consumer
        return .init(
            send: { update in channel.continuation.yield(update) },
            finish: { [weak self] in
                channel.continuation.finish()
                consumer.cancel()
                guard let self, self.outputProgressID == id else { return }
                self.endOutputProgress()
            })
    }
    var output: String { translated }
    @Published var speaking = false
    @Published private(set) var speechSide: SpeechSide?
    // While speaking: true once the speech is audible, after any synthesis wait.
    @Published private(set) var speechAudible = false
    // Why the guide's sample could not be read; the translator's notice stays untouched.
    @Published private(set) var sampleSpeechIssue: String?
    private var activeSpeechText = ""
    private var activeSpeechLanguage = "en"
    @Published var slowSpeech = false
    private var speaker: AVSpeechSynthesizer?
    private var activeUtterance: AVSpeechUtterance?
    private var speechTask: Task<Void, Never>?
    private var speechID = UUID()
    private var audioPlayer: AVAudioPlayer?
    // A long local passage plays its first sentences while the rest is
    // generated; the rest plays as soon as both are ready.
    private var speechContinuation: Task<Void, Never>?
    private var pendingSpeechAudio: Data?
    private var pendingSpeechFallback: String?
    private var awaitingSpeechContinuation = false
    private var continuationPlaybackRate: Float = 1
    private let languageDefaults: UserDefaults
    private var rememberSelection = false
    convenience override init() { self.init(languageDefaults: .standard) }
    init(languageDefaults: UserDefaults, windowSession: WindowSession = WindowSession()) {
        self.windowSession = windowSession
        self.languageDefaults = languageDefaults
        self.preferences = Preferences.load(defaults: languageDefaults)
        super.init()
        ProcessingPolicyController.shared.update(preferences.processingPolicy)
        loadDirectionLearning()
        L10n.configure(preferences.interfaceLanguage)
        _ = Connectivity.shared
        if languageDefaults === UserDefaults.standard {
            APIStreamingFallback.observe { [weak self] endpoint, model in
                DispatchQueue.main.async { self?.recordAPIStreamingUnsupported(endpoint: endpoint, model: model) }
            }
            let legacy = languageDefaults.persistentDomain(forName: "local.glasstranslate.prototype") ?? [:]
            for name in ["openShortcut", "selectionShortcut"] where languageDefaults.data(forKey: name) == nil {
                if let data = legacy[name] as? Data { languageDefaults.set(data, forKey: name) }
            }
        }
        let saved = languageDefaults.dictionary(forKey: "yullo.lastLanguages") ?? [:]
        let from = saved["source"] as? String ?? "auto"
        let to = saved["target"] as? String ?? preferences.defaultTarget
        let enabled = Language.enabled(preferences.enabledLanguages)
        sourceLanguage = from == "auto" || enabled.contains(where: { $0.id == from }) ? from : "auto"
        targetLanguage =
            [to, preferences.defaultTarget, Language.canonicalCode(preferences.interfaceLanguage)]
            .first { code in enabled.contains { $0.id == code } } ?? enabled[0].id
        normalSourceLanguage = sourceLanguage
        rememberSelection = true
        if let data = languageDefaults.data(forKey: "openShortcut"),
            let key = try? JSONDecoder().decode(Shortcut.self, from: data)
        {
            openKey = key
        }
        if let data = languageDefaults.data(forKey: "selectionShortcut"),
            let key = try? JSONDecoder().decode(Shortcut.self, from: data)
        {
            selectionKey = key
        }
        // Global keys copied from a legacy domain arrive after the refine default.
        if [openKey, selectionKey].contains(where: { $0.conflicts(preferences.refineSelectionShortcut) }) {
            preferences.refineSelectionShortcut = .unassigned
        }
        // So do the default Refine in place and Edit with voice keys.
        let defaultKeys = Preferences().outputShortcutKeys
        for (id, key) in preferences.outputShortcutKeys
        where key == defaultKeys[id] && [openKey, selectionKey].contains(where: { $0.conflicts(key) }) {
            preferences.outputShortcutKeys[id] = .unassigned
        }
    }
    private func rememberLanguages() {
        guard rememberSelection, !swappingLanguages else { return }
        if !selectionContext {
            normalSourceLanguage = sourceLanguage
            languageDefaults.set(["source": sourceLanguage, "target": targetLanguage], forKey: "yullo.lastLanguages")
        }
    }
    // A menu choice is committed like a target choice: it skips the typing
    // pause. Auto-detect still waits for the current source's analysis.
    func chooseSourceLanguage(_ code: String) {
        guard code == "auto" || Language.enabled(preferences.enabledLanguages).contains(where: { $0.id == code }),
            sourceLanguage != code
        else { return }
        sourceLanguage = code
        translateCommittedInputIfAutomatic()
    }
    func chooseTargetLanguage(_ code: String) {
        guard Language.enabled(preferences.enabledLanguages).contains(where: { $0.id == code }) else { return }
        let changed = targetLanguage != code
        if changed { selectionRefinesOnly = false }
        if !selectionContext { normalManualTargetContext = normalDraftID }
        targetLanguage = code
        noteExplicitDirectionChoice()
        if selectionContext { rememberSelectionDirection() } else { recordPendingDirectionChoice() }
        if changed { translateCommittedInputIfAutomatic() }
    }
    // More languages… in a To menu: the language joins your languages, then becomes the target.
    func chooseNewTargetLanguage(_ code: String) {
        guard Language.catalog.contains(where: { $0.id == code }) else { return }
        if !preferences.enabledLanguages.contains(code) {
            var updated = preferences
            updated.enabledLanguages.append(code)
            apply(updated, restartAutomaticTranslation: false)
        }
        chooseTargetLanguage(code)
    }
    var ordinaryTranslationTarget: String {
        selectionContext ? normalContext?.targetLanguage ?? preferences.defaultTarget : targetLanguage
    }
    // Setup chooses the ordinary translator's target without scheduling a
    // request for text hidden behind Settings, or changing either voice target.
    @discardableResult func setTranslationTargetWithoutProcessing(_ code: String) -> Bool {
        guard Language.enabled(preferences.enabledLanguages).contains(where: { $0.id == code }) else { return false }
        normalManualTargetContext = normalDraftID
        pendingDirectionChoice = nil
        if selectionContext {
            if let saved = normalContext {
                normalContext = NormalContext(
                    source: saved.source, output: saved.targetLanguage == code ? saved.output : "",
                    sourceLanguage: saved.sourceLanguage, targetLanguage: code, analysis: saved.analysis,
                    acceptedTranslation: saved.targetLanguage == code ? saved.acceptedTranslation : nil,
                    writingSelection: saved.targetLanguage == code ? saved.writingSelection : nil,
                    writingReviewNotice: saved.targetLanguage == code ? saved.writingReviewNotice : nil,
                    historyRecordID: saved.targetLanguage == code ? saved.historyRecordID : nil,
                    notice: saved.targetLanguage == code ? saved.notice : "",
                    recoveryAction: saved.targetLanguage == code ? saved.recoveryAction : nil,
                    canRetryPreferred: saved.targetLanguage == code && saved.canRetryPreferred)
                languageDefaults.set(["source": saved.sourceLanguage, "target": code], forKey: "yullo.lastLanguages")
            }
        } else if targetLanguage != code {
            settingTargetWithoutProcessing = true
            targetLanguage = code
            settingTargetWithoutProcessing = false
            invalidateTranslation()
        }
        return true
    }
    private func rememberSelectionDirection() {
        languageDefaults.set(targetLanguage, forKey: "yullo.selectionTarget")
        recordPendingDirectionChoice()
    }
    private func noteExplicitDirectionChoice() {
        if !selectionContext { normalManualTargetContext = normalDraftID }
        let revision: UInt64? = hasSourceText ? sourceRevision : nil
        pendingDirectionChoice = PendingDirectionChoice(
            sourceRevision: revision, selectionRevision: selectionRevision,
            selection: selectionContext, normalDraft: normalDraftID, target: targetLanguage)
    }
    private func recordPendingDirectionChoice() {
        guard let choice = pendingDirectionChoice else { return }
        guard preferences.learnTranslationDirections,
            (choice.sourceRevision == nil || choice.sourceRevision == sourceRevision), choice.target == targetLanguage,
            choice.selection == selectionContext,
            (choice.selection ? choice.selectionRevision == selectionRevision : choice.normalDraft == normalDraftID)
        else {
            pendingDirectionChoice = nil
            return
        }
        guard hasSourceText else { return }
        let from =
            sourceLanguage == "auto"
            ? (completedDetectionSource == source && detectedLanguages.count == 1 ? detectedLanguages.first : nil)
            : sourceLanguage
        guard let from else {
            if completedDetectionSource == source && choice.sourceRevision != nil { pendingDirectionChoice = nil }
            return
        }
        pendingDirectionChoice = nil
        guard from != targetLanguage, Language.catalog.contains(where: { $0.id == from }),
            Language.catalog.contains(where: { $0.id == targetLanguage })
        else { return }
        directionLearning.record(source: from, target: targetLanguage, now: Date())
        persistDirectionLearning()
    }
    private func loadDirectionLearning() {
        let stored = languageDefaults.data(forKey: Self.directionLearningKey).flatMap {
            try? JSONDecoder().decode(DirectionLearningHistory.self, from: $0)
        }
        directionLearning = stored ?? DirectionLearningHistory()
        guard !languageDefaults.bool(forKey: Self.directionMigrationKey) else { return }
        if stored == nil && preferences.learnTranslationDirections {
            let legacy =
                languageDefaults.dictionary(forKey: "yullo.selectionTargetsBySource") as? [String: String] ?? [:]
            for (source, target) in legacy
            where Language.catalog.contains(where: { $0.id == source })
                && Language.catalog.contains(where: { $0.id == target })
            {
                directionLearning.record(source: source, target: target, now: Date(), weight: 0.25)
            }
        }
        persistDirectionLearning()
        languageDefaults.set(true, forKey: Self.directionMigrationKey)
        languageDefaults.removeObject(forKey: "yullo.selectionTargetsBySource")
    }
    private func persistDirectionLearning() {
        if let data = try? JSONEncoder().encode(directionLearning) {
            languageDefaults.set(data, forKey: Self.directionLearningKey)
        }
    }
    func resetLearnedDirections() {
        pendingDirectionChoice = nil
        directionLearning = DirectionLearningHistory()
        persistDirectionLearning()
        languageDefaults.set(true, forKey: Self.directionMigrationKey)
        languageDefaults.removeObject(forKey: "yullo.selectionTargetsBySource")
    }
    private func personalizedTarget(detected: [String], current: String) -> String {
        let enabled = Language.enabled(preferences.enabledLanguages).map(\.id)
        let source = detected.count == 1 ? detected.first : nil
        let history = preferences.learnTranslationDirections ? directionLearning : DirectionLearningHistory()
        return SelectionLanguagePolicy.personalizedTarget(
            detected: detected, enabled: enabled,
            sourceSpecific: source.flatMap { history.recommendedTarget(source: $0, enabled: enabled, now: Date()) },
            global: source.flatMap { history.globalTarget(excluding: $0, enabled: enabled, now: Date()) },
            currentTarget: current, preferredTarget: preferences.defaultTarget,
            interfaceLanguage: Language.canonicalCode(L10n.language))
    }
    private func resetNormalDirectionChoice() {
        normalDraftID = UUID()
        normalManualTargetContext = nil
        pendingDirectionChoice = nil
    }
    private func adjustNormalDirection(resolvingRequest: Bool = false) {
        guard !selectionContext, !translating || resolvingRequest,
            normalManualTargetContext != normalDraftID
        else { return }
        let sources: [String]
        if sourceLanguage == "auto" {
            guard completedDetectionSource == source else { return }
            sources = detectedLanguages
        } else {
            sources = [sourceLanguage]
        }
        let target = personalizedTarget(detected: sources, current: targetLanguage)
        guard target != targetLanguage else { return }
        // The existing source-change debounce remains the sole request owner.
        // This automatic correction neither trains a preference nor restarts it.
        swappingLanguages = true
        targetLanguage = target
        swappingLanguages = false
        if !translated.isEmpty { outputIsStale = true }
        rememberLanguages()
    }
    func beginSelection(
        _ text: String, analysis: InputAnalysis, replacementToken: UUID? = nil, refining: Bool = false
    ) {
        discardQuickReturn()
        pendingDirectionChoice = nil
        invalidateSourceDictationTarget()
        windowSession.resetPin()
        cancelReplacement()
        self.replacementToken = replacementToken
        selectionOffersReplacement = replacementToken != nil
        selectedOriginalText = text
        if !selectionContext {
            normalSourceLanguage = sourceLanguage
            let analysis =
                completedDetectionSource == source
                ? InputAnalysis(languages: detectedLanguages, words: sourceWordCount) : nil
            let keepsOutput = !output.isEmpty && !outputIsStale && !isTranslationPending
            normalContext = NormalContext(
                source: source, output: keepsOutput ? output : "", sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage, analysis: analysis,
                acceptedTranslation: keepsOutput ? acceptedTranslation : nil,
                writingSelection: translationWritingSelection, writingReviewNotice: translationWritingReviewNotice,
                historyRecordID: outputHistoryRecordID,
                notice: keepsOutput ? refinementPreviousNotice ?? notice : "",
                recoveryAction: keepsOutput
                    ? (refiningTranslation ? refinementPreviousRecoveryAction : translationRecoveryAction) : nil,
                canRetryPreferred: keepsOutput && canRetryPreferredTranslation)
        }
        let saved = normalContext
        // Refining shows the text's own language as the target, so the pair
        // reads as same-language writing; an unclear language keeps the target.
        let ownLanguage = analysis.languages.count == 1 ? analysis.languages.first : nil
        let selectionTarget =
            refining && Language.catalog.contains(where: { $0.id == ownLanguage })
            ? ownLanguage!
            : personalizedTarget(
                detected: analysis.languages,
                current: languageDefaults.string(forKey: "yullo.selectionTarget") ?? saved?.targetLanguage
                    ?? targetLanguage)
        swappingLanguages = true
        selectionRefinesOnly = refining
        selectionContext = true
        sourceLanguage = "auto"
        targetLanguage = selectionTarget
        source = text
        // Reuse the capture worker's analysis so neither the first request nor
        // the visible language label waits for a second detection pass.
        detectionTask?.cancel()
        detectionTask = nil
        detectionID = UUID()
        detectionDelayTask?.cancel()
        detectionDelayTask = nil
        detectionSource = text
        completedDetectionSource = text
        detectedLanguages = analysis.languages
        sourceWordCount = analysis.words
        selectionRevision &+= 1
        swappingLanguages = false
        inputChanged()
    }
    func endSelection() {
        guard selectionContext else {
            let previousTarget = targetLanguage
            adjustNormalDirection()
            if targetLanguage != previousTarget { invalidateTranslation(keepingOutput: true) }
            return
        }
        finishWindowSession()
        swappingLanguages = true
        selectionContext = false
        selectionRefinesOnly = false
        let saved = normalContext
        normalContext = nil
        sourceLanguage = saved?.sourceLanguage ?? normalSourceLanguage
        if let saved {
            source = saved.source
            targetLanguage = saved.targetLanguage
        }
        if let saved, let analysis = saved.analysis {
            detectionTask?.cancel()
            detectionTask = nil
            detectionID = UUID()
            detectionDelayTask?.cancel()
            detectionDelayTask = nil
            detectionSource = saved.source
            completedDetectionSource = saved.source
            detectedLanguages = analysis.languages
            sourceWordCount = analysis.words
        }
        swappingLanguages = false
        inputChanged()
        if let saved, !saved.output.isEmpty, sourceLanguage == saved.sourceLanguage,
            targetLanguage == saved.targetLanguage
        {
            cancelPendingInput()
            translated = saved.output
            acceptedTranslation = saved.acceptedTranslation
            translationWritingSelection = saved.writingSelection
            translationWritingReviewNotice = saved.writingReviewNotice
            outputHistoryRecordID = saved.historyRecordID
            notice = saved.notice
            translationRecoveryAction = saved.recoveryAction
            canRetryPreferredTranslation = saved.canRetryPreferred
        }
        rememberLanguages()
    }
    var canUseOutput: Bool { !output.isEmpty && !outputIsStale && !isTranslationPending && !refiningTranslation }
    // When the shown result last became ready to use, by the system clock's uptime.
    private(set) var outputReadyAt: TimeInterval?
    private var readyOutput: String?
    func noteOutputReadiness(now: TimeInterval) {
        guard canUseOutput else {
            readyOutput = nil
            outputReadyAt = nil
            return
        }
        guard readyOutput != output else { return }
        readyOutput = output
        outputReadyAt = now
    }
    private var hasReadyWritingBaseline: Bool {
        canUseOutput && acceptedTranslation != nil && !replacingSelection
            && !sourceVoiceUnavailable && sourceVoiceState == .idle
    }
    private var sameLanguagePair: Bool {
        guard hasSourceText,
            Language.catalog.contains(where: { $0.id == targetLanguage })
        else { return false }
        let from: String
        if sourceLanguage == "auto" {
            guard detectedLanguages.count == 1, let detected = detectedLanguages.first,
                detected == targetLanguage, TextMutationRange.identical(completedDetectionSource, source)
            else { return false }
            from = detected
        } else {
            from = sourceLanguage
        }
        guard from == targetLanguage, Language.catalog.contains(where: { $0.id == from }) else { return false }
        return (try? CoreJSONTranslationPlan.isCandidate(source: source)) == false
    }
    var hasSameLanguageWritingContext: Bool {
        acceptedTranslation?.isSource == true || sameLanguagePair || (selectionRefinesOnly && hasSourceText)
    }
    var canRefineInstead: Bool {
        guard !translating, !refiningTranslation, !replacingSelection,
            !sourceVoiceUnavailable, sourceVoiceState == .idle
        else { return false }
        return hasSameLanguageWritingContext && acceptedTranslation?.isSource != false
    }
    // The Refine button is always in the window once there is a result to refine;
    // structured text (JSON) keeps its structure and offers no rewrite.
    var canRefineTranslation: Bool {
        (hasReadyWritingBaseline && (try? CoreJSONTranslationPlan.isCandidate(source: source)) != true)
            || canRefineInstead
    }
    var translationBaselineTitleKey: String { acceptedTranslation?.isSource == true ? "Original" : "Translation" }
    var translationRestoreTitleKey: String {
        acceptedTranslation?.isSource == true ? "Restore original" : "Restore translation"
    }
    var outputTitleKey: String {
        if translationWritingStyle != nil || selectionRefinesOnly { return "Refined text" }
        return translationBaselineTitleKey
    }
    var outputCopyTitleKey: String {
        if translationWritingStyle != nil { return "Copy result" }
        return acceptedTranslation?.isSource == true ? "Copy original" : "Copy translation"
    }
    var canRestoreUnadjustedTranslation: Bool {
        hasReadyWritingBaseline && acceptedTranslation.map { !TextMutationRange.identical($0.text, translated) } == true
    }
    var canCompareTranslation: Bool {
        preferences.translationResultComparisonEnabled && canRestoreUnadjustedTranslation
    }
    var translationWritingConfigured: Bool {
        switch preferences.voiceRefinementEngine {
        case "api": return (try? APIConnectionSettings(endpoint: preferences.endpoint, model: preferences.model)) != nil
        case "cli": return CLIClient.hasConfiguredMetadata(preferences.cli)
        case "ollama": return !preferences.ollamaModel.isEmpty
        case "apple": return true
        default: return false
        }
    }
    var translationWritingAvailable: Bool {
        translationWritingConfigured
            && (preferences.processingPolicy == .standard || preferences.voiceRefinementEngine == "apple"
                || (preferences.voiceRefinementEngine == "ollama"
                    && CoreOllama.isOnThisMac(host: preferences.ollamaHost)))
    }
    var canRetryTranslation: Bool {
        !isTranslationPending && (!canUseOutput || translationIncomplete) && hasSourceText
    }
    var shouldOfferTranslationRetry: Bool { needsTranslationRetry && canRetryTranslation }
    var shouldOfferManualTranslation: Bool {
        !automaticTranslationEnabled && configured && canRetryTranslation && !selectionRefinesOnly
    }
    var shouldOfferTranslationRetryInFooter: Bool { automaticTranslationEnabled && shouldOfferTranslationRetry }
    var needsTranslationConnection: Bool {
        !configured && acceptedTranslation?.isSource != true && !selectionRefinesOnly
    }
    var showsTranslationFooter: Bool {
        copyFailed || translationRecoveryAction != nil || !notice.isEmpty
            || translationWritingReviewNotice != nil || needsTranslationConnection
            || shouldOfferTranslationRetryInFooter
    }
    var automaticTranslationEnabled: Bool {
        selectionContext ? preferences.translateSelection : preferences.autoTranslate
    }
    func toggleAutomaticTranslation() {
        var updated = preferences
        if selectionContext { updated.translateSelection.toggle() } else { updated.autoTranslate.toggle() }
        apply(updated)
    }
    var configured: Bool {
        switch preferences.engine {
        case "apple": return true
        case "cli":
            return !preferences.cli.executablePath.isEmpty
                && (preferences.cli.provider != .codex
                    || !preferences.cli.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case "api": return (try? APIConnectionSettings(endpoint: preferences.endpoint, model: preferences.model)) != nil
        case "local": return !preferences.localTranslationModelID.isEmpty
        default: return false
        }
    }
    var appearance: ColorScheme? {
        preferences.appearance == "dark" ? .dark : preferences.appearance == "light" ? .light : nil
    }
    func invalidateTranslation(keepingOutput: Bool = false) {
        clearCopyConfirmation()
        endOutputProgress()
        invalidateRefinement()
        acceptedTranslation = nil
        translationWritingSelection = nil
        translationWritingReviewNotice = nil
        outputHistoryRecordID = nil
        translationRecoveryAction = nil
        canRetryPreferredTranslation = false
        cancelReplacement()
        if needsTranslationRetry { needsTranslationRetry = false }
        debounceTask?.cancel()
        debounceTask = nil
        translationTask?.cancel()
        translationTask = nil
        requestID = UUID()
        if translating { translating = false }
        if isTranslationPending { isTranslationPending = false }
        outputIsStale = keepingOutput && !translated.isEmpty
        if !keepingOutput && !translated.isEmpty { translated = "" }
        stopSpeaking()
        if !notice.isEmpty { notice = "" }
    }
    func inputChanged(preserveOutput: Bool = false) {
        guard !swappingLanguages else { return }
        if applyingPreferences && quickReturnRequiresManualProcessing {
            invalidateTranslation()
            needsTranslationRetry = hasSourceText
            return
        }
        quickReturnRequiresManualProcessing = false
        cancelQuickReturnRetention()
        scheduleDetection()
        let automatic = selectionContext ? preferences.translateSelection : preferences.autoTranslate
        let hasInput = hasSourceText
        invalidateTranslation(keepingOutput: preserveOutput && automatic && hasInput)
        adjustNormalDirection()
        guard configured, hasInput, automatic, !selectionRefinesOnly else { return }
        isTranslationPending = true
        prepareLocalTranslation()
        let delay: UInt64 = preferences.engine == "apple" ? 250_000_000 : 450_000_000
        debounceTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.debounceTask = nil
            self.translate()
        }
    }
    // A local model loads while typing settles, so the request that follows
    // does not wait for helper launch and model loading. No text is sent.
    private func prepareLocalTranslation() {
        guard preferences.engine == "local" else { return }
        let modelID = preferences.localTranslationModelID
        #if YULLO_TESTING
            guard let prepare = testLocalPreparation else { return }
        #else
            let prepare: @Sendable (String) async -> Void = {
                await LocalTranslationProvider.shared.prepare(modelID: $0)
            }
        #endif
        Task.detached(priority: .utility) { await prepare(modelID) }
    }
    private func scheduleDetection(force: Bool = false) {
        guard force || source != detectionSource else { return }
        detectionSource = source
        if !detectedLanguages.isEmpty { detectedLanguages = [] }
        detectionTask?.cancel()
        detectionDelayTask?.cancel()
        detectionDelayTask = nil
        let id = UUID()
        detectionID = id
        let text = source
        guard Self.hasContent(text) else {
            detectionTask = nil
            completedDetectionSource = text
            if !detectedLanguages.isEmpty { detectedLanguages = [] }
            if sourceWordCount != 0 { sourceWordCount = 0 }
            return
        }
        // The quiet period settles typing. Explicit Translate may wake it
        // without cancelling or repeating an analysis already in progress.
        let delay = Task<Void, Never> {
            do { try await Task.sleep(nanoseconds: 120_000_000) } catch {}
        }
        detectionDelayTask = delay
        #if YULLO_TESTING
            let analyze = testInputAnalyzer ?? Self.analyzeInput
        #else
            let analyze = Self.analyzeInput
        #endif
        detectionTask = Task { @MainActor [weak self] in
            await withTaskCancellationHandler {
                await delay.value
            } onCancel: {
                delay.cancel()
            }
            guard !Task.isCancelled else { return }
            if self?.detectionID == id { self?.detectionDelayTask = nil }
            let worker = Task.detached(priority: .utility) { analyze(text) }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self, self.detectionID == id else { return }
            self.completedDetectionSource = text
            if self.detectedLanguages != result.languages { self.detectedLanguages = result.languages }
            if self.sourceWordCount != result.words { self.sourceWordCount = result.words }
            self.detectionTask = nil
            self.recordPendingDirectionChoice()
            self.adjustNormalDirection()
        }
    }
    func cancelPendingInput() {
        debounceTask?.cancel()
        debounceTask = nil
        if !translating && isTranslationPending { isTranslationPending = false }
    }
    func cancelTranslation() {
        if refiningTranslation {
            cancelTranslationRefinement()
            return
        }
        invalidateTranslation(keepingOutput: !translated.isEmpty)
        needsTranslationRetry = hasSourceText
    }
    nonisolated static func analyzeInput(_ text: String) -> InputAnalysis { InputLanguageAnalysis.analyzeInput(text) }
    nonisolated static func wordCount(_ text: String) -> Int { InputLanguageAnalysis.wordCount(text) }
    nonisolated static func detectLanguages(_ text: String) -> [String] { InputLanguageAnalysis.detectLanguages(text) }
    var detectedLanguageLabel: String {
        detectedLanguages.compactMap { code in
            Language.catalog.first { $0.id == code }?.displayName(
                localized: preferences.showLocalizedLanguageNames, locale: L10n.locale)
        }.joined(separator: " · ")
    }
    func swapLanguages() {
        guard !isTranslationPending && !outputIsStale else { return }
        var from = sourceLanguage
        if from == "auto" {
            guard completedDetectionSource == source, detectedLanguages.count == 1,
                let detected = detectedLanguages.first
            else {
                notice = L10n.tr("Choose a source language to swap.")
                return
            }
            from = detected
        }
        guard Language.enabled(preferences.enabledLanguages).contains(where: { $0.id == from }) else {
            let name = Language.displayName(
                for: from, localized: preferences.showLocalizedLanguageNames, locale: L10n.locale)
            notice = L10n.format("%@ isn’t one of your languages.", name)
            translationRecoveryAction = .languages
            return
        }
        let previousTarget = targetLanguage
        let result = canUseOutput ? output : ""
        selectionRefinesOnly = false
        swappingLanguages = true
        sourceLanguage = previousTarget
        targetLanguage = from
        if !result.isEmpty { source = result }
        swappingLanguages = false
        rememberLanguages()
        noteExplicitDirectionChoice()
        if selectionContext { rememberSelectionDirection() } else { recordPendingDirectionChoice() }
        inputChanged()
        translateCommittedInputIfAutomatic()
    }
    private func translateCommittedInputIfAutomatic() {
        guard automaticTranslationEnabled, configured, hasSourceText, !selectionRefinesOnly else { return }
        debounceTask?.cancel()
        // Keep same-turn dismissal/new-input cancellation, without a typing delay.
        debounceTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            self.debounceTask = nil
            self.translate()
        }
    }
    private func acceptSourceBaseline() {
        let text = source, from = sourceLanguage, target = targetLanguage
        invalidateTranslation()
        translated = text
        acceptedTranslation = AcceptedTranslation(
            id: UUID(), source: text, sourceLanguage: from, targetLanguage: target, text: text,
            historyRecordID: nil, notice: "", canRetryPreferred: false, recoveryAction: nil, isSource: true)
    }
    func translate() {
        startTranslation(retryPreferredProvider: false)
    }
    func retryTranslation() {
        startTranslation(retryPreferredProvider: true)
    }
    // After key access is allowed, run again whatever stopped for the key:
    // a refinement of the shown result, refined selected text, or the translation.
    func retryAfterKeyAccess() {
        // A return that already restarted the work leaves it running.
        guard translationRecoveryAction == .keychain, !translating, !refiningTranslation else { return }
        let refinement = refinementStoppedForKey
        refinementStoppedForKey = nil
        if selectionContext && selectionRefinesOnly {
            refineSelection()
        } else if let refinement, acceptedTranslation != nil {
            translationRecoveryAction = nil
            refineTranslation(selection: refinement)
        } else {
            retryTranslation()
        }
    }
    private func startTranslation(retryPreferredProvider: Bool) {
        // An explicit Translate leaves refine-only selected text.
        if !translating { selectionRefinesOnly = false }
        clearCopyConfirmation()
        invalidateRefinement()
        acceptedTranslation = nil
        translationWritingSelection = nil
        translationWritingReviewNotice = nil
        canRetryPreferredTranslation = false
        translationRecoveryAction = nil
        debounceTask?.cancel()
        debounceTask = nil
        if translating {
            cancelTranslation()
            notice = L10n.tr("Translation canceled")
            return
        }
        guard hasSourceText else {
            notice = L10n.tr("Enter text to translate")
            return
        }
        guard configured else {
            notice = L10n.tr("No translation service is set up.")
            translationRecoveryAction = .service
            return
        }
        cancelQuickReturnRetention()
        quickReturnRequiresManualProcessing = false
        outputHistoryRecordID = nil
        if !translated.isEmpty { outputIsStale = true }
        if needsTranslationRetry { needsTranslationRetry = false }
        isTranslationPending = true
        if speechSide != .source { stopSpeaking() }
        let id = UUID()
        requestID = id
        let config = preferences
        let text = source
        let sourceCode = sourceLanguage
        let settings = TranslationSettings(config)
        let historyStore = resultHistoryStore
        let historyTicket = config.resultHistoryEnabled ? historyStore?.captureWriteTicket() : nil
        #if YULLO_TESTING
            let execute = testExecutor
        #endif
        translating = true
        notice = ""
        translationTask = Task { @MainActor [weak self] in
            do {
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                if !self.selectionContext {
                    if sourceCode == "auto", self.completedDetectionSource != text {
                        if self.detectionTask == nil { self.scheduleDetection(force: true) }
                        self.detectionDelayTask?.cancel()
                        // This is the shared analysis task, never this translation
                        // task. Its quiet target correction does not restart us.
                        await self.detectionTask?.value
                    }
                    guard self.requestID == id, !Task.isCancelled, self.source == text else { return }
                    self.adjustNormalDirection(resolvingRequest: true)
                }
                let targetCode = self.targetLanguage
                // Only this request's source and resolved language pair enter
                // the service; direction memory contains language codes only.
                let progress = self.beginOutputProgress(mode: .translation) {
                    $0.requestID == id && $0.translating && $0.isTranslationPending
                }
                defer { progress.finish() }
                #if YULLO_TESTING
                    let service = self.testTranslationService ?? TranslationService.shared
                #else
                    let service = TranslationService.shared
                #endif
                let operation = {
                    try await service.translate(
                        text: text, source: sourceCode, target: targetCode, settings: settings,
                        retryPreferredProvider: retryPreferredProvider,
                        progress: settings.engine != "api" || settings.apiStreamingEnabled ? progress.send : nil)
                }
                let route: TranslationRoute.Result
                #if YULLO_TESTING
                    if let execute {
                        route = TranslationRoute.Result(text: try await execute(text), usedApple: false)
                    } else {
                        route = try await operation()
                    }
                #else
                    route = try await operation()
                #endif
                let result = route.text
                let fallbackUsed = route.usedAnyApple && config.engine != "apple"
                guard self.requestID == id, !Task.isCancelled else { return }
                self.translationTask = nil
                if !route.usedAnyApple, let service = ConnectedService.text(config.engine) {
                    self.recordWorkingService(service, settings: config)
                }
                if !route.incomplete, self.preferences.resultHistoryEnabled, let historyStore, let historyTicket {
                    let entry = ResultHistoryAcceptedResult(
                        task: .translation, source: text, result: result,
                        sourceLanguage: sourceCode == "auto" ? nil : sourceCode, targetLanguage: targetCode)
                    self.outputHistoryRecordID = entry.id
                    self.enqueueHistoryWrite {
                        try await historyStore.save(entry, using: historyTicket)
                    }
                }
                self.translated = result
                self.translationIncomplete = route.incomplete
                self.translating = false
                self.isTranslationPending = false
                self.outputIsStale = false
                self.needsTranslationRetry = route.incomplete
                self.canRetryPreferredTranslation =
                    fallbackUsed && config.engine == "api" && config.processingPolicy == .standard
                self.translationRecoveryAction = route.recovery == .apiKeyAccess ? .keychain : nil
                self.notice = [
                    route.incomplete ? L10n.tr("Part of this wasn’t translated.") : nil,
                    fallbackUsed
                        ? L10n.tr(route.appleFallbackNoticeKey) : nil,
                    route.terminologyUnavailable
                        ? L10n.tr(
                            route.usedAnyApple
                                ? "Apple translation doesn’t use your personal vocabulary."
                                : "This translation service doesn’t use your personal vocabulary.") : nil
                ].compactMap { $0 }.joined(separator: "\n")
                self.acceptedTranslation =
                    route.incomplete
                    ? nil
                    : AcceptedTranslation(
                        id: UUID(), source: text, sourceLanguage: sourceCode, targetLanguage: targetCode,
                        text: result, historyRecordID: self.outputHistoryRecordID, notice: self.notice,
                        canRetryPreferred: self.canRetryPreferredTranslation,
                        recoveryAction: self.translationRecoveryAction)
            } catch {
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                self.translationTask = nil
                self.translating = false
                self.isTranslationPending = false
                self.needsTranslationRetry = true
                self.translationRecoveryAction = TranslationRecoveryAction.fixing(error, writing: false)
                if let failure = error as? TranslationRoute.Failure {
                    let primary =
                        failure.api is ProcessingPolicyIssue || failure.api is APIError || failure.api is CLIError
                            || failure.api is LocalTranslationIssue || failure.api is ModelLibraryError
                            || failure.api is StructuredJSONIssue
                        ? failure.api.localizedDescription : L10n.tr("Couldn’t reach the translation API.")
                    let fallback: String
                    switch failure.apple as? AppleTranslationIssue {
                    case .unsupported: fallback = L10n.tr("Apple fallback doesn’t support this language pair.")
                    case .downloadRequired:
                        fallback = L10n.tr("Download this pair in Translation settings for offline fallback.")
                    case .unidentified: fallback = L10n.tr("Choose a source language for Apple fallback.")
                    default: fallback = L10n.tr("Apple fallback was also unavailable.")
                    }
                    self.notice = L10n.sentences([primary, fallback])
                } else if case AppleTranslationIssue.unsupported = error, config.engine != "apple",
                    config.engine != "local", Connectivity.shared.isOffline
                {
                    self.notice = L10n.tr(
                        "Apple can’t translate this pair offline. Connect to the internet to use your API.")
                } else {
                    self.notice =
                        (error is ProcessingPolicyIssue || error is APIError || error is CLIError
                            || error is LocalTranslationIssue || error is ModelLibraryError
                            || error is AppleTranslationIssue || error is TranslationError
                            || error is CoreLongTranslationError || error is StructuredJSONIssue)
                        ? error.localizedDescription
                        : L10n.tr("Translation failed. Check the translation service in Settings.")
                }
            }
        }
    }
    private func revokeTranslationComparison() {
        guard translationComparisonTicket != nil else { return }
        translationComparisonTicket = nil
        dismissTranslationComparison?()
    }
    private func invalidateRefinement() {
        endOutputProgress(mode: .refinement)
        revokeTranslationComparison()
        refinementRevision = UUID()
        refinementTask?.cancel()
        refinementTask = nil
        if refiningTranslation {
            if let previousNotice = refinementPreviousNotice { notice = previousNotice }
            translationRecoveryAction = refinementPreviousRecoveryAction
        }
        refinementPreviousNotice = nil
        refinementPreviousRecoveryAction = nil
        refiningTranslation = false
    }
    func cancelTranslationRefinement() {
        guard refiningTranslation else { return }
        invalidateRefinement()
    }
    // Your formats that rewrite text; one based on What I say has nothing to refine.
    var availableTranslationWritingPresets: [CoreDictationPresetRecord] {
        YourFormats.records(preferences.dictationPresets).filter { record in
            record.definition.isAppStyle
                && (record.definition.style == nil || RewriteStyle(rawValue: record.definition.style!) != nil)
        }
    }
    // Presets for resolving new dictation: the saved ones, with an active
    // scenario selected in a private copy.
    var activeDictationPresets: CoreDictationPresetsConfiguration {
        guard let scenario, let value = try? preferences.dictationPresets.activatingTemporary(scenario.record) else {
            return preferences.dictationPresets
        }
        return value
    }
    var activePresetRecord: CoreDictationPresetRecord? {
        let presets = activeDictationPresets
        guard let id = presets.selectedID, let record = presets.record(for: id), record.enabled else { return nil }
        return record
    }
    // The indicator's name for the preset a recording actually applied.
    func presetTitle(forAppliedID id: String?) -> String? {
        id.flatMap { activeDictationPresets.record(for: $0) }.map(DictationPresetPresentation.activeTitle)
    }
    // "Scenario: Landlord" or a saved preset's name; nil for base settings.
    var activePresetTitle: String? {
        activePresetRecord.map(DictationPresetPresentation.activeTitle)
    }
    // The active preset (or scenario) offered first in the translator when it
    // has writing fields: a style, technical text or its own instructions.
    var activeWritingPreset: CoreDictationPresetRecord? {
        guard let record = activePresetRecord, record.legacyIssue == nil,
            record.definition.style.map({ RewriteStyle(rawValue: $0) != nil }) ?? true,
            record.definition.style != nil || record.definition.preserveTechnicalLiterals
                || record.definition.instructions != nil
        else { return nil }
        return record
    }
    func startScenario(_ description: String) -> Bool {
        guard let value = DictationScenario.make(description: description) else { return false }
        scenario = value
        return true
    }
    func endScenario() { scenario = nil }
    // Adds a copy to the saved list; the scenario and the saved selection stay as they are.
    func saveScenarioAsPreset() throws {
        guard let scenario else { return }
        var config = preferences
        // Saved as a format of yours: its language comes from the row that uses it.
        var definition = scenario.record.definition
        if definition.mode == "translate" {
            definition.mode = "original"
            definition.targetLanguage = nil
        }
        try config.dictationPresets.create(
            name: DictationPresetPresentation.title(scenario.record), definition: definition,
            availableTargetLanguageIDs: Set(Language.catalog.map(\.id)))
        apply(config, restartAutomaticTranslation: false)
    }
    private func writingStyle(for record: CoreDictationPresetRecord) -> RewriteStyle {
        record.definition.style.flatMap(RewriteStyle.init(rawValue:))
            ?? RewriteStyle(rawValue: preferences.voiceRefinementStyle) ?? .professional
    }
    var translationWritingLabel: String {
        guard let selection = translationWritingSelection else { return L10n.tr("Refine") }
        return selection.preset.map(DictationPresetPresentation.activeTitle)
            ?? WritingStylePresentation.title(selection.style)
    }
    func isTranslationWritingPresetSelected(_ record: CoreDictationPresetRecord) -> Bool {
        guard let selection = translationWritingSelection, let applied = selection.preset else { return false }
        return applied.id == record.id && applied.name == record.name && applied.templateID == record.templateID
            && applied.definition == record.definition && selection.style == writingStyle(for: record)
            && selection.preserveTechnicalLiterals == record.definition.preserveTechnicalLiterals
    }
    func refinePreset(id: String) {
        guard
            let record = activeWritingPreset.flatMap({ $0.id == id ? $0 : nil })
                ?? availableTranslationWritingPresets.first(where: { $0.id == id })
        else { return }
        refineTranslation(
            selection: .init(
                style: writingStyle(for: record), preset: record,
                preserveTechnicalLiterals: record.definition.preserveTechnicalLiterals))
    }
    // The Refine menu lists formats as every Format pop-up does.
    func refineFormat(_ format: String) {
        if let id = CoreOutput(format: format).presetID {
            refinePreset(id: id)
        } else if format == CoreOutput.technical {
            refineTranslation(selection: .init(style: .professional, preset: nil, preserveTechnicalLiterals: true))
        } else if let style = RewriteStyle(rawValue: format) {
            refineTranslation(style)
        }
    }
    func isRefineFormatSelected(_ format: String) -> Bool {
        guard let selection = translationWritingSelection else { return false }
        if let id = CoreOutput(format: format).presetID {
            return preferences.dictationPresets.record(for: id).map(isTranslationWritingPresetSelected) ?? false
        }
        guard selection.preset == nil else { return false }
        let technical = format == CoreOutput.technical
        return selection.preserveTechnicalLiterals == technical
            && selection.style.rawValue == (technical ? RewriteStyle.professional.rawValue : format)
    }
    // Refine selected text: the captured source becomes the baseline and is
    // refined once in its own language, with the active preset when it has
    // writing fields, otherwise the default writing style.
    func refineSelection() {
        guard selectionContext, selectionRefinesOnly, hasSourceText else { return }
        // Without a writing service the result pane stays empty beside the
        // setup step, rather than repeating the selection as if it were a result.
        guard translationWritingAvailable else {
            invalidateTranslation()
            notice = L10n.tr(
                preferences.processingPolicy == .onDeviceOnly
                    ? "Yullo works on this Mac only. API and CLI services are off."
                    : "Refining uses a writing service you connect.")
            translationRecoveryAction = .writingService
            return
        }
        refineTranslation(selection: selectionWritingChoice)
    }
    // The writing choice Refine selected text applies: the active preset when
    // it has writing fields, otherwise the default writing style.
    var selectionWritingChoice: TranslatorWritingSelection {
        guard let preset = activeWritingPreset else {
            return .init(
                style: RewriteStyle(rawValue: preferences.voiceRefinementStyle) ?? .professional, preset: nil,
                preserveTechnicalLiterals: false)
        }
        return .init(
            style: writingStyle(for: preset), preset: preset,
            preserveTechnicalLiterals: preset.definition.preserveTechnicalLiterals)
    }
    // The writing route and trusted parameters for one writing choice.
    func writingSettings(for selection: TranslatorWritingSelection) -> TranslationSettings {
        var settings = TranslationSettings(preferences, engine: preferences.voiceRefinementEngine)
        settings.preserveTechnicalLiterals = selection.preserveTechnicalLiterals
        settings.presetInstructions = CorePresetInstructions.normalized(selection.preset?.definition.instructions)
        return settings
    }
    // A missing writing service is a next step, not a failure: refining
    // selected text names the setup the person needs.
    var needsWritingServiceSetup: Bool {
        translationRecoveryAction == .writingService && !translationWritingConfigured
            && preferences.processingPolicy == .standard
    }
    func refineTranslation(_ style: RewriteStyle) {
        refineTranslation(selection: .init(style: style, preset: nil, preserveTechnicalLiterals: false))
    }
    private func refineTranslation(selection: TranslatorWritingSelection) {
        let style = selection.style
        guard canRefineTranslation else { return }
        if !hasReadyWritingBaseline { acceptSourceBaseline() }
        guard hasReadyWritingBaseline, let baseline = acceptedTranslation else { return }
        clearCopyConfirmation()
        guard translationWritingAvailable else {
            notice = L10n.tr(
                preferences.processingPolicy == .onDeviceOnly
                    ? "Yullo works on this Mac only. API and CLI services are off."
                    : selectionRefinesOnly
                        ? "Refining uses a writing service you connect."
                        : "Choose an API or CLI connection to refine writing.")
            translationRecoveryAction = .writingService
            return
        }
        cancelQuickReturnRetention()
        quickReturnRequiresManualProcessing = false
        invalidateRefinement()
        stopSpeaking()
        let revision = UUID()
        refinementRevision = revision
        let config = preferences
        let settings = writingSettings(for: selection)
        let context: RefinementVocabularyContext? =
            baseline.isSource
            ? nil
            : .init(
                originalSource: baseline.source, targetLanguage: baseline.targetLanguage)
        let historyStore = resultHistoryStore
        let historyTicket = config.resultHistoryEnabled ? historyStore?.captureWriteTicket() : nil
        #if YULLO_TESTING
            let service = testRefinementService ?? RefinementService.shared
        #else
            let service = RefinementService.shared
        #endif
        refinementPreviousNotice = notice
        refinementPreviousRecoveryAction = translationRecoveryAction
        notice = ""
        translationRecoveryAction = nil
        refiningTranslation = true
        refinementTask = Task { @MainActor [weak self] in
            do {
                guard let self, !Task.isCancelled, self.refinementRevision == revision,
                    self.refiningTranslation, self.acceptedTranslation?.id == baseline.id
                else { return }
                let progress = self.beginOutputProgress(mode: .refinement) {
                    $0.refinementRevision == revision && $0.refiningTranslation
                        && $0.acceptedTranslation?.id == baseline.id
                }
                defer { progress.finish() }
                let result = try await service.refine(
                    text: baseline.text, style: style, settings: settings, vocabularyContext: context,
                    progress: { update in
                        progress.send(
                            .init(sequence: update.sequence, text: update.text, completedJobs: 0, totalJobs: 1))
                    })
                let review = try await WritingReview.inspect(
                    source: baseline.text, result: result, vocabulary: settings.personalVocabulary,
                    vocabularyContext: context)
                guard !Task.isCancelled, self.refinementRevision == revision,
                    self.acceptedTranslation?.id == baseline.id
                else { return }
                self.refinementTask = nil
                self.refinementPreviousNotice = nil
                self.refinementPreviousRecoveryAction = nil
                self.translated = result
                self.refiningTranslation = false
                self.translationWritingSelection = selection
                self.translationWritingReviewNotice = review.notice
                self.canRetryPreferredTranslation = false
                self.notice = ""
                self.outputHistoryRecordID = nil
                if self.preferences.resultHistoryEnabled, let historyStore, let historyTicket {
                    let entry = ResultHistoryAcceptedResult(
                        task: .writing, source: baseline.text, result: result,
                        sourceLanguage: baseline.targetLanguage, targetLanguage: baseline.targetLanguage)
                    self.outputHistoryRecordID = entry.id
                    self.enqueueHistoryWrite { try await historyStore.save(entry, using: historyTicket) }
                }
            } catch {
                guard let self, !Task.isCancelled, self.refinementRevision == revision,
                    self.acceptedTranslation?.id == baseline.id
                else { return }
                let previousNotice = self.refinementPreviousNotice
                self.refinementTask = nil
                self.refinementPreviousNotice = nil
                self.refinementPreviousRecoveryAction = nil
                self.refiningTranslation = false
                if case APIError.keychain = error { self.refinementStoppedForKey = selection }
                self.translationRecoveryAction =
                    error is ProcessingPolicyIssue
                    ? .writingService : TranslationRecoveryAction.fixing(error, writing: true)
                let message =
                    (error is APIError || error is CLIError || error is ProcessingPolicyIssue
                        || error is RefinementIssue || error is OllamaIssue || error is AppleWriterIssue)
                    ? error.localizedDescription
                    : L10n.tr(
                        baseline.isSource
                            ? "Couldn’t refine this text."
                            : "Couldn’t refine this translation. Your previous result is still available.")
                self.notice = [previousNotice, message].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            }
        }
    }
    func restoreUnadjustedTranslation() {
        guard let baseline = acceptedTranslation, canRestoreUnadjustedTranslation else { return }
        clearCopyConfirmation()
        invalidateRefinement()
        stopSpeaking()
        translated = baseline.text
        translationWritingSelection = nil
        translationWritingReviewNotice = nil
        outputHistoryRecordID = baseline.historyRecordID
        canRetryPreferredTranslation = baseline.canRetryPreferred
        translationRecoveryAction = baseline.recoveryAction
        notice = baseline.notice
    }
    func compareTranslation() {
        guard canCompareTranslation, let baseline = acceptedTranslation,
            let present = presentTranslationComparison
        else { return }
        revokeTranslationComparison()
        let ticket = UUID()
        let revision = refinementRevision
        let result = translated
        translationComparisonTicket = ticket
        let isCurrent = { [weak self] in
            guard let self else { return false }
            return self.translationComparisonTicket == ticket && self.refinementRevision == revision
                && self.acceptedTranslation?.id == baseline.id && self.canCompareTranslation
                && TextMutationRange.identical(self.translated, result)
        }
        let snapshot = VoiceComparisonSnapshot(
            sessionID: baseline.id, revision: revision, original: baseline.text, current: result,
            outputTitle: L10n.tr("Refined text"), context: .preview, message: translationWritingReviewNotice,
            appearance: preferences.appearance, canRestoreOriginal: true,
            originalTitle: L10n.tr(translationBaselineTitleKey),
            restoreOriginalTitle: L10n.tr(translationRestoreTitleKey))
        present(
            .init(
                snapshot: snapshot, isCurrent: isCurrent,
                restoreOriginal: { [weak self] in
                    guard isCurrent() else { return }
                    self?.restoreUnadjustedTranslation()
                }))
    }
    func setInterfaceLanguage(_ language: String) {
        guard L10n.choices.contains(where: { $0.id == language }), preferences.interfaceLanguage != language else {
            return
        }
        L10n.configure(language)
        preferences.interfaceLanguage = language
        preferences.persist(defaults: languageDefaults)
        interfaceLanguageChanged?()
    }
    // A connected service that just worked is offered on its task page. A
    // request made with settings that have since changed is not credited.
    func recordWorkingService(_ service: ConnectedService, settings: Preferences) {
        guard service.fingerprint(settings) == service.fingerprint(preferences), !preferences.isWorking(service)
        else { return }
        preferences.recordWorking(service)
        preferences.persist(defaults: languageDefaults)
    }
    // A service that answered only without streaming: its translations arrive complete
    // from now on. A request made with an endpoint or model since changed is not recorded.
    func recordAPIStreamingUnsupported(endpoint: URL, model: String) {
        guard preferences.isAPIConnection(endpoint: endpoint, model: model), !preferences.apiStreamingKnownUnsupported
        else { return }
        preferences.recordAPIStreamingUnsupported()
        preferences.persist(defaults: languageDefaults)
    }
    func setVisibility(showInDock: Bool? = nil, showInMenuBar: Bool? = nil, hideWhenClickingOutside: Bool? = nil) {
        if let showInDock { preferences.showInDock = showInDock }
        if let showInMenuBar { preferences.showInMenuBar = showInMenuBar }
        if let hideWhenClickingOutside { preferences.hideWhenClickingOutside = hideWhenClickingOutside }
        preferences.persist(defaults: languageDefaults)
        visibilityChanged?()
    }
    func apply(_ config: Preferences, restartAutomaticTranslation: Bool = true) {
        let wasApplying = applyingPreferences
        applyingPreferences = true
        defer { applyingPreferences = wasApplying }
        let previous = preferences
        if previous.restoreTranslationOnQuickReturn && !config.restoreTranslationOnQuickReturn { discardQuickReturn() }
        let processingChanged = previous.processingPolicy != config.processingPolicy
        ProcessingPolicyController.shared.update(config.processingPolicy)
        let speechProvider = SpeechProvider(rawValue: config.speechEngine) ?? .macOS
        let voiceChanged: Bool
        switch speechProvider {
        case .macOS: voiceChanged = previous.voiceIDs != config.voiceIDs
        case .local:
            voiceChanged =
                previous.localSpeechModelID != config.localSpeechModelID
                || previous.localSpeechVoices(forModel: previous.localSpeechModelID)
                    != config.localSpeechVoices(forModel: config.localSpeechModelID)
                || previous.localSpeechReferencePath != config.localSpeechReferencePath
        case .azure:
            voiceChanged =
                previous.azureRegion != config.azureRegion
                || previous.azureVoiceIDsByLanguage != config.azureVoiceIDsByLanguage
        case .google: voiceChanged = previous.googleSpeech != config.googleSpeech
        case .elevenlabs: voiceChanged = previous.elevenLabsSpeech != config.elevenLabsSpeech
        case .speechAPI: voiceChanged = previous.speechAPI != config.speechAPI
        }
        if processingChanged || previous.speechEngine != config.speechEngine || previous.speechRate != config.speechRate
            || voiceChanged
        {
            stopSpeaking()
            SpeechService.clearCachedAudio()
        }
        let connectionChanged =
            processingChanged || previous.engine != config.engine
            || (config.engine == "api" && (previous.endpoint != config.endpoint || previous.model != config.model))
            || (config.engine == "cli" && previous.cli != config.cli)
            || (config.engine == "local" && previous.localTranslationModelID != config.localTranslationModelID)
            || (config.engine != "apple" && previous.appleFallback != config.appleFallback)
            || !Self.sameTranslationTerminology(previous.personalVocabulary, config.personalVocabulary)
        let writingChanged =
            processingChanged || previous.voiceRefinementEngine != config.voiceRefinementEngine
            || (config.voiceRefinementEngine == "api"
                && (previous.endpoint != config.endpoint || previous.model != config.model))
            || (config.voiceRefinementEngine == "cli" && previous.cli != config.cli)
            || previous.personalVocabulary != config.personalVocabulary
        if writingChanged { invalidateRefinement() }
        if previous.translationResultComparisonEnabled && !config.translationResultComparisonEnabled {
            revokeTranslationComparison()
        }
        let automationChanged =
            selectionContext
            ? previous.translateSelection != config.translateSelection : previous.autoTranslate != config.autoTranslate
        if connectionChanged {
            invalidateTranslation()
            if let saved = normalContext {
                normalContext = NormalContext(
                    source: saved.source, output: "", sourceLanguage: saved.sourceLanguage,
                    targetLanguage: saved.targetLanguage, analysis: saved.analysis)
            }
        }
        if previous.interfaceLanguage != config.interfaceLanguage { L10n.configure(config.interfaceLanguage) }
        if previous != config {
            preferences = config
            preferences.clearAPIStreamingSupport(ifConnectionChangedFrom: previous)
            preferences.persist(defaults: languageDefaults)
        }
        if previous.interfaceLanguage != config.interfaceLanguage { interfaceLanguageChanged?() }
        if previous.enabledLanguages != config.enabledLanguages {
            let enabled = Language.enabled(config.enabledLanguages)
            let ids = Set(enabled.map(\.id))
            let fallback =
                [config.defaultTarget, Language.canonicalCode(config.interfaceLanguage)].first { ids.contains($0) }
                ?? enabled[0].id
            if sourceLanguage != "auto" && !ids.contains(sourceLanguage) { sourceLanguage = "auto" }
            if !ids.contains(targetLanguage) { targetLanguage = fallback }
            if let saved = normalContext {
                let from =
                    saved.sourceLanguage == "auto" || ids.contains(saved.sourceLanguage) ? saved.sourceLanguage : "auto"
                let to = ids.contains(saved.targetLanguage) ? saved.targetLanguage : fallback
                normalContext = NormalContext(
                    source: saved.source,
                    output: from == saved.sourceLanguage && to == saved.targetLanguage ? saved.output : "",
                    sourceLanguage: from, targetLanguage: to, analysis: saved.analysis,
                    acceptedTranslation: from == saved.sourceLanguage && to == saved.targetLanguage
                        ? saved.acceptedTranslation : nil,
                    writingSelection: from == saved.sourceLanguage && to == saved.targetLanguage
                        ? saved.writingSelection : nil,
                    writingReviewNotice: from == saved.sourceLanguage && to == saved.targetLanguage
                        ? saved.writingReviewNotice : nil,
                    historyRecordID: from == saved.sourceLanguage && to == saved.targetLanguage
                        ? saved.historyRecordID : nil,
                    notice: from == saved.sourceLanguage && to == saved.targetLanguage ? saved.notice : "",
                    recoveryAction: from == saved.sourceLanguage && to == saved.targetLanguage
                        ? saved.recoveryAction : nil,
                    canRetryPreferred: from == saved.sourceLanguage && to == saved.targetLanguage
                        && saved.canRetryPreferred)
            }
        }
        if previous.appearance != config.appearance || previous.showInDock != config.showInDock
            || previous.showInMenuBar != config.showInMenuBar
            || previous.hideWhenClickingOutside != config.hideWhenClickingOutside
        {
            visibilityChanged?()
        }
        if connectionChanged || automationChanged {
            if quickReturnRequiresManualProcessing {
                cancelPendingInput()
                prepareQuickReturnPresentation()
            } else if restartAutomaticTranslation && !processingChanged {
                inputChanged()
            } else {
                cancelPendingInput()
            }
        }
    }
    private static func sameTranslationTerminology(
        _ left: CoreVocabularyConfiguration, _ right: CoreVocabularyConfiguration
    ) -> Bool {
        let previous = left.enabled ? left.entries.filter { $0.enabled && $0.useInTranslation } : []
        let current = right.enabled ? right.entries.filter { $0.enabled && $0.useInTranslation } : []
        return previous.elementsEqual(current) {
            TextMutationRange.identical($0.canonical, $1.canonical)
                && TextMutationRange.identical($0.translation, $1.translation)
                && $0.targetLanguage == $1.targetLanguage && $0.boundary == $1.boundary
        }
    }
    func stopSpeaking() {
        speechID = UUID()
        speechTask?.cancel()
        speechTask = nil
        cancelSpeechContinuation()
        audioPlayer?.stop()
        audioPlayer = nil
        activeUtterance = nil
        if speaker?.isSpeaking == true { speaker?.stopSpeaking(at: .immediate) }
        if speaking { speaking = false }
        if speechSide != nil { speechSide = nil }
        if speechAudible { speechAudible = false }
    }
    func listen(_ side: SpeechSide = .translation) {
        guard side != .sample, side == .source || canUseOutput else { return }
        if speaking && speechSide == side {
            stopSpeaking()
            return
        }
        let text = side == .source ? source : output
        let hint = side == .source ? (sourceLanguage == "auto" ? nil : sourceLanguage) : targetLanguage
        speak(text, hint: hint, side: side)
    }
    // Reads the setup guide's sample with the chosen voice service, voice and
    // speed, exactly as the translator's speaker would. The editor, its notice,
    // History and the working-service record stay untouched.
    func speakSample(_ text: String, language: String) {
        sampleSpeechIssue = nil
        speak(text, hint: language, side: .sample)
    }
    private func reportSpeechIssue(_ message: String, side: SpeechSide?, fix: TranslationRecoveryAction? = nil) {
        if side == .sample {
            sampleSpeechIssue = message
        } else {
            notice = message
            if let fix { translationRecoveryAction = fix }
        }
    }
    // A notice from outside the translator, with the one action that resolves it.
    func showNotice(_ message: String, fix: TranslationRecoveryAction?) {
        notice = TranslationRecoveryAction.notice(message, fix: fix)
        translationRecoveryAction = fix
    }
    private func speak(_ text: String, hint: String?, side: SpeechSide) {
        stopSpeaking()
        guard Self.hasContent(text) else { return }
        let config = preferences
        let authorization = ProcessingPolicyController.shared.authorization(for: config.processingPolicy)
        let rate = config.speechRate * (slowSpeech ? 0.75 : 1)
        guard let provider = SpeechProvider(rawValue: config.speechEngine) else {
            reportSpeechIssue(L10n.tr("No voice service is chosen."), side: side, fix: .readAloud)
            return
        }
        let configuration: SpeechAPIConfiguration
        switch provider {
        case .speechAPI: configuration = config.speechAPI
        case .google: configuration = config.googleSpeech
        case .elevenlabs: configuration = config.elevenLabsSpeech
        case .azure: configuration = SpeechAPIConfiguration(voiceIDsByLanguage: config.azureVoiceIDsByLanguage)
        case .local:
            configuration = SpeechAPIConfiguration(
                model: config.localSpeechModelID,
                voiceIDsByLanguage: config.localSpeechVoices(forModel: config.localSpeechModelID))
        case .macOS: configuration = SpeechAPIConfiguration()
        }
        activeSpeechText = text
        speechSide = side
        let offline = Connectivity.shared.isOffline
        let nativeRoute = !SpeechService.shouldUseService(
            provider: provider, configuration: configuration, offline: offline)
        let id = UUID()
        speechID = id
        speaking = true
        speechTask = Task { @MainActor [weak self] in
            // Detection uses only this text, off the UI thread. The voice editor's
            // preview language and the enabled translation menu never enter it.
            // The macOS route also loads installed voices there, not in playback.
            let detection = Task.detached(priority: .userInitiated) { () -> String in
                let language = SpeechLanguagePolicy.language(for: text, hint: hint)
                if nativeRoute { _ = MacVoiceCatalog.voices(for: language) }
                return language
            }
            let language = await withTaskCancellationHandler(
                operation: { await detection.value }, onCancel: { detection.cancel() })
            guard let self, self.speechID == id, !Task.isCancelled else { return }
            self.activeSpeechLanguage = language
            if nativeRoute {
                self.speakLocally(text, language: language)
                return
            }
            let localSegments =
                provider == .local ? LocalSpeechSynthesizer.leadingSegment(text) : (first: text, rest: nil)
            let localReference =
                config.localSpeechReferencePath.isEmpty ? nil : URL(fileURLWithPath: config.localSpeechReferencePath)
            do {
                let data = try await SpeechService.route(
                    provider: provider, offline: offline, configuration: configuration
                ) {
                    if provider == .local {
                        AudioOutputWarmup.start()
                        return try await LocalSpeechSynthesizer.shared.synthesize(
                            text: localSegments.first, language: language,
                            modelID: config.localSpeechModelID, voiceID: configuration.voice(for: language), rate: rate,
                            referenceAudioURL: localReference)
                    }
                    return try await ProcessingPolicyController.shared.performExternal(authorization: authorization) {
                        let account = try SpeechService.keyAccount(
                            provider: provider, configuration: configuration, region: config.azureRegion)
                        let key = try await KeyStore.readAsync(account)
                        try Task.checkCancellation()
                        AudioOutputWarmup.start()
                        return try await SpeechService.synthesize(
                            provider: provider, configuration: configuration, region: config.azureRegion,
                            key: key, text: text, language: language, rate: rate, authorization: authorization)
                    }
                }
                guard self.speechID == id, !Task.isCancelled else { return }
                guard let data else {
                    await self.speakLocallyAfterCatalog(text, language: language, id: id)
                    return
                }
                let player = try AVAudioPlayer(data: data)
                let playbackRate = SpeechService.playbackRate(
                    provider: provider, configuration: configuration, region: config.azureRegion, language: language,
                    rate: rate)
                if playbackRate != 1 {
                    player.enableRate = true
                    player.rate = playbackRate
                }
                player.delegate = self
                self.audioPlayer = player
                guard player.play() else { throw SpeechAPIError.audio }
                self.speechAudible = true
                if let rest = localSegments.rest {
                    self.continueLocalSpeech(
                        rest, language: language, modelID: config.localSpeechModelID,
                        voiceID: configuration.voice(for: language), rate: rate, reference: localReference,
                        playbackRate: playbackRate, id: id)
                }
                if side != .sample, let service = ConnectedService.speech(provider) {
                    self.recordWorkingService(service, settings: config)
                }
            } catch {
                guard self.speechID == id, !Task.isCancelled else { return }
                self.audioPlayer = nil
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    self.stopSpeaking()
                    return
                }
                if error is ProcessingPolicyIssue || (error as? CoreFallbackError)?.allowsAutomaticFallback == false {
                    self.stopSpeaking()
                    self.reportSpeechIssue(
                        error.localizedDescription, side: side,
                        fix: error is SpeechAPIError || error is APIError ? .readAloud : nil)
                    return
                }
                await self.speakLocallyAfterCatalog(text, language: language, id: id)
            }
        }
    }
    // A provider fallback loads installed voices off the main actor, then
    // rechecks Stop before speaking with the unchanged voice selection.
    @MainActor private func speakLocallyAfterCatalog(_ text: String, language: String, id: UUID) async {
        await Task.detached(priority: .userInitiated) { _ = MacVoiceCatalog.voices(for: language) }.value
        guard speechID == id, !Task.isCancelled else { return }
        speakLocally(text, language: language)
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard audioPlayer === player else { return }
        audioPlayer = nil
        if let next = pendingSpeechAudio {
            pendingSpeechAudio = nil
            playSpeechContinuation(next)
            return
        }
        if let rest = pendingSpeechFallback {
            pendingSpeechFallback = nil
            speakLocally(rest, language: activeSpeechLanguage)
            return
        }
        // The rest is still being generated; it starts playing when ready.
        if awaitingSpeechContinuation { return }
        speaking = false
        speechSide = nil
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard audioPlayer === player else { return }
        audioPlayer = nil
        cancelSpeechContinuation()
        speakLocally(activeSpeechText, language: activeSpeechLanguage)
    }
    private func continueLocalSpeech(
        _ rest: String, language: String, modelID: String, voiceID: String, rate: Double, reference: URL?,
        playbackRate: Float, id: UUID
    ) {
        awaitingSpeechContinuation = true
        continuationPlaybackRate = playbackRate
        speechContinuation = Task { @MainActor [weak self] in
            let result: Result<Data, Error>
            do {
                result = .success(
                    try await LocalSpeechSynthesizer.shared.synthesize(
                        text: rest, language: language, modelID: modelID, voiceID: voiceID, rate: rate,
                        referenceAudioURL: reference))
            } catch { result = .failure(error) }
            guard let self, self.speechID == id, !Task.isCancelled else { return }
            self.awaitingSpeechContinuation = false
            self.speechContinuation = nil
            switch result {
            case .success(let audio):
                if self.audioPlayer == nil {
                    self.playSpeechContinuation(audio)
                } else {
                    self.pendingSpeechAudio = audio
                }
            case .failure(let error):
                if error is CancellationError { return }
                // Like a failed whole passage, the remaining text uses a Mac voice.
                if self.audioPlayer == nil {
                    self.speakLocally(rest, language: language)
                } else {
                    self.pendingSpeechFallback = rest
                }
            }
        }
    }
    private func playSpeechContinuation(_ audio: Data) {
        guard let player = try? AVAudioPlayer(data: audio) else {
            speaking = false
            speechSide = nil
            return
        }
        if continuationPlaybackRate != 1 {
            player.enableRate = true
            player.rate = continuationPlaybackRate
        }
        player.delegate = self
        audioPlayer = player
        if !player.play() {
            audioPlayer = nil
            speaking = false
            speechSide = nil
        }
    }
    private func cancelSpeechContinuation() {
        speechContinuation?.cancel()
        speechContinuation = nil
        pendingSpeechAudio = nil
        pendingSpeechFallback = nil
        awaitingSpeechContinuation = false
    }
    private func speakLocally(_ text: String, language: String) {
        let matching = MacVoiceCatalog.voices(for: language)
        guard
            let voice = matching.first(where: { $0.identifier == preferences.voiceIDs[language] })
                ?? matching.max(by: { $0.quality.rawValue < $1.quality.rawValue })
        else {
            let side = speechSide
            speaking = false
            speechSide = nil
            reportSpeechIssue(
                L10n.tr("No voice for this language yet."), side: side,
                fix: .systemVoices)
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(preferences.speechRate) * (slowSpeech ? 0.75 : 1.0)
        activeUtterance = utterance
        speaking = true
        if speaker == nil {
            let synthesizer = AVSpeechSynthesizer()
            synthesizer.delegate = self
            speaker = synthesizer
        }
        speaker?.speak(utterance)
        speechAudible = true
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            guard self.activeUtterance === utterance else { return }
            self.activeUtterance = nil
            self.speaking = false
            self.speechSide = nil
        }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            guard self.activeUtterance === utterance else { return }
            self.activeUtterance = nil
            self.speaking = false
            self.speechSide = nil
        }
    }
    static func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    var canReplaceSelection: Bool {
        guard selectionContext, replacementToken != nil, canUseOutput, !replacingSelection, !translationIncomplete,
            let selectedOriginalText
        else { return false }
        return !TextMutationRange.identical(output, selectedOriginalText)
    }
    private func cancelQuickReturnRetention() {
        quickReturnExpiryTask?.cancel()
        quickReturnExpiryTask = nil
        windowSession.clearQuickReturn()
    }
    func discardQuickReturn() {
        guard quickReturnExpiryTask != nil else {
            windowSession.clearQuickReturn()
            return
        }
        clearTranslatorDraft()
    }
    @discardableResult
    func prepareQuickReturn(surface: WindowSession.Surface) -> Bool {
        guard preferences.restoreTranslationOnQuickReturn else {
            clearTranslatorDraft()
            return false
        }
        // Outside-click and resign-active can describe the same hide. Native
        // admission checks visibility; this also prevents extending a ticket.
        if quickReturnExpiryTask != nil { return windowSession.hasPendingQuickReturn }
        let keepsAcceptedResult = acceptedTranslation != nil && !outputIsStale && !translated.isEmpty
        cancelPendingInput()
        translationTask?.cancel()
        translationTask = nil
        requestID = UUID()
        endOutputProgress()
        translating = false
        isTranslationPending = false
        finishWindowSession(preservingDraft: true)
        stopSpeaking()
        detectionTask?.cancel()
        detectionTask = nil
        detectionDelayTask?.cancel()
        detectionDelayTask = nil
        detectionID = UUID()
        if !keepsAcceptedResult {
            translated = ""
            acceptedTranslation = nil
            translationWritingSelection = nil
            translationWritingReviewNotice = nil
            outputHistoryRecordID = nil
            canRetryPreferredTranslation = false
            outputIsStale = false
            needsTranslationRetry = hasSourceText
        }
        quickReturnRequiresManualProcessing = true
        let ticket = windowSession.armQuickReturn(surface: surface)
        quickReturnExpiryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(until: ticket.deadline, clock: .continuous) } catch { return }
            guard !Task.isCancelled, let self, self.windowSession.expireQuickReturn(id: ticket.id) else { return }
            self.clearTranslatorDraft()
        }
        return true
    }
    func consumeQuickReturn() -> WindowSession.Surface? {
        guard quickReturnExpiryTask != nil else {
            windowSession.clearQuickReturn()
            return nil
        }
        quickReturnExpiryTask?.cancel()
        quickReturnExpiryTask = nil
        let surface = windowSession.consumeQuickReturn()
        guard preferences.restoreTranslationOnQuickReturn, let surface else {
            clearTranslatorDraft()
            return nil
        }
        prepareQuickReturnPresentation()
        return surface
    }

    func prepareQuickReturnPresentation() {
        quickReturnRequiresManualProcessing = true
        cancelPendingInput()
        if !canUseOutput { needsTranslationRetry = hasSourceText }
    }

    func finishWindowSession(preservingDraft: Bool = false) {
        invalidateRefinement()
        if !preservingDraft { pendingDirectionChoice = nil }
        invalidateSourceDictationTarget()
        if !selectionContext && !preservingDraft { resetNormalDirectionChoice() }
        windowSession.resetPin()
        cancelReplacement(invalidateTarget: true)
        selectionOffersReplacement = false
    }
    // Dismissing a translator ends this draft. History is an explicit recovery
    // destination; reopening a window never repopulates its editors.
    func clearTranslatorDraft() {
        quickReturnRequiresManualProcessing = false
        cancelQuickReturnRetention()
        let saved = selectionContext ? normalContext : nil
        let from = saved?.sourceLanguage ?? sourceLanguage
        let target = saved?.targetLanguage ?? targetLanguage
        finishWindowSession()
        invalidateTranslation()
        detectionTask?.cancel()
        detectionTask = nil
        detectionDelayTask?.cancel()
        detectionDelayTask = nil
        detectionID = UUID()
        swappingLanguages = true
        source = ""
        translated = ""
        selectionContext = false
        normalContext = nil
        sourceLanguage = from
        targetLanguage = target
        normalSourceLanguage = from
        detectedLanguages = []
        sourceWordCount = 0
        sourceCharacterCount = 0
        detectionSource = ""
        completedDetectionSource = ""
        resetNormalDirectionChoice()
        swappingLanguages = false
        rememberLanguages()
    }
    func cancelReplacement(invalidateTarget: Bool = false) {
        replacementTask?.cancel()
        replacementTask = nil
        replacementID = UUID()
        if replacingSelection { replacingSelection = false }
        if invalidateTarget {
            let ownedToken = replacementToken
            replacementToken = nil
            selectedOriginalText = nil
            if let ownedToken { SelectionReplacement.invalidate(if: ownedToken) }
        }
    }
    func replaceSelection() {
        guard canReplaceSelection, let token = replacementToken else { return }
        let historyID = outputHistoryRecordID
        let id = UUID()
        replacementID = id
        let text = output
        #if YULLO_TESTING
            let execute = testReplacementExecutor
        #endif
        replacingSelection = true
        clearCopyConfirmation()
        let previousNotice = notice
        replacementTask = Task { @MainActor [weak self] in
            self?.updateHistoryDelivery(.uncertain, recordID: historyID)
            do {
                let pid: Int32
                #if YULLO_TESTING
                    if let execute {
                        pid = try await execute(token, text)
                    } else {
                        pid = try await SelectionReplacement.replace(token: token, with: text)
                    }
                #else
                    pid = try await SelectionReplacement.replace(token: token, with: text)
                #endif
                self?.updateHistoryDelivery(.inserted, recordID: historyID)
                guard let self, self.replacementID == id, !Task.isCancelled else { return }
                self.replacementTask = nil
                self.replacingSelection = false
                self.replacementToken = nil
                self.selectionReplaced?(pid)
            } catch {
                let issue = error as? SelectionReplacement.Issue
                self?.updateHistoryDelivery(
                    issue != nil && issue != .uncertain ? .notInserted : .uncertain, recordID: historyID)
                guard let self, self.replacementID == id, !Task.isCancelled else { return }
                self.replacementTask = nil
                self.replacingSelection = false
                self.replacementToken = nil
                SelectionReplacement.invalidate(if: token)
                let recoveryNotice: String
                switch issue {
                case .unsupported:
                    let copied = self.copyOutputToClipboard()
                    self.clearCopyConfirmation()
                    recoveryNotice = L10n.tr(
                        copied
                            ? "Copied. Can’t replace text here. Paste the translation instead."
                            : "Couldn’t copy. Try again.")
                case .focusUnavailable, .staleSelection, .failed:
                    // Nothing was written: the result the person asked to put back is copied.
                    let copied = self.copyOutputToClipboard()
                    self.clearCopyConfirmation()
                    recoveryNotice = L10n.tr(
                        copied
                            ? "Couldn’t replace the text. Result copied."
                            : issue == .staleSelection
                                ? "The original selection changed. Select the text again."
                                : "Couldn’t access the original selection. Select it again.")
                case .permission:
                    recoveryNotice = L10n.tr("Replacing text needs Accessibility access.")
                    self.translationRecoveryAction = .accessibility
                case .uncertain:
                    recoveryNotice = L10n.tr("Check the original app before inserting again.")
                default:
                    recoveryNotice = L10n.tr(
                        "Couldn’t replace the selection. The translation is still available to copy.")
                }
                self.notice = [previousNotice, recoveryNotice].filter { !$0.isEmpty }.joined(separator: "\n")
            }
        }
    }
    // Saved text is a fresh local draft, never a recovered editor/AX lease.
    func restoreHistory(_ entry: ResultHistoryEntry, translateAgain: Bool) {
        clearTranslatorDraft()
        let text = translateAgain ? entry.source : entry.result
        let savedLanguage =
            translateAgain
            ? entry.summary.sourceLanguage
            : (entry.summary.task == .translation ? entry.summary.targetLanguage : entry.summary.sourceLanguage)
        let language =
            savedLanguage.flatMap { value in Language.enabled(preferences.enabledLanguages).first { $0.id == value }?.id
            } ?? "auto"
        swappingLanguages = true
        source = text
        sourceLanguage = language
        normalSourceLanguage = language
        swappingLanguages = false
        scheduleDetection(force: true)
        if translateAgain { translate() }
    }
    func waitForPendingHistoryWrites() async { await historyWriteTask?.value }
    @MainActor private func enqueueHistoryWrite(_ action: @escaping () async throws -> Bool) {
        let previous = historyWriteTask
        historyWriteTask = Task { @MainActor [weak self] in
            await previous?.value
            do {
                if try await action() { self?.historyWriteSucceeded?() }
            } catch {
                guard let self else { return }
                self.historyWriteFailed?(error)
            }
        }
    }
    @MainActor private func updateHistoryDelivery(_ outcome: ResultHistoryDelivery, recordID: UUID?) {
        guard let recordID, let store = resultHistoryStore else { return }
        enqueueHistoryWrite { try await store.updateDelivery(outcome, for: recordID) }
    }
    func copyTranslation() {
        guard canUseOutput else { return }
        let copied = copyOutputToClipboard()
        let confirmation = UUID()
        copyConfirmationID = confirmation
        copyFeedback = copied ? .copied : .failed
        // The check mark is visual; VoiceOver hears the same confirmation once.
        if copied {
            NSAccessibility.post(
                element: NSApp.keyWindow ?? NSApp as Any, notification: .announcementRequested,
                userInfo: [.announcement: L10n.tr("Copied"), .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.finishCopyConfirmation(confirmation)
        }
    }
    private func copyOutputToClipboard() -> Bool {
        guard canUseOutput else { return false }
        #if YULLO_TESTING
            if let write = testClipboardWriter { return write(output) }
        #endif
        return Self.writeClipboard(output)
    }
    private func finishCopyConfirmation(_ receipt: UUID) {
        guard copyConfirmationID == receipt else { return }
        copyFeedback = nil
    }
    private func clearCopyConfirmation() {
        guard copyFeedback != nil else { return }
        copyConfirmationID = UUID()
        copyFeedback = nil
    }
    private static func writeClipboard(_ text: String) -> Bool {
        // Test builds never reach the owner's clipboard, even without a writer set.
        #if YULLO_TESTING
            let board = NSPasteboard(name: .init("local.yullo.testing.translation"))
        #else
            let board = NSPasteboard.general
        #endif
        board.clearContents()
        return board.setString(text, forType: .string)
    }
}
