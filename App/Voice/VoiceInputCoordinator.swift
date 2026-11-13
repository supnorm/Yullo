import AVFoundation
import AppKit
import SwiftUI

enum VoiceInputMode: Equatable { case dictation, translation }
enum VoiceInputPhase: Equatable {
    case idle, preparing, recording, paused, transcribing, translating, refining, delivering, cancelling, preview, error
}
enum VoiceSetupDestination: Equatable {
    case recognition, finishMethods, microphone, accessibility, credentials, processing, translation(engine: String),
        refinement(
            engine: String)
    // Fixed outside Settings: start Ollama, or turn on Apple Intelligence.
    case openOllama, appleIntelligence
}

// Configuration metadata only: opening a menu never probes a process, network
// connection or credential. Actual availability is checked when used.
enum VoiceWritingConnection {
    // Set up regardless of where Yullo works: what a menu offers.
    static func isSetUp(_ preferences: Preferences) -> Bool {
        var value = preferences
        value.processingPolicy = .standard
        return isConfigured(value)
    }
    static func isConfigured(_ preferences: Preferences) -> Bool {
        // Apple's model needs no setup and never leaves this Mac; whether it can
        // run now is shown under Write with and checked before each request.
        if preferences.voiceRefinementEngine == "apple" { return true }
        if preferences.voiceRefinementEngine == "ollama" {
            // Ollama on this Mac stays usable under On-device only.
            return !preferences.ollamaModel.isEmpty
                && (preferences.processingPolicy == .standard || CoreOllama.isOnThisMac(host: preferences.ollamaHost))
        }
        guard preferences.processingPolicy == .standard else { return false }
        if preferences.voiceRefinementEngine == "api" {
            return (try? APIConnectionSettings(endpoint: preferences.endpoint, model: preferences.model)) != nil
        }
        guard preferences.voiceRefinementEngine == "cli" else { return false }
        return CLIClient.hasConfiguredMetadata(preferences.cli)
    }
}

enum VoiceResources {
    static let library = ModelLibrary.shared
    static let transcriber = LocalTranscriber(library: library)
    static let appleSpeech = AppleSpeechTranscriber()
    static let liveLocal = LocalLiveRecognitionProvider(library: library)
    // Final recognition without preview first tries the warm live helper, which
    // keeps the model loaded between recordings, then the one-shot helpers.
    static let recognition = VoiceRecognitionService(
        library: library, local: transcriber, apple: appleSpeech,
        sharedReserve: { await liveLocal.reserve(modelID: $0, languageHint: $1, vocabularyHints: $2) })
    // Starts loading the selected local recognizer for a likely recording. No
    // audio is sent; an unused helper retires after its idle interval.
    static func prepareRecognition(_ settings: VoiceRecognitionSettings, livePreview: Bool) async {
        // Without preview, a natively streaming model recognizes the WAV in its one-shot helper.
        guard livePreview || LiveRecognitionSupport.mode(modelID: settings.modelID) != .nativeStream else { return }
        await liveLocal.prepare(settings: settings)
    }
}

extension VoiceResources {
    // Loads the selected recognizer before a likely first recording. A local
    // helper retires after its idle interval, so no model stays loaded unused.
    static func prewarm(_ settings: VoiceRecognitionSettings, livePreview: Bool) async {
        if settings.isApplePrimary {
            await AppleLiveRecognitionProvider.prewarm(settings: settings)
        } else {
            await prepareRecognition(settings, livePreview: livePreview)
        }
    }
}

// When Yullo prepares dictation after it opens: shortly after an ordinary
// launch, later and without a recognizer after a login launch, and never a
// recognizer in Low Power Mode, under thermal pressure or with little memory.
struct VoicePrewarmPolicy: Equatable {
    var delay: Duration
    var loadsRecognizer: Bool
    static func make(
        launchedAtLogin: Bool, lowPower: Bool, thermal: ProcessInfo.ThermalState, memoryBytes: UInt64
    ) -> VoicePrewarmPolicy {
        let constrained = lowPower || thermal == .serious || thermal == .critical || memoryBytes < 8 << 30
        return VoicePrewarmPolicy(
            delay: launchedAtLogin ? .seconds(20) : .seconds(2), loadsRecognizer: !launchedAtLogin && !constrained)
    }
    static func current(launchedAtLogin: Bool) -> VoicePrewarmPolicy {
        let process = ProcessInfo.processInfo
        return make(
            launchedAtLogin: launchedAtLogin, lowPower: process.isLowPowerModeEnabled, thermal: process.thermalState,
            memoryBytes: process.physicalMemory)
    }
}

protocol VoiceAudioFile: Sendable {
    var url: URL { get }
    func cleanup()
}
extension CapturedAudio: VoiceAudioFile {}

@MainActor protocol VoiceAudioRecording {
    // True while starting would first ask for microphone permission.
    var awaitsPermission: Bool { get }
    var supportsPause: Bool { get }
    func pause() async throws
    func resume() async throws
    func setLiveSamplesHandler(_ handler: AudioCapture.SamplesHandler?)
    func start(
        requiresSpeechActivity: Bool, onLevel: @escaping AudioCapture.LevelHandler,
        onSpeechActivity: @escaping AudioCapture.SpeechHandler,
        onSpeechActivityUnavailable: @escaping AudioCapture.SpeechUnavailableHandler,
        onError: @escaping AudioCapture.ErrorHandler) async throws
    func finish() async throws -> any VoiceAudioFile
    func cancel() async
}
extension VoiceAudioRecording {
    var awaitsPermission: Bool { false }
    var supportsPause: Bool { false }
    func pause() async throws { throw AudioCaptureError.unavailable }
    func resume() async throws { throw AudioCaptureError.unavailable }
    func setLiveSamplesHandler(_ handler: AudioCapture.SamplesHandler?) {}
}
@MainActor private final class SystemVoiceAudio: VoiceAudioRecording {
    private let capture = AudioCapture()
    var supportsPause: Bool { true }
    var awaitsPermission: Bool { AVCaptureDevice.authorizationStatus(for: .audio) != .authorized }
    func pause() async throws { try await capture.pause() }
    func resume() async throws { try await capture.resume() }
    private var samplesHandler: AudioCapture.SamplesHandler?
    func setLiveSamplesHandler(_ handler: AudioCapture.SamplesHandler?) {
        samplesHandler = handler
        capture.setSamplesHandler(handler)
    }
    func start(
        requiresSpeechActivity: Bool, onLevel: @escaping AudioCapture.LevelHandler,
        onSpeechActivity: @escaping AudioCapture.SpeechHandler,
        onSpeechActivityUnavailable: @escaping AudioCapture.SpeechUnavailableHandler,
        onError: @escaping AudioCapture.ErrorHandler
    ) async throws {
        try await capture.start(
            requiresSpeechActivity: requiresSpeechActivity, onSamples: samplesHandler,
            onLevel: onLevel, onSpeechActivity: onSpeechActivity,
            onSpeechActivityUnavailable: onSpeechActivityUnavailable, onError: onError)
    }
    func finish() async throws -> any VoiceAudioFile { try await capture.finish() }
    func cancel() async { await capture.cancel() }
}

@MainActor protocol VoicePresenting: AnyObject {
    func showCompletionNotice(_ message: String)
    func dismissCompletionNotice()
    var onPauseResume: (() -> Void)? { get set }
    func configurePause(_ supported: Bool)
    var onFinish: (() -> Void)? { get set }
    var onCancel: (() -> Void)? { get set }
    var onCopy: (() -> Void)? { get set }
    var onInsert: (() -> Void)? { get set }
    var onCopyDraft: (() -> Void)? { get set }
    var onSettings: (() -> Void)? { get set }
    func setSettingsTitle(_ key: String)
    var onCompare: (() -> Void)? { get set }
    var onOutputChoiceChange: ((VoiceOutputChoice) -> Void)? { get set }
    var onFormatChange: ((String) -> Void)? { get set }
    func configureFormats(_ menu: VoiceFormatMenu?)
    var onOutputMenuTracking: ((Bool) -> Void)? { get set }
    func configureOutputChoice(
        languages: [String], refinement: Bool, refinementAvailable: Bool, selected: VoiceOutputChoice, changing: Bool)
    var onOutputLanguageChange: ((String?) -> Void)? { get set }
    func configureOutputLanguage(_ languages: [String], selected: String?)
    func configureSpokenLanguage(_ language: String?)
    func show(placement: VoiceOverlayPlacement, caretBounds: CGRect?, preferredScreen: NSScreen?)
    func prewarm()
    func update(phase: VoiceOverlayPhase, modeLabel: String, level: Double, result: String, message: String?)
    func updateCaretBounds(_ bounds: CGRect)
    func configureLivePreview(size: VoiceLivePreviewSize)
    func updateLiveTranscript(_ text: String)
    func updateLiveTranscriptStatus(_ message: String?)
    func configureResultContext(_ context: VoiceOverlayResultContext)
    func configureRecognitionRecovery(_ snapshot: VoiceRecognitionRecoverySnapshot?)
    func configureComparison(_ available: Bool)
    func configureCopyShortcut(_ label: String?)
    func configurePreviewInsert(_ label: String?)
    func showCopyFeedback(_ message: String?)
    func suspendPresentation() -> Bool
    func restorePresentation()
    func hide()
    func setAppearance(_ value: String)
    func configureLanguageNames(localized: Bool, modeLabel: String)
    func configurePreset(_ title: String)
}
extension VoicePresenting {
    func configurePreset(_ title: String) {}
    var onInsert: (() -> Void)? {
        get { nil }
        set {}
    }
    var onFormatChange: ((String) -> Void)? {
        get { nil }
        set {}
    }
    func configureFormats(_ menu: VoiceFormatMenu?) {}
    func showCompletionNotice(_ message: String) { hide() }
    func dismissCompletionNotice() {}
    var onPauseResume: (() -> Void)? {
        get { nil }
        set {}
    }
    func configurePause(_ supported: Bool) {}
    var onCompare: (() -> Void)? {
        get { nil }
        set {}
    }
    var onOutputMenuTracking: ((Bool) -> Void)? {
        get { nil }
        set {}
    }
    var onOutputLanguageChange: ((String?) -> Void)? {
        get { nil }
        set {}
    }
    func configureOutputLanguage(_ languages: [String], selected: String?) {}
    func configureSpokenLanguage(_ language: String?) {}
    func setAppearance(_ value: String) {}
    func configureLanguageNames(localized: Bool, modeLabel: String) {}
    func updateCaretBounds(_ bounds: CGRect) {}
    func configureLivePreview(size: VoiceLivePreviewSize) {}
    func updateLiveTranscript(_ text: String) {}
    func updateLiveTranscriptStatus(_ message: String?) {}
    func configureResultContext(_ context: VoiceOverlayResultContext) {}
    func configureRecognitionRecovery(_ snapshot: VoiceRecognitionRecoverySnapshot?) {}
    var onCopyDraft: (() -> Void)? {
        get { nil }
        set {}
    }
    func configureCopyShortcut(_ label: String?) {}
    func configurePreviewInsert(_ label: String?) {}
    func showCopyFeedback(_ message: String?) {}
    func configureComparison(_ available: Bool) {}
    func suspendPresentation() -> Bool { false }
    func restorePresentation() {}
    func configureOutputChoice(
        languages: [String], refinement: Bool, refinementAvailable: Bool, selected: VoiceOutputChoice, changing: Bool
    ) {}
}
extension VoicePresenting {
    func setSettingsTitle(_ key: String) {}
    func prewarm() {}
}
extension VoiceRecordingOverlay: VoicePresenting {
    func setSettingsTitle(_ key: String) { settingsTitleKey = key }
}
protocol VoiceFinishingKeys: AnyObject {
    var onFinish: (() -> Void)? { get set }
    var onCancel: (() -> Void)? { get set }
    var onCopy: (() -> Void)? { get set }
    func configureCopy(key: UInt32?, modifiers: UInt32) -> Bool
    func start(finishOnReturn: Bool) -> Bool
    func retainCancellation() -> Bool
    func swallowReturn() -> Bool
    func stop()
    func suspendForMenu()
    // While set, called once the person types or clicks in another app: a key
    // other than Return, Enter or Escape (an input method's composition, a
    // dead key, a new line of their own), or a mouse press outside Yullo.
    func watchOtherInput(_ handler: (() -> Void)?)
}
extension VoiceFinishingKeys {
    var onCopy: (() -> Void)? {
        get { nil }
        set {}
    }
    func watchOtherInput(_ handler: (() -> Void)?) {}
    func configureCopy(key: UInt32?, modifiers: UInt32) -> Bool { false }
    func suspendForMenu() { stop() }
    func swallowReturn() -> Bool { retainCancellation() }
}
extension RecordingKeyMonitor: VoiceFinishingKeys {}

// Dependencies express the only effects a recording may perform. Neither the
// destination token nor UI/application context enters the recognition/LLM calls.
struct VoiceBackend {
    var prepareModel: (VoiceRecognitionSettings) async throws -> Void
    var transcribe: (URL, VoiceRecognitionSettings) async throws -> LocalTranscriptionResult
    var translate: (String, String, TranslationSettings) async throws -> String {
        didSet { translateResult = nil }
    }
    var captureDestination: (Int32) async throws -> TextDelivery.Capture
    var insert: (String, UUID) async throws -> Int32
    var invalidateDestination: () -> Void
    var caretBounds: (UUID) async -> CGRect? = { _ in nil }
    var refine: (String, RewriteStyle, TranslationSettings) async throws -> String = {
        try await RefinementService.shared.refine(text: $0, style: $1, settings: $2)
    }
    var translateResult: ((String, String, TranslationSettings) async throws -> TranslationRoute.Result)? = nil
    var startLive:
        (
            VoiceRecognitionSettings, @Sendable @escaping (String) -> Void,
            @Sendable @escaping (Error) -> Void
        ) async throws -> any VoiceLiveRecognizing = { settings, text, failure in
            if settings.isApplePrimary {
                return try await AppleLiveRecognitionProvider.start(
                    settings: settings, onTranscript: text, onFailure: failure)
            }
            return try await VoiceResources.liveLocal.start(settings: settings, onTranscript: text, onFailure: failure)
        }
    // Optional preparation of the post-Stop recognizer's model while recording.
    // It cannot fail the recording and ends when the recognition warmup is cancelled.
    var warmModel: (VoiceRecognitionSettings) async -> Void = { _ in }
    // Optional recognizer started while recording; Stop gives it the finished WAV.
    var reserveRecognizer: (VoiceRecognitionSettings) async -> (any VoiceRecognitionReserving)? = { _ in nil }
    // Optional loading of the local translation model or Ollama on this Mac that will
    // translate or write the result, while recording. No text is sent.
    var prepareTranslation: (TranslationSettings) async -> Void = { _ in }
    // Optional loading of the recognizer as soon as a recording is requested,
    // in parallel with destination capture and microphone startup.
    var prepareRecognition: (VoiceRecognitionSettings, _ livePreview: Bool) async -> Void = { _, _ in }
    // Loads the recognizer after launch, before any recording; no audio is sent.
    var prewarmRecognition: (VoiceRecognitionSettings, _ livePreview: Bool) async -> Void = { _, _ in }
    static var system: VoiceBackend {
        VoiceBackend(
            prepareModel: { try await VoiceResources.recognition.prepare($0) },
            transcribe: { try await VoiceResources.recognition.transcribe(audioURL: $0, settings: $1) },
            translate: {
                try await TranslationService.shared.translate(text: $0, source: "auto", target: $1, settings: $2)
                    .finished()
            },
            captureDestination: { try await TextDelivery.capture(in: $0) },
            insert: { try await TextDelivery.insert($0, token: $1) },
            invalidateDestination: { TextDelivery.invalidate() },
            caretBounds: { await TextDelivery.caretBounds(token: $0) },
            translateResult: {
                try await TranslationService.shared.translate(text: $0, source: "auto", target: $1, settings: $2)
            }, warmModel: { await VoiceResources.recognition.warm($0) },
            reserveRecognizer: { await VoiceResources.recognition.reserve($0) },
            prepareTranslation: {
                if $0.ollamaOnThisMac {
                    await OllamaClient.shared.warmUp(host: $0.ollamaHost, model: $0.ollamaModel)
                    return
                }
                guard $0.engine == "local" else { return }
                await LocalTranslationProvider.shared.prepare(modelID: $0.localTranslationModelID)
            },
            prepareRecognition: { await VoiceResources.prepareRecognition($0, livePreview: $1) },
            prewarmRecognition: { await VoiceResources.prewarm($0, livePreview: $1) })
    }
}

// The authoritative WAV is independent of optional live startup. Buffer only a
// bounded prefix while the selected live model warms. A missing/rejected prefix
// makes final recognition use the complete WAV rather than incomplete live text.
private final class VoiceStartupPCM: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumSamples = 128_000
    private var buffered: [[Float]] = []
    private var count = 0
    private var recognizer: (any VoiceLiveRecognizing)?
    private var complete = true
    private var closed = false
    private let onFailure: @Sendable () -> Void
    init(onFailure: @escaping @Sendable () -> Void) { self.onFailure = onFailure }
    var hasCompletePrefix: Bool {
        lock.lock()
        defer { lock.unlock() }
        return complete
    }
    /// A loading local helper can take the buffered prefix in its one replay.
    var fitsLiveReplay: Bool {
        lock.lock()
        defer { lock.unlock() }
        return complete && LocalLiveRecognitionInput.admitsBurst(samples: count, frames: buffered.count)
    }
    func accept(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        if let recognizer {
            let failed = !recognizer.accept(samples)
            if failed {
                complete = false
                closed = true
                self.recognizer = nil
            }
            lock.unlock()
            if failed { onFailure() }
        } else {
            if complete, samples.count <= maximumSamples - count {
                buffered.append(samples)
                count += samples.count
            } else {
                complete = false
                buffered.removeAll()
                count = 0
            }
            lock.unlock()
        }
    }
    func attach(_ recognizer: any VoiceLiveRecognizing) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        self.recognizer = recognizer
        for samples in buffered where !recognizer.accept(samples) {
            complete = false
            closed = true
            self.recognizer = nil
            buffered.removeAll()
            count = 0
            return false
        }
        buffered.removeAll()
        count = 0
        return true
    }
    func close() {
        lock.lock()
        closed = true
        recognizer = nil
        buffered.removeAll()
        count = 0
        lock.unlock()
    }
}

@MainActor private final class VoiceInstructionCompletion {
    private var result: ((String) -> Void)?
    private var cancelled: (() -> Void)?
    init(result: @escaping (String) -> Void, cancelled: (() -> Void)?) {
        self.result = result
        self.cancelled = cancelled
    }
    func accept(_ text: String) {
        let callback = result
        result = nil
        cancelled = nil
        callback?(text)
    }
    func invalidate() {
        let callback = cancelled
        result = nil
        cancelled = nil
        callback?()
    }
}

@MainActor final class VoiceInputCoordinator: ObservableObject {
    @Published private(set) var phase: VoiceInputPhase = .idle { didSet { stateDidChange?() } }
    private(set) var level: Double = 0
    @Published private(set) var result = ""
    @Published private(set) var message = ""
    @Published private(set) var recentResultAvailable = false
    var openSettings: (() -> Void)?
    var openSetup: ((VoiceSetupDestination) -> Void)?
    var stateDidChange: (() -> Void)?
    var captureResultHistory: (() -> ResultHistoryStore.WriteTicket?)?
    var rememberResultHistory: ((ResultHistoryStore.WriteTicket, RecentVoiceResultStore.Snapshot) -> Bool)?
    var updateResultHistoryDelivery: ((UUID, RecentVoiceResultStore.DeliveryOutcome) -> Void)?
    var isSourceSession: Bool { session?.sourceResult != nil }
    var isInstructionSession: Bool { session?.instructionCompletion != nil }
    var isBusy: Bool {
        [.preparing, .recording, .paused, .transcribing, .translating, .refining, .delivering, .cancelling].contains(
            phase)
    }
    var canOpenRecentResult: Bool { !isBusy && result.isEmpty && recentResults.hasValue }
    var canClearRecentResult: Bool { recentResultAvailable || recoveredResult }
    var recentResultMetadata: RecentVoiceResultStore.Metadata? { recentResults.metadata() }
    private let recentResults: RecentVoiceResultStore
    private var recentRetentionEnabled = false
    private var recentRetentionSeconds = 300.0
    private var recoveredResult = false
    private var recoveredVoiceEdit = false
    // This describes earlier automatic delivery in the same expression, not
    // whether a later explicitly transformed version has itself been inserted.
    private var deliveryLineage = RecentVoiceResultStore.DeliveryOutcome.notInserted
    private struct Session {
        let id: UUID
        let appearance: String
        let entryMode: VoiceInputMode
        let recognition: VoiceRecognitionSettings
        var output: VoiceOutputChoice
        let allowsRecordingChoice: Bool
        let allowsRefinement: Bool
        let canRefine: Bool
        let outputLanguages: [String]
        // The recording window's language switch (empty when off) and the
        // language this recording writes in; neither is ever saved.
        var languageSwitch: [String] = []
        var outputLanguage: String? = nil
        var translation: TranslationSettings
        var refinement: TranslationSettings
        let previewFirst: Bool
        let livePreview: Bool
        let livePreviewSize: VoiceLivePreviewSize
        let placement: VoiceOverlayPlacement
        let autoFinish: Bool
        let finishOnReturn: Bool
        let finishOnShortcut: Bool
        let seconds: Double
        let sourceResult: ((String) -> SourceDictationDelivery)?
        var instructionCompletion: VoiceInstructionCompletion? = nil
        var trialCompletion: VoiceTrialCompletion? = nil
        var historyTicket: ResultHistoryStore.WriteTicket? = nil
        // Ordinary dictation's format and its menu; a pick lasts for this recording only.
        var format: String? = nil
        var formatSource: VoiceFormatSource? = nil
        // The menu names a format, except while a plain translation is picked without the language switch.
        @MainActor var formatMenu: VoiceFormatMenu? {
            guard let format, let formatSource else { return nil }
            if languageSwitch.isEmpty, case .translation = output { return formatSource.menu(selected: "") }
            return formatSource.menu(selected: format)
        }
    }
    private var session: Session?
    private var destination: TextDelivery.Capture?
    // Review before inserting: a kept result still holds the place it was
    // dictated into, so Return (or the shortcut again) puts it there. It ends
    // when another app comes forward, the preview closes or a minute passes.
    private struct PreviewInsertion {
        let sessionID: UUID
        let capture: TextDelivery.Capture
        let expiry: Task<Void, Never>
    }
    private var previewInsertion: PreviewInsertion?
    var previewInsertLifetime: Duration = .seconds(60)
    var canInsertPreview: Bool {
        guard let previewInsertion, phase == .preview, !previewChanging, !result.isEmpty else { return false }
        return session?.id == previewInsertion.sessionID
    }
    private var captureIssue: TextDelivery.Issue?
    private var resultContext = VoiceOverlayResultContext.preview
    private var operation: Task<Void, Never>?
    private var recognitionWarmup: Task<Void, Never>?
    // Set only while that warmup awaits startLive for this session and preview revision.
    private struct LiveStartup: Equatable {
        let session: UUID
        let revision: UUID
    }
    private var liveStartup: LiveStartup?
    // "Getting ready…" is shown while a cold live helper loads its model.
    private var liveReadyNotice: UUID?
    private var captureTransition: Task<Void, Never>?
    private var startupPCM: VoiceStartupPCM?
    private struct DrainingError {
        let sessionID: UUID
        var dismissed = false
    }
    private var drainingError: DrainingError?
    private var caretTracking: Task<Void, Never>?
    private var setupDestination: VoiceSetupDestination = .recognition {
        didSet {
            overlay.setSettingsTitle(
                setupDestination == .openOllama
                    ? "Open Ollama"
                    : setupDestination == .appleIntelligence ? "Turn on Apple Intelligence…" : "Settings")
        }
    }
    private var originalTranscript: String?
    private var processingTranscript: String?
    private var vocabularyNotice: String?
    private var transformationNotice: String?
    private var translationRecovery: RecentVoiceResultStore.Recovery?
    private var outputChoice: VoiceOutputChoice = .original
    private var previewChanging = false
    private var outputMenuTracking = false
    private var settingsPresented = false
    // The output that failed for lack of key access, kept for one retry of
    // that same session.
    private var keyAccessRetry: (session: UUID, choice: VoiceOutputChoice)?
    private var previewRevision = UUID()
    private var resultComparisonEnabled = true
    private var comparisonTicket: UUID?
    private var comparisonTask: Task<Void, Never>?
    private var comparisonPresentationNeedsRestore = false
    private var previewDrains: [UUID: Task<Void, Never>] = [:]
    private var localizedLanguageNames = false
    private var languageNameLocale = ""
    private var automaticFinishUnavailable = false
    private var recognitionRecovery: VoiceRecognitionRecoverySnapshot?
    private var errorRecognitionRecovery: VoiceRecognitionRecoverySnapshot?
    private var recoveryGeneration = UUID()
    #if YULLO_TESTING
        var testDraftWriter: ((String) -> Bool)?
    #endif
    private var liveRecognition: (any VoiceLiveRecognizing)?
    private var recognitionReservation: (any VoiceRecognitionReserving)?
    private var liveRevision = UUID()
    // The language the pill names for "same as spoken": the recognizer's own
    // language, or the most likely one, re-detected from live words until it settles.
    private var spokenTag = SpokenLanguageTag(likely: nil)
    private var spokenLanguages: [String] = []
    private var spokenText: (pending: String?, last: String) = (nil, "")
    private var spokenDetection: Task<Void, Never>?
    nonisolated static let lastSpokenLanguageKey = "yullo.lastSpokenLanguage"
    private var liveDrains: [UUID: Task<Void, Never>] = [:]
    private let audio: any VoiceAudioRecording
    private let overlay: any VoicePresenting
    private var resultCopyShortcut = Preferences().voiceResultCopyShortcut
    private var copyFeedbackID = UUID()
    private let keys: any VoiceFinishingKeys
    private let backend: VoiceBackend
    private let silence: RecordingSilenceMonitor
    private let comparison: any VoiceComparisonPresenting
    init(
        audio: (any VoiceAudioRecording)? = nil, overlay: (any VoicePresenting)? = nil,
        keys: (any VoiceFinishingKeys)? = nil, backend: VoiceBackend = .system,
        silence: RecordingSilenceMonitor? = nil, recentResults: RecentVoiceResultStore? = nil,
        comparison: (any VoiceComparisonPresenting)? = nil
    ) {
        self.audio = audio ?? SystemVoiceAudio()
        self.overlay = overlay ?? VoiceRecordingOverlay()
        self.keys = keys ?? RecordingKeyMonitor()
        self.backend = backend
        self.silence = silence ?? RecordingSilenceMonitor()
        self.comparison = comparison ?? VoiceResultComparisonPresenter()
        self.recentResults = recentResults ?? RecentVoiceResultStore()
        self.recentResultAvailable = self.recentResults.hasValue
        self.recentResults.onChange = { [weak self] in
            guard let self else { return }
            self.recentResultAvailable = self.recentResults.hasValue
            self.stateDidChange?()
        }
        self.keys.onFinish = { [weak self] in
            guard let self, !self.settingsPresented else { return }
            if self.phase == .preview {
                self.insertPreview()
                return
            }
            self.finish()
        }
        self.keys.onCancel = { [weak self] in
            guard let self, !self.outputMenuTracking, !self.settingsPresented else { return }
            self.cancel()
        }
        self.overlay.onFinish = { [weak self] in self?.finish() }
        self.overlay.onCancel = { [weak self] in self?.cancel() }
        self.keys.onCopy = { [weak self] in self?.copyVisibleResult() }
        self.overlay.onCopy = { [weak self] in self?.copyResult() }
        self.overlay.onInsert = { [weak self] in self?.insertPreview() }
        self.overlay.onCompare = { [weak self] in self?.compareResult() }
        observeSystemSuspension()
    }
    // Sleep, a locked screen or a switch to another user: the microphone never
    // stays on while the owner is away. A recording pauses, keeping what was
    // said, and says why; where audio can't pause, it finishes instead.
    private var suspensionObservers: [(NotificationCenter, NSObjectProtocol)] = []
    private func observeSystemSuspension() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let names: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.willSleepNotification), (workspace, NSWorkspace.screensDidSleepNotification),
            (workspace, NSWorkspace.sessionDidResignActiveNotification),
            (distributed, Notification.Name("com.apple.screenIsLocked"))
        ]
        suspensionObservers = names.map { center, name in
            (
                center,
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.systemWillSuspend() }
                }
            )
        }
        let activation = workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let processID = app?.processIdentifier
            MainActor.assumeIsolated { self?.frontApplicationChanged(to: processID) }
        }
        suspensionObservers.append((workspace, activation))
    }
    func systemWillSuspend() {
        guard let value = session, phase == .recording || phase == .preparing else { return }
        // Nothing said yet: stop. Audio that can't pause: finish with what was said.
        if phase == .preparing { return cancel() }
        guard canPauseResume else { return finish() }
        pauseOrResume()
        let transition = captureTransition
        Task { @MainActor [weak self] in
            await transition?.value
            guard let self, self.session?.id == value.id, self.phase == .paused else { return }
            self.message = L10n.tr("Paused while your Mac was asleep or locked. Resume in the recording indicator.")
            self.present(.paused, message: self.message)
        }
    }
    func configureResultPreferences(_ preferences: Preferences) {
        configureResultCopyShortcut(preferences.voiceResultCopyShortcut)
        configureResultComparison(enabled: preferences.voiceResultComparisonEnabled)
    }
    func configureResultCopyShortcut(_ shortcut: Shortcut) {
        resultCopyShortcut = shortcut
        refreshCopyShortcut()
    }
    // This is a presentation permission, independent of the captured processing
    // settings. Tightening it revokes all reader/copy leases before returning.
    func configureResultComparison(enabled: Bool) {
        guard resultComparisonEnabled != enabled else { return }
        resultComparisonEnabled = enabled
        if !enabled {
            let wasOpen = invalidateComparison()
            if wasOpen { _ = restoreKeysOrReportFailure() }
            restoreCurrentPresentationIfNeeded()
        }
        overlay.configureComparison(canCompareResult)
        stateDidChange?()
    }
    func configureRecentResultRetention(_ preferences: Preferences) {
        configureRecentResultRetention(
            enabled: preferences.voiceKeepRecentResult, seconds: preferences.voiceRecentResultSeconds)
    }
    // A pending Settings draft may tighten retention immediately. Enabling or
    // extending it waits for the ordinary successful preference commit.
    func restrictRecentResultRetention(enabled: Bool, seconds: Double) {
        configureRecentResultRetention(
            enabled: recentRetentionEnabled && enabled, seconds: min(recentRetentionSeconds, seconds))
    }
    private func configureRecentResultRetention(enabled: Bool, seconds: Double) {
        recentRetentionEnabled = enabled && seconds.isFinite
        recentRetentionSeconds = Preferences.normalizedVoiceRecentResultSeconds(seconds)
        recentResults.configure(enabled: enabled, durationSeconds: seconds)
        if !recentRetentionEnabled, recoveredResult { cancel() }
    }
    // Names are current UI metadata, independent of frozen processing choices.
    // Updating them must not present a result, restart work or renew retention.
    func configureLanguageNames(_ preferences: Preferences) {
        let localized = preferences.showLocalizedLanguageNames
        guard localizedLanguageNames != localized || languageNameLocale != L10n.language else { return }
        localizedLanguageNames = localized
        languageNameLocale = L10n.language
        overlay.configureLanguageNames(localized: localized, modeLabel: modeLabel)
    }
    func clearRecentResult() {
        recentResults.clear()
        if recoveredResult { cancel() }
    }
    @discardableResult func rememberReviewedVoiceEdit(
        source: String, result: String, outcome: RecentVoiceResultStore.DeliveryOutcome
    ) -> UUID? {
        let id = UUID()
        return recentResults.remember(
            .init(id: id, originalTranscript: source, finalText: result, output: .voiceEdit, deliveryOutcome: outcome))
            ? id : nil
    }
    func updateReviewedVoiceEditDelivery(_ outcome: RecentVoiceResultStore.DeliveryOutcome, recordID: UUID) {
        recentResults.updateDeliveryOutcome(outcome, for: recordID)
    }
    @discardableResult func openRecentResult(preferences: Preferences) -> Bool {
        guard canOpenRecentResult, let saved = recentResults.read()?.snapshot else { return false }
        overlay.configurePreset("")
        configureResultPreferences(preferences)
        automaticFinishUnavailable = false
        invalidateComparison()
        comparisonPresentationNeedsRestore = false
        stopCaretTracking()
        backend.invalidateDestination()
        endPreviewInsertion()
        destination = nil
        captureIssue = nil
        clearRecognitionRecovery()
        originalTranscript = saved.originalTranscript
        processingTranscript = saved.processingTranscript ?? saved.originalTranscript
        vocabularyNotice = nil
        translationRecovery = saved.recovery
        transformationNotice = Self.recoveryNotice(saved.recovery)
        deliveryLineage = saved.deliveryOutcome
        recoveredResult = true
        recoveredVoiceEdit = saved.output == .voiceEdit
        settingsPresented = false
        level = 0
        previewChanging = false
        previewRevision = UUID()
        outputMenuTracking = false
        setupDestination = saved.recovery == nil ? .recognition : .credentials
        outputChoice = Self.outputChoice(saved.output)
        resultContext = Self.recoveredContext(saved.deliveryOutcome)
        let languages = Language.enabled(preferences.enabledLanguages).map(\.id)
        let value = Session(
            id: UUID(), appearance: preferences.appearance, entryMode: .dictation,
            recognition: VoiceRecognitionSettings(preferences),
            output: outputChoice, allowsRecordingChoice: preferences.voiceTranslateEnabled,
            allowsRefinement: preferences.voiceTranslateEnabled,
            canRefine: VoiceWritingConnection.isConfigured(preferences), outputLanguages: languages,
            translation: TranslationSettings(preferences),
            refinement: TranslationSettings(preferences, engine: preferences.voiceRefinementEngine),
            previewFirst: true, livePreview: false,
            livePreviewSize: VoiceLivePreviewSize(rawValue: preferences.voiceLivePreviewSize) ?? .compact,
            placement: VoiceOverlayPlacement(rawValue: preferences.voicePlacement) ?? .bottom,
            autoFinish: false, finishOnReturn: false, finishOnShortcut: false, seconds: 3, sourceResult: nil)
        session = value
        configureOverlayActions(sessionID: value.id)
        configureLanguageNames(preferences)
        overlay.setAppearance(preferences.appearance)
        overlay.updateLiveTranscript("")
        overlay.updateLiveTranscriptStatus(nil)
        overlay.show(placement: value.placement, caretBounds: nil, preferredScreen: nil)
        keep(saved.finalText)
        _ = restoreKeysOrReportFailure()
        return true
    }
    // Prepares what a first recording would otherwise build while the person
    // waits: the hidden indicator, the audio stack and, when allowed, the recognizer.
    func prewarm(preferences: Preferences, loadsRecognizer: Bool) {
        if isBusy { return }
        overlay.setAppearance(preferences.appearance)
        overlay.prewarm()
        Task.detached(priority: .utility) { AudioCapture.prewarmAudioStack() }
        guard loadsRecognizer else { return }
        let settings = VoiceRecognitionSettings(preferences)
        let live =
            preferences.voiceLivePreview
            && (LiveRecognitionSupport.mode(modelID: preferences.voiceModelID) != nil
                || preferences.voiceModelID.hasPrefix("import-"))
        let io = backend
        Task.detached(priority: .utility) { await io.prewarmRecognition(settings, live) }
    }

    func start(
        mode: VoiceInputMode, preferences: Preferences, targetPID: Int32?,
        preserveTechnicalLiterals: Bool = false, presetTitle: String? = nil, presetInstructions: String? = nil,
        sourceCaretBounds: CGRect? = nil, sourceScreen: NSScreen? = nil,
        sourceCaretBoundsProvider: (() -> CGRect?)? = nil,
        sourceResult: ((String) -> SourceDictationDelivery)? = nil,
        instructionResult: ((String) -> Void)? = nil, instructionCancelled: (() -> Void)? = nil,
        finishShortcutAvailable: Bool = true, recordHistory: Bool = true,
        trialCompletion: VoiceTrialCompletion? = nil, startedBy: VoiceInputMode? = nil,
        formats: VoiceFormatSource? = nil
    ) {
        guard !isBusy else { return }
        // The key that started this recording finishes it, even when its
        // output runs as another mode (a voice translation row that formats).
        let entryMode = startedBy ?? mode
        overlay.dismissCompletionNotice()
        configureResultPreferences(preferences)
        automaticFinishUnavailable = false
        invalidateComparison()
        comparisonPresentationNeedsRestore = false
        recoveredResult = false
        recoveredVoiceEdit = false
        configureRecentResultRetention(preferences)
        deliveryLineage = .notInserted
        stopCaretTracking()
        if sourceResult == nil { backend.invalidateDestination() }
        endPreviewInsertion()
        destination = nil
        captureIssue = nil
        resultContext = .preview
        overlay.configureResultContext(.preview)
        result = ""
        message = ""
        level = 0
        liveRevision = UUID()
        spokenDetection?.cancel()
        spokenDetection = nil
        spokenTag = SpokenLanguageTag(likely: Self.likelySpokenLanguage(preferences))
        spokenLanguages = Language.enabled(preferences.enabledLanguages).map(\.id)
        spokenText = (nil, "")
        liveReadyNotice = nil
        audio.setLiveSamplesHandler(nil)
        overlay.updateLiveTranscript("")
        overlay.updateLiveTranscriptStatus(nil)
        setupDestination = .recognition
        clearRecognitionRecovery()
        originalTranscript = nil
        processingTranscript = nil
        vocabularyNotice = nil
        transformationNotice = nil
        translationRecovery = nil
        previewChanging = false
        previewRevision = UUID()
        outputMenuTracking = false
        settingsPresented = false
        let languages = Language.enabled(preferences.enabledLanguages).map(\.id)
        let requested = mode == .translation ? preferences.voiceTarget : preferences.voiceDictationTarget
        let output: VoiceOutputChoice
        if sourceResult != nil || instructionResult != nil || trialCompletion != nil {
            output = .original
        } else if mode == .translation {
            output = .translation(languages.contains(requested) ? requested : (languages.first ?? "en"))
        } else if !preferences.voiceTranslateEnabled {
            output = .original
        } else if preferences.voiceOutputMode == "refine" {
            output = .refinement(RewriteStyle(rawValue: preferences.voiceRefinementStyle) ?? .professional)
        } else if preferences.voiceOutputMode == "translate" {
            output = .translation(languages.contains(requested) ? requested : (languages.first ?? "en"))
        } else {
            output = .original
        }
        outputChoice = output
        let finishPolicy = preferences.effectiveVoiceFinishPolicy(
            forVoiceTranslation: entryMode == .translation, shortcutAvailable: finishShortcutAvailable)
        // A preset's frozen task choices apply only to ordinary dictation; the
        // caller passes a title only when resolution actually applied a preset.
        let ordinaryDictation =
            mode == .dictation && sourceResult == nil && instructionResult == nil && trialCompletion == nil
        let presetApplies = ordinaryDictation && preferences.voiceTranslateEnabled
        var refinement = TranslationSettings(preferences, engine: preferences.voiceRefinementEngine)
        refinement.preserveTechnicalLiterals = preserveTechnicalLiterals && presetApplies
        // A format on Apple's model: the model loads while the person speaks.
        if case .refinement = output, preferences.voiceRefinementEngine == "apple" {
            AppleWriterWarmSession.shared.prewarm("")
        }
        // A format in another language is one writing request in that language.
        if ordinaryDictation, let language = preferences.voiceWritingLanguage {
            refinement.writingRequirements = refinement.writingRequirements.writing(
                in: Self.writingLanguageName(language))
        }
        // The switch starts at the language this recording resolved to, so a
        // format keeps writing in the language the switch shows.
        let recordingLanguage: String?
        switch output {
        case .translation(let language): recordingLanguage = language
        case .refinement: recordingLanguage = ordinaryDictation ? preferences.voiceWritingLanguage : nil
        case .original: recordingLanguage = nil
        }
        var languageSwitch: [String] = []
        if preferences.voiceLanguageSwitch, preferences.offersDictationLanguages(writing: recordingLanguage),
            sourceResult == nil, instructionResult == nil, trialCompletion == nil,
            mode == .translation || preferences.voiceTranslateEnabled
        {
            languageSwitch = preferences.quickLanguageIDs
            if let recordingLanguage, !languageSwitch.contains(recordingLanguage) {
                languageSwitch.insert(recordingLanguage, at: 0)
            }
            if let recordingLanguage {
                refinement.writingRequirements = refinement.writingRequirements.writing(
                    in: Self.writingLanguageName(recordingLanguage))
            }
        }
        var translation = TranslationSettings(preferences)
        if presetApplies {
            refinement.presetInstructions = presetInstructions
            translation.presetInstructions = presetInstructions
        }
        let formatSource = presetApplies ? formats : nil
        overlay.configurePreset(
            ordinaryDictation
                ? formatSource.map { $0.menu(selected: $0.resolved).title($0.resolved) } ?? presetTitle ?? "" : "")
        var value = Session(
            id: UUID(), appearance: preferences.appearance, entryMode: entryMode,
            recognition: VoiceRecognitionSettings(preferences),
            output: output,
            allowsRecordingChoice: sourceResult == nil && instructionResult == nil && trialCompletion == nil
                && (mode == .translation || preferences.voiceTranslateEnabled),
            allowsRefinement: sourceResult == nil && instructionResult == nil && trialCompletion == nil
                && preferences.voiceTranslateEnabled,
            canRefine: VoiceWritingConnection.isConfigured(preferences),
            outputLanguages: languages, languageSwitch: languageSwitch, outputLanguage: recordingLanguage,
            translation: translation, refinement: refinement,
            previewFirst: sourceResult == nil && preferences.voicePreviewFirst,
            livePreview: preferences.voiceLivePreview
                && (LiveRecognitionSupport.mode(modelID: preferences.voiceModelID) != nil
                    || preferences.voiceModelID.hasPrefix("import-")),
            livePreviewSize: VoiceLivePreviewSize(rawValue: preferences.voiceLivePreviewSize) ?? .compact,
            placement: VoiceOverlayPlacement(rawValue: preferences.voicePlacement) ?? .bottom,
            autoFinish: finishPolicy.finishAfterPause,
            finishOnReturn: finishPolicy.finishOnReturn,
            finishOnShortcut: finishPolicy.finishOnShortcut,
            seconds: preferences.voiceSilenceSeconds.isFinite ? min(10, max(1, preferences.voiceSilenceSeconds)) : 3,
            sourceResult: sourceResult,
            instructionCompletion: instructionResult.map {
                VoiceInstructionCompletion(result: $0, cancelled: instructionCancelled)
            },
            trialCompletion: trialCompletion,
            historyTicket: recordHistory && sourceResult == nil && instructionResult == nil && trialCompletion == nil
                ? captureResultHistory?() : nil)
        if value.allowsRecordingChoice, let formatSource {
            value.format = formatSource.resolved
            value.formatSource = formatSource
        }
        overlay.setAppearance(preferences.appearance)
        overlay.configureLivePreview(size: value.livePreviewSize)
        overlay.configureOutputChoice(
            languages: [], refinement: false, refinementAvailable: false, selected: output, changing: false)
        overlay.configureFormats(nil)
        overlay.configureOutputLanguage([], selected: nil)
        session = value
        configureLanguageNames(preferences)
        phase = .preparing
        configureOverlayActions(sessionID: value.id)
        let io = backend
        let pressed = ContinuousClock.now
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            var preparing: Task<Void, Never>?
            defer { preparing?.cancel() }
            do {
                guard self.restoreKeyInterception() else {
                    throw VoiceInputIssue.finishKeyUnavailable
                }
                if !value.recognition.isApplePrimary {
                    let settings = value.recognition, live = value.livePreview
                    Task.detached(priority: .userInitiated) { await io.prepareRecognition(settings, live) }
                }
                // Capture before the HUD or permission UI can affect focus.
                if value.sourceResult == nil, value.instructionCompletion == nil, value.trialCompletion == nil,
                    let targetPID
                {
                    do {
                        let captured = try await io.captureDestination(targetPID)
                        try self.check(value.id)
                        self.destination = captured
                    } catch {
                        try self.check(value.id)
                        self.captureIssue = (error as? TextDelivery.Issue) ?? .failed
                    }
                }
                try self.check(value.id)
                if value.livePreview {
                    let revision = self.liveRevision
                    let startup = VoiceStartupPCM { [weak self] in
                        Task { @MainActor in
                            guard let self, self.session?.id == value.id, self.liveRevision == revision else { return }
                            self.stopLivePreview(message: LiveRecognitionIssue.overloaded.localizedDescription)
                        }
                    }
                    self.startupPCM = startup
                    self.audio.setLiveSamplesHandler { samples in startup.accept(samples) }
                }
                // A start that is still busy after a moment shows the indicator
                // as Preparing, so the key press is answered at once. A pending
                // permission request keeps the system prompt alone on screen.
                if !self.audio.awaitsPermission {
                    preparing = Task { @MainActor [weak self] in
                        try? await Task.sleep(until: pressed + Self.preparingIndicatorDelay)
                        guard !Task.isCancelled, let self, self.session?.id == value.id, self.phase == .preparing
                        else { return }
                        self.present(.preparing)
                        self.overlay.show(
                            placement: value.placement,
                            caretBounds: sourceCaretBounds ?? self.destination?.caretBounds,
                            preferredScreen: sourceScreen)
                    }
                }
                // A stated anchor (the Yullo window, the guide's trial or Sample card) wins over
                // the destination's caret, which those recordings don't have.
                try await self.audio.start(
                    requiresSpeechActivity: value.autoFinish,
                    onLevel: { [weak self] level in
                        guard let self, self.session?.id == value.id, self.phase == .recording else { return }
                        self.level = Double(level)
                        self.present(.recording)
                    },
                    onSpeechActivity: { [weak self] active in
                        guard let self, self.session?.id == value.id, self.phase == .recording else { return }
                        self.silence.observeSpeech(active)
                    }, onSpeechActivityUnavailable: { [weak self] in self?.speechActivityUnavailable(id: value.id) },
                    onError: { [weak self] error in self?.fail(error, id: value.id) })
                preparing?.cancel()
                try self.check(value.id)
                self.phase = .recording
                // Render the active phase before ordering the window front;
                // its previous/default phase must not flash during startup.
                self.present(.recording)
                self.overlay.show(
                    placement: value.placement,
                    caretBounds: sourceCaretBounds ?? self.destination?.caretBounds,
                    preferredScreen: sourceScreen)
                self.startCaretTracking(value, sourceBounds: sourceCaretBoundsProvider)
                guard self.restoreKeyInterception() else { throw VoiceInputIssue.finishKeyUnavailable }
                if !self.automaticFinishUnavailable {
                    self.silence.start(autoFinish: value.autoFinish, seconds: value.seconds) { [weak self] in
                        self?.finish()
                    }
                }
                self.operation = nil
                self.present(.recording)
                self.warmRecognition(value, backend: io)
                if value.livePreview { self.scheduleLiveReadyNotice(value.id) }
                if let settings = Self.preparedSettings(value) {
                    Task.detached(priority: .utility) { await io.prepareTranslation(settings) }
                }
            } catch {
                if !Task.isCancelled, self.session?.id == value.id {
                    self.present(.error, message: error.localizedDescription)
                    self.overlay.show(
                        placement: value.placement, caretBounds: sourceCaretBounds, preferredScreen: sourceScreen)
                    self.fail(error, id: value.id)
                }
            }
        }
    }
    // Below this, a start goes straight to Listening without a Preparing frame.
    static let preparingIndicatorDelay = Duration.milliseconds(80)
    // The service that will turn this recording's words into its result, if any.
    private static func preparedSettings(_ value: Session) -> TranslationSettings? {
        if value.instructionCompletion != nil { return value.refinement }
        switch value.output {
        case .original: return nil
        case .translation: return value.translation
        case .refinement: return value.refinement
        }
    }
    private func warmRecognition(_ value: Session, backend io: VoiceBackend) {
        recognitionWarmup = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.session?.id == value.id { self.recognitionWarmup = nil } }
            do {
                try await io.prepareModel(value.recognition)
                try self.check(value.id)
                guard self.phase == .recording || self.phase == .paused else { return }
                guard value.livePreview else {
                    // Without a live helper, final recognition's helper starts now and
                    // loads its model while the user speaks. A runtime that cannot
                    // wait for the audio gets its model verified and read instead.
                    if let reserved = await io.reserveRecognizer(value.recognition) {
                        guard !Task.isCancelled, self.session?.id == value.id,
                            self.phase == .recording || self.phase == .paused
                        else {
                            await reserved.cancel()
                            return
                        }
                        self.recognitionReservation = reserved
                        return
                    }
                    await io.warmModel(value.recognition)
                    return
                }
                let revision = self.liveRevision
                let startup = LiveStartup(session: value.id, revision: revision)
                self.liveStartup = startup
                do {
                    let live = try await io.startLive(
                        value.recognition,
                        { [weak self] text in
                            Task { @MainActor in
                                guard let self, self.session?.id == value.id, self.liveRevision == revision,
                                    self.phase == .recording || self.phase == .paused, self.liveRecognition != nil
                                else { return }
                                if value.instructionCompletion == nil {
                                    self.recognitionRecovery = VoiceRecognitionRecoverySnapshot(
                                        text: text, coverage: .latestWords)
                                }
                                if self.phase == .recording { self.overlay.updateLiveTranscript(text) }
                                self.detectSpokenLanguage(text, session: value.id)
                            }
                        },
                        { [weak self] error in
                            Task { @MainActor in
                                guard let self, self.session?.id == value.id, self.liveRevision == revision,
                                    self.phase == .recording || self.phase == .paused
                                else { return }
                                self.stopLivePreview(message: self.liveFailureMessage(error))
                            }
                        })
                    if self.liveStartup == startup { self.liveStartup = nil }
                    // Only finish's adoption leaves this task uncancelled in Transcribing;
                    // the complete buffered prefix then precedes the WAV finish frame.
                    guard !Task.isCancelled, self.session?.id == value.id, self.liveRevision == revision,
                        [.recording, .paused, .transcribing].contains(self.phase),
                        self.startupPCM?.attach(live) == true
                    else {
                        await live.cancel()
                        return
                    }
                    self.liveRecognition = live
                    if self.liveReadyNotice != nil {
                        self.liveReadyNotice = nil
                        self.overlay.updateLiveTranscriptStatus(nil)
                    }
                } catch {
                    if self.liveStartup == startup { self.liveStartup = nil }
                    try self.check(value.id)
                    // After Stop, finish recognizes the complete WAV once without a preview notice.
                    guard self.phase == .recording || self.phase == .paused else { return }
                    self.stopLivePreview(
                        message: (error as? LiveRecognitionIssue) == .unsupported ? "" : self.liveFailureMessage(error)
                    )
                }
            } catch {
                if !Task.isCancelled, self.session?.id == value.id,
                    self.phase == .recording || self.phase == .paused
                {
                    self.fail(error, id: value.id)
                }
            }
        }
    }

    // A warm helper is usually ready within a few milliseconds; only a model
    // that is still loading after a short moment shows "Getting ready…".
    private func scheduleLiveReadyNotice(_ id: UUID) {
        let notice = UUID()
        liveReadyNotice = notice
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, self.liveReadyNotice == notice, self.session?.id == id,
                self.phase == .recording || self.phase == .paused, self.liveRecognition == nil,
                self.liveStartup?.session == id || self.recognitionWarmup != nil
            else { return }
            self.overlay.updateLiveTranscriptStatus(L10n.tr("Getting ready…"))
        }
    }

    #if YULLO_TESTING
        var recognitionIsWarming: Bool { recognitionWarmup != nil }
    #endif
    var canPauseResume: Bool {
        audio.supportsPause && captureTransition == nil && !outputMenuTracking && !settingsPresented
            && (phase == .recording || phase == .paused)
    }
    func pauseOrResume() {
        guard canPauseResume, let value = session else { return }
        let resuming = phase == .paused
        captureTransition = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.session?.id == value.id {
                    self.captureTransition = nil
                    self.overlay.configurePause(self.canPauseResume)
                    self.stateDidChange?()
                }
            }
            do {
                try Task.checkCancellation()
                guard self.session?.id == value.id, self.phase == (resuming ? .paused : .recording) else { return }
                self.overlay.configurePause(false)
                if resuming {
                    try await self.audio.resume()
                    try self.check(value.id)
                    guard self.phase == .paused else { return }
                    self.phase = .recording
                    self.message = ""
                    self.silence.resumeAfterInteraction()
                    self.present(.recording)
                } else {
                    self.phase = .paused
                    self.level = 0
                    self.silence.pause()
                    try await self.audio.pause()
                    try self.check(value.id)
                    guard self.phase == .paused else { return }
                    self.present(.paused)
                }
                _ = self.restoreKeysOrReportFailure()
            } catch {
                guard !Task.isCancelled, self.session?.id == value.id, self.phase == .paused else { return }
                if resuming, let issue = error as? AudioCaptureError,
                    issue == .unavailable || issue == .deviceChanged
                {
                    self.message = error.localizedDescription
                    self.present(.paused, message: self.message)
                } else {
                    self.fail(error, id: value.id)
                }
            }
        }
    }

    private func speechActivityUnavailable(id: UUID) {
        guard session?.id == id, session?.autoFinish == true,
            phase == .preparing || phase == .recording || phase == .paused
        else { return }
        automaticFinishUnavailable = true
        silence.stop()
        if phase == .recording { present(.recording) }
    }
    static func outsideFix(_ error: Error) -> VoiceSetupDestination? {
        switch TranslationRecoveryAction.fixing(error, writing: true) {
        case .openOllama: return .openOllama
        case .appleIntelligence: return .appleIntelligence
        default: return nil
        }
    }
    private func configureOverlayActions(sessionID: UUID) {
        overlay.onPauseResume = { [weak self] in
            guard let self, self.session?.id == sessionID else { return }
            self.pauseOrResume()
        }
        overlay.onSettings = { [weak self] in
            guard let self, self.session?.id == sessionID,
                self.phase == .preview || self.phase == .error || self.hasVisibleDrainingError
            else { return }
            if let openSetup = self.openSetup { openSetup(self.setupDestination) } else { self.openSettings?() }
        }
        overlay.onOutputChoiceChange = { [weak self] choice in
            guard let self, self.session?.id == sessionID else { return }
            self.changeOutputChoice(choice)
        }
        overlay.onFormatChange = { [weak self] format in
            guard let self, self.session?.id == sessionID else { return }
            self.changeFormat(format)
        }
        overlay.onOutputMenuTracking = { [weak self] tracking in
            guard let self, self.session?.id == sessionID else { return }
            self.trackOutputMenu(tracking)
        }
        overlay.onOutputLanguageChange = { [weak self] language in
            guard let self, self.session?.id == sessionID else { return }
            self.changeOutputLanguage(language)
        }
    }
    @discardableResult func finishFromShortcut(_ mode: VoiceInputMode) -> Bool {
        guard let value = session, value.entryMode == mode, value.finishOnShortcut,
            (phase == .recording || phase == .paused), !outputMenuTracking, !settingsPresented
        else { return false }
        finish()
        return true
    }
    func finish() {
        guard let value = session, (phase == .recording || phase == .paused), !outputMenuTracking else { return }
        // A local live helper still loading for this preview can finalize the
        // complete WAV itself; cancelling it would discard that model load and
        // start a second cold recognizer. The adopted warmup stays registered,
        // so cancellation and failure still stop it. A longer prefix would be
        // refused on replay, so that helper is cancelled now.
        let adoptsLiveStartup =
            !value.recognition.isApplePrimary && liveStartup == LiveStartup(session: value.id, revision: liveRevision)
            && startupPCM?.fitsLiveReplay == true
        let warmup = recognitionWarmup
        if !adoptsLiveStartup {
            recognitionWarmup = nil
            warmup?.cancel()
        }
        let transition = captureTransition
        captureTransition = nil
        transition?.cancel()
        stopCaretTracking()
        // The phase claim precedes every await: Return and silence can finish
        // only once, even if both arrive in the same run-loop turn.
        phase = .transcribing
        automaticFinishUnavailable = false
        silence.stop()
        level = 0
        guard restoreKeyInterception() else {
            fail(VoiceInputIssue.finishKeyUnavailable, id: value.id)
            return
        }
        present(.transcribing)
        let io = backend
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            var recognizing = false
            do {
                await transition?.value
                let file = try await self.audio.finish()
                // Capture has drained every buffer. If its tail overflowed the
                // bounded prefix or the replay bound, the complete WAV needs no live helper.
                if adoptsLiveStartup, self.startupPCM?.fitsLiveReplay != true { warmup?.cancel() }
                await warmup?.value
                defer { file.cleanup() }
                try self.check(value.id)
                self.audio.setLiveSamplesHandler(nil)
                let live = self.liveRecognition
                self.liveRevision = UUID()
                let transcription: LocalTranscriptionResult
                recognizing = true
                var usedLiveFinal = false
                if let live, self.startupPCM?.hasCompletePrefix == true {
                    do {
                        transcription = try await live.finish(audioURL: file.url)
                        usedLiveFinal = true
                    } catch {
                        await self.captureRecognitionRecovery(from: live, sessionID: value.id)
                        await live.cancel()
                        try self.check(value.id)
                        transcription = try await io.transcribe(file.url, value.recognition)
                    }
                } else {
                    if let live { await self.captureRecognitionRecovery(from: live, sessionID: value.id) }
                    await live?.cancel()
                    for cleanup in Array(self.liveDrains.values) { await cleanup.value }
                    try self.check(value.id)
                    let reserved = self.recognitionReservation
                    self.recognitionReservation = nil
                    if let reserved {
                        transcription = try await reserved.finish(audioURL: file.url)
                    } else {
                        transcription = try await io.transcribe(file.url, value.recognition)
                    }
                }
                self.liveRecognition = nil
                self.startupPCM?.close()
                self.startupPCM = nil
                try self.check(value.id)
                let raw = transcription.text
                guard Self.validOutput(raw) else { throw LocalTranscriptionError.noSpeech }
                if Self.recognizerLanguage(value.recognition) == nil {
                    Self.rememberSpokenLanguage(of: raw, among: self.spokenLanguages)
                }
                recognizing = false
                self.clearRecognitionRecovery()
                if let instruction = value.instructionCompletion {
                    // A dedicated editing command is never ordinary dictation,
                    // a correction target, a deliverable body or recent text.
                    self.completed(value.id)
                    instruction.accept(raw)
                    return
                }
                let vocabulary = value.translation.personalVocabulary
                var original = raw
                var hintsRequested = false
                var notices: [String] = []
                if vocabulary.enabled {
                    let correction = Task.detached(priority: .userInitiated) {
                        try Task.checkCancellation()
                        let snapshot = try CoreVocabularyProcessor.shared.snapshot(for: vocabulary)
                        let text = try snapshot.correct(raw)
                        try Task.checkCancellation()
                        return (text, !snapshot.recognitionHintText.isEmpty)
                    }
                    do {
                        (original, hintsRequested) = try await withTaskCancellationHandler(
                            operation: { try await correction.value }, onCancel: { correction.cancel() })
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        notices.append(
                            L10n.tr("Couldn’t apply personal vocabulary. The original transcript is kept."))
                    }
                }
                try self.check(value.id)
                if transcription.vocabularyHintsUnavailable || (usedLiveFinal && hintsRequested) {
                    notices.append(
                        L10n.tr("This model doesn’t support recognition hints. Spelling corrections still apply."))
                }
                self.originalTranscript = raw
                self.processingTranscript = original
                self.vocabularyNotice = notices.isEmpty ? nil : notices.joined(separator: "\n")
                let text: String
                var completionNotice: String?
                if value.output == .original {
                    text = original
                } else {
                    if case .refinement = value.output {
                        self.phase = .refining
                        self.present(.refining)
                    } else {
                        self.phase = .translating
                        self.present(.translating)
                    }
                    do {
                        let transformed = try await self.transform(
                            original, choice: value.output, session: value, backend: io)
                        try self.check(value.id)
                        try Task.checkCancellation()
                        text = transformed.text
                        guard Self.validOutput(text) else { throw VoiceInputIssue.invalidResult }
                        self.transformationNotice = transformed.notice
                        self.translationRecovery = transformed.recovery
                        self.setupDestination = transformed.recovery == nil ? .recognition : .credentials
                        completionNotice = transformed.completionNotice
                    } catch {
                        try self.check(value.id)
                        self.setupDestination =
                            Self.outsideFix(error)
                            ?? (Self.isCredentialFailure(error)
                                ? .credentials
                                : error is ProcessingPolicyIssue
                                    ? .processing : self.setupDestination(for: value.output, session: value))
                        self.keyAccessRetry = Self.isCredentialFailure(error) ? (value.id, value.output) : nil
                        self.outputChoice = .original
                        self.rememberAcceptedResult(original, outcome: .notInserted)
                        self.keep(
                            original, message: self.failureMessage(error, choice: value.output, previous: false),
                            original: true)
                        return
                    }
                }
                try self.check(value.id)
                guard Self.validOutput(text) else { throw VoiceInputIssue.invalidResult }
                self.result = text
                if let trial = value.trialCompletion {
                    self.completed(value.id)
                    trial.complete(.recognized(text))
                    return
                }
                if value.previewFirst {
                    self.rememberAcceptedResult(text, outcome: .notInserted)
                    self.keep(text, insertable: true)
                    return
                }
                if let sourceResult = value.sourceResult {
                    self.phase = .delivering
                    let recordID = self.rememberAcceptedResult(text, outcome: .uncertain)
                    switch sourceResult(text) {
                    case .inserted:
                        self.updateRecentDelivery(.inserted, recordID: recordID)
                        self.completed(value.id, notice: completionNotice)
                    case .stale:
                        self.deliveryLineage = .notInserted
                        self.updateRecentDelivery(.notInserted, recordID: recordID)
                        self.keep(text, message: L10n.tr("The insertion point changed. Copy the result when ready."))
                    case .uncertain: self.keep(text, context: .insertionUnconfirmed)
                    }
                    return
                }
                guard let destination = self.destination else {
                    self.rememberAcceptedResult(text, outcome: .notInserted)
                    if self.captureIssue == .permission { self.setupDestination = .accessibility }
                    self.keepCopied(text, issue: self.captureIssue, capturing: true)
                    return
                }
                self.phase = .delivering
                // Dispatch may commit before cancellation or an acknowledgement
                // error arrives. Record uncertainty before crossing that boundary.
                let recordID = self.rememberAcceptedResult(text, outcome: .uncertain)
                do {
                    _ = try await io.insert(text, destination.token)
                    // A confirmed late receipt may correct this exact record,
                    // but cannot revive clear/expiry or replace a newer version.
                    self.updateRecentDelivery(.inserted, recordID: recordID)
                    try self.check(value.id)
                    self.completed(value.id, notice: completionNotice)
                } catch {
                    let issue = error as? TextDelivery.Issue
                    // TextDelivery's typed non-uncertain issues certify that
                    // its write was not dispatched. Unknown/cancelled writes
                    // have no such receipt and must remain uncertain.
                    let noWrite = issue != nil && issue != .uncertain
                    if noWrite { self.updateRecentDelivery(.notInserted, recordID: recordID) }
                    try self.check(value.id)
                    if issue == .permission { self.setupDestination = .accessibility }
                    if noWrite {
                        self.deliveryLineage = .notInserted
                        self.keepCopied(text, issue: issue, capturing: false)
                    } else {
                        self.keep(text, context: .insertionUnconfirmed)
                    }
                }
            } catch {
                if !Task.isCancelled {
                    if recognizing, self.session?.id == value.id, value.instructionCompletion == nil {
                        self.errorRecognitionRecovery = self.recognitionRecovery
                    }
                    self.fail(error, id: value.id)
                }
            }
        }
    }
    func cancelGuidedTrial(_ id: UUID) {
        guard session?.trialCompletion?.id == id else { return }
        cancel()
    }
    func cancel() {
        session?.trialCompletion?.complete(.cancelled)
        clearRecognitionRecovery()
        session?.instructionCompletion?.invalidate()
        automaticFinishUnavailable = false
        invalidateComparison()
        comparisonPresentationNeedsRestore = false
        stopCaretTracking()
        setupDestination = .recognition
        if phase == .cancelling {
            guard hasVisibleDrainingError else { return }
            // The failure task remains the sole cleanup owner. Dismiss its UI
            // now, but keep the busy phase until that same task has drained.
            drainingError?.dismissed = true
            session = nil
            keys.stop()
            originalTranscript = nil
            processingTranscript = nil
            vocabularyNotice = nil
            transformationNotice = nil
            translationRecovery = nil
            recoveredResult = false
            recoveredVoiceEdit = false
            outputChoice = .original
            previewChanging = false
            previewRevision = UUID()
            outputMenuTracking = false
            result = ""
            message = ""
            overlay.hide()
            return
        }
        let warmup = recognitionWarmup
        recognitionWarmup = nil
        warmup?.cancel()
        let transition = captureTransition
        captureTransition = nil
        transition?.cancel()
        startupPCM?.close()
        startupPCM = nil
        let task = operation
        task?.cancel()
        operation = nil
        let drains = Array(previewDrains.values)
        previewDrains.removeAll()
        drains.forEach { $0.cancel() }
        let live = liveRecognition
        liveRecognition = nil
        let reservation = recognitionReservation
        recognitionReservation = nil
        liveRevision = UUID()
        audio.setLiveSamplesHandler(nil)
        let liveCleanup = Array(liveDrains.values)
        liveDrains.removeAll()
        if !isSourceSession { backend.invalidateDestination() }
        endPreviewInsertion()
        session = nil
        silence.stop()
        keys.stop()
        destination = nil
        captureIssue = nil
        originalTranscript = nil
        processingTranscript = nil
        vocabularyNotice = nil
        transformationNotice = nil
        translationRecovery = nil
        recoveredResult = false
        recoveredVoiceEdit = false
        outputChoice = .original
        previewChanging = false
        previewRevision = UUID()
        outputMenuTracking = false
        result = ""
        message = ""
        overlay.hide()
        phase = .cancelling
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            await transition?.value
            await self.audio.cancel()
            await live?.cancel()
            await task?.value
            await warmup?.value
            await reservation?.cancel()
            for cleanup in liveCleanup { await cleanup.value }
            for drain in drains { await drain.value }
            self.operation = nil
            self.phase = .idle
        }
    }
    func cancelAndWait() async {
        cancel()
        await operation?.value
    }
    private func fail(_ error: Error, id: UUID) {
        guard session?.id == id, phase != .cancelling else { return }
        session?.instructionCompletion?.invalidate()
        automaticFinishUnavailable = false
        invalidateComparison()
        if (error as? AudioCaptureError) == .permissionDenied {
            setupDestination = .microphone
        } else {
            setupDestination =
                (error as? AudioCaptureError) == .speechDetectionUnavailable
                    || (error as? VoiceInputIssue) == .finishKeyUnavailable ? .finishMethods : .recognition
        }
        if let trial = session?.trialCompletion {
            trial.complete(.failed(error.localizedDescription))
            cancel()
            return
        }
        stopCaretTracking()
        let warmup = recognitionWarmup
        recognitionWarmup = nil
        warmup?.cancel()
        let transition = captureTransition
        captureTransition = nil
        transition?.cancel()
        startupPCM?.close()
        startupPCM = nil
        let task = operation
        task?.cancel()
        operation = nil
        let live = liveRecognition
        liveRecognition = nil
        let reservation = recognitionReservation
        recognitionReservation = nil
        liveRevision = UUID()
        audio.setLiveSamplesHandler(nil)
        let liveCleanup = Array(liveDrains.values)
        liveDrains.removeAll()
        let drains = Array(previewDrains.values)
        previewDrains.removeAll()
        drains.forEach { $0.cancel() }
        outputMenuTracking = false
        silence.stop()
        if !isSourceSession { backend.invalidateDestination() }
        endPreviewInsertion()
        destination = nil
        captureIssue = nil
        if errorRecognitionRecovery != nil,
            (error as? LocalTranscriptionError) == .noSpeech || (error as? VoiceInputIssue) == .invalidResult
        {
            message = L10n.tr("Couldn’t finish recognition.")
        } else {
            message = error.localizedDescription
        }
        phase = .error
        drainingError = DrainingError(sessionID: id)
        _ = restoreKeyInterception()
        present(.error, message: message)
        // Quiesce capture before another start is allowed.
        phase = .cancelling
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            await transition?.value
            await self.audio.cancel()
            await live?.cancel()
            await task?.value
            await warmup?.value
            await reservation?.cancel()
            for cleanup in liveCleanup { await cleanup.value }
            for drain in drains { await drain.value }
            guard let error = self.drainingError, error.sessionID == id else { return }
            self.drainingError = nil
            self.operation = nil
            self.phase = error.dismissed ? .idle : .error
            _ = self.restoreKeyInterception()
        }
    }
    private func keep(
        _ text: String, message: String? = nil, original: Bool = false, context: VoiceOverlayResultContext? = nil,
        insertable: Bool = false
    ) {
        let comparisonWasOpen = invalidateComparison()
        stopCaretTracking()
        if let context { resultContext = context }
        var message = message ?? resultContext.message
        for notice in [vocabularyNotice, transformationNotice].compactMap({ $0 })
        where message?.contains(notice) != true {
            message = [message, notice].compactMap { $0 }.joined(separator: "\n")
        }
        result = text
        self.message = message ?? ""
        phase = .preview
        operation = nil
        previewChanging = false
        if original { outputChoice = .original }
        let capture = insertable ? destination ?? previewInsertion?.capture : nil
        if let capture, let id = session?.id, !isSourceSession, !isInstructionSession,
            session?.trialCompletion == nil, resultContext == .preview
        {
            if previewInsertion?.capture.token != capture.token { armPreviewInsertion(capture, sessionID: id) }
        } else {
            endPreviewInsertion()
            if !isSourceSession { backend.invalidateDestination() }
        }
        destination = nil
        captureIssue = nil
        overlay.configureResultContext(resultContext)
        overlay.configureOutputChoice(
            languages: session?.allowsRecordingChoice == true ? session?.outputLanguages ?? [] : [],
            refinement: !isSourceSession && session?.allowsRefinement == true,
            refinementAvailable: session?.canRefine == true, selected: outputChoice, changing: false)
        overlay.configureFormats(isSourceSession ? nil : session?.formatMenu)
        overlay.update(
            phase: .preview, modeLabel: modeLabel,
            level: 0, result: text, message: message)
        overlay.configureComparison(canCompareResult)
        if comparisonWasOpen {
            _ = restoreKeysOrReportFailure()
        } else if session?.finishOnReturn == true || previewInsertion != nil {
            // A shown preview gives the held Return back to the app; Escape
            // stays. A preview that can still insert keeps Return for that.
            _ = restoreKeyInterception()
        }
        refreshCopyShortcut()
        restoreCurrentPresentationIfNeeded()
    }
    private func armPreviewInsertion(_ capture: TextDelivery.Capture, sessionID: UUID) {
        endPreviewInsertion()
        let lifetime = previewInsertLifetime
        let expiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled, let self, self.previewInsertion?.capture.token == capture.token else { return }
            self.releasePreviewInsertion()
        }
        previewInsertion = PreviewInsertion(sessionID: sessionID, capture: capture, expiry: expiry)
        keys.watchOtherInput { [weak self] in self?.otherInputWhilePreviewHeld() }
        overlay.configurePreviewInsert("↩")
    }
    private func endPreviewInsertion() {
        guard let value = previewInsertion else { return }
        previewInsertion = nil
        value.expiry.cancel()
        keys.watchOtherInput(nil)
        overlay.configurePreviewInsert(nil)
    }
    // The preview stays open for copying; Return goes back to the app.
    private func releasePreviewInsertion() {
        guard previewInsertion != nil else { return }
        endPreviewInsertion()
        backend.invalidateDestination()
        if phase == .preview { _ = restoreKeyInterception() }
    }
    // Another app came forward: the place the result was dictated into is no
    // longer where the person is, so Return is theirs again.
    // Yullo's own windows count too (the translator, the guide, About): a
    // Return meant for them must never write into the other app. Only the
    // comparison this preview opened keeps the place.
    func frontApplicationChanged(to processID: Int32?) {
        guard let insertion = previewInsertion, let processID, processID != insertion.capture.processID,
            processID != ProcessInfo.processInfo.processIdentifier || comparisonTicket == nil
        else { return }
        releasePreviewInsertion()
    }
    // The person typed or clicked in an app while the preview held Return:
    // they went on by themselves, so Return (and an input method's commit)
    // is theirs again. The preview stays for copying.
    func otherInputWhilePreviewHeld() {
        guard previewInsertion != nil, phase == .preview else { return }
        releasePreviewInsertion()
    }
    // The dictation shortcut pressed again while its preview can insert.
    @discardableResult func insertPreviewFromShortcut(_ mode: VoiceInputMode) -> Bool {
        guard canInsertPreview, session?.entryMode == mode, !settingsPresented, !outputMenuTracking else {
            return false
        }
        insertPreview()
        return true
    }
    func insertPreview() {
        guard canInsertPreview, !settingsPresented, !outputMenuTracking, comparisonTicket == nil,
            let insertion = previewInsertion, let value = session
        else { return }
        let text = result
        endPreviewInsertion()
        invalidateComparison()
        phase = .delivering
        // The Return that asked for this stays held until it is released.
        _ = keys.swallowReturn()
        refreshCopyShortcut()
        let recordID = rememberAcceptedResult(text, outcome: .uncertain)
        let io = backend
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // The token is checked afresh: same app, field, range and value.
                _ = try await io.insert(text, insertion.capture.token)
                self.updateRecentDelivery(.inserted, recordID: recordID)
                guard self.session?.id == value.id else { return }
                self.completed(value.id, notice: L10n.tr("Inserted"))
            } catch {
                let issue = error as? TextDelivery.Issue
                let noWrite = issue != nil && issue != .uncertain
                if noWrite { self.updateRecentDelivery(.notInserted, recordID: recordID) }
                guard self.session?.id == value.id, !Task.isCancelled else { return }
                if issue == .permission { self.setupDestination = .accessibility }
                if noWrite {
                    self.deliveryLineage = .notInserted
                    self.keepCopied(text, issue: issue, capturing: false)
                } else {
                    self.keep(text, context: .insertionUnconfirmed)
                }
            }
        }
    }
    // A result the person asked to insert that couldn't be written is put on
    // the clipboard, and the notice says so; only ⌘V remains.
    private func keepCopied(_ text: String, issue: TextDelivery.Issue?, capturing: Bool) {
        let reason = Self.deliveryFailureMessage(issue, capturing: capturing)
        guard DeliveryFallback.copy(text) else { return keep(text, message: reason) }
        // A reason that names a fix stays below; "copy when ready" no longer applies.
        let explains = issue != .failed && (issue != .staleDestination || capturing)
        keep(
            text,
            message: explains
                ? L10n.tr("Couldn’t insert the text. Result copied.") + "\n" + reason
                : L10n.tr("Couldn’t insert the text. Result copied."))
    }
    private func liveFailureMessage(_ error: Error) -> String {
        if let issue = error as? LiveRecognitionIssue { return issue.localizedDescription }
        return LiveRecognitionIssue.unavailable.localizedDescription
    }
    private func stopLivePreview(message: String) {
        liveReadyNotice = nil
        let live = liveRecognition
        liveRecognition = nil
        liveRevision = UUID()
        startupPCM?.close()
        audio.setLiveSamplesHandler(nil)
        overlay.updateLiveTranscriptStatus(message)
        guard let live else { return }
        let id = UUID()
        let owner = session?.id
        let generation = recoveryGeneration
        let cleanup = Task { @MainActor [weak self] in
            if let owner {
                await self?.captureRecognitionRecovery(from: live, sessionID: owner, generation: generation)
            }
            await live.cancel()
        }
        liveDrains[id] = cleanup
        Task { @MainActor [weak self] in
            await cleanup.value
            self?.liveDrains.removeValue(forKey: id)
        }
    }
    // After key access is allowed, run once more the output that stopped for
    // the key, on the same kept transcript.
    func retryAfterKeyAccess() {
        guard let retry = keyAccessRetry else { return }
        keyAccessRetry = nil
        guard session?.id == retry.session else { return }
        changeOutputChoice(retry.choice)
    }
    // A format from the pill: its plan for this recording only, then the same
    // path as any other output change. Recents remember the format, never text.
    private func changeFormat(_ format: String) {
        guard var value = session, let source = value.formatSource, value.sourceResult == nil,
            value.allowsRecordingChoice, phase == .recording || phase == .paused || phase == .preview,
            let plan = source.plan(format, language: value.languageSwitch.isEmpty ? nil : value.outputLanguage),
            plan.choice.isAvailable(
                languages: value.outputLanguages + [value.outputLanguage].compactMap { $0 },
                refinement: value.allowsRefinement && value.canRefine)
        else { return }
        let changed = format != value.format
        source.remember(format)
        value.format = format
        value.refinement.presetInstructions = plan.instructions
        value.refinement.preserveTechnicalLiterals = plan.preserveTechnicalLiterals
        value.translation.presetInstructions = plan.instructions
        session = value
        overlay.configurePreset(source.menu(selected: format).title(format))
        changeOutputChoice(plan.choice, formatChanged: changed)
    }
    private func changeOutputChoice(_ requested: VoiceOutputChoice, formatChanged: Bool = false) {
        guard let value = session, value.sourceResult == nil, value.allowsRecordingChoice,
            requested.isAvailable(
                languages: value.outputLanguages, refinement: value.allowsRefinement && value.canRefine)
        else { return }
        if phase == .recording || phase == .paused {
            // With the language switch, a format keeps the language it shows.
            var requested = requested
            if !value.languageSwitch.isEmpty, requested == .original, let language = value.outputLanguage {
                requested = .translation(language)
            }
            guard value.allowsRecordingChoice, requested != value.output || formatChanged else { return }
            // A plain pick from Translate is What I say in that language, without a format's instructions.
            if !formatChanged, session?.format != nil {
                session?.format = CoreOutput.spoken.format
                session?.refinement.presetInstructions = nil
                session?.refinement.preserveTechnicalLiterals = false
                session?.translation.presetInstructions = nil
            }
            session?.output = requested
            outputChoice = requested
            present(phase == .paused ? .paused : .recording)
            return
        }
        guard let raw = originalTranscript, phase == .preview || previewChanging else { return }
        let original = requested == .original ? raw : processingTranscript ?? raw
        guard
            requested != outputChoice || previewChanging || formatChanged
                || (requested == .original && !TextMutationRange.identical(raw, result))
        else { return }
        if !formatChanged, session?.format != nil {
            session?.format = CoreOutput.spoken.format
            session?.refinement.presetInstructions = nil
            session?.refinement.preserveTechnicalLiterals = false
            session?.translation.presetInstructions = nil
        }
        session?.historyTicket = captureResultHistory?()
        let comparisonWasOpen = invalidateComparison()
        if comparisonWasOpen, !restoreKeysOrReportFailure() { return }
        setupDestination = .recognition
        drainPreviewOperation()
        previewRevision = UUID()
        let revision = previewRevision
        if requested == .original {
            processingTranscript = raw
            vocabularyNotice = nil
            transformationNotice = nil
            translationRecovery = nil
            recoveredVoiceEdit = false
            outputChoice = .original
            rememberAcceptedResult(original, outcome: deliveryLineage)
            keep(original, insertable: previewInsertion != nil)
            return
        }
        if requested == outputChoice, !formatChanged {
            setupDestination = translationRecovery == nil ? .recognition : .credentials
            keep(result, insertable: previewInsertion != nil)
            return
        }
        previewChanging = true
        refreshCopyShortcut()
        if case .refinement = requested { phase = .refining } else { phase = .translating }
        // While the shown result changes, Return is the app's; Escape stays.
        if previewInsertion != nil { _ = restoreKeyInterception() }
        guard previewRevision == revision, previewChanging else { return }
        overlay.configureOutputChoice(
            languages: value.outputLanguages, refinement: value.allowsRefinement, refinementAvailable: value.canRefine,
            selected: outputChoice, changing: true)
        restoreCurrentPresentationIfNeeded()
        let previous = result, io = backend
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard !Task.isCancelled, self.session?.id == value.id,
                    self.previewRevision == revision, self.previewChanging
                else { return }
                let transformed = try await self.transform(
                    original, choice: requested, session: self.session ?? value, backend: io)
                try self.check(value.id)
                try Task.checkCancellation()
                guard self.previewRevision == revision else { return }
                let text = transformed.text
                guard Self.validOutput(text) else { throw VoiceInputIssue.invalidResult }
                self.outputChoice = requested
                self.recoveredVoiceEdit = false
                self.transformationNotice = transformed.notice
                self.translationRecovery = transformed.recovery
                self.setupDestination = transformed.recovery == nil ? .recognition : .credentials
                self.rememberAcceptedResult(text, outcome: self.deliveryLineage)
                self.keep(text, insertable: self.previewInsertion != nil)
            } catch {
                guard !Task.isCancelled, self.session?.id == value.id, self.previewRevision == revision else { return }
                self.keyAccessRetry = Self.isCredentialFailure(error) ? (value.id, requested) : nil
                self.setupDestination =
                    Self.outsideFix(error)
                    ?? (Self.isCredentialFailure(error)
                        ? .credentials
                        : error is ProcessingPolicyIssue
                            ? .processing : self.setupDestination(for: requested, session: value))
                self.keep(previous, message: self.failureMessage(error, choice: requested, previous: true))
            }
        }
    }
    // The language an open recording writes in, while it can still change.
    // The menu bar shows and changes this same state as the pill.
    var recordingOutputLanguage: String?? {
        guard let value = session, phase == .recording || phase == .paused, value.allowsRecordingChoice else {
            return nil
        }
        return .some(value.outputLanguage)
    }
    // The menu bar's Dictation Language during a recording: the pill's own
    // change, also when the pill's language button is hidden.
    func chooseRecordingOutputLanguage(_ language: String?) { changeOutputLanguage(language, fromPill: false) }
    // The recording window's language switch: this recording only, never a saved setting.
    private func changeOutputLanguage(_ language: String?, fromPill: Bool = true) {
        guard var value = session, phase == .recording || phase == .paused, value.allowsRecordingChoice,
            !fromPill || (!value.languageSwitch.isEmpty && (language.map(value.languageSwitch.contains) ?? true)),
            language != value.outputLanguage
        else { return }
        value.outputLanguage = language
        value.refinement.writingRequirements = value.refinement.writingRequirements.writing(
            in: language.map(Self.writingLanguageName))
        switch value.output {
        case .refinement: break
        case .original, .translation: value.output = language.map { .translation($0) } ?? .original
        }
        session = value
        outputChoice = value.output
        present(phase == .paused ? .paused : .recording)
    }
    // The recognizer's set language; otherwise the language detected last
    // time, or the first of the person's languages.
    static func likelySpokenLanguage(_ preferences: Preferences, defaults: UserDefaults = .standard) -> String? {
        let set = preferences.voiceRecognitionLanguage
        if !set.isEmpty, set != "auto" { return set }
        if let last = defaults.string(forKey: lastSpokenLanguageKey),
            Language.catalog.contains(where: { $0.id == last })
        {
            return last
        }
        return Language.enabled(preferences.enabledLanguages).first?.id
    }
    // Apple Speech transcribes in its locale's language; local models report
    // nothing until finish, so only their set language counts.
    static func recognizerLanguage(_ recognition: VoiceRecognitionSettings) -> String? {
        recognition.isApplePrimary ? Language.canonicalCode(recognition.appleLocale) : recognition.languageHint
    }
    private static func rememberSpokenLanguage(of text: String, among languages: [String]) {
        Task.detached(priority: .utility) {
            guard let language = SpokenLanguageDetection.detect(String(text.prefix(2_000)), among: languages),
                Language.catalog.contains(where: { $0.id == language })
            else { return }
            UserDefaults.standard.set(language, forKey: lastSpokenLanguageKey)
        }
    }
    // One detection at a time on the newest live words; a settled tag stops it.
    private func detectSpokenLanguage(_ text: String, session id: UUID) {
        guard let session, session.id == id, Self.recognizerLanguage(session.recognition) == nil, !spokenTag.settled,
            text != spokenText.last
        else { return }
        spokenText.pending = text
        guard spokenDetection == nil else { return }
        spokenText = (nil, text)
        let sample = String(text.suffix(400)), languages = spokenLanguages
        spokenDetection = Task { @MainActor [weak self] in
            let language = await Task.detached(priority: .utility) {
                SpokenLanguageDetection.detect(sample, among: languages)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.spokenDetection = nil
            guard self.session?.id == id else { return }
            if self.spokenTag.accept(language) { self.overlay.configureSpokenLanguage(self.spokenTag.shown) }
            if let next = self.spokenText.pending { self.detectSpokenLanguage(next, session: id) }
        }
    }
    private static func writingLanguageName(_ id: String) -> String {
        Language.catalog.first(where: { $0.id == id })?.subtitle ?? id
    }
    private func transform(_ text: String, choice: VoiceOutputChoice, session: Session, backend: VoiceBackend)
        async throws -> (
            text: String, notice: String?, completionNotice: String?, recovery: RecentVoiceResultStore.Recovery?
        )
    {
        switch choice {
        case .original: return (text, nil, nil, nil)
        case .translation(let language):
            if let translate = backend.translateResult {
                let translated = try await translate(text, language, session.translation)
                if translated.incomplete { throw TranslationIncomplete() }
                let notice =
                    translated.terminologyUnavailable
                    ? L10n.tr(
                        translated.usedAnyApple
                            ? "Apple translation doesn’t use your personal vocabulary."
                            : "This translation service doesn’t use your personal vocabulary.") : nil
                let fallback = translated.usedAnyApple && session.translation.engine != "apple"
                let recovery: RecentVoiceResultStore.Recovery? =
                    fallback && translated.recovery == .apiKeyAccess
                    ? (translated.usedMixedProviders ? .partlyAppleForAPIKeyAccess : .appleForAPIKeyAccess) : nil
                let details = [fallback ? L10n.tr(translated.appleFallbackNoticeKey) : nil, notice]
                    .compactMap { $0 }.joined(separator: "\n")
                return (
                    translated.text, details.isEmpty ? nil : details,
                    recovery != nil
                        ? L10n.tr("Inserted · Apple · API key access needed")
                        : fallback
                            ? L10n.tr(
                                translated.usedMixedProviders
                                    ? "Inserted · includes Apple translation" : "Inserted · Apple translation") : nil,
                    recovery
                )
            }
            return (try await backend.translate(text, language, session.translation), nil, nil, nil)
        case .refinement(let style):
            // Apple's model and Ollama on this Mac write under On this Mac only.
            let writer = session.refinement
            if writer.engine != "apple" && !writer.ollamaOnThisMac {
                try ProcessingPolicyController.shared.requireExternal(writer.authorization)
            }
            guard session.canRefine else { throw RefinementIssue.connectionRequired }
            let output = try await backend.refine(text, style, session.refinement)
            // A result written in another language can't be compared word for word.
            if session.refinement.writingRequirements.outputLanguage != nil { return (output, nil, nil, nil) }
            let review = try await WritingReview.inspect(
                source: text, result: output, vocabulary: session.refinement.personalVocabulary)
            return (output, review.notice, review.completionNotice, nil)
        }
    }
    private static func recoveryNotice(_ recovery: RecentVoiceResultStore.Recovery?) -> String? {
        switch recovery {
        case .appleForAPIKeyAccess: return L10n.tr("Translated with Apple. API key access was unavailable.")
        case .partlyAppleForAPIKeyAccess:
            return L10n.tr("Some parts were translated with Apple. API key access was unavailable.")
        case nil: return nil
        }
    }
    private func failureMessage(_ error: Error, choice: VoiceOutputChoice, previous: Bool) -> String {
        let kept = L10n.tr(previous ? "Previous result kept." : "Original kept.")
        if let failure = error as? TranslationRoute.Failure {
            let primary = Self.safeFailureReason(failure.api) ?? L10n.tr("Couldn’t reach the translation API.")
            let fallback: String
            switch failure.apple as? AppleTranslationIssue {
            case .unsupported: fallback = L10n.tr("Apple fallback doesn’t support this language pair.")
            case .downloadRequired:
                fallback = L10n.tr("Download this pair in Translation settings for offline fallback.")
            case .unidentified: fallback = L10n.tr("Choose a source language for Apple fallback.")
            default: fallback = L10n.tr("Apple fallback was also unavailable.")
            }
            return L10n.sentences([primary, fallback, kept])
        }
        if error is ProcessingPolicyIssue { return error.localizedDescription }
        if let reason = Self.safeFailureReason(error) { return L10n.sentences([reason, kept]) }
        if case .refinement = choice {
            return L10n.tr(
                previous ? "Refinement failed. Previous result kept." : "Refinement failed. Original transcript kept.")
        }
        return L10n.tr(
            previous ? "Translation failed. Previous result kept." : "Translation failed. Original transcript kept.")
    }
    private static func safeFailureReason(_ error: Error) -> String? {
        if let failure = error as? TranslationRoute.Failure { return safeFailureReason(failure.api) }
        return error is APIError || error is CLIError || error is RefinementIssue || error is ProcessingPolicyIssue
            || error is CoreLongTranslationError || error is StructuredJSONIssue || error is AppleTranslationIssue
            ? error.localizedDescription : nil
    }
    private static func isCredentialFailure(_ error: Error) -> Bool {
        if let issue = error as? APIError, case .keychain = issue { return true }
        if let failure = error as? TranslationRoute.Failure { return isCredentialFailure(failure.api) }
        return false
    }
    private func setupDestination(for choice: VoiceOutputChoice, session: Session) -> VoiceSetupDestination {
        switch choice {
        case .original: return .recognition
        case .translation: return .translation(engine: session.translation.engine)
        case .refinement: return .refinement(engine: session.refinement.engine)
        }
    }
    private func trackOutputMenu(_ tracking: Bool) {
        guard let value = session, (phase == .recording || phase == .paused || phase == .preview || previewChanging),
            value.allowsRecordingChoice,
            tracking != outputMenuTracking
        else { return }
        if tracking { invalidateComparison() }
        outputMenuTracking = tracking
        if tracking {
            if phase == .recording { silence.pause() }
            keys.suspendForMenu()
            refreshCopyShortcut()
        } else {
            guard restoreKeysOrReportFailure() else { return }
            if phase == .recording { silence.resumeAfterInteraction() }
        }
        overlay.configureComparison(canCompareResult)
        restoreCurrentPresentationIfNeeded()
    }
    func setSettingsPresented(_ presented: Bool) {
        // Native presentation calls this for every admitted app surface. A
        // newer navigation wins over a comparison queued before modal entry.
        let comparisonWasOpen = invalidateComparison()
        guard settingsPresented != presented || comparisonWasOpen || comparisonPresentationNeedsRestore else { return }
        settingsPresented = presented
        // A Yullo window in front: the dictated-into place is no longer where
        // the person is, so the preview keeps Copy only.
        if presented, previewInsertion != nil {
            endPreviewInsertion()
            backend.invalidateDestination()
        }
        _ = restoreKeysOrReportFailure()
        overlay.configureComparison(canCompareResult)
        restoreCurrentPresentationIfNeeded()
    }
    @discardableResult private func restoreKeysOrReportFailure() -> Bool {
        if restoreKeyInterception() { return true }
        guard (phase == .preview || previewChanging), !result.isEmpty else {
            if let value = session { fail(VoiceInputIssue.finishKeyUnavailable, id: value.id) }
            return false
        }
        // A valid preview remains useful with mouse Copy/Close even when a
        // global Escape binding is unavailable. Do not renew retained history.
        if previewChanging {
            drainPreviewOperation()
            previewRevision = UUID()
        }
        setupDestination = .finishMethods
        let detail = L10n.tr("Escape isn’t available right now. You can still copy or close this result.")
        let warning = resultContext.message
        var prior = message
        if let warning {
            if prior == warning {
                prior = ""
            } else if prior.hasPrefix(warning + "\n") {
                prior.removeFirst(warning.count + 1)
            }
        }
        prior = prior.components(separatedBy: "\n").filter { $0 != detail }.joined(separator: "\n")
        let recovery = [warning, prior.isEmpty ? nil : prior, detail].compactMap { $0 }.joined(separator: "\n")
        keep(result, message: recovery)
        return false
    }
    private func restoreKeyInterception() -> Bool {
        defer { refreshCopyShortcut() }
        guard let value = session, phase != .idle, phase != .cancelling || hasVisibleDrainingError else {
            keys.stop()
            return true
        }
        if settingsPresented || outputMenuTracking || comparisonTicket != nil {
            keys.suspendForMenu()
            return true
        }
        switch phase {
        case .recording, .paused: return keys.start(finishOnReturn: value.finishOnReturn)
        case .preparing, .transcribing, .translating, .refining, .delivering:
            // Changing a shown preview's output is not this recording's work.
            return value.finishOnReturn && !previewChanging ? keys.swallowReturn() : keys.retainCancellation()
        case .preview where canInsertPreview:
            if keys.start(finishOnReturn: true) { return true }
            endPreviewInsertion()
            return keys.retainCancellation()
        default: return keys.retainCancellation()
        }
    }
    private var hasVisibleDrainingError: Bool {
        guard phase == .cancelling, let error = drainingError, !error.dismissed else { return false }
        return session?.id == error.sessionID
    }
    private func drainPreviewOperation() {
        guard let pending = operation else { return }
        pending.cancel()
        operation = nil
        let id = UUID()
        previewDrains[id] = pending
        Task { @MainActor [weak self] in
            await pending.value
            self?.previewDrains.removeValue(forKey: id)
        }
    }
    private func completed(_ id: UUID, notice: String? = nil) {
        guard session?.id == id else { return }
        clearRecognitionRecovery()
        invalidateComparison()
        comparisonPresentationNeedsRestore = false
        stopCaretTracking()
        setupDestination = .recognition
        operation = nil
        endPreviewInsertion()
        destination = nil
        captureIssue = nil
        result = ""
        message = ""
        session = nil
        originalTranscript = nil
        processingTranscript = nil
        vocabularyNotice = nil
        transformationNotice = nil
        translationRecovery = nil
        recoveredResult = false
        recoveredVoiceEdit = false
        outputChoice = .original
        previewChanging = false
        outputMenuTracking = false
        keys.stop()
        if let notice { overlay.showCompletionNotice(notice) } else { overlay.hide() }
        phase = .idle
    }
    private static func deliveryFailureMessage(_ issue: TextDelivery.Issue?, capturing: Bool) -> String {
        switch issue {
        case .permission: return L10n.tr("Direct insertion needs Accessibility access in System Settings.")
        case .unsupported: return L10n.tr("This text field doesn’t support direct insertion.")
        case .uncertain: return VoiceOverlayResultContext.insertionUnconfirmed.message ?? ""
        case .staleDestination where !capturing:
            return L10n.tr("The insertion point changed. Copy the result when ready.")
        case .staleDestination, .none:
            return L10n.tr("To insert directly, click a text field before you start dictating.")
        case .failed: return L10n.tr("Direct insertion failed. Copy the result when ready.")
        }
    }
    private var modeLabel: String {
        // The instruction prompt guides the recording; an error speaks for itself.
        if session?.instructionCompletion != nil { return phase == .error ? "" : L10n.tr("Say what to change") }
        if recoveredVoiceEdit { return L10n.tr("Edited text") }
        if !recoveredResult, let menu = session?.formatMenu, !menu.selected.isEmpty { return menu.title(menu.selected) }
        return recoveredResult || session?.allowsRecordingChoice == true
            ? outputChoice.title(localizedLanguageNames: localizedLanguageNames) : ""
    }
    @discardableResult private func rememberAcceptedResult(
        _ text: String, outcome: RecentVoiceResultStore.DeliveryOutcome
    ) -> UUID? {
        guard session?.trialCompletion == nil else { return nil }
        deliveryLineage = outcome
        guard let originalTranscript else { return nil }
        let id = UUID()
        let snapshot = RecentVoiceResultStore.Snapshot(
            id: id, originalTranscript: originalTranscript, finalText: text,
            output: Self.storedOutput(outputChoice), deliveryOutcome: outcome,
            processingTranscript: processingTranscript.flatMap {
                TextMutationRange.identical($0, originalTranscript) ? nil : $0
            }, recovery: translationRecovery)
        let recentAccepted = recentResults.remember(snapshot)
        let historyAccepted = session?.historyTicket.flatMap { rememberResultHistory?($0, snapshot) } ?? false
        return recentAccepted || historyAccepted ? id : nil
    }
    private func updateRecentDelivery(_ outcome: RecentVoiceResultStore.DeliveryOutcome, recordID: UUID?) {
        guard let recordID else { return }
        recentResults.updateDeliveryOutcome(outcome, for: recordID)
        updateResultHistoryDelivery?(recordID, outcome)
    }
    private static func storedOutput(_ choice: VoiceOutputChoice) -> RecentVoiceResultStore.Output {
        switch choice {
        case .original: return .original
        case .translation(let id): return .translation(languageID: id)
        case .refinement(let style): return .refinement(style: style)
        }
    }
    private static func outputChoice(_ output: RecentVoiceResultStore.Output) -> VoiceOutputChoice {
        switch output {
        case .voiceEdit: return .original
        case .original: return .original
        case .translation(let id): return .translation(id)
        case .refinement(let style): return .refinement(style)
        }
    }
    private static func recoveredContext(_ outcome: RecentVoiceResultStore.DeliveryOutcome) -> VoiceOverlayResultContext
    {
        switch outcome {
        case .inserted: return .earlierOutputInserted
        case .notInserted: return .earlierOutputNotInserted
        case .uncertain: return .earlierOutputUnconfirmed
        }
    }
    private func stopCaretTracking() {
        caretTracking?.cancel()
        caretTracking = nil
    }
    private func startCaretTracking(_ value: Session, sourceBounds: (() -> CGRect?)?) {
        guard value.placement == .caret else { return }
        let token = destination?.token, io = backend
        guard sourceBounds != nil || token != nil else { return }
        caretTracking = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.session?.id == value.id,
                    self.phase == .preparing || self.phase == .recording || self.phase == .paused
                else { return }
                let bounds: CGRect?
                if let sourceBounds {
                    bounds = sourceBounds()
                } else if let token {
                    bounds = await io.caretBounds(token)
                } else {
                    return
                }
                guard !Task.isCancelled, self.session?.id == value.id,
                    self.phase == .preparing || self.phase == .recording || self.phase == .paused
                else { return }
                if let bounds, VoiceCaretCoordinates.isValid(bounds) { self.overlay.updateCaretBounds(bounds) }
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            }
        }
    }
    private func clearRecognitionRecovery() {
        recoveryGeneration = UUID()
        recognitionRecovery = nil
        errorRecognitionRecovery = nil
        overlay.onCopyDraft = nil
        overlay.configureRecognitionRecovery(nil)
    }
    private func captureRecognitionRecovery(
        from live: any VoiceLiveRecognizing, sessionID: UUID, generation: UUID? = nil
    ) async {
        let owner = generation ?? recoveryGeneration
        let snapshot = await live.recoverySnapshot()
        guard recoveryGeneration == owner, session?.id == sessionID, session?.instructionCompletion == nil else {
            return
        }
        if let snapshot { recognitionRecovery = snapshot }
    }
    private func configureRecognitionRecoveryForError() {
        let snapshot = errorRecognitionRecovery
        overlay.configureRecognitionRecovery(snapshot)
        guard let snapshot, let id = session?.id else {
            overlay.onCopyDraft = nil
            return
        }
        let generation = recoveryGeneration
        overlay.onCopyDraft = { [weak self] in
            guard let self, self.recoveryGeneration == generation, self.session?.id == id,
                self.phase == .error || self.hasVisibleDrainingError,
                self.errorRecognitionRecovery == snapshot, self.canCopyVisibleResult
            else { return }
            self.copyText(snapshot.text)
        }
    }
    private func present(_ phase: VoiceOverlayPhase, message: String? = nil) {
        if phase == .error { configureRecognitionRecoveryForError() }
        overlay.configureComparison(false)
        overlay.configurePause(canPauseResume)
        let editing = (phase == .recording || phase == .paused) && session?.allowsRecordingChoice == true
        overlay.configureOutputChoice(
            languages: editing ? session?.outputLanguages ?? [] : [],
            refinement: editing && session?.allowsRefinement == true, refinementAvailable: session?.canRefine == true,
            selected: outputChoice, changing: false)
        overlay.configureFormats(editing ? session?.formatMenu : nil)
        overlay.configureSpokenLanguage(session.flatMap { Self.recognizerLanguage($0.recognition) } ?? spokenTag.shown)
        overlay.configureOutputLanguage(
            editing ? session?.languageSwitch ?? [] : [], selected: session?.outputLanguage)
        let notice =
            message
            ?? ((phase == .recording || phase == .paused) && automaticFinishUnavailable
                ? L10n.tr("Automatic stopping is unavailable. Use the stop button to finish.") : nil)
        overlay.update(phase: phase, modeLabel: modeLabel, level: level, result: "", message: notice)
        refreshCopyShortcut()
        restoreCurrentPresentationIfNeeded()
    }
    var canCompareResult: Bool {
        guard resultComparisonEnabled, phase == .preview, !previewChanging, !settingsPresented, !outputMenuTracking,
            let originalTranscript,
            !originalTranscript.isEmpty, !result.isEmpty
        else { return false }
        return !TextMutationRange.identical(originalTranscript, result)
    }

    func compareResult() {
        guard canCompareResult, comparisonTicket == nil, let value = session, let originalTranscript else { return }
        let snapshot = VoiceComparisonSnapshot(
            sessionID: value.id, revision: previewRevision, original: originalTranscript, current: result,
            outputTitle: recoveredVoiceEdit
                ? L10n.tr("Edited text")
                : (outputChoice == .original
                    ? L10n.tr("Corrected transcript")
                    : outputChoice.title(localizedLanguageNames: localizedLanguageNames)), context: resultContext,
            message: message.isEmpty ? nil : message,
            appearance: value.appearance, canRestoreOriginal: true)
        let ticket = UUID()
        comparisonTicket = ticket
        keys.suspendForMenu()
        refreshCopyShortcut()
        comparisonTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            defer {
                // A modal callback may already have cancelled or replaced this
                // session. Never dismiss or restore keys over a newer owner.
                if self.comparisonTicket == ticket {
                    self.comparisonTicket = nil
                    self.comparisonTask = nil
                    self.comparison.setRestoreOriginalAction(nil)
                    self.comparison.dismiss()
                    if self.session?.id == snapshot.sessionID, self.previewRevision == snapshot.revision,
                        self.phase == .preview
                    {
                        _ = self.restoreKeysOrReportFailure()
                        self.restoreCurrentPresentationIfNeeded()
                    } else {
                        self.comparisonPresentationNeedsRestore = false
                    }
                }
            }
            guard !Task.isCancelled, self.comparisonIsCurrent(snapshot, ticket: ticket) else { return }
            self.comparisonPresentationNeedsRestore = self.overlay.suspendPresentation()
            guard !Task.isCancelled, self.comparisonIsCurrent(snapshot, ticket: ticket) else { return }
            self.comparison.setRestoreOriginalAction { [weak self] in
                guard let self, self.comparisonIsCurrent(snapshot, ticket: ticket) else { return }
                self.invalidateComparison()
                guard self.restoreKeysOrReportFailure() else { return }
                self.previewRevision = UUID()
                self.processingTranscript = snapshot.original
                self.vocabularyNotice = nil
                self.transformationNotice = nil
                self.translationRecovery = nil
                self.setupDestination = .recognition
                self.outputChoice = .original
                self.recoveredVoiceEdit = false
                self.rememberAcceptedResult(snapshot.original, outcome: self.deliveryLineage)
                // Restoring changes only this local result. No destination is
                // captured, renewed or written by the comparison action.
                self.keep(snapshot.original)
            }
            self.comparison.present(snapshot) { [weak self] in
                self?.comparisonIsCurrent(snapshot, ticket: ticket) == true
            }
        }
    }

    // The presenter clears text and copy leases synchronously. Lifecycle
    // mutations call this before changing the session, result or revision.
    @discardableResult func invalidateComparison() -> Bool {
        let wasOpen = comparisonTicket != nil
        comparisonTicket = nil
        comparisonTask?.cancel()
        comparisonTask = nil
        comparison.setRestoreOriginalAction(nil)
        overlay.configureComparison(false)
        if wasOpen { comparison.dismiss() }
        return wasOpen
    }

    // Called only after rendering the current owner. Suspension never clears
    // the HUD model, and an old modal completion cannot resurrect an old one.
    private func restoreCurrentPresentationIfNeeded() {
        guard comparisonPresentationNeedsRestore else { return }
        comparisonPresentationNeedsRestore = false
        guard phase != .idle, phase != .cancelling else { return }
        overlay.restorePresentation()
    }

    private func comparisonIsCurrent(_ snapshot: VoiceComparisonSnapshot, ticket: UUID) -> Bool {
        comparisonTicket == ticket && session?.id == snapshot.sessionID && previewRevision == snapshot.revision
            && canCompareResult && resultContext == snapshot.context && message == (snapshot.message ?? "")
            && TextMutationRange.identical(originalTranscript ?? "", snapshot.original)
            && TextMutationRange.identical(result, snapshot.current)
    }
    private var canCopyVisibleResult: Bool {
        guard !settingsPresented, !outputMenuTracking, comparisonTicket == nil, !previewChanging else { return false }
        return (phase == .preview && !result.isEmpty)
            || ((phase == .error || hasVisibleDrainingError) && errorRecognitionRecovery != nil)
    }
    private func refreshCopyShortcut() {
        let enabled = canCopyVisibleResult && resultCopyShortcut.isAssigned
        let registered = keys.configureCopy(
            key: enabled ? resultCopyShortcut.key : nil, modifiers: resultCopyShortcut.modifiers)
        overlay.configureCopyShortcut(registered && enabled ? resultCopyShortcut.displayLabel : nil)
    }
    private func copyVisibleResult() {
        guard canCopyVisibleResult else { return }
        if phase == .preview { copyResult() } else { overlay.onCopyDraft?() }
    }
    private func copyText(_ text: String) {
        let copied: Bool
        #if YULLO_TESTING
            if let writer = testDraftWriter {
                copied = writer(text)
            } else {
                // Never the owner's clipboard from a test build.
                let board = NSPasteboard(name: .init("local.yullo.testing.voice"))
                board.clearContents()
                copied = board.setString(text, forType: .string)
            }
        #else
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(text, forType: .string)
        #endif
        let id = UUID()
        copyFeedbackID = id
        overlay.showCopyFeedback(L10n.tr(copied ? "Copied" : "Couldn’t copy. Try again."))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.copyFeedbackID == id else { return }
            self.overlay.showCopyFeedback(nil)
        }
    }
    private func copyResult() {
        guard canCopyVisibleResult, phase == .preview else { return }
        copyText(result)
    }
    private func check(_ id: UUID) throws {
        try Task.checkCancellation()
        guard session?.id == id else { throw CancellationError() }
    }
    private static func validOutput(_ text: String) -> Bool {
        // Only "um", "uh" or "嗯" is no speech, never text to insert.
        text.utf8.count <= 262_144 && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !CoreSpokenFiller.isOnlyFiller(text)
    }
}

enum VoiceInputIssue: Error, LocalizedError, Equatable {
    case finishKeyUnavailable, invalidResult
    var errorDescription: String? {
        L10n.tr(
            self == .finishKeyUnavailable
                ? "Recording shortcuts are unavailable. Try again." : "No text was returned. Try recording again.")
    }
}
