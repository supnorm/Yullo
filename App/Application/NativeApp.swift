import SwiftUI
import AppKit
import Carbon
import ApplicationServices
import Combine

enum OutsideClickPolicy {
    // A press this close to a Yullo window aims at its edge, to resize or move
    // it, and never counts as leaving the window.
    static let edgeTolerance: CGFloat = 6
    static func isOnWindow(_ point: CGPoint, frames: [CGRect]) -> Bool {
        frames.contains { $0.insetBy(dx: -edgeTolerance, dy: -edgeTolerance).contains(point) }
    }
    static func shouldHide(enabled: Bool, trackingMenu: Bool, frames: [CGRect], point: CGPoint) -> Bool {
        enabled && !trackingMenu && !frames.isEmpty && !isOnWindow(point, frames: frames)
    }
    // Another app became active while the button is held on a Yullo window's
    // edge: the press began a resize or move, not a switch to that app.
    static func pressKeepsWindow(buttons: Int, point: CGPoint, frames: [CGRect]) -> Bool {
        buttons & 1 != 0 && isOnWindow(point, frames: frames)
    }
}

enum AppWindowSizing {
    static let mainMinimum = NSSize(width: 640, height: 320)
    static let selectionMinimum = NSSize(width: 360, height: 400)
    static let selectionSize = NSSize(width: 360, height: 440)
    static let settingsMinimum = NSSize(width: 700, height: 500)
    // The guide alone, without the Settings sidebar: at least its own minimum
    // (520 × 360) and opening a little above its ideal (620 × 550).
    static let setupMinimum = NSSize(width: 540, height: 360)
    static let setupSize = NSSize(width: 640, height: 600)

    static func configure(_ window: NSWindow, minimum: NSSize) {
        window.styleMask.insert(.resizable)
        window.contentMinSize = minimum
        window.contentResizeIncrements = NSSize(width: 1, height: 1)
    }
    // A large window moved from an external display must still fit when it is
    // reopened on a smaller display. Ordinary presentation keeps its user size.
    static func fit(_ window: NSWindow, in visible: NSRect) {
        let content = window.contentRect(forFrameRect: window.frame).size
        let chrome = window.frame.height - content.height
        let width = min(content.width, max(window.contentMinSize.width, visible.width))
        let height = min(content.height, max(window.contentMinSize.height, visible.height - chrome))
        if width != content.width || height != content.height {
            window.setContentSize(NSSize(width: width, height: height))
        }
    }
    // Setup is focused in the Settings window: a compact frame that keeps the
    // window's top centre. Returns the size that ending setup restores.
    @discardableResult static func focusSetup(_ window: NSWindow, in visible: NSRect?) -> NSSize {
        let previous = window.frame.size
        window.contentMinSize = setupMinimum
        GuideWindowFollowing.add(window)
        resize(window, to: window.frameRect(forContentRect: NSRect(origin: .zero, size: setupSize)).size, in: visible)
        return previous
    }
    static func restoreSettings(_ window: NSWindow, size: NSSize, in visible: NSRect?) {
        GuideWindowFollowing.remove(window)
        window.contentMinSize = settingsMinimum
        resize(window, to: size, in: visible)
        if let visible { fit(window, in: visible) }
    }
    private static func resize(_ window: NSWindow, to size: NSSize, in visible: NSRect?) {
        let current = window.frame
        var frame = NSRect(
            x: current.midX - size.width / 2, y: current.maxY - size.height, width: size.width, height: size.height)
        if let visible {
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        window.setFrame(frame, display: false)
    }
}

final class FloatingPanel: NSPanel, TextRevealingWindow {
    func roundContentCorners(_ radius: CGFloat) {
        // Rounded corners leave transparent pixels that would pass a press to
        // the app beneath; the whole frame belongs to this window, so a press
        // on a corner resizes it instead of activating that app.
        ignoresMouseEvents = false
        guard let contentView else { return }
        contentView.focusRingType = .none
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = radius
        contentView.layer?.cornerCurve = .continuous
        contentView.layer?.masksToBounds = true
        contentView.layer?.borderWidth = 0
        invalidateShadow()
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) {}  // Dismissal is handled by the configured local shortcut.

    // Set for one selection: the window grows so its finished text shows.
    // A size the person drags to ends growing for that selection.
    var growsToFitText = false
    override init(
        contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool
    ) {
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
        NotificationCenter.default.addObserver(
            self, selector: #selector(userResizeBegan), name: NSWindow.willStartLiveResizeNotification, object: self)
    }
    @objc private func userResizeBegan() { growsToFitText = false }
    // Grows downward, keeping the top edge, within the screen; text beyond that scrolls.
    private var growing = false
    func reveal(overflow: CGFloat) {
        guard growsToFitText, !growing, overflow > 1, isVisible, !inLiveResize, let visible = screen?.visibleFrame
        else { return }
        let height = min(frame.height + ceil(overflow), visible.height)
        guard height > frame.height + 0.5 else { return }
        var next = frame
        next.size.height = height
        next.origin.y = max(visible.minY, frame.maxY - height)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            setFrame(next, display: true)
            return
        }
        // A short ease-out, so the finished text opens rather than jumps;
        // the layout that follows measures again for any remainder.
        growing = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(next, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.growing = false
                self?.contentView?.needsLayout = true
            }
        }
    }
}

@available(macOS 26.0, *)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let model: Model
    private let welcomeStartup: WelcomeStartupCoordinator
    let voiceInput: VoiceInputCoordinator = {
        #if YULLO_TESTING
            if let injected = AppDelegate.testingSeams.voiceInput { return injected }
        #endif
        return VoiceInputCoordinator()
    }()
    let resultHistoryStore: ResultHistoryStore?
    let resultHistoryController: ResultHistoryController?
    private var historyWriteTask: Task<Void, Never>?
    private var voiceEditHistoryTicket: (session: UUID, ticket: ResultHistoryStore.WriteTicket?)?
    private var voiceEditHistoryRecord: (session: UUID, record: UUID)?
    private var voiceEditHistoryReceipts: [UUID: UUID] = [:]
    private var voiceEditHistoryReceiptOrder: [UUID] = []
    let selectionVoiceEdit: SelectionVoiceEdit = {
        #if YULLO_TESTING
            if let injected = AppDelegate.testingSeams.voiceEdit { return injected }
        #endif
        return SelectionVoiceEdit()
    }()
    #if YULLO_TESTING
        // In-process end-to-end checks: fake audio and writers, a stated microphone,
        // and activation recorded instead of taking the screen from other apps.
        struct TestingSeams {
            var voiceInput: VoiceInputCoordinator?
            var voiceEdit: SelectionVoiceEdit?
            var microphoneAuthorized: Bool?
            var activate: (() -> Void)?
            // The guide's screen for placement when its window is kept off every display.
            var guideScreen: CGRect?
            // Other apps, as the checks state them: which is in front, which still
            // run, and the activations Yullo asks for, recorded instead of taken.
            var frontmostPID: (() -> pid_t?)?
            var isRunning: ((pid_t) -> Bool)?
            var activateApplication: ((pid_t) -> Void)?
            var keyWindow: (() -> NSWindow?)?
            var uptime: (() -> TimeInterval)?
            var accessibilityTrusted: Bool?
            // The displays windows are placed on, so checks keep every window off the real ones.
            var screens: [PlacementScreen]?
            // Where the review's Copy writes, so checks never touch the general pasteboard.
            var reviewBackend: VoiceComparisonBackend?
        }
        nonisolated(unsafe) static var testingSeams = TestingSeams()
    #endif
    // Every activation goes through here, so checks can see it without taking the screen.
    private var reviewBackend: VoiceComparisonBackend {
        #if YULLO_TESTING
            if let backend = AppDelegate.testingSeams.reviewBackend { return backend }
        #endif
        return .system
    }
    private static func activateYullo() {
        #if YULLO_TESTING
            if let activate = AppDelegate.testingSeams.activate { return activate() }
        #endif
        NSApp.activate(ignoringOtherApps: true)
    }
    private var frontmostPID: pid_t? {
        #if YULLO_TESTING
            if let stated = AppDelegate.testingSeams.frontmostPID { return stated() }
        #endif
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
    private func applicationIsRunning(_ pid: pid_t) -> Bool {
        #if YULLO_TESTING
            if let stated = AppDelegate.testingSeams.isRunning { return stated(pid) }
        #endif
        return NSRunningApplication(processIdentifier: pid).map { !$0.isTerminated } ?? false
    }
    private func activateApplication(_ pid: pid_t) {
        #if YULLO_TESTING
            if let activate = AppDelegate.testingSeams.activateApplication { return activate(pid) }
        #endif
        NSRunningApplication(processIdentifier: pid)?.activate()
    }
    private var currentKeyWindow: NSWindow? {
        #if YULLO_TESTING
            if let stated = AppDelegate.testingSeams.keyWindow { return stated() }
        #endif
        return NSApp.keyWindow
    }
    // Read live at every selection action, never cached at launch.
    private func accessibilityGrant(_ action: String) -> AccessibilityGrant {
        #if YULLO_TESTING
            if let stated = AppDelegate.testingSeams.accessibilityTrusted { return stated ? .granted : .missing }
        #endif
        return AccessibilityGrant.checked(action)
    }
    private var uptime: TimeInterval {
        #if YULLO_TESTING
            if let stated = AppDelegate.testingSeams.uptime { return stated() }
        #endif
        return ProcessInfo.processInfo.systemUptime
    }
    // Leaving a translator goes back to the app the person came from, only
    // while Yullo is still in front and that app still runs; the selection's
    // own app first. A receipt arriving after they moved on changes nothing.
    private func focusReturnTarget(preferring preferred: pid_t? = nil) -> pid_t? {
        let own = ProcessInfo.processInfo.processIdentifier
        guard frontmostPID == own, let pid = preferred ?? translatorSourcePID ?? lastExternalPID, pid != own,
            applicationIsRunning(pid)
        else { return nil }
        return pid
    }
    private func guideScreenFrame(_ guide: NSWindow) -> CGRect? {
        #if YULLO_TESTING
            if let stated = AppDelegate.testingSeams.guideScreen { return stated }
        #endif
        return (guide.screen ?? NSScreen.main)?.visibleFrame
    }
    private var microphoneAuthorized: Bool {
        #if YULLO_TESTING
            if let stated = AppDelegate.testingSeams.microphoneAuthorized { return stated }
        #endif
        return PermissionSettingsBackend.system.status().microphone == .authorized
    }
    private let translationComparison = VoiceResultComparisonPresenter()
    private var voiceEditWindow: NSWindow?
    private let scenarioPanel = ScenarioPanelController()
    private var voiceEditReader: SelectionVoiceEditReview?
    private let voiceEditChip = RefineChip()
    private var voiceEditAnchor: NSRect?
    // Edit with voice from its key, reviewed first: the app it was pressed in,
    // the selection's write lease and where the selection is on screen.
    private var voiceEditSource: (processID: Int32, token: UUID?, bounds: CGRect?, end: CGRect?)?
    // An Edit with voice tried on the guide's sample: no selection, no History, no draft.
    private var voiceEditFromGuide = false
    // Edit with text: the same edit, its request typed in the review's own field.
    private var voiceEditTyped = false
    // Its target: Replace puts the edited text into the guide's sample.
    private var guideSampleReplace: ((String) -> Void)?
    private var voiceEditRecentSession: UUID?
    private var voiceEditRecentRecord: UUID?
    private var voiceEditReceipt: (attempt: UUID, record: UUID?)?
    private var voiceEditSuspendedForSettings = false
    let shortcuts: ShortcutRegistry
    var panel: FloatingPanel!
    var sidebar: FloatingPanel!
    var item: NSStatusItem!
    var settingsWindow: NSWindow!
    private var systemPromptReturn: SystemPromptReturn!
    private var systemPromptObservers: [NSObjectProtocol] = []
    var settingsLoaded = false
    private let settingsCommits = SettingsCommitCoordinator()
    private var settingsPreviewAppearance: String?
    private var settingsPreviewWindowStyle: String?
    private var settingsInitialAnchor: String?
    // Settings size to restore after the focused setup view; nil when unfocused.
    private var settingsSizeBeforeSetup: NSSize?
    private var settingsInitialModelTask: ModelTask?
    private var activeGuidedTrialID: UUID?
    private enum SettingsReturnContext: Equatable {
        case main, selection, quickMain, quickSelection, voice, noWindow
        // The Scenario panel, with the description typed so far.
        case scenario(String)
    }
    private var settingsReturnContext: SettingsReturnContext?
    // A return held back while the setup celebration plays; any newer presentation cancels it.
    private var pendingSettingsReturn: UUID?
    private var openingSettingsFromVoice = false
    private var openingSettingsFromScenario: String?
    private var editingMenuItem: NSMenuItem?
    private var voicePreferencesObservation: AnyCancellable?
    private var keyboardLayoutObservation: AnyCancellable?
    private var observedVoicePreferences: Preferences?
    var localShortcutMonitor: Any?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var trackingMenus = 0
    private var selectionCaptureTask: Task<Void, Never>?
    private var selectionCaptureID = UUID()
    private var pendingMainOrigin: CGPoint?
    private var saveMainOriginWork: DispatchWorkItem?
    private var lastExternalPID: pid_t?
    // The app a translator was opened from: the selection's app, or the one in front.
    private var translatorSourcePID: pid_t?
    private let pillRecents = VoicePillRecents()
    private let refineInPlace = RefineInPlaceController()
    private var activationObserver: NSObjectProtocol?
    private var changingActivationPolicy = false
    private var activationPolicyChangedAt = -TimeInterval.infinity
    // Key access was allowed during this Settings visit; the task that
    // stopped for the key runs again when Settings returns to it.
    private var keyAccessAllowedInSettings = false
    private var trialCardFrame: CGRect?
    private var sampleCardFrame: CGRect?
    private var launchedAtLogin = false
    private var voicePrewarm: Task<Void, Never>?
    private var prewarmedRecognition: [String]?
    override convenience init() {
        let welcome = WelcomeStateStore.application()
        let system = Language.systemIDs(
            preferred: Locale.preferredLanguages, inputSources: Self.inputSourceLanguages())
        if !system.isEmpty { Language.systemDefaultIDs = system }
        // Capture first-launch state before Model writes migration markers.
        let model = Model()
        let profile =
            welcome.isNewInstallation
            ? ShortcutProfile.recommended(using: ShortcutKeyboardLayout.keyCode) ?? .recommended : nil
        self.init(
            model: model, welcome: welcome,
            historyStore: ResultHistoryStore(
                enabled: model.preferences.resultHistoryEnabled,
                retention: ResultHistoryRetention(rawValue: model.preferences.resultHistoryRetention) ?? .week),
            initialShortcutProfile: profile, initialLanguages: welcome.isNewInstallation ? system : nil)
    }
    // The language of each input method the person has turned on (Pinyin, Kana…).
    // Plain keyboard layouts are left out: a Swiss German layout says where the
    // keyboard was bought, not that its owner writes German.
    private static func inputSourceLanguages() -> [String] {
        let filter =
            [
                kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                kTISPropertyInputSourceIsSelectCapable as String: true
            ] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource]
        else { return [] }
        return list.compactMap { source in
            if let type = TISGetInputSourceProperty(source, kTISPropertyInputSourceType),
                Unmanaged<CFString>.fromOpaque(type).takeUnretainedValue() as String == kTISTypeKeyboardLayout as String
            {
                return nil
            }
            guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return nil }
            return (Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String])?.first
        }
    }
    init(
        model: Model, welcome: WelcomeStateStore, historyStore: ResultHistoryStore? = nil,
        shortcutRegistry: ShortcutRegistry? = nil, initialShortcutProfile: ShortcutProfile? = nil,
        initialLanguages: [String]? = nil
    ) {
        resultHistoryStore = historyStore
        resultHistoryController = historyStore.map { ResultHistoryController(store: $0) }
        shortcuts = shortcutRegistry ?? ShortcutRegistry()
        welcomeStartup = WelcomeStartupCoordinator(welcome: welcome)
        self.model = model
        super.init()
        if welcome.isNewInstallation, let initialShortcutProfile {
            _ = model.adoptInitialShortcutProfile(initialShortcutProfile)
        }
        if welcome.isNewInstallation, let initialLanguages { model.adoptInitialLanguages(initialLanguages) }
        model.resultHistoryStore = historyStore
        model.historyWriteFailed = { [weak self] error in self?.resultHistoryController?.reportWriteFailure(error) }
        model.historyWriteSucceeded = { [weak self] in self?.resultHistoryController?.reportWriteSuccess() }
        voiceInput.captureResultHistory = { [weak self] in self?.captureHistoryTicket() }
        voiceInput.rememberResultHistory = { [weak self] ticket, snapshot in
            self?.rememberVoiceHistory(snapshot, ticket: ticket) ?? false
        }
        voiceInput.updateResultHistoryDelivery = { [weak self] id, outcome in
            self?.updateHistoryDelivery(outcome, for: id)
        }
        configureResultHistory(model.preferences)
    }
    private func captureHistoryTicket() -> ResultHistoryStore.WriteTicket? {
        model.preferences.resultHistoryEnabled ? resultHistoryStore?.captureWriteTicket() : nil
    }
    func configureResultHistory(_ preferences: Preferences) {
        guard let store = resultHistoryStore else { return }
        let enabled = preferences.resultHistoryEnabled
        let retention = ResultHistoryRetention(rawValue: preferences.resultHistoryRetention) ?? .week
        let configuration = store.prepareConfiguration(enabled: enabled, retention: retention)
        enqueueHistoryWrite {
            try await store.configure(configuration)
            return false
        }
    }
    private func enqueueHistoryWrite(_ action: @escaping () async throws -> Bool) {
        let previous = historyWriteTask
        historyWriteTask = Task { @MainActor [weak self] in
            await previous?.value
            do {
                if try await action() { self?.resultHistoryController?.reportWriteSuccess() }
            } catch { self?.resultHistoryController?.reportWriteFailure(error) }
        }
    }
    #if YULLO_TESTING
        func testEnqueueHistoryWrite(_ action: @escaping () async throws -> Bool) { enqueueHistoryWrite(action) }
        func testTryVoiceEditOnSample(
            _ text: String, typed: Bool = false, replace: @escaping (String) -> Void
        ) -> Bool {
            tryVoiceEditOnSample(text, typed: typed, replace: replace)
        }
        var testVoiceEditReader: SelectionVoiceEditReview? { voiceEditReader }
        var testVoiceEditWindow: NSWindow? { voiceEditWindow }
        var testVoiceEditChip: RefineChip { voiceEditChip }
        func testShowGuide(sampleCard: CGRect) {
            settingsSizeBeforeSetup = settingsWindow.frame.size
            sampleCardFrame = sampleCard
        }
        func testDismissTranslators() { dismissTranslators() }
        func testSetTranslatorSource(_ pid: pid_t?) { translatorSourcePID = pid }
        func testDismissTranslatorsTemporarily() { dismissTranslators(temporarily: true) }
        func testWireTranslatorActions() { wireTranslatorActions() }
        func testWireVoiceEdit() { wireSelectionVoiceEdit() }
        func testWireShortcutActions() { wireShortcutActions() }
        // The saved keys registered as at launch, through the registry this app was given.
        func testRegisterSavedShortcuts() -> Bool { registerSavedShortcuts() }
        // What the guide's Try buttons call.
        func testGuideTourActions() -> GuidedTourActions { guideTourActions() }
        var testRefineInPlace: RefineInPlaceController { refineInPlace }
        // The menu-bar menu as it opens, its items' keys set.
        func testStatusMenu() -> NSMenu {
            let menu = makeStatusMenu()
            menuNeedsUpdate(menu)
            return menu
        }
        // The real guide, as Welcome's Set up Yullo opens it.
        func testPresentGuide() { showSetupGuide() }
        var testSettingsLoaded: Bool { settingsLoaded }
        var testSampleCardScreenRect: NSRect? { voiceEditAnchor ?? sampleCardScreenRect() }
        var testingFrontApplication: OutputAppChooser.App?
    #endif
    @discardableResult private func rememberVoiceHistory(
        _ snapshot: RecentVoiceResultStore.Snapshot, ticket: ResultHistoryStore.WriteTicket
    ) -> Bool {
        guard model.preferences.resultHistoryEnabled, let store = resultHistoryStore else { return false }
        let task: ResultHistoryTask, target: String?
        switch snapshot.output {
        case .translation(let language):
            task = .translation
            target = language
        case .refinement:
            task = .writing
            target = nil
        case .original:
            task = .dictation
            target = nil
        case .voiceEdit: return false
        }
        let entry = ResultHistoryAcceptedResult(
            id: snapshot.id, task: task, source: snapshot.originalTranscript, result: snapshot.finalText,
            targetLanguage: target, delivery: Self.historyDelivery(snapshot.deliveryOutcome))
        enqueueHistoryWrite { try await store.save(entry, using: ticket) }
        return true
    }
    private static func historyDelivery(_ value: RecentVoiceResultStore.DeliveryOutcome) -> ResultHistoryDelivery {
        switch value {
        case .inserted: return .inserted
        case .notInserted: return .notInserted
        case .uncertain: return .uncertain
        }
    }
    private func updateHistoryDelivery(_ outcome: RecentVoiceResultStore.DeliveryOutcome, for id: UUID) {
        guard let store = resultHistoryStore else { return }
        let delivery = Self.historyDelivery(outcome)
        enqueueHistoryWrite { try await store.updateDelivery(delivery, for: id) }
    }
    func captureVoiceEditHistory(session: UUID) {
        voiceEditHistoryTicket = (session, captureHistoryTicket())
        voiceEditHistoryRecord = nil
    }
    func rememberVoiceEditHistory(
        session: UUID, source: String, result: String, outcome: RecentVoiceResultStore.DeliveryOutcome
    ) {
        guard model.preferences.resultHistoryEnabled, let store = resultHistoryStore,
            let admission = voiceEditHistoryTicket, admission.session == session, let ticket = admission.ticket
        else { return }
        let entry = ResultHistoryAcceptedResult(
            task: .writing, source: source, result: result, delivery: Self.historyDelivery(outcome))
        voiceEditHistoryRecord = (session, entry.id)
        enqueueHistoryWrite { try await store.save(entry, using: ticket) }
    }
    func updateVoiceEditHistory(session: UUID, attempt: UUID, outcome: RecentVoiceResultStore.DeliveryOutcome) {
        if voiceEditHistoryReceipts[attempt] == nil, outcome == .uncertain {
            guard let current = voiceEditHistoryRecord, current.session == session else { return }
            voiceEditHistoryReceipts[attempt] = current.record
            voiceEditHistoryReceiptOrder.append(attempt)
            if voiceEditHistoryReceiptOrder.count > 16 {
                voiceEditHistoryReceipts.removeValue(forKey: voiceEditHistoryReceiptOrder.removeFirst())
            }
        }
        guard let id = voiceEditHistoryReceipts[attempt] else { return }
        updateHistoryDelivery(outcome, for: id)
        if outcome != .uncertain {
            voiceEditHistoryReceipts.removeValue(forKey: attempt)
            voiceEditHistoryReceiptOrder.removeAll { $0 == attempt }
        }
    }
    func waitForPendingHistoryWrites() async {
        await resultHistoryController?.waitForPendingChanges()
        await model.waitForPendingHistoryWrites()
        await historyWriteTask?.value
    }
    func closeResultHistory() async {
        resultHistoryController?.disappear()
        await waitForPendingHistoryWrites()
        await resultHistoryStore?.close()
    }
    func openHistoryResult(_ entry: ResultHistoryEntry, translateAgain: Bool) {
        guard terminationTask == nil else { return }
        cancelSelectionCapture()
        voiceEditWindow?.close()
        voiceEditChip.dismiss()
        selectionVoiceEdit.cancel()
        panel?.orderOut(nil)
        sidebar?.orderOut(nil)
        if settingsWindow != nil {
            hideSettingsWindow()
            discardSettingsContent()
        }
        model.restoreHistory(entry, translateAgain: translateAgain)
        if let panel {
            positionMainPanel()
            if present(panel) { model.requestSourceFocus() }
        }
    }
    func applicationWillFinishLaunching(_ notification: Notification) {
        terminationSignal = TerminationSignal { NSApp.terminate(nil) }
        launchedAtLogin = LoginLaunchPolicy.shouldStartQuietly(event: NSAppleEventManager.shared().currentAppleEvent)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        launchedAtLogin =
            launchedAtLogin
            || LoginLaunchPolicy.shouldStartQuietly(event: NSAppleEventManager.shared().currentAppleEvent)
        AppUpdates.shared.start(quiet: welcomeStartup.shouldOfferWelcome)
        #if !YULLO_TESTING
            DispatchQueue.global(qos: .utility).async { TemporaryLeftovers.sweep() }
        #endif
        WindowStyleState.shared.apply(solid: Preferences.isSolidWindowStyle(model.preferences.windowStyle))
        rememberExternalApplication(NSWorkspace.shared.frontmostApplication)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.rememberExternalApplication(
                    note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            }
        }
        // macOS selects the bundled default/dark/tinted app icon. Overriding
        // applicationIconImage here would flatten those native appearances.
        NSApp.setActivationPolicy(model.preferences.showInDock ? .regular : .accessory)
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 430),
            styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        AppTheme.apply(model.preferences.appearance, to: panel)
        let mainHosting = ThemeHostingView(
            rootView: MainView(model: model), theme: model.preferences.appearance,
            inheritedAppearance: panel.effectiveAppearance)
        mainHosting.sizingOptions = []
        panel.contentView = mainHosting
        AppWindowSizing.configure(panel, minimum: AppWindowSizing.mainMinimum)
        panel.roundContentCorners(26)
        panel.delegate = self
        settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered,
            defer: false)
        AppWindowSizing.configure(settingsWindow, minimum: AppWindowSizing.settingsMinimum)
        settingsWindow.title = L10n.tr("Settings")
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.delegate = self
        settingsWindow.titleVisibility = .hidden
        settingsWindow.titlebarAppearsTransparent = true
        settingsWindow.center()
        systemPromptReturn = SystemPromptReturn { [weak self] window in
            guard let self, self.terminationTask == nil,
                window.isVisible || (window === self.settingsWindow && self.settingsLoaded)
            else { return }
            window.makeKeyAndOrderFront(nil)
            AppDelegate.activateYullo()
        }
        systemPromptObservers = [
            NotificationCenter.default.addObserver(
                forName: NSApplication.willResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.systemPromptReturn.yulloWillResign(keyWindow: NSApp.keyWindow) }
            },
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let bundleID = app?.bundleIdentifier
                let isYullo = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
                MainActor.assumeIsolated { self?.systemPromptReturn.activated(bundleID: bundleID, isYullo: isYullo) }
            },
            NotificationCenter.default.addObserver(
                forName: CredentialAccessInteraction.allowed, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.keyAccessAllowedInSettings = true }
            },
            NotificationCenter.default.addObserver(
                forName: CredentialAccessInteraction.changed, object: nil, queue: .main
            ) { [weak self] note in
                // The macOS key prompt can leave Settings behind other apps; bring it back when it ends.
                guard (note.object as? Bool) == false else { return }
                MainActor.assumeIsolated {
                    guard let self, self.terminationTask == nil, self.settingsLoaded else { return }
                    self.settingsWindow.makeKeyAndOrderFront(nil)
                    AppDelegate.activateYullo()
                }
            }
        ]

        AppTheme.apply(model.preferences.appearance, to: settingsWindow)
        model.openSettings = { [weak self] in self?.showSettings() }
        model.presentTranslationComparison = { [weak self] request in
            guard let self, self.terminationTask == nil, !self.hasBlockingModalInteraction else { return }
            self.translationComparison.setRestoreOriginalAction(request.restoreOriginal)
            self.translationComparison.present(request.snapshot, isCurrent: request.isCurrent)
        }
        model.dismissTranslationComparison = { [weak self] in self?.translationComparison.dismiss() }
        model.openTranslationRecovery = { [weak self] action in
            guard let self else { return }
            switch action {
            case .writingService, .anotherService(writing: true):
                self.presentSettings(page: .translation, anchor: "writing-service")
            case .anotherService(writing: false):
                self.presentSettings(page: .translation, anchor: "translation-model")
            case .keychain, .speechKeyAccess, .speechKey:
                guard let anchor = Self.savedKeyAnchor(action) else { return }
                self.presentSettings(page: .models, anchor: anchor.rawValue)
            case .openOllama:
                OllamaSuggestion.openApp(host: self.model.preferences.ollamaHost) {}
            case .appleLanguages:
                self.presentSettings(page: .translation, anchor: "apple-language-manager")
            case .appleIntelligence:
                NSWorkspace.shared.open(AppleWriterPresentation.settingsURL)
            case .accessibility:
                Model.openAccessibilitySettings()
            case .languages:
                self.presentSettings(page: .languages, anchor: "catalog")
            case .shortcuts:
                self.presentSettings(page: .general, anchor: "shortcuts")
            case .readAloud:
                self.presentSettings(page: .speech, anchor: nil)
            case .writer:
                let location = Self.engineLocation(self.model.preferences.voiceRefinementEngine, writing: true)
                self.presentSettings(page: location.page, anchor: location.anchor, modelTask: location.task)
            case .cliSignIn(let provider):
                self.showVoiceSetup(.cliSignIn(provider))
            case .allowOnline:
                self.presentSettings(page: .setup, anchor: "processing")
            case .systemVoices:
                if let url = URL(
                    string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")
                {
                    NSWorkspace.shared.open(url)
                }
            case .service:
                let location = Self.engineLocation(self.model.preferences.engine, writing: false)
                self.presentSettings(page: location.page, anchor: location.anchor, modelTask: location.task)
            }
        }
        voiceInput.openSettings = { [weak self] in self?.showVoiceSettings() }
        voiceInput.openSetup = { [weak self] destination in self?.showVoiceSetup(destination) }
        model.startSourceDictation = { [weak self] in self?.sourceDictation() }
        model.editSelectionWithVoice = { [weak self] in self?.startSelectionVoiceEdit() }
        wireSelectionVoiceEdit()
        selectionVoiceEdit.didAcceptResult = { [weak self] session, source, result, outcome in
            // A sample tried in the guide is kept nowhere.
            guard let self, !self.voiceEditFromGuide else { return }
            self.rememberVoiceEditHistory(session: session, source: source, result: result, outcome: outcome)
            self.voiceEditRecentSession = session
            self.voiceEditRecentRecord = self.voiceInput.rememberReviewedVoiceEdit(
                source: source, result: result, outcome: outcome)
        }
        selectionVoiceEdit.didAttemptReplacement = { [weak self] session, attempt, outcome in
            guard let self else { return }
            self.updateVoiceEditHistory(session: session, attempt: attempt, outcome: outcome)
            if outcome == .uncertain, self.voiceEditReceipt?.attempt != attempt {
                guard self.voiceEditRecentSession == session else { return }
                self.voiceEditReceipt = (attempt, self.voiceEditRecentRecord)
            }
            guard self.voiceEditReceipt?.attempt == attempt, let record = self.voiceEditReceipt?.record else { return }
            self.voiceInput.updateReviewedVoiceEditDelivery(outcome, recordID: record)
        }
        voiceInput.stateDidChange = { [weak self] in
            self?.updateSourceVoiceState()
            self?.refreshRecentResultMenuItems()
        }
        voicePreferencesObservation = model.$preferences.sink { [weak self] preferences in
            guard let self else { return }
            let previous = self.observedVoicePreferences
            self.observedVoicePreferences = preferences
            // Unrelated menu edits must not loosen a stricter, unsaved Settings
            // choice. Explicit settings commits apply their complete choice.
            if previous?.voiceKeepRecentResult != preferences.voiceKeepRecentResult
                || previous?.voiceRecentResultSeconds != preferences.voiceRecentResultSeconds
            {
                self.voiceInput.configureRecentResultRetention(preferences)
            }
            if previous?.voiceResultComparisonEnabled != preferences.voiceResultComparisonEnabled {
                self.voiceInput.configureResultComparison(enabled: preferences.voiceResultComparisonEnabled)
            }
            if previous?.voiceResultCopyShortcut != preferences.voiceResultCopyShortcut {
                self.voiceInput.configureResultCopyShortcut(preferences.voiceResultCopyShortcut)
            }
            self.voiceInput.configureLanguageNames(preferences)
            if previous?.resultHistoryEnabled != preferences.resultHistoryEnabled
                || previous?.resultHistoryRetention != preferences.resultHistoryRetention
            {
                self.configureResultHistory(preferences)
            }
        }
        keyboardLayoutObservation = DistributedNotificationCenter.default().publisher(
            for: ShortcutKeyboardLayout.didChange
        ).receive(on: DispatchQueue.main).sink { [weak self] _ in
            // Refresh shortcut captions only. Stored physical bindings and
            // active translation/recording work remain unchanged.
            self?.model.objectWillChange.send()
        }
        model.previewSettingsAppearance = { [weak self] value in
            self?.previewSettingsAppearance(value)
        }
        model.previewSettingsWindowStyle = { [weak self] value in
            self?.settingsPreviewWindowStyle = value
            self?.applyAppearance()
        }
        sidebar = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: AppWindowSizing.selectionSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        sidebar.isOpaque = false
        sidebar.backgroundColor = .clear
        sidebar.hasShadow = true
        sidebar.hidesOnDeactivate = false
        sidebar.level = .floating
        sidebar.isMovableByWindowBackground = true
        sidebar.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        AppTheme.apply(model.preferences.appearance, to: sidebar)
        let selectionHosting = ThemeHostingView(
            rootView: SelectionView(model: model), theme: model.preferences.appearance,
            inheritedAppearance: sidebar.effectiveAppearance)
        selectionHosting.sizingOptions = []
        sidebar.contentView = selectionHosting
        AppWindowSizing.configure(sidebar, minimum: AppWindowSizing.selectionMinimum)
        sidebar.roundContentCorners(23)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = BrandArtwork.templateImage
        item.button?.toolTip = "Yullo"
        item.button?.setAccessibilityLabel("Yullo")
        let menu = makeStatusMenu()
        item.menu = menu
        item.isVisible = model.preferences.showInMenuBar
        wireTranslatorActions()
        model.windowSession.didChange = { [weak self] in self?.updateOutsideClickMonitoring() }
        model.visibilityChanged = { [weak self] in self?.applyVisibility() }
        model.interfaceLanguageChanged = { [weak self] in self?.applyInterfaceLanguage() }
        let main = NSMenu()
        let appMenu = NSMenuItem(title: "Yullo", action: nil, keyEquivalent: "")
        appMenu.submenu = menu.copy() as? NSMenu
        appMenu.submenu?.delegate = self
        appMenu.submenu?.items.forEach { $0.submenu?.delegate = self }
        main.addItem(appMenu)
        let editItem = NSMenuItem(title: L10n.tr("Edit"), action: nil, keyEquivalent: "")
        editingMenuItem = editItem
        let edit = NSMenu(title: L10n.tr("Edit"))
        edit.delegate = self
        edit.addItem(withTitle: L10n.tr("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L10n.tr("Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L10n.tr("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L10n.tr("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L10n.tr("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L10n.tr("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
        localShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleLocalKeyDown(event)
        }
        // Notes when a shown result became ready, for the Return that commits it.
        outputReadinessObserver = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.noteOutputReadiness() }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuBegan(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(menuEnded(_:)), name: NSMenu.didEndTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(recordingShortcut(_:)), name: .yulloRecordingShortcut, object: nil)
        wireShortcutActions()
        refineInPlace.openInYullo = { [weak self] original in
            guard let self else { return }
            self.model.windowSession.resetPin()
            self.model.beginSelection(
                original, analysis: InputLanguageAnalysis.analyzeInput(original), replacementToken: nil,
                refining: true)
            self.openPanel()
        }
        // Not set up: the writer's own setup, or the row that chooses one.
        refineInPlace.openSetup = { [weak self] in
            guard let self else { return }
            let engine = self.model.preferences.voiceRefinementEngine
            guard VoiceEditService.isConfigured(self.model.preferences) else {
                WriteWithRow.opensChooser = true
                self.presentSettings(page: .refine, anchor: "writing-service")
                return
            }
            let location = Self.engineLocation(engine, writing: true)
            self.presentSettings(page: location.page, anchor: location.anchor, modelTask: location.task)
        }
        refineInPlace.openFix = { [weak self] fix in self?.model.openTranslationRecovery?(fix) }
        refineInPlace.recordInstruction = { [weak self] in await self?.recordInPlaceInstruction() }
        refineInPlace.openReview = { [weak self] original, instruction, result in
            self?.openInPlaceEditReview(original: original, instruction: instruction, result: result)
        }
        if !registerSavedShortcuts() {
            model.showNotice(L10n.tr("This shortcut is used by another app."), fix: .shortcuts)
        }
        applyAppearance()
        applyInterfaceLanguage()
        // Launching at login stays quiet in the menu bar. Otherwise Yullo opens
        // the window chosen in General, and Settings while translation needs setup.
        if !launchedAtLogin {
            if !offerWelcomeIfNeeded() {
                if model.configured && model.preferences.openYulloAtLaunch { openPanel() } else { showSettings() }
            }
        }
        scheduleVoicePrewarm(atLaunch: true)
    }
    // After Welcome, with a dictation key in place, the first recording finds
    // its indicator, audio stack and recognizer already prepared. Each
    // recognizer choice is loaded once; a later recording keeps it warm. Only
    // the login launch itself waits and skips the recognizer; closing Settings
    // later prepares the model chosen there.
    private func scheduleVoicePrewarm(atLaunch: Bool = false) {
        let policy = VoicePrewarmPolicy.current(launchedAtLogin: atLaunch && launchedAtLogin)
        voicePrewarm?.cancel()
        voicePrewarm = Task { @MainActor [weak self] in
            try? await Task.sleep(for: policy.delay)
            guard let self, !Task.isCancelled, self.terminationTask == nil, !self.welcomeStartup.shouldOfferWelcome,
                !self.voiceInput.isBusy, self.shortcuts.lastRegistrationReport.activeActionIDs.contains(3)
            else { return }
            let preferences = self.model.preferences
            // The model and its language decide what loads; a vocabulary edit doesn't load it again.
            let recognition = VoiceRecognitionSettings(preferences)
            let model = [
                recognition.modelID, "\(recognition.useAppleFallback)", recognition.appleLocale,
                recognition.languageHint ?? "", "\(preferences.voiceLivePreview)"
            ]
            let loads = policy.loadsRecognizer && self.prewarmedRecognition != model
            if loads { self.prewarmedRecognition = model }
            self.voiceInput.prewarm(preferences: preferences, loadsRecognizer: loads)
        }
    }
    @objc private func menuBegan(_ notification: Notification) { trackingMenus += 1 }
    @objc private func menuEnded(_ notification: Notification) { trackingMenus = max(0, trackingMenus - 1) }
    private func updateOutsideClickMonitoring() {
        let needed =
            !model.windowSession.isPinned && model.preferences.hideWhenClickingOutside
            && (panel.isVisible || sidebar.isVisible)
        if !needed {
            if let globalClickMonitor {
                NSEvent.removeMonitor(globalClickMonitor)
                self.globalClickMonitor = nil
            }
            if let localClickMonitor {
                NSEvent.removeMonitor(localClickMonitor)
                self.localClickMonitor = nil
            }
            return
        }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if globalClickMonitor == nil {
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
                DispatchQueue.main.async { self?.considerOutsideClick() }
            }
        }
        if localClickMonitor == nil {
            localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                self?.considerOutsideClick(eventWindow: event.window)
                return event
            }
        }
    }
    private var hasBlockingModalInteraction: Bool {
        welcomeStartup.isPresenting || hasOtherBlockingModalInteraction
            || (voiceEditSuspendedForSettings && settingsWindow?.isVisible == true)
    }
    private var hasOtherBlockingModalInteraction: Bool {
        KeyStore.isAuthorizing || CredentialAccessInteraction.isActive || voiceEditWindow?.isVisible == true
            || selectionVoiceEdit.phase == .processing
            || AppModalPolicy.blocksNewAction(
                modalWindow: NSApp.modalWindow, ownedWindows: [panel, sidebar, settingsWindow])
    }
    @discardableResult private func raiseModalInteraction() -> Bool {
        if voiceEditSuspendedForSettings, settingsWindow?.isVisible == true {
            settingsWindow.makeKeyAndOrderFront(nil)
            AppDelegate.activateYullo()
            return true
        }
        if let voiceEditWindow, voiceEditWindow.isVisible {
            // It takes keys without activating Yullo, so the app it edits stays in front.
            voiceEditWindow.makeKeyAndOrderFront(nil)
            return true
        }
        // The edit's own chip is already showing.
        if selectionVoiceEdit.phase == .processing { return true }
        guard terminationTask == nil,
            let window = AppModalPolicy.windowToRaise(
                modalWindow: NSApp.modalWindow, ownedWindows: [panel, sidebar, settingsWindow])
        else { return false }
        window.makeKeyAndOrderFront(nil)
        AppDelegate.activateYullo()
        return true
    }
    private var hasProtectedInteraction: Bool {
        // Explicit replacement can briefly return focus to its captured app.
        // Resigning Yullo during that operation must not cancel the same write.
        if model.replacingSelection { return true }
        if voiceEditWindow?.isVisible == true || [.processing, .error].contains(selectionVoiceEdit.phase) {
            return true
        }
        if voiceInput.isInstructionSession, voiceInput.isBusy { return true }
        if voiceInput.isSourceSession, voiceInput.phase == .preparing { return true }
        let front = NSWorkspace.shared.frontmostApplication
        if KeyStore.isAuthorizing || NSApp.modalWindow != nil || trackingMenus > 0
            || front?.bundleIdentifier == "com.apple.SecurityAgent"
        {
            return true
        }
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.hasMarkedText() {
            let identifier = front?.bundleIdentifier ?? ""
            if front?.processIdentifier == ProcessInfo.processInfo.processIdentifier
                || identifier.hasPrefix("com.apple.inputmethod.") || identifier == "com.apple.CharacterPaletteIM"
            {
                return true
            }
        }
        return false
    }
    private func considerOutsideClick(eventWindow: NSWindow? = nil) {
        guard !model.windowSession.isPinned, !hasProtectedInteraction, eventWindow !== settingsWindow else { return }
        if voiceInput.isSourceSession, eventWindow is VoiceOverlayPanel { return }
        if let eventWindow, eventWindow === panel || eventWindow === sidebar { return }
        let frames = [panel!, sidebar!].filter(\.isVisible).map(\.frame)
        if OutsideClickPolicy.shouldHide(
            enabled: model.preferences.hideWhenClickingOutside, trackingMenu: trackingMenus > 0, frames: frames,
            point: NSEvent.mouseLocation)
        {
            dismissTranslators(temporarily: true)
        }
    }
    private func wireTranslatorActions() {
        model.selectionReplaced = { [weak self] pid in
            // A receipt may arrive after the user has moved to another app.
            self?.dismissTranslators(returningFocus: true, to: pid)
        }
    }
    private var outputReadinessObserver: AnyCancellable?
    private func noteOutputReadiness() { model.noteOutputReadiness(now: uptime) }
    private func returnContext() -> TranslatorReturnRouting.Context {
        noteOutputReadiness()
        return .init(
            isSelectionWindow: currentKeyWindow === sidebar && model.selectionContext,
            offersReplacement: model.selectionOffersReplacement && !model.translationIncomplete,
            canReplace: model.canReplaceSelection, canUseOutput: model.canUseOutput,
            outputReadyAt: model.outputReadyAt, now: uptime)
    }
    // ⌘↩ copies; an unpinned window then closes and the previous app comes
    // back, so ⌘V is the only press left. A pinned window stays.
    private func copyTranslatorResult(closing: Bool? = nil) {
        guard model.canUseOutput else { return }
        model.copyTranslation()
        guard !model.copyFailed, closing ?? !model.windowSession.isPinned else { return }
        dismissTranslators(returningFocus: true)
    }
    @discardableResult func handleLocalKeyDown(_ event: NSEvent) -> NSEvent? {
        if SettingsSearchShortcut.handle(
            event, settingsWindow: self.settingsWindow, keyWindow: self.currentKeyWindow,
            focus: { self.settingsCommits.requestSearchFocus() })
        {
            return nil
        }
        guard self.currentKeyWindow === self.panel || self.currentKeyWindow === self.sidebar else { return event }
        // Escape and Return first belong to an in-progress input-method
        // composition. Do not consume them as window/task commands.
        if ShortcutInputRouting.shouldDeferToInputMethod(event, firstResponder: self.currentKeyWindow?.firstResponder) {
            return event
        }
        if self.model.preferences.localTranslateShortcut.matches(event) {
            if self.model.isTranslationPending { self.model.cancelTranslation() } else { self.model.translate() }
            return nil
        }
        if self.model.canUseBuiltInLocalShortcut(ShortcutProfile.localCancel),
            ShortcutProfile.localCancel.matches(event)
        {
            if self.voiceInput.isBusy { self.voiceInput.cancel() } else { self.model.cancelTranslation() }
            return nil
        }
        if self.model.canUseBuiltInLocalShortcut(ShortcutProfile.localCloseWindow),
            ShortcutProfile.localCloseWindow.matches(event)
        {
            self.dismissTranslators(returningFocus: true)
            return nil
        }
        if self.model.preferences.closeShortcut.matches(event) {
            self.dismissTranslators(returningFocus: true)
            return nil
        }
        if TranslatorCopyRouting.isCommandCopy(event) {
            guard
                TranslatorCopyRouting.canCopyResult(
                    firstResponder: self.currentKeyWindow?.firstResponder,
                    hasAcceptedOutput: self.model.canUseOutput)
            else { return event }
            self.model.copyTranslation()
            return nil
        }
        if self.model.preferences.copyShortcut.matches(event) {
            self.copyTranslatorResult()
            return nil
        }
        switch TranslatorReturnRouting.action(
            for: event, firstResponder: self.currentKeyWindow?.firstResponder, context: self.returnContext())
        {
        case .pass: break
        case .ignore: return nil
        case .replace:
            self.model.replaceSelection()
            return nil
        case .copyAndReturn:
            self.copyTranslatorResult(closing: true)
            return nil
        }
        if self.currentKeyWindow === self.sidebar, self.model.preferences.replaceShortcut.matches(event) {
            self.model.replaceSelection()
            return nil
        }
        return event
    }
    private func dismissTranslators(temporarily: Bool = false, returningFocus: Bool = false, to preferred: pid_t? = nil)
    {
        if temporarily && !panel.isVisible && !sidebar.isVisible { return }
        // Leaving (Esc, the close key, Copy and close, a finished Replace) goes
        // back to the previous app; a click outside or a pinned window does not.
        let returnTo =
            returningFocus && !temporarily && !model.windowSession.isPinned && !guideIsShown
            ? focusReturnTarget(preferring: preferred) : nil
        let surface: WindowSession.Surface = sidebar.isVisible ? .selection : .main
        cancelSelectionCapture()
        panel.orderOut(nil)
        sidebar.orderOut(nil)
        model.stopSpeaking()
        if temporarily { model.prepareQuickReturn(surface: surface) } else { model.clearTranslatorDraft() }
        // A translator opened later, from another app, goes back to that app.
        if !temporarily { translatorSourcePID = nil }
        updateOutsideClickMonitoring()
        returnToGuide()
        if let returnTo { activateApplication(returnTo) }
    }
    // The guide stays open behind a window it opened; when that window goes, the
    // guide comes forward at the step it was on.
    private var guideIsShown: Bool { settingsWindow?.isVisible == true && settingsSizeBeforeSetup != nil }
    // Esc, the toggle key, the close button and a click outside all end here, even
    // when the click went to another app: Yullo comes forward with the guide.
    private func returnToGuide() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.guideIsShown, !self.panel.isVisible, !self.sidebar.isVisible,
                self.voiceEditWindow == nil, !self.voiceInput.isBusy
            else { return }
            self.updateActivationPolicy()
            AppDelegate.activateYullo()
            self.settingsWindow.makeKeyAndOrderFront(nil)
        }
    }
    // Edit with voice on the guide's sample: the spoken change, then the real review
    // window. Nothing is selected elsewhere, so there is nothing to replace.
    // The edit draws itself as it changes: chip, review or nothing.
    // The menu-bar menu: where Yullo works, the actions with their keys, then the app's own items.
    private func makeStatusMenu() -> NSMenu {
        let menu = AppMenuPolicy.managedMenu(title: "Yullo", delegate: self)
        // Where Yullo works, at a glance; it opens its row in Settings.
        // Actions follow; the app's own items (About, Settings, Quit) close the menu.
        let whereItem = menu.addItem(withTitle: "", action: #selector(showWhereYulloWorks), keyEquivalent: "")
        whereItem.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: nil)
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.tr("Show Yullo"), action: #selector(togglePanel), keyEquivalent: "")
        menu.addItem(
            withTitle: L10n.tr("Translate Selected Text"), action: #selector(selectionPanel), keyEquivalent: "")
        menu.addItem(
            withTitle: L10n.tr("Refine in Yullo Window…"), action: #selector(refineSelectionPanel), keyEquivalent: "")
        let refineItem = menu.addItem(
            withTitle: L10n.tr("Refine in Place"), action: #selector(refineInPlaceFromMenu(_:)), keyEquivalent: "")
        refineItem.identifier = NSUserInterfaceItemIdentifier("refine-in-place")
        refineItem.submenu = NSMenu(title: L10n.tr("Refine in Place"))
        refineItem.submenu?.delegate = self
        menu.addItem(
            withTitle: L10n.tr("Edit with Voice"), action: #selector(editWithVoiceInPlace), keyEquivalent: "")
        menu.addItem(
            withTitle: L10n.tr("Edit with Text"), action: #selector(editWithTextInPlace), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.tr("Start Dictation"), action: #selector(startDictation), keyEquivalent: "")
        let writesItem = menu.addItem(withTitle: L10n.tr("Dictation Writes"), action: nil, keyEquivalent: "")
        writesItem.identifier = NSUserInterfaceItemIdentifier("dictation-writes")
        writesItem.submenu = NSMenu(title: L10n.tr("Dictation Writes"))
        writesItem.submenu?.delegate = self
        let languageItem = menu.addItem(withTitle: L10n.tr("Dictation Language"), action: nil, keyEquivalent: "")
        languageItem.identifier = NSUserInterfaceItemIdentifier("dictation-language")
        languageItem.submenu = NSMenu(title: L10n.tr("Dictation Language"))
        languageItem.submenu?.delegate = self
        menu.addItem(withTitle: L10n.tr("Pause recording"), action: #selector(toggleVoicePause), keyEquivalent: "")
        menu.addItem(withTitle: L10n.tr("Finish recording"), action: #selector(finishVoiceRecording), keyEquivalent: "")
        menu.addItem(withTitle: L10n.tr("Recent result"), action: #selector(showRecentVoiceResult), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.tr("About Yullo"), action: #selector(showAbout), keyEquivalent: "")
        // Held ⌥: what to send when Yullo can't edit text on a Mac.
        let diagnostics = menu.addItem(
            withTitle: L10n.tr("Copy Diagnostics"), action: #selector(copyDiagnostics), keyEquivalent: "")
        diagnostics.keyEquivalentModifierMask = .option
        diagnostics.isAlternate = true
        menu.addItem(withTitle: L10n.tr("Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "")
        // Grouped as in a macOS app menu: about and updates, settings, quit.
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.tr("Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        // The first-run guide, again: it continues at the step where it was left.
        menu.addItem(withTitle: L10n.tr("Setup Guide…"), action: #selector(showSetupGuide), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.tr("Quit Yullo"), action: #selector(quit), keyEquivalent: "q")
        for entry in menu.items { entry.target = self }
        return menu
    }
    // The guide's Shortcuts step Tries: the live task routes, and Edit with voice and Edit
    // with text on the Sample card.
    private func guideTourActions() -> GuidedTourActions {
        var tour = GuidedTourActions.live(model)
        tour.editWithVoice = { [weak self] in self?.tryVoiceEditOnSample($0, replace: $1) ?? false }
        tour.editWithText = { [weak self] in self?.tryVoiceEditOnSample($0, typed: true, replace: $1) ?? false }
        return tour
    }
    // What each registered key does, by its registry ID.
    private func wireShortcutActions() {
        shortcuts.action = { [weak self] id in
            switch id {
            case 2: self?.selectionPanel()
            case 3: self?.voiceShortcut(.dictation)
            case 4: self?.voiceShortcut(.translation)
            case 5: self?.toggleScenario()
            case 6: self?.refineSelectionPanel()
            case ShortcutRegistry.editWithVoiceID: self?.editWithVoiceInPlace()
            case ShortcutRegistry.editWithTextID: self?.editWithTextInPlace()
            case ShortcutRegistry.dictationRowBase..<(ShortcutRegistry.dictationRowBase + 16):
                guard let self else { return }
                let rows = self.dictationRows
                let index = Int(id - ShortcutRegistry.dictationRowBase)
                if rows.indices.contains(index) { self.voiceShortcut(.dictation, shortcutID: rows[index].id) }
            case ShortcutRegistry.refineRowBase..<(ShortcutRegistry.refineRowBase + 16):
                self?.refineInPlace(row: Int(id - ShortcutRegistry.refineRowBase))
            default: self?.togglePanel()
            }
        }
    }
    private func wireSelectionVoiceEdit() {
        selectionVoiceEdit.didChange = { [weak self] in self?.renderSelectionVoiceEdit() }
        // A written result closes the review and says so where the text was.
        selectionVoiceEdit.didReplace = { [weak self] pid in
            guard let self else { return }
            // Under the selection from the key; else where the review was, the way Refine in place confirms.
            let fromKey = self.voiceEditSource != nil
            if !fromKey, let window = self.voiceEditWindow { self.voiceEditAnchor = window.frame }
            let bounds = fromKey ? self.voiceEditSource?.bounds : self.voiceEditChipBounds
            self.voiceEditWindow?.close()
            if !fromKey { self.model.selectionReplaced?(pid) }
            self.voiceEditChip.show(L10n.tr("Edited · ⌘Z to undo"), near: bounds, for: 3, status: .done)
        }
    }
    private func tryVoiceEditOnSample(
        _ text: String, typed: Bool = false, replace: @escaping (String) -> Void
    ) -> Bool {
        // A second Try while the sample's edit is still listening or open is the same Try.
        if voiceEditFromGuide, voiceInput.isBusy || selectionVoiceEdit.isBusy || voiceEditWindow != nil {
            return true
        }
        guard terminationTask == nil, !voiceInput.isBusy, !selectionVoiceEdit.isBusy, voiceEditWindow == nil,
            VoiceEditService.isConfigured(model.preferences)
        else { return false }
        let preferences = model.preferences
        let settings = TranslationSettings(preferences, engine: preferences.voiceRefinementEngine)
        // As the real shortcut does: listening at once, its pill by the Sample card.
        // Without the microphone, the review opens with its change field ready to type.
        voiceEditFromGuide = true
        voiceEditTyped = typed
        guideSampleReplace = replace
        voiceEditHistoryTicket = nil
        voiceEditSource = nil
        voiceEditAnchor =
            settingsWindow?.isVisible == true
            ? GuideTryPlacement.card(reported: sampleCardScreenRect(), guide: settingsWindow.frame) : nil
        voiceEditChip.dismiss()
        // Edit with text: its field alone under the Sample card, the change typed there.
        if typed {
            guard
                (try? selectionVoiceEdit.prepare(
                    source: text, token: nil, settings: settings, sourceIsCurrent: { true }, ownTarget: true)) != nil
            else {
                voiceEditFromGuide = false
                voiceEditTyped = false
                guideSampleReplace = nil
                return false
            }
            showVoiceEditReview()
            return true
        }
        if microphoneAuthorized,
            let id = try? selectionVoiceEdit.prepare(
                source: text, token: nil, settings: settings, sourceIsCurrent: { true }, ownTarget: true)
        {
            recordVoiceEditInstruction(id: id)
        } else {
            selectionVoiceEdit.showEdited(
                source: text, instruction: "", result: text, settings: settings, ownTarget: true)
        }
        return true
    }
    // The guide's Sample card on screen (AppKit coordinates), or nil when it is not shown.
    private func sampleCardScreenRect() -> NSRect? {
        guard let frame = sampleCardFrame, !frame.isNull, let window = settingsWindow, window.isVisible,
            let content = window.contentView
        else { return nil }
        // SwiftUI reports from the top edge; an unflipped content view counts from the bottom.
        let local =
            content.isFlipped
            ? frame
            : NSRect(x: frame.minX, y: content.bounds.height - frame.maxY, width: frame.width, height: frame.height)
        return window.convertToScreen(content.convert(local, to: nil))
    }
    // The Sample card in accessibility coordinates, for the recording pill.
    private func sampleCardBounds() -> CGRect? {
        guard let rect = voiceEditAnchor ?? sampleCardScreenRect() else { return nil }
        return VoiceCaretCoordinates.accessibilityRect(
            fromAppKit: rect, primaryScreenTop: NSScreen.screens.first?.frame.maxY ?? 0)
    }
    @objc func recordingShortcut(_ note: Notification) {
        if note.object as? Bool == true {
            shortcuts.clear()
        } else if !registerSavedShortcuts() {
            model.showNotice(L10n.tr("This shortcut is used by another app."), fix: .shortcuts)
        } else {
            clearResolvedShortcutNotice()
        }
    }
    // A shortcut notice describes a failed registration; once every shortcut
    // works again, the translator no longer shows it.
    private func clearResolvedShortcutNotice() {
        let notices = [
            "This shortcut is used by another app."
        ].map(L10n.tr)
        if notices.contains(model.notice) { model.showNotice("", fix: nil) }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        if let parent = menu.supermenu?.items.first(where: { $0.submenu === menu }) {
            let kind = parent.identifier?.rawValue
            if kind == "dictation-writes" || kind == "dictation-writes-everywhere" || kind == "dictation-writes-app" {
                updateDictationWritesMenu(
                    menu, everywhere: kind == "dictation-writes-everywhere", newApp: kind == "dictation-writes-app")
                return
            }
            if kind == "dictation-language" {
                updateDictationLanguageMenu(menu)
                return
            }
            if kind == "refine-in-place" {
                updateRefineInPlaceMenu(menu)
                return
            }
        }
        let blockedByModal = hasBlockingModalInteraction
        for entry in menu.items {
            if entry.identifier?.rawValue == "dictation-writes" {
                // Names what ⌃⇧V writes in the app in front, and where that comes from.
                let target = dictationWritesTarget()
                let name = OutputPresentation.formatTitle(
                    target.output.format, presets: model.preferences.dictationPresets)
                entry.title =
                    target.ruleID == nil
                    ? L10n.format("Dictation Writes: %@", name)
                    : L10n.format("Dictation Writes: %@ (%@)", name, target.where)
                entry.isEnabled = terminationTask == nil && !blockedByModal
            }
            if entry.identifier?.rawValue == "dictation-language" {
                // The language half of what ⌃⇧V writes, beside its format.
                let target = dictationWritesTarget()
                let name = OutputPresentation.languageTitle(
                    voiceInput.recordingOutputLanguage ?? target.output.language)
                entry.title =
                    target.ruleID == nil
                    ? L10n.format("Dictation Language: %@", name)
                    : L10n.format("Dictation Language: %@ (%@)", name, target.where)
                entry.isEnabled = terminationTask == nil && !blockedByModal
                // One language has nothing to switch between, unless a row or the open
                // recording already writes another: the pill's language button rule.
                entry.isHidden = !model.preferences.offersDictationLanguages(
                    writing: voiceInput.recordingOutputLanguage ?? nil)
            }
            if entry.identifier?.rawValue == "refine-in-place" {
                // One row is one item with its key; more rows open a submenu, one item per row.
                let rows = model.preferences.outputs.refineInPlace
                entry.submenu = rows.count > 1 ? (entry.submenu ?? NSMenu(title: L10n.tr("Refine in Place"))) : nil
                entry.submenu?.delegate = self
                entry.isEnabled = terminationTask == nil && !blockedByModal
                if rows.count == 1, let key = model.preferences.outputShortcutKeys[rows[0].id] {
                    key.presentation.apply(to: entry)
                }
            }
            if entry.action == #selector(showWhereYulloWorks) {
                entry.title = L10n.tr(
                    model.preferences.processingPolicy == .onDeviceOnly
                        ? "Works on this Mac only" : "Works on this Mac and online")
                entry.isEnabled = terminationTask == nil && !blockedByModal
            }
            let shortcut: Shortcut?
            if entry.action == #selector(togglePanel) {
                entry.title = L10n.tr(
                    !blockedByModal && (panel.isVisible || sidebar.isVisible) ? "Hide Yullo" : "Show Yullo")
                entry.isEnabled = terminationTask == nil
                shortcut = model.openKey
            } else if entry.action == #selector(selectionPanel) {
                entry.isEnabled = !blockedByModal
                shortcut = model.selectionKey
            } else if entry.action == #selector(refineSelectionPanel) {
                entry.isEnabled = !blockedByModal
                shortcut = model.preferences.refineSelectionShortcut
            } else if entry.action == #selector(editWithVoiceInPlace) {
                entry.isEnabled = !blockedByModal && !voiceInput.isBusy && !refineInPlace.isBusy
                shortcut = model.preferences.outputShortcutKeys[Shortcut.editWithVoiceID]
            } else if entry.action == #selector(editWithTextInPlace) {
                entry.isEnabled = !blockedByModal && !voiceInput.isBusy && !refineInPlace.isBusy
                shortcut = model.preferences.outputShortcutKeys[Shortcut.editWithTextID]
            } else if entry.action == #selector(startDictation) {
                entry.title = L10n.tr("Start Dictation")
                entry.isEnabled = !voiceInput.isBusy && !blockedByModal
                shortcut = model.preferences.dictationShortcut
            } else if entry.action == #selector(startVoiceTranslation) {
                entry.title = L10n.tr("Start voice translation")
                entry.isEnabled = !voiceInput.isBusy && !blockedByModal
                shortcut = shownVoiceTranslation(model.preferences.voiceTranslationShortcut)
            } else if entry.action == #selector(showRecentVoiceResult) {
                entry.title = L10n.tr("Recent result")
                // An opt-in memory aid: offered only while results are kept.
                entry.isHidden = !model.preferences.voiceKeepRecentResult
                entry.isEnabled = terminationTask == nil && !blockedByModal && voiceInput.canOpenRecentResult
                shortcut = nil
            } else if entry.action == #selector(toggleVoicePause) {
                entry.title = L10n.tr(voiceInput.phase == .paused ? "Resume recording" : "Pause recording")
                // Recording controls appear only while there is a recording.
                entry.isHidden = !(voiceInput.phase == .recording || voiceInput.phase == .paused)
                entry.isEnabled = terminationTask == nil && !blockedByModal && voiceInput.canPauseResume
                shortcut = nil
            } else if entry.action == #selector(finishVoiceRecording) {
                entry.title = L10n.tr("Finish recording")
                entry.isHidden = !(voiceInput.phase == .recording || voiceInput.phase == .paused)
                entry.isEnabled =
                    terminationTask == nil && !blockedByModal
                    && (voiceInput.phase == .recording || voiceInput.phase == .paused)
                shortcut = nil
            } else {
                shortcut = nil
            }
            if entry.action == #selector(showSettings) { entry.isEnabled = !blockedByModal }
            if entry.action == #selector(showAbout) { entry.isEnabled = terminationTask == nil && !blockedByModal }
            if entry.action == #selector(checkForUpdates) { entry.isEnabled = terminationTask == nil }
            if let action = entry.action {
                let titles = [
                    "selectionPanel": "Translate Selected Text", "refineSelectionPanel": "Refine in Yullo Window…",
                    "refineInPlaceFromMenu:": "Refine in Place", "editWithVoiceInPlace": "Edit with Voice",
                    "editWithTextInPlace": "Edit with Text",
                    "showSettings": "Settings…",
                    "showAbout": "About Yullo", "checkForUpdates": "Check for Updates…",
                    "quit": "Quit Yullo",
                    "undo:": "Undo", "redo:": "Redo", "cut:": "Cut", "copy:": "Copy", "paste:": "Paste",
                    "selectAll:": "Select All"
                ]
                if let key = titles[NSStringFromSelector(action)] { entry.title = L10n.tr(key) }
            }
            if let shortcut {
                shortcut.presentation.apply(to: entry)
            }
        }
    }
    // Scenario mode: the shortcut opens the description panel, or ends an
    // active scenario so new dictation returns to the saved preset.
    private func toggleScenario() {
        guard terminationTask == nil else { return }
        if model.scenario != nil {
            endScenario()
        } else {
            showScenarioPanel()
        }
    }
    @objc private func showScenarioPanel() { presentScenarioPanel(description: "") }
    private func presentScenarioPanel(description: String) {
        guard terminationTask == nil, !hasBlockingModalInteraction else { return }
        let shortcut = model.preferences.scenarioShortcut
        scenarioPanel.present(
            model: model, description: description,
            actions: .init(
                start: { [weak self] text in
                    guard let self, self.model.startScenario(text) else { return false }
                    self.scenarioPanel.close()
                    return true
                },
                end: { [weak self] in self?.endScenario() },
                save: { [weak self] in
                    guard let self else { return nil }
                    guard self.commitSettingsIfNeeded() else { return L10n.tr("Finish editing Settings first.") }
                    do {
                        try self.model.saveScenarioAsPreset()
                        return nil
                    } catch CoreDictationPresetValidationError.tooManyRecords {
                        return L10n.tr("You can save up to 32 formats of your own.")
                    } catch { return L10n.tr("Check this format’s settings.") }
                },
                openOutput: { [weak self] description in
                    guard let self else { return }
                    self.scenarioPanel.close()
                    // Closing Settings reopens the panel with this description.
                    self.openingSettingsFromScenario = description
                    defer { self.openingSettingsFromScenario = nil }
                    self.presentSettings(page: .dictation, anchor: "output")
                },
                close: { [weak self] in self?.scenarioPanel.close() }),
            shortcutLabel: shortcut.isAssigned ? shortcut.displayLabel : nil)
    }
    @objc private func endScenario() {
        model.endScenario()
        scenarioPanel.close()
    }
    // The output the Dictation Writes menu shows and edits: the rule for the app
    // in front when one applies, otherwise Everywhere else.
    private func dictationWritesTarget() -> (output: CoreOutput, ruleID: UUID?, where: String) {
        let outputs = model.preferences.outputs
        if let app = dictationWritesApp(), let rule = outputs.rule(forApplication: app.bundleID) {
            return (rule.output, rule.id, rule.applicationName)
        }
        return (outputs.everywhere, nil, L10n.tr("Everywhere else"))
    }
    private func dictationWritesApp() -> OutputAppChooser.App? {
        #if YULLO_TESTING
            if let testingFrontApplication { return testingFrontApplication }
        #endif
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let pid = front == ProcessInfo.processInfo.processIdentifier ? lastExternalPID : front
        guard let app = pid.flatMap({ NSRunningApplication(processIdentifier: $0) }),
            let bundleID = app.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier
        else { return nil }
        return .init(bundleID: bundleID, name: app.localizedName ?? bundleID)
    }
    // The app in front when it has no row yet, paused or not: "In Mail ›" adds one.
    private func dictationWritesNewApp() -> OutputAppChooser.App? {
        guard let app = dictationWritesApp(),
            !model.preferences.outputs.rules.contains(where: {
                $0.applicationBundleID.caseInsensitiveCompare(app.bundleID) == .orderedSame
            })
        else { return nil }
        return app
    }
    private func updateDictationWritesMenu(_ menu: NSMenu, everywhere: Bool, newApp: Bool = false) {
        menu.removeAllItems()
        let available = terminationTask == nil && !hasBlockingModalInteraction
        let front = dictationWritesTarget()
        let editsRule = front.ruleID != nil && !everywhere
        let output = editsRule ? front.output : model.preferences.outputs.everywhere
        // Picking a format for an app without a row adds its row; nothing is ticked yet.
        let scope = newApp ? "app" : editsRule ? "rule" : "everywhere"
        if !newApp {
            let heading = menu.addItem(
                withTitle: editsRule ? L10n.format("In %@", front.where) : L10n.tr("Everywhere else"), action: nil,
                keyEquivalent: "")
            heading.isEnabled = false
        }
        let presets = model.preferences.dictationPresets
        for (index, group) in OutputPresentation.formatGroups.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for format in group {
                let entry = menu.addItem(
                    withTitle: OutputPresentation.formatTitle(format, presets: presets),
                    action: #selector(chooseOutputFormat(_:)), keyEquivalent: "")
                entry.representedObject = [format, scope]
                entry.state = !newApp && output.format == format ? .on : .off
                entry.target = self
                entry.isEnabled = available
            }
        }
        // Your own formats, as in Settings.
        let own = YourFormats.records(presets)
        if !own.isEmpty {
            menu.addItem(.separator())
            for record in own {
                let format = CoreOutput.preset(record.id).format
                let entry = menu.addItem(
                    withTitle: DictationPresetPresentation.title(record), action: #selector(chooseOutputFormat(_:)),
                    keyEquivalent: "")
                entry.representedObject = [format, scope]
                entry.state = !newApp && output.format == format ? .on : .off
                entry.target = self
                entry.isEnabled = available
            }
        }
        if editsRule {
            menu.addItem(.separator())
            let other = menu.addItem(
                withTitle: L10n.format(
                    "Everywhere else: %@",
                    OutputPresentation.name(model.preferences.outputs.everywhere, preferences: model.preferences)),
                action: nil, keyEquivalent: "")
            other.identifier = NSUserInterfaceItemIdentifier("dictation-writes-everywhere")
            other.submenu = NSMenu(title: L10n.tr("Everywhere else"))
            other.submenu?.delegate = self
            other.isEnabled = available
        }
        guard !everywhere, !newApp else { return }
        if !editsRule, let app = dictationWritesNewApp() {
            menu.addItem(.separator())
            let only = menu.addItem(withTitle: L10n.format("In %@", app.name), action: nil, keyEquivalent: "")
            only.identifier = NSUserInterfaceItemIdentifier("dictation-writes-app")
            only.submenu = NSMenu(title: app.name)
            only.submenu?.delegate = self
            only.isEnabled = available
        }
        menu.addItem(.separator())
        let settings = menu.addItem(
            withTitle: L10n.tr("Dictation Settings…"), action: #selector(showDictationSettings), keyEquivalent: "")
        settings.target = self
        settings.isEnabled = available
    }
    // Same as I speak, then the quick languages the language button cycles through.
    private func updateDictationLanguageMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let front = dictationWritesTarget()
        let editsRule = front.ruleID != nil
        var quick = model.preferences.quickLanguageIDs
        if let current = front.output.language, !quick.contains(current) { quick.append(current) }
        // While a recording is open, its language is the one shown and checked.
        let checked = voiceInput.recordingOutputLanguage ?? front.output.language
        if let recording = voiceInput.recordingOutputLanguage, let current = recording, !quick.contains(current) {
            quick.append(current)
        }
        let choices: [String?] = [nil] + quick
        for (index, id) in choices.enumerated() {
            if index == 1 { menu.addItem(.separator()) }
            let entry = menu.addItem(
                withTitle: OutputPresentation.languageTitle(
                    id, localized: model.preferences.showLocalizedLanguageNames),
                action: #selector(chooseOutputLanguage(_:)), keyEquivalent: "")
            entry.representedObject = [id ?? "", editsRule ? "rule" : "everywhere"]
            entry.state = checked == id ? .on : .off
            entry.target = self
        }
        // Shown only while Settings shows the rows they stand for.
        guard model.preferences.offersDictationLanguages else { return }
        menu.addItem(.separator())
        let button = menu.addItem(
            withTitle: L10n.tr("Show Language Button"), action: #selector(toggleLanguageButton), keyEquivalent: "")
        button.state = model.preferences.voiceLanguageSwitch ? .on : .off
        button.target = self
        let edit = menu.addItem(
            withTitle: L10n.tr("Edit Quick Languages…"), action: #selector(showQuickLanguages), keyEquivalent: "")
        edit.target = self
    }
    // The same switch as Settings › Dictation; it changes only itself.
    @objc private func toggleLanguageButton() {
        guard terminationTask == nil, !hasBlockingModalInteraction, commitSettingsIfNeeded() else { return }
        var preferences = model.preferences
        preferences.voiceLanguageSwitch.toggle()
        model.apply(preferences, restartAutomaticTranslation: false)
    }
    private func updateRefineInPlaceMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        for (index, row) in model.preferences.outputs.refineInPlace.enumerated() {
            let entry = menu.addItem(
                withTitle: OutputPresentation.name(row.output, preferences: model.preferences),
                action: #selector(refineInPlaceFromMenu(_:)), keyEquivalent: "")
            entry.tag = index
            entry.target = self
            model.preferences.outputShortcutKeys[row.id]?.presentation.apply(to: entry)
        }
    }
    // Choosing writes only what it names: the format, or the language, of the shown output.
    private func editShownOutput(rule: Bool, _ change: (inout CoreOutput) -> Void) {
        guard terminationTask == nil, !hasBlockingModalInteraction, commitSettingsIfNeeded() else { return }
        var preferences = model.preferences
        let front = dictationWritesTarget()
        if rule, let id = front.ruleID, let index = preferences.outputs.rules.firstIndex(where: { $0.id == id }) {
            change(&preferences.outputs.rules[index].output)
        } else {
            change(&preferences.outputs.everywhere)
        }
        model.apply(preferences, restartAutomaticTranslation: false)
    }
    @objc func chooseOutputFormat(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? [String], value.count == 2 else { return }
        if value[1] == "app" {
            addDictationWritesRule(format: value[0])
            return
        }
        editShownOutput(rule: value[1] == "rule") { $0.format = value[0] }
    }
    // Adds only the front app's row: the chosen format in Everywhere else's language.
    private func addDictationWritesRule(format: String) {
        guard terminationTask == nil, !hasBlockingModalInteraction, let app = dictationWritesNewApp(),
            commitSettingsIfNeeded()
        else { return }
        var preferences = model.preferences
        var output = preferences.outputs.everywhere
        output.format = format
        preferences.outputs.rules.append(
            .init(applicationBundleID: app.bundleID, applicationName: app.name, output: output))
        model.apply(preferences, restartAutomaticTranslation: false)
    }
    @objc private func chooseOutputLanguage(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? [String], value.count == 2 else { return }
        let language = value[0].isEmpty ? nil : value[0]
        editShownOutput(rule: value[1] == "rule") { $0.language = language }
        // An open recording takes it now, as from its own pill.
        voiceInput.chooseRecordingOutputLanguage(language)
    }
    @objc private func refineInPlaceFromMenu(_ sender: NSMenuItem) {
        // The status menu doesn't activate Yullo, so the selection is still live.
        refineInPlace(row: sender.submenu == nil ? sender.tag : 0)
    }
    @objc private func showDictationSettings() { presentSettings(page: .dictation, anchor: "output") }
    @objc private func showQuickLanguages() { presentSettings(page: .dictation, anchor: "quick-languages") }
    private func refreshRecentResultMenuItems() {
        for menu in [item?.menu, NSApp.mainMenu?.items.first?.submenu].compactMap({ $0 }) {
            for entry in menu.items where entry.action == #selector(showRecentVoiceResult) {
                entry.isEnabled =
                    terminationTask == nil && !hasBlockingModalInteraction && voiceInput.canOpenRecentResult
            }
        }
    }
    private func applyInterfaceLanguage() {
        settingsWindow.title = L10n.tr(settingsSizeBeforeSetup == nil ? "Settings" : "Set Up Yullo")
        editingMenuItem?.title = L10n.tr("Edit")
        editingMenuItem?.submenu?.title = L10n.tr("Edit")
        for menu in [item.menu, NSApp.mainMenu?.items.first?.submenu, editingMenuItem?.submenu].compactMap({ $0 }) {
            menuNeedsUpdate(menu)
        }
    }
    func previewSettingsAppearance(_ value: String) {
        settingsPreviewAppearance = value
        applyAppearance()
    }
    func applyAppearance() {
        let value = model.preferences.appearance
        for window in [panel, sidebar] { if let window { AppTheme.apply(value, to: window) } }
        if let settingsWindow { AppTheme.apply(settingsPreviewAppearance ?? value, to: settingsWindow) }
        // Window style switches every open window together, live.
        WindowStyleState.shared.apply(
            solid: Preferences.isSolidWindowStyle(settingsPreviewWindowStyle ?? model.preferences.windowStyle))
    }
    func applyVisibility() {
        applyAppearance()
        let currentWindow = NSApp.keyWindow
        item.isVisible = model.preferences.showInMenuBar
        updateActivationPolicy()
        if let window = currentWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            AppDelegate.activateYullo()
        }
        updateOutsideClickMonitoring()
    }
    // Without a Dock icon, Settings or the voice-edit review covered by System
    // Settings or another app could not be reached again. While either is open,
    // Yullo joins the Dock and Command-Tab; Show in Dock decides the rest of the
    // time. Minimizing calls no update, so a minimized Settings keeps its icon.
    private func updateActivationPolicy() {
        // The Edit with voice review floats like the selection window: no Dock icon for it.
        let windowOpen = settingsWindow?.isVisible == true
        let policy: NSApplication.ActivationPolicy =
            model.preferences.showInDock || windowOpen ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        let wasActive = NSApp.isActive
        changingActivationPolicy = true
        activationPolicyChangedAt = ProcessInfo.processInfo.systemUptime
        NSApp.setActivationPolicy(policy)
        // Leaving the Dock can deactivate Yullo; keep a visible translator in front.
        if wasActive, policy == .accessory, panel.isVisible || sidebar.isVisible {
            AppDelegate.activateYullo()
        }
        DispatchQueue.main.async { [weak self] in self?.changingActivationPolicy = false }
    }
    private func hideSettingsWindow() {
        settingsWindow.orderOut(nil)
        updateActivationPolicy()
    }
    private func registerSavedShortcuts() -> Bool {
        let report = shortcuts.registerAtStartup(
            model.openKey, model.selectionKey, dictation: model.preferences.dictationShortcut,
            voiceTranslation: shownVoiceTranslation(model.preferences.voiceTranslationShortcut),
            scenario: model.preferences.scenarioShortcut,
            refineSelection: model.preferences.refineSelectionShortcut, rows: refineRowBindings)
        model.inactiveGlobalShortcutIDs = report.inactiveIntendedActionIDs
        return report.succeeded
    }
    // Voice translation's key registers only while its dictation shortcut row exists,
    // so no key works without a row in Settings that shows it.
    private func shownVoiceTranslation(_ shortcut: Shortcut) -> Shortcut {
        model.preferences.outputs.dictationShortcuts.contains { $0.id == CoreOutputSettings.voiceTranslationShortcutID }
            ? shortcut : .unassigned
    }
    func saveKeys(
        _ first: Shortcut, _ second: Shortcut, _ dictation: Shortcut, _ translation: Shortcut, _ scenario: Shortcut,
        _ refine: Shortcut
    ) -> String? {
        guard !first.conflicts(second) else { return L10n.tr("Choose a different shortcut for each action.") }
        let report = shortcuts.replace(
            first, second, dictation: dictation, voiceTranslation: shownVoiceTranslation(translation),
            scenario: scenario, refineSelection: refine, rows: refineRowBindings)
        guard report.succeeded else {
            let saved: [(UInt32, Shortcut)] = [
                (1, model.openKey), (2, model.selectionKey),
                (3, model.preferences.dictationShortcut), (4, model.preferences.voiceTranslationShortcut),
                (5, model.preferences.scenarioShortcut), (6, model.preferences.refineSelectionShortcut)
            ]
            model.inactiveGlobalShortcutIDs = Set(saved.filter { $0.1.isAssigned }.map(\.0))
                .subtracting(report.activeActionIDs)
            let actionTitles = ShortcutRegistry.actionTitles
            let failure = report.failure
            let action = L10n.tr(actionTitles[failure?.actionID ?? 0] ?? "Keyboard shortcuts")
            let label = failure?.shortcut?.displayLabel ?? ""
            var message = L10n.format(
                "Couldn’t activate %@ (%@). Review this shortcut under Keyboard shortcuts in General settings.",
                action, label)
            if !report.restoredPreviousSet {
                message +=
                    " "
                    + ShortcutRegistry.unavailableNotice(
                        report.inactiveIntendedActionIDs, menuBarItemVisible: model.preferences.showInMenuBar)
            }
            return message
        }
        model.inactiveGlobalShortcutIDs = []
        clearResolvedShortcutNotice()
        model.openKey = first
        model.selectionKey = second
        UserDefaults.standard.set(try? JSONEncoder().encode(first), forKey: "openShortcut")
        UserDefaults.standard.set(try? JSONEncoder().encode(second), forKey: "selectionShortcut")
        return nil
    }
    // All entry points use one presentation owner. Only one app surface is visible.
    private func cancelSelectionCapture() {
        selectionCaptureID = UUID()
        selectionCaptureTask?.cancel()
        selectionCaptureTask = nil
    }
    @discardableResult func present(_ window: NSWindow, forWelcome: Bool = false) -> Bool {
        guard terminationTask == nil, !hasOtherBlockingModalInteraction,
            !welcomeStartup.isPresenting || (forWelcome && window === settingsWindow)
        else { return false }
        pendingSettingsReturn = nil
        // The guide is never discarded by a window it opens; it stays at its step behind it.
        let keepsGuide = window !== settingsWindow && guideIsShown
        if keepsGuide {
            // Nothing to commit or discard: the guide applies its own choices.
        } else if window !== settingsWindow {
            guard commitSettingsIfNeeded() else { return false }
            settingsReturnContext = nil
            discardSettingsContent()
        } else if settingsReturnContext == nil {
            settingsReturnContext = currentSettingsReturnContext()
        }
        voiceInput.setSettingsPresented(window === settingsWindow)
        cancelSelectionCapture()
        if (panel.isVisible && window !== panel) || (sidebar.isVisible && window !== sidebar) {
            model.invalidateSourceDictationTarget()
        }
        model.cancelPendingInput()
        model.cancelReplacement()
        for other in [panel!, sidebar!, settingsWindow!]
        where other !== window && !(keepsGuide && other === settingsWindow) {
            other.orderOut(nil)
        }
        model.stopSpeaking()
        applyAppearance()
        (window.contentView as? AppThemeHosting)?.synchronizeTheme()
        window.contentView?.layoutSubtreeIfNeeded()
        window.invalidateShadow()
        window.makeKeyAndOrderFront(nil)
        updateActivationPolicy()
        AppDelegate.activateYullo()
        updateOutsideClickMonitoring()
        return true
    }
    @objc func togglePanel() {
        guard !offerWelcomeIfNeeded() else { return }
        if raiseModalInteraction() { return }
        guard !hasBlockingModalInteraction else { return }
        if panel.isVisible || sidebar.isVisible {
            dismissTranslators(returningFocus: true)
        } else {
            openPanel()
        }
    }
    @objc func openPanel() {
        guard !offerWelcomeIfNeeded() else { return }
        if raiseModalInteraction() { return }
        guard !hasBlockingModalInteraction else { return }
        guard commitSettingsIfNeeded() else { return }
        if let surface = model.consumeQuickReturn() {
            if surface == .main { positionMainPanel() }
            _ = present(surface == .main ? panel : sidebar)
            return
        }
        model.windowSession.resetPin()
        model.endSelection()
        // The main window goes back to the app in front when it opened, not to an older selection's.
        translatorSourcePID = nil
        positionMainPanel()
        // Only a fresh presentation moves the caret; Settings return and quick
        // return keep the previous responder.
        if resumeMainPanel() { model.requestSourceFocus() }
    }
    @discardableResult private func resumeMainPanel() -> Bool {
        guard present(panel) else { return false }
        if !model.canUseOutput && !model.translating && !model.refiningTranslation && !model.isTranslationPending
            && model.preferences.autoTranslate
        {
            model.inputChanged(preserveOutput: true)
        }
        return true
    }
    private var placementScreens: [PlacementScreen] {
        #if YULLO_TESTING
            if let stated = AppDelegate.testingSeams.screens { return stated }
        #endif
        return NSScreen.screens.map { PlacementScreen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
    }
    private func positionMainPanel() {
        let saved = UserDefaults.standard.array(forKey: "yullo.mainWindowOrigin") as? [Double]
        let remembered = pendingMainOrigin ?? saved.flatMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        if let visible = WindowPlacement.screen(near: nil, pointer: NSEvent.mouseLocation, screens: placementScreens)?
            .visibleFrame
        {
            AppWindowSizing.fit(panel, in: visible)
        }
        let origin = WindowPlacement.mainOrigin(
            size: panel.frame.size,
            centered: model.preferences.mainWindowPosition != "last", rememberedOrigin: remembered,
            pointer: NSEvent.mouseLocation, screens: placementScreens)
        panel.setFrameOrigin(origin)
        if model.preferences.mainWindowPosition == "last", remembered != origin {
            pendingMainOrigin = origin
            saveMainOrigin()
        }
    }
    func windowDidMove(_ notification: Notification) {
        guard notification.object as? NSWindow === panel, panel.isVisible else { return }
        let origin = panel.frame.origin
        guard origin != pendingMainOrigin else { return }
        pendingMainOrigin = origin
        saveMainOriginWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveMainOrigin() }
        saveMainOriginWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
    private func saveMainOrigin() {
        saveMainOriginWork?.cancel()
        saveMainOriginWork = nil
        guard let origin = pendingMainOrigin else { return }
        UserDefaults.standard.set([Double(origin.x), Double(origin.y)], forKey: "yullo.mainWindowOrigin")
    }
    private func rememberExternalApplication(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
            app.activationPolicy == .regular
        else { return }
        lastExternalPID = app.processIdentifier
    }
    private var terminationTask: Task<Void, Never>?
    private var terminationSignal: TerminationSignal?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        guard commitSettingsIfNeeded() else { return .terminateCancel }
        settingsReturnContext = nil
        model.cancelTranslation()
        translationComparison.dismiss()
        voiceInput.invalidateComparison()
        voiceInput.clearRecentResult()
        voiceEditWindow?.close()
        voiceEditChip.dismiss()
        scenarioPanel.close()
        model.endScenario()
        selectionVoiceEdit.cancel()
        welcomeStartup.cancelWelcome()
        discardSettingsContent()
        model.clearTranslatorDraft()
        cancelSelectionCapture()
        let subprocessWork = CLISubprocess.beginShutdown()
        guard voiceInput.isBusy || subprocessWork || resultHistoryStore != nil else { return .terminateNow }
        terminationTask = Task { @MainActor in
            await voiceInput.cancelAndWait()
            await CLISubprocess.shutdownAndWait()
            await closeResultHistory()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        voiceInput.invalidateComparison()
        voiceInput.clearRecentResult()
        welcomeStartup.cancelWelcome()
        saveMainOrigin()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if offerWelcomeIfNeeded() { return true }
        if raiseModalInteraction() { return true }
        // The Dock icon shown for open Settings returns to Settings, even minimized.
        if let settingsWindow, settingsWindow.isVisible || settingsWindow.isMiniaturized {
            settingsWindow.deminiaturize(nil)
            settingsWindow.makeKeyAndOrderFront(nil)
            AppDelegate.activateYullo()
            return true
        }
        if !flag {
            if model.preferences.openYulloAtLaunch { openPanel() } else { showSettings() }
        }
        return true
    }
    func applicationDidResignActive(_ notification: Notification) {
        // Leaving the Dock (Settings closing as Yullo opens, for example)
        // deactivates Yullo a moment later; the window just shown stays in front.
        if ProcessInfo.processInfo.systemUptime - activationPolicyChangedAt < 0.6,
            panel.isVisible || sidebar.isVisible, terminationTask == nil
        {
            AppDelegate.activateYullo()
            return
        }
        guard !changingActivationPolicy, settingsWindow?.isVisible != true, !hasProtectedInteraction else { return }
        cancelSelectionCapture()
        guard !model.windowSession.isPinned, model.preferences.hideWhenClickingOutside,
            !OutsideClickPolicy.pressKeepsWindow(
                buttons: NSEvent.pressedMouseButtons, point: NSEvent.mouseLocation,
                frames: [panel!, sidebar!].filter(\.isVisible).map(\.frame))
        else { return }
        dismissTranslators(temporarily: true)
    }
    @objc func selectionPanel() { captureSelection(refining: false) }
    // Refine selected text shares the capture, permission, destination and
    // Replace path with translation; it rewrites in the text's own language.
    @objc func refineSelectionPanel() { captureSelection(refining: true) }
    func refineInPlace(row: Int) {
        guard !hasBlockingModalInteraction, !refineInPlace.isEditing else { return }
        guard accessibilityGrant("refine-in-place") == .granted else {
            captureSelection(refining: true)
            return
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard front != ProcessInfo.processInfo.processIdentifier else {
            model.notice = L10n.tr("Select text in another app.")
            return
        }
        refineInPlace.run(row: row, preferences: model.preferences, sourcePID: front)
    }
    // Edit with voice in place. Its key starts the edit and ends the spoken
    // instruction; while the edit runs, the chip's Cancel is the way out.
    private var editWithVoiceKeyLabel: String? {
        guard let key = model.preferences.outputShortcutKeys[Shortcut.editWithVoiceID], key.isAssigned else {
            return nil
        }
        return key.displayLabel
    }
    @objc func editWithVoiceInPlace() {
        guard terminationTask == nil else { return }
        refineInPlace.editKeyLabel = editWithVoiceKeyLabel
        // While a request is spoken, the key ends it.
        if voiceInput.isInstructionSession, voiceInput.phase == .recording || voiceInput.phase == .paused {
            voiceInput.finish()
            return
        }
        // While the spoken change is written, the key cancels it, as Refine's does.
        if refineInPlace.isEditing {
            refineInPlace.cancelEditing()
            return
        }
        if selectionVoiceEdit.phase == .processing, !selectionVoiceEdit.isRefiningResult, voiceEditWindow == nil {
            endSelectionVoiceEdit()
            return
        }
        // With the review open, the key says a further request.
        if voiceEditWindow?.isVisible == true {
            if selectionVoiceEdit.phase == .review, let id = selectionVoiceEdit.prepareAnotherInstruction() {
                recordVoiceEditInstruction(id: id)
            }
            return
        }
        guard !offerWelcomeIfNeeded(), !hasBlockingModalInteraction, !voiceInput.isBusy, !refineInPlace.isBusy,
            !selectionVoiceEdit.isBusy
        else { return }
        guard accessibilityGrant("edit-in-place") == .granted else {
            captureSelection(refining: true)
            return
        }
        let front = frontmostPID
        guard front != ProcessInfo.processInfo.processIdentifier else {
            model.notice = L10n.tr("Select text in another app.")
            return
        }
        if model.preferences.voiceEditReview, let front {
            reviewVoiceEdit(in: front)
            return
        }
        refineInPlace.editWithVoice(preferences: model.preferences, sourcePID: front)
    }
    // Edit with text: Edit with voice with the request typed. The review opens as
    // its field alone, under the selection; the result appears in its place.
    @objc func editWithTextInPlace() {
        guard terminationTask == nil else { return }
        // With the review open, the key opens its change field.
        if let window = voiceEditWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            voiceEditReader?.state.openChange()
            return
        }
        guard !offerWelcomeIfNeeded(), !hasBlockingModalInteraction, !voiceInput.isBusy, !refineInPlace.isBusy,
            !selectionVoiceEdit.isBusy
        else { return }
        guard accessibilityGrant("edit-in-place") == .granted else {
            captureSelection(refining: true)
            return
        }
        guard let front = frontmostPID, front != ProcessInfo.processInfo.processIdentifier
        else {
            model.notice = L10n.tr("Select text in another app.")
            return
        }
        reviewVoiceEdit(in: front, typed: true)
    }
    // Edit with text says what Edit with voice says, in its own words where those name speaking.
    private func typedWording(_ message: String) -> String {
        guard voiceEditTyped else { return message }
        return message.components(separatedBy: "\n").map { line in
            switch line {
            case L10n.tr("Select text first, then say how to change it."): return L10n.tr("Select text first.")
            default: return line
            }
        }.joined(separator: "\n")
    }
    // Edit with voice, reviewed first: the selection is captured where it is,
    // the request is heard (or typed), and the result waits in the review for Accept.
    private func reviewVoiceEdit(in front: Int32, typed: Bool = false) {
        let preferences = model.preferences
        Task { [weak self] in
            guard let self,
                let selection = await self.refineInPlace.captureForReview(preferences: preferences, sourcePID: front)
            else { return }
            guard self.terminationTask == nil, !self.voiceInput.isBusy, !self.selectionVoiceEdit.isBusy,
                self.voiceEditWindow == nil
            else {
                if let token = selection.replacementToken { SelectionReplacement.invalidate(if: token) }
                return
            }
            self.voiceEditTyped = typed
            do {
                // The write lease itself proves the selection at Accept.
                let id = try self.selectionVoiceEdit.prepare(
                    source: selection.text, token: selection.replacementToken,
                    settings: TranslationSettings(preferences, engine: preferences.voiceRefinementEngine),
                    sourceIsCurrent: { true },
                    sourceApp: NSRunningApplication(processIdentifier: front)?.localizedName)
                self.captureVoiceEditHistory(session: id)
                self.voiceEditAnchor = nil
                self.voiceEditSource = (
                    front, selection.replacementToken, selection.bounds, selection.endBounds
                )
                self.voiceEditChip.dismiss()
                if typed { self.showVoiceEditReview() } else { self.recordVoiceEditInstruction(id: id) }
            } catch {
                if let token = selection.replacementToken { SelectionReplacement.invalidate(if: token) }
                self.voiceEditChip.show(
                    self.typedWording(RefineInPlaceController.editMessage(for: error)), near: selection.bounds, for: 5)
            }
        }
    }
    // The key route ends: its lease goes, and the app it came from gets focus back.
    private func releaseVoiceEditSource() {
        guard let source = voiceEditSource else { return }
        voiceEditSource = nil
        if let token = source.token { SelectionReplacement.invalidate(if: token) }
        if frontmostPID == ProcessInfo.processInfo.processIdentifier { activateApplication(source.processID) }
    }
    // The spoken instruction, through the recording indicator; nil when it
    // ends without one.
    private func recordInPlaceInstruction() async -> String? {
        guard !voiceInput.isBusy else { return nil }
        var recognition = model.preferences
        recognition.personalVocabulary.enabled = false
        return await withCheckedContinuation { continuation in
            var pending: CheckedContinuation<String?, Never>? = continuation
            let finish: (String?) -> Void = { text in
                pending?.resume(returning: text)
                pending = nil
            }
            voiceInput.start(
                mode: .dictation, preferences: recognition, targetPID: nil,
                instructionResult: { finish($0) }, instructionCancelled: { finish(nil) },
                finishShortcutAvailable: shortcuts.lastRegistrationReport.activeActionIDs.contains(3))
            // A recording that couldn't start ends here.
            if !voiceInput.isBusy { finish(nil) }
        }
    }
    // Open in Yullo after an in-place edit: the review, without a write lease.
    private func openInPlaceEditReview(original: String, instruction: String, result: String) {
        guard terminationTask == nil, !hasBlockingModalInteraction, !voiceInput.isBusy, !selectionVoiceEdit.isBusy
        else { return }
        voiceEditAnchor = nil
        voiceEditTyped = false
        selectionVoiceEdit.showEdited(
            source: original, instruction: instruction, result: result,
            settings: TranslationSettings(model.preferences, engine: model.preferences.voiceRefinementEngine))
    }
    // Dictation shortcut rows other than voice translation, which keeps its own key.
    var dictationRows: [CoreOutputShortcut] {
        model.preferences.outputs.dictationShortcuts.filter { $0.id != CoreOutputSettings.voiceTranslationShortcutID }
    }
    var refineRowBindings: [(id: UInt32, shortcut: Shortcut)] {
        let refine = model.preferences.outputs.refineInPlace.enumerated().compactMap { index, row in
            model.preferences.outputShortcutKeys[row.id].map { (ShortcutRegistry.refineRowBase + UInt32(index), $0) }
        }
        let dictation = dictationRows.enumerated().compactMap { index, row in
            model.preferences.outputShortcutKeys[row.id].map { (ShortcutRegistry.dictationRowBase + UInt32(index), $0) }
        }
        // Edit with voice and Edit with text keep their keys with the row keys.
        let keyed = ShortcutRegistry.keyedActions.compactMap { action in
            model.preferences.outputShortcutKeys[action.key].map { (action.id, $0) }
        }
        return dictation + refine + keyed
    }
    private func captureSelection(refining: Bool) {
        // An edit with voice in place owns the selection until it ends.
        guard !refineInPlace.isEditing else { return }
        guard !offerWelcomeIfNeeded() else { return }
        guard !hasBlockingModalInteraction else { return }
        guard commitSettingsIfNeeded() else { return }
        let grant = accessibilityGrant(refining ? "refine-selection" : "translate-selection")
        guard grant == .granted else {
            let alert = NSAlert()
            alert.messageText = L10n.tr(
                refining ? "Enable selected-text refinement" : "Enable selected-text translation")
            alert.informativeText = grant.message ?? ""
            alert.addButton(withTitle: L10n.tr("Open Accessibility Settings"))
            alert.addButton(withTitle: L10n.tr("Not Now"))
            AppDelegate.activateYullo()
            if alert.runModal() == .alertFirstButtonReturn { Model.openAccessibilitySettings() }
            return
        }
        model.discardQuickReturn()
        cancelSelectionCapture()
        model.cancelReplacement(invalidateTarget: true)
        let id = selectionCaptureID
        let originalPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let sourcePID = originalPID == ProcessInfo.processInfo.processIdentifier ? lastExternalPID : originalPID
        translatorSourcePID = sourcePID
        guard let sourcePID else {
            openPanel()
            model.notice = L10n.tr("Couldn’t read the selection. Paste the text here.")
            return
        }
        let pointer = NSEvent.mouseLocation
        selectionCaptureTask = Task { @MainActor [weak self] in
            // Nothing selected is told apart from a selection Yullo can't read.
            let worker = Task.detached(priority: .userInitiated) {
                () async -> (prepared: (SelectionReader.Result, InputAnalysis)?, empty: Bool) in
                let outcome = await SelectionReader.captureOutcome(in: sourcePID)
                guard let captured = outcome.selection else {
                    if case .empty = outcome { return (nil, true) }
                    return (nil, false)
                }
                guard !Task.isCancelled else {
                    if let token = captured.replacementToken { SelectionReplacement.invalidate(if: token) }
                    return (nil, false)
                }
                let analysis = Model.analyzeInput(captured.text)
                guard !Task.isCancelled else {
                    if let token = captured.replacementToken { SelectionReplacement.invalidate(if: token) }
                    return (nil, false)
                }
                return ((captured, analysis), false)
            }
            let capture = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            let prepared = capture.prepared
            var handedToModel = false
            defer {
                if !handedToModel, let token = prepared?.0.replacementToken {
                    SelectionReplacement.invalidate(if: token)
                }
            }
            guard !Task.isCancelled, let self, self.selectionCaptureID == id else { return }
            self.selectionCaptureTask = nil
            guard !self.hasBlockingModalInteraction else { return }
            let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard currentPID == originalPID || currentPID == sourcePID else { return }
            guard let (captured, analysis) = prepared else {
                // Nothing selected: the same hint as every selection shortcut, no empty window.
                // Text Yullo can't read still opens Yullo to paste it.
                if capture.empty {
                    self.refineInPlace.showSelectionHint(for: .empty)
                    return
                }
                self.openPanel()
                self.model.notice = L10n.tr("Couldn’t read the selection. Paste the text here.")
                return
            }
            self.model.windowSession.resetPin()
            self.model.beginSelection(
                captured.text, analysis: analysis, replacementToken: captured.replacementToken, refining: refining)
            self.model.notice = ""
            let top = NSScreen.screens.first?.frame.maxY ?? 0
            let anchor = captured.bounds.map {
                CGRect(x: $0.minX, y: top - $0.maxY, width: $0.width, height: $0.height)
            }
            guard self.showSelection(near: anchor, fallbackPointer: pointer) else {
                self.model.cancelReplacement(invalidateTarget: true)
                return
            }
            handedToModel = true
            if refining {
                self.model.refineSelection()
            } else if self.model.preferences.translateSelection {
                self.model.translate()
            }
        }
    }
    @discardableResult func showSelection(near selection: CGRect?, fallbackPointer: NSPoint? = nil) -> Bool {
        guard !hasBlockingModalInteraction else { return false }
        let mouse = fallbackPointer ?? NSEvent.mouseLocation
        let chosen = WindowPlacement.screen(near: selection, pointer: mouse, screens: placementScreens)
        let anchor =
            selection.flatMap { bounds in
                chosen.map {
                    !$0.frame.intersection(bounds).isEmpty && !$0.frame.intersection(bounds).isNull ? bounds : nil
                } ?? nil
            } ?? CGRect(x: mouse.x, y: mouse.y, width: 1, height: 1)
        let visible = chosen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        // Each selection opens at the original size, then grows for its finished text.
        sidebar.setContentSize(AppWindowSizing.selectionSize)
        sidebar.growsToFitText = true
        AppWindowSizing.fit(sidebar, in: visible)
        sidebar.setFrameOrigin(selectionPanelOrigin(anchor: anchor, visible: visible, size: sidebar.frame.size))
        return present(sidebar)
    }
    @objc func startDictation() { startVoice(.dictation) }
    @objc func startVoiceTranslation() { startVoice(.translation) }
    @objc private func toggleVoicePause() {
        guard terminationTask == nil, !hasBlockingModalInteraction, voiceInput.canPauseResume else { return }
        voiceInput.pauseOrResume()
    }
    @objc private func finishVoiceRecording() {
        guard terminationTask == nil, !hasBlockingModalInteraction,
            voiceInput.phase == .recording || voiceInput.phase == .paused
        else { return }
        voiceInput.finish()
    }
    @objc private func showRecentVoiceResult() {
        guard !offerWelcomeIfNeeded() else { return }
        guard terminationTask == nil, !hasBlockingModalInteraction, voiceInput.canOpenRecentResult else { return }
        guard commitSettingsIfNeeded(), voiceInput.canOpenRecentResult else { return }
        dismissTranslators()
        hideSettingsWindow()
        discardSettingsContent()
        voiceInput.openRecentResult(preferences: model.preferences)
    }
    private func voiceShortcut(_ mode: VoiceInputMode, shortcutID: String? = nil) {
        guard terminationTask == nil else { return }
        if voiceInput.isBusy {
            voiceInput.finishFromShortcut(mode)
            return
        }
        // A reviewed result that can still go where it was dictated: the
        // same shortcut puts it there, like Return.
        if !hasBlockingModalInteraction, voiceInput.insertPreviewFromShortcut(mode) { return }
        startVoice(mode, shortcutID: shortcutID)
    }
    private func startVoice(_ mode: VoiceInputMode, shortcutID: String? = nil) {
        // While the translator has keyboard focus, dictation belongs to its source
        // text, as with its microphone button, rather than hiding it for another app.
        if mode == .dictation, (model.selectionContext ? sidebar : panel)?.isKeyWindow == true {
            sourceDictation()
            return
        }
        if mode == .dictation, shortcutID == nil, settingsWindow?.isKeyWindow == true,
            let start = GuidedTrialShortcut.start
        {
            start()
            return
        }
        guard !offerWelcomeIfNeeded() else { return }
        guard terminationTask == nil, !voiceInput.isBusy, !hasBlockingModalInteraction else { return }
        guard commitSettingsIfNeeded() else { return }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let target = front == ProcessInfo.processInfo.processIdentifier ? lastExternalPID : front
        let preferences = model.preferences
        let bundleID = target.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        // Voice translation is the dictation shortcut row that kept its key.
        let row = mode == .translation ? CoreOutputSettings.voiceTranslationShortcutID : shortcutID
        let hasRow = preferences.outputs.dictationShortcuts.contains { $0.id == row }
        // An active scenario is a temporary output for new ordinary dictation, like a choice for this recording.
        let scenario =
            mode == .dictation && shortcutID == nil ? model.scenario.map { CoreOutput.preset($0.record.id) } : nil
        // The front browser page's host, for this one resolution; never kept.
        // Read only when a website rule could decide the format: no choice, no shortcut row,
        // and at least one rule for a website. Otherwise the browser is never asked.
        let websiteDecides =
            mode == .dictation && scenario == nil && !hasRow
            && preferences.outputs.rules.contains { $0.enabled && $0.website != nil }
        let website = websiteDecides ? target.flatMap { BrowserAddress.host(pid: $0, bundleID: bundleID) } : nil
        let configuration =
            mode == .translation && !hasRow
            ? preferences.resolvingOutput(
                applicationBundleID: bundleID,
                recordingChoice: .init(format: "spoken", language: preferences.voiceTarget))
            : preferences.resolvingOutput(
                applicationBundleID: bundleID, website: website, shortcutID: row, recordingChoice: scenario,
                presets: model.activeDictationPresets)
        // A row that formats as well as translates runs as dictation with that output.
        let plainTranslation: Bool
        if case .translation = configuration.output.choice { plainTranslation = true } else { plainTranslation = false }
        let key = mode
        let mode: VoiceInputMode = mode == .translation && !plainTranslation ? .dictation : mode
        dismissTranslators()
        hideSettingsWindow()
        discardSettingsContent()
        voiceInput.start(
            mode: mode, preferences: configuration.preferences, targetPID: target,
            preserveTechnicalLiterals: configuration.output.preserveTechnicalLiterals,
            presetTitle: model.presetTitle(forAppliedID: configuration.output.appliedPresetID),
            presetInstructions: configuration.output.presetInstructions,
            finishShortcutAvailable: shortcuts.lastRegistrationReport.activeActionIDs.contains(
                key == .dictation ? 3 : 4), startedBy: key,
            formats: key == .dictation
                ? VoiceFormatSource(
                    resolved: configuration.format, preferences: preferences, presets: model.activeDictationPresets,
                    recents: pillRecents) : nil)
    }
    private func startVoiceTrial() {
        guard terminationTask == nil, !hasBlockingModalInteraction,
            VoiceTrial.canStart(isBusy: voiceInput.isBusy, result: voiceInput.result)
        else { return }
        guard commitSettingsIfNeeded() else { return }
        guard VoiceTrial.canStart(isBusy: voiceInput.isBusy, result: voiceInput.result) else { return }
        let preferences = VoiceTrial.preferences(from: model.preferences)
        dismissTranslators()
        hideSettingsWindow()
        discardSettingsContent()
        voiceInput.start(
            mode: .dictation, preferences: preferences, targetPID: nil,
            finishShortcutAvailable: shortcuts.lastRegistrationReport.activeActionIDs.contains(3), recordHistory: false)
    }
    private func startGuidedVoiceTrial(_ receive: @escaping (VoiceTrialOutcome) -> Void) {
        guard terminationTask == nil, !hasBlockingModalInteraction, commitSettingsIfNeeded() else {
            receive(.cancelled)
            return
        }
        guard VoiceTrial.canStart(isBusy: voiceInput.isBusy, result: voiceInput.result) else {
            receive(.failed(L10n.tr("Finish or close the current dictation first.")))
            return
        }
        model.stopSpeaking()
        let id = UUID()
        let completion = VoiceTrialCompletion(id: id) { [weak self] outcome in
            guard let self, self.activeGuidedTrialID == id else { return }
            self.activeGuidedTrialID = nil
            self.voiceInput.setSettingsPresented(self.settingsWindow?.isVisible == true)
            receive(outcome)
        }
        activeGuidedTrialID = id
        voiceInput.start(
            mode: .dictation, preferences: VoiceTrial.preferences(from: model.preferences), targetPID: nil,
            sourceCaretBounds: trialCardBounds(), sourceScreen: settingsWindow?.screen,
            sourceCaretBoundsProvider: { [weak self] in self?.trialCardBounds() },
            finishShortcutAvailable: shortcuts.lastRegistrationReport.activeActionIDs.contains(3),
            recordHistory: false, trialCompletion: completion)
    }
    private func cancelGuidedVoiceTrial() {
        guard let id = activeGuidedTrialID else { return }
        voiceInput.cancelGuidedTrial(id)
        if activeGuidedTrialID == id { activeGuidedTrialID = nil }
    }
    // The trial card's place on screen, in accessibility coordinates, for the
    // Near the caret indicator.
    private func trialCardBounds() -> CGRect? {
        guard let frame = trialCardFrame, !frame.isNull, let window = settingsWindow, window.isVisible,
            let content = window.contentView
        else { return nil }
        let onScreen = window.convertToScreen(content.convert(frame, to: nil))
        return VoiceCaretCoordinates.accessibilityRect(
            fromAppKit: onScreen, primaryScreenTop: NSScreen.screens.first?.frame.maxY ?? 0)
    }
    // Loads the trial's local recognizer while its guide step is open; no audio is sent.
    private func prepareGuidedVoiceTrial() {
        let preferences = VoiceTrial.preferences(from: model.preferences)
        let settings = VoiceRecognitionSettings(preferences)
        let live = preferences.voiceLivePreview
        Task.detached(priority: .utility) { await VoiceResources.prepareRecognition(settings, livePreview: live) }
    }
    private func sourceDictation() {
        guard terminationTask == nil else { return }
        if voiceInput.isSourceSession, voiceInput.phase == .recording || voiceInput.phase == .paused {
            voiceInput.finish()
            return
        }
        guard !offerWelcomeIfNeeded() else { return }
        guard !voiceInput.isBusy, !hasBlockingModalInteraction else { return }
        guard commitSettingsIfNeeded() else { return }
        let window = model.selectionContext ? sidebar : panel
        guard let window, window.isVisible else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        let editor = SourceDictationTarget.editor(in: window, matching: model.source)
        let allowAppend = editor == nil && !SourceDictationTarget.hasEditableEditor(in: window)
        let target = SourceDictationTarget(
            model: model, editor: editor, allowAppend: allowAppend,
            available: { [weak self, weak window] in
                guard let self, let window, window.isVisible else { return false }
                if allowAppend && SourceDictationTarget.hasEditableEditor(in: window) { return false }
                return self.model.selectionContext ? window === self.sidebar : window === self.panel
            })
        model.stopSpeaking()
        voiceInput.start(
            mode: .dictation, preferences: model.preferences, targetPID: nil,
            sourceCaretBounds: target.caretBounds, sourceScreen: window.screen,
            sourceCaretBoundsProvider: { target.currentCaretBounds }, sourceResult: { target.insert($0) },
            finishShortcutAvailable: shortcuts.lastRegistrationReport.activeActionIDs.contains(3))
    }
    private func startSelectionVoiceEdit() {
        guard terminationTask == nil, !voiceInput.isBusy, !selectionVoiceEdit.isBusy,
            !hasBlockingModalInteraction, model.selectionContext, commitSettingsIfNeeded()
        else { return }
        let preferences = model.preferences
        guard VoiceEditService.isConfigured(preferences) else {
            model.notice = VoiceEditIssue.connectionRequired.localizedDescription
            showVoiceSetup(
                preferences.processingPolicy == .onDeviceOnly
                    ? .processing : .refinement(engine: preferences.voiceRefinementEngine))
            return
        }
        let snapshot = model.captureSourceDictation(), revision = model.selectionRevision
        do {
            let id = try selectionVoiceEdit.prepare(
                source: snapshot.text, token: model.selectionReplacementTokenForVoiceEdit,
                settings: TranslationSettings(preferences, engine: preferences.voiceRefinementEngine),
                sourceIsCurrent: { [weak model] in
                    guard let model else { return false }
                    return model.selectionContext && model.selectionRevision == revision
                        && model.matchesSourceDictation(snapshot)
                })
            captureVoiceEditHistory(session: id)
            voiceEditAnchor = [sidebar, panel].compactMap { $0 }.first(where: \.isVisible)?.frame
            voiceEditChip.dismiss()
            cancelSelectionCapture()
            model.cancelTranslation()
            model.stopSpeaking()
            // Keep the captured selection lease. Ordinary dismissal ends it.
            panel.orderOut(nil)
            sidebar.orderOut(nil)
            hideSettingsWindow()
            discardSettingsContent()
            updateOutsideClickMonitoring()
            recordVoiceEditInstruction(id: id)
        } catch {
            model.showNotice(error.localizedDescription, fix: TranslationRecoveryAction.fixing(error, writing: true))
        }
    }
    private func recordVoiceEditInstruction(id: UUID) {
        guard !voiceInput.isBusy, selectionVoiceEdit.id == id, selectionVoiceEdit.phase == .instruction else { return }
        // Another instruction is recorded, and its result shown, where the review was.
        if let window = voiceEditWindow, window.isVisible { voiceEditAnchor = window.frame }
        voiceEditReader?.invalidate()
        voiceEditWindow?.orderOut(nil)
        var recognition = model.preferences
        recognition.personalVocabulary.enabled = false
        // On the guide's sample, the recording pill sits by the Sample card, whatever
        // the Recording indicator setting says for other apps.
        let fromGuide = voiceEditFromGuide
        if fromGuide { recognition.voicePlacement = VoiceOverlayPlacement.caret.rawValue }
        voiceInput.start(
            mode: .dictation, preferences: recognition, targetPID: nil,
            sourceCaretBounds: fromGuide ? sampleCardBounds() : nil,
            sourceScreen: fromGuide ? settingsWindow?.screen : nil,
            sourceCaretBoundsProvider: fromGuide ? { [weak self] in self?.sampleCardBounds() } : nil,
            instructionResult: { [weak self] text in self?.selectionVoiceEdit.acceptInstruction(text, for: id) },
            instructionCancelled: { [weak self] in
                guard let self, self.selectionVoiceEdit.id == id else { return }
                // A further request said nothing: back to the result it would refine.
                if self.selectionVoiceEdit.cancelRequest() { return }
                if self.voiceEditWindow == nil {
                    self.endSelectionVoiceEdit()
                    return
                }
                self.selectionVoiceEdit.cancel()
            }, finishShortcutAvailable: shortcuts.lastRegistrationReport.activeActionIDs.contains(3))
    }
    private func renderSelectionVoiceEdit() {
        // One surface per moment: the HUD chip while editing or after a
        // failure, the review window only once there is a result.
        let edit = selectionVoiceEdit
        guard terminationTask == nil, !voiceEditSuspendedForSettings else { return }
        let id = edit.id
        switch edit.phase {
        case .processing where edit.isRefiningResult:
            showVoiceEditReview()
        // A typed request is written, or fails, in its own window: no chip.
        case .instruction where voiceEditTyped && edit.result.isEmpty && voiceEditWindow != nil,
            .processing where voiceEditTyped, .error where voiceEditTyped && voiceEditWindow != nil:
            showVoiceEditReview()
        case .processing:
            voiceEditChip.didExpire = nil
            voiceEditChip.show(
                L10n.tr("Editing…"), near: voiceEditChipBounds, for: nil, status: .working,
                action: (
                    L10n.tr("Cancel"),
                    { [weak self] in
                        guard self?.selectionVoiceEdit.id == id else { return }
                        self?.endSelectionVoiceEdit()
                    }
                ), actionHelp: editWithVoiceKeyLabel.map { L10n.tr("Cancel") + " · " + $0 })
        case .error:
            voiceEditReader?.invalidate()
            voiceEditWindow?.orderOut(nil)
            voiceEditChip.didExpire = { [weak self] in
                guard self?.selectionVoiceEdit.id == id else { return }
                self?.endSelectionVoiceEdit()
            }
            voiceEditChip.show(edit.message, near: voiceEditChipBounds, for: 8, action: voiceEditFix(edit))
        case .replacing where voiceEditWindow?.isVisible != true:
            // Accept stepped aside so the app gets its keys back; it reappears only on failure.
            return
        case .review, .replacing:
            voiceEditChip.didExpire = nil
            voiceEditChip.dismiss()
            showVoiceEditReview()
        case .idle, .instruction, .finished:
            return
        }
    }
    private func showVoiceEditReview() {
        let edit = selectionVoiceEdit
        let window: NSWindow
        let placed: Bool
        if let existing = voiceEditWindow {
            window = existing
            placed = true
        } else {
            let review = SelectionVoiceEditReview.makePanel()
            review.delegate = self
            window = review
            voiceEditWindow = window
            placed = false
        }
        let id = edit.id, revision = edit.revision
        let context: VoiceOverlayResultContext =
            edit.deliveryOutcome == .uncertain
            ? .insertionUnconfirmed : edit.deliveryOutcome == .inserted ? .earlierOutputInserted : .preview
        let lines = SelectionVoiceEditReview.lines(
            message: typedWording(edit.message), appWarning: context.message, onSample: voiceEditFromGuide)
        // Edit with text before its first result: the request field alone.
        let asking = voiceEditTyped && edit.result.isEmpty
        // Edit with text keeps its field as it was typed in: the same width, no mic.
        let recordAgain: (() -> Void)? =
            edit.phase == .review && !voiceEditTyped
            ? { [weak self] in
                guard let self, let id = self.selectionVoiceEdit.prepareAnotherInstruction() else { return }
                self.recordVoiceEditInstruction(id: id)
            } : nil
        var content = SelectionVoiceEditReview.Content(
            edited: edit.result,
            message: lines.joined(separator: "\n"), canReplace: edit.canReplace,
            replacing: edit.phase == .replacing, canUndo: edit.canUndo,
            working: edit.isRefiningResult || (asking && edit.phase == .processing),
            replaceable: edit.hasReplacementTarget,
            textSize: CGFloat(model.preferences.textSize - 1),
            voiceKey: model.preferences.outputShortcutKeys[Shortcut.editWithVoiceID].flatMap {
                $0.isAssigned ? $0.displayLabel : nil
            })
        // Still the original text, before a change or after one that changed nothing:
        // secondary, with nothing to replace or copy; full strength always means a new result.
        content.unchanged = !edit.result.isEmpty && TextMutationRange.identical(edit.source, edit.result)
        content.original = edit.source
        content.asking = asking
        // On the guide's sample, Replace has a target of its own: the Sample card.
        let sampleTarget = voiceEditFromGuide ? guideSampleReplace : nil
        if sampleTarget != nil {
            content.replaceable = true
            content.canReplace = edit.phase == .review && !edit.result.isEmpty && !content.unchanged
        }
        let replace: () -> Void = { [weak window, weak edit] in
            if let sampleTarget {
                guard let edit, edit.phase == .review, !edit.result.isEmpty else { return }
                sampleTarget(edit.result)
                window?.close()
                return
            }
            // Steps aside first, so the edited app has its keys for the write.
            window?.orderOut(nil)
            edit?.replaceReviewedResult()
        }
        let isCurrent: () -> Bool = { [weak self, weak window] in
            self?.selectionVoiceEdit.id == id && self?.selectionVoiceEdit.revision == revision
                && window?.isVisible == true
        }
        let close: () -> Void = { [weak window, weak edit] in
            // Esc during a further request stops just that request.
            if edit?.cancelRequest() != true { window?.close() }
        }
        // Before a typed request's first result, its field is the way to try another; other repairs show.
        let fix =
            edit.recovery == .permissions || edit.recovery == .writingService
                || (asking && edit.phase == .error && edit.recovery != .recordInstruction)
            ? voiceEditFix(edit) : nil
        let request: (String) -> Void =
            asking
            ? { [weak self] in self?.selectionVoiceEdit.ask($0) } : { [weak edit] in edit?.request($0) }
        let reader: SelectionVoiceEditReview
        if placed, let existing = voiceEditReader, window.contentView === existing {
            // The same review: a further change lands in place.
            reader = existing
            reader.update(
                content: content, backend: reviewBackend, isCurrent: isCurrent, close: close,
                replace: replace, recordAgain: recordAgain,
                request: request, undo: { [weak edit] in edit?.undo() },
                tryAgain: edit.instruction.isEmpty || asking ? nil : { [weak edit] in edit?.tryAgain() },
                stop: { [weak edit] in _ = edit?.cancelRequest() }, fix: fix)
        } else {
            voiceEditReader?.invalidate()
            reader = SelectionVoiceEditReview(
                content: content, backend: reviewBackend, isCurrent: isCurrent, close: close,
                replace: replace, recordAgain: recordAgain,
                request: request, undo: { [weak edit] in edit?.undo() },
                tryAgain: edit.instruction.isEmpty || asking ? nil : { [weak edit] in edit?.tryAgain() },
                stop: { [weak edit] in _ = edit?.cancelRequest() }, fix: fix,
                theme: model.preferences.appearance)
            voiceEditReader = reader
            window.contentView = reader
            (window as? FloatingPanel)?.roundContentCorners(SelectionVoiceEditReview.cornerRadius)
        }
        window.title = L10n.tr(voiceEditTyped ? "Edit with text" : "Edit with voice")
        AppTheme.apply(model.preferences.appearance, to: window)
        reader.setTheme(model.preferences.appearance)
        // Where it goes: under the selection's last line, never over it, on its screen.
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        func flipped(_ rect: CGRect?) -> CGRect? {
            rect.map { CGRect(x: $0.minX, y: top - $0.maxY, width: $0.width, height: $0.height) }
        }
        let selection = voiceEditAnchor ?? flipped(voiceEditSource?.bounds)
        let end = voiceEditAnchor == nil ? flipped(voiceEditSource?.end) : nil
        let mouse = NSEvent.mouseLocation
        // A Try on the guide's sample stays on the guide's screen as it grows.
        let guideScreen = voiceEditFromGuide ? settingsWindow.flatMap(guideScreenFrame) : nil
        let visible =
            placed
            ? (guideScreen ?? window.screen?.visibleFrame
                ?? placementScreens.first { $0.frame.intersects(window.frame) }?.visibleFrame ?? window.frame)
            : (WindowPlacement.screen(near: end ?? selection, pointer: mouse, screens: placementScreens)?.visibleFrame
                ?? NSScreen.main?.visibleFrame ?? window.frame)
        // Sized to the text so it reads without scrolling: wider and a step
        // smaller for long text, as tall as the screen allows, then scrolling.
        let shown = window.isVisible
        var frame: NSRect
        if placed {
            // A typed request's result keeps its field's width, so the two line up.
            let laid = reader.applyLayout(screen: visible)
            let width = voiceEditTyped ? window.contentLayoutRect.width : min(laid, visible.width - 24)
            let height = reader.fittingHeight(width: width)
            frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: NSSize(width: width, height: height)))
            // A further change keeps the top edge, moving up only to stay on screen.
            frame.origin = NSPoint(
                x: min(window.frame.minX, visible.maxX - frame.width - 12),
                y: max(visible.minY + 12, window.frame.maxY - frame.height))
        } else if voiceEditFromGuide, let guide = settingsWindow, let screen = guideScreenFrame(guide) {
            // The guide's Sample card is the selection: the same rule as any text, under it
            // or above it, never over it, on the guide's screen.
            frame = reader.placement(in: screen, selection: voiceEditAnchor, end: nil, pointer: mouse)
        } else {
            frame = reader.placement(in: visible, selection: selection, end: end, pointer: mouse)
        }
        window.contentMinSize = NSSize(width: reader.minimumContentWidth, height: frame.height)
        if placed, shown, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // The window keeps its size, its new text not yet drawn, then eases to the text's
            // height with its top edge in place; the text shows, and its rest begins, once it has.
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration = 0.2
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    window.animator().setFrame(frame, display: true)
                },
                completionHandler: { [weak reader] in
                    MainActor.assumeIsolated {
                        reader?.state.awaitingSize = false
                        reader?.state.startMorph()
                    }
                })
        } else {
            window.setFrame(frame, display: true)
            reader.state.awaitingSize = false
            // A window about to fade in starts its arrival once it has; one already showing, now.
            if shown { reader.state.startMorph() }
        }
        // It appears with a short fade, as the Yullo window's content settles.
        // A result arriving waits until the window has faded in, so the whole change is seen.
        if !shown, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            reader.state.fadingIn = true
            window.alphaValue = 0
            window.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    window.animator().alphaValue = 1
                },
                completionHandler: { [weak reader] in
                    MainActor.assumeIsolated {
                        reader?.state.fadingIn = false
                        reader?.state.startMorph()
                    }
                })
        } else {
            window.alphaValue = 1
            window.makeKeyAndOrderFront(nil)
            reader.state.startMorph()
        }
        // Never activates Yullo for another app's text: the panel is key while that app stays
        // in front. From the guide, Yullo is the app in front, so the review takes the keys.
        updateActivationPolicy()
        if voiceEditFromGuide {
            AppDelegate.activateYullo()
            window.makeKeyAndOrderFront(nil)
        }
        // On the untouched sample, the first thing to do is say or type a change: the field is open.
        if content.unchanged, voiceEditFromGuide, !reader.state.changing { reader.state.openChange() }
    }
    // The chip sits near the top of where the selection panel was, in
    // accessibility (top-left) coordinates.
    private var voiceEditChipBounds: CGRect? {
        guard let anchor = voiceEditAnchor, let primary = NSScreen.screens.first else { return voiceEditSource?.bounds }
        return CGRect(x: anchor.minX + 12, y: primary.frame.maxY - anchor.maxY, width: anchor.width - 24, height: 1)
    }
    private func voiceEditFix(_ edit: SelectionVoiceEdit) -> (String, () -> Void)? {
        let recovery = edit.recovery
        switch recovery {
        case .none:
            return nil
        case .retry:
            return (L10n.tr("Try Again"), { [weak edit] in edit?.retry() })
        case .recordInstruction:
            return (
                L10n.tr("Record another instruction"),
                { [weak self] in
                    guard let self, let id = self.selectionVoiceEdit.prepareAnotherInstruction() else { return }
                    self.recordVoiceEditInstruction(id: id)
                }
            )
        case .writingService:
            // The guide's fix: an installed Claude Code or Codex CLI in one click, the same
            // request then running with it; otherwise the writing-service chooser.
            let installed = InstalledCLIs.shared
            if !installed.looked {
                Task { [weak self] in
                    guard let self else { return }
                    await installed.refresh(self.model.preferences)
                    if self.selectionVoiceEdit.recovery == .writingService { self.renderSelectionVoiceEdit() }
                }
            }
            if let setup = installed.offers(model.preferences).first {
                return (
                    L10n.format("Use %@", setup.provider.displayName),
                    { [weak self, weak edit] in
                        guard let self, let edit else { return }
                        let preferences = InstalledCLIs.choose(setup, writing: true, in: self.model.preferences)
                        self.model.apply(preferences, restartAutomaticTranslation: false)
                        edit.retry(with: TranslationSettings(preferences, engine: preferences.voiceRefinementEngine))
                    }
                )
            }
            return (
                L10n.tr("Choose a Writing Service…"),
                { [weak self] in
                    guard let self else { return }
                    self.voiceEditReader?.invalidate()
                    self.voiceEditWindow?.makeFirstResponder(nil)
                    self.voiceEditWindow?.orderOut(nil)
                    self.selectionVoiceEdit.suspendForSettings()
                    self.hideSettingsWindow()
                    self.voiceEditSuspendedForSettings = true
                    WriteWithRow.opensChooser = true
                    self.presentSettings(page: .refine, anchor: "writing-service")
                }
            )
        case .openOllama:
            // Started where the edit stopped; the same request runs once Ollama answers.
            return (
                L10n.tr("Open Ollama"),
                { [weak self, weak edit] in
                    guard let self else { return }
                    OllamaSuggestion.openApp(host: self.model.preferences.ollamaHost) { edit?.retry() }
                }
            )
        case .signIn(let provider):
            return (
                L10n.tr("Sign in…"),
                { [weak self] in self?.showVoiceSetup(.cliSignIn(provider)) }
            )
        case .permissions:
            // Accessibility is allowed in System Settings, opened at its pane; the review stays.
            return (L10n.tr("Allow access…"), { Model.openAccessibilitySettings() })
        case .credentials, .processing, .service, .vocabulary:
            let label =
                recovery == .credentials
                ? "Allow access…"
                : recovery == .processing
                    ? "Review setup…"
                    : recovery == .vocabulary
                        ? "Personal vocabulary"
                        : "Service settings…"
            return (
                L10n.tr(label),
                { [weak self] in
                    guard let self else { return }
                    self.voiceEditReader?.invalidate()
                    self.voiceEditWindow?.makeFirstResponder(nil)
                    self.voiceEditWindow?.orderOut(nil)
                    self.selectionVoiceEdit.suspendForSettings()
                    self.hideSettingsWindow()
                    self.voiceEditSuspendedForSettings = true
                    if recovery == .vocabulary {
                        self.presentSettings(page: .languages, anchor: "personal-vocabulary")
                        return
                    }
                    self.showVoiceSetup(
                        recovery == .credentials
                            ? .credentials
                            : recovery == .processing
                                ? .processing
                                : .refinement(engine: self.model.preferences.voiceRefinementEngine))
                }
            )
        }
    }
    // Ends an edit that has no window: Cancel, Esc or a timed-out error.
    private func endSelectionVoiceEdit() {
        voiceEditChip.didExpire = nil
        voiceEditChip.dismiss()
        if let window = voiceEditWindow {
            window.close()
            return
        }
        selectionVoiceEdit.cancel()
        voiceEditTyped = false
        if voiceEditFromGuide {
            voiceEditFromGuide = false
            guideSampleReplace = nil
            returnToGuide()
            return
        }
        if voiceEditSource != nil {
            releaseVoiceEditSource()
            return
        }
        // A panel opened since then keeps its own draft.
        if !panel.isVisible, !sidebar.isVisible { model.clearTranslatorDraft() }
    }
    private func updateSourceVoiceState() {
        let state: SourceVoiceState
        if voiceInput.isSourceSession, voiceInput.isBusy {
            switch voiceInput.phase {
            case .recording: state = .recording
            case .paused: state = .paused
            default: state = .processing
            }
        } else {
            state = .idle
        }
        if model.sourceVoiceState != state { model.sourceVoiceState = state }
        let unavailable = voiceInput.isBusy
        if model.sourceVoiceUnavailable != unavailable { model.sourceVoiceUnavailable = unavailable }
    }
    private func showVoiceSettings() {
        showVoiceSetup(.recognition)
    }
    // A saved key is fixed in its service's editor in Services. Allow access
    // there starts at once, so the press where the task stopped is the whole fix.
    static func savedKeyAnchor(_ action: TranslationRecoveryAction) -> SavedKeyAnchor? {
        switch action {
        case .keychain: return SavedKeyAnchor(service: .textAPI, allow: true)
        case .speechKeyAccess(let service): return SavedKeyAnchor(service: service, allow: true)
        case .speechKey(let service): return SavedKeyAnchor(service: service, allow: false)
        default: return nil
        }
    }
    // Where an engine's own setup is, for the task that failed: its editor in
    // Services (opened), the model library, Apple's languages, or the row that chooses one.
    static func engineLocation(_ engine: String, writing: Bool) -> (
        page: SettingsPage, anchor: String, task: ModelTask?
    ) {
        switch engine {
        case "api": return (.models, "api", nil)
        case "cli": return (.models, "cli", nil)
        case "ollama": return (.models, "ollama", nil)
        case "local": return (.models, "model-library", writing ? nil : .translation)
        case "apple" where !writing: return (.translation, "apple-language-manager", nil)
        default: return writing ? (.refine, "writing-service", nil) : (.translation, "translation-model", nil)
        }
    }
    static func voiceSetupLocation(_ destination: VoiceSetupDestination) -> (page: SettingsPage, anchor: String) {
        switch destination {
        case .recognition:
            return (.dictation, "recognition")
        case .finishMethods:
            return (.dictation, "finish")
        case .microphone, .accessibility:
            return (.setup, "permissions")
        case .credentials:
            return (.models, savedKeyAnchor(.keychain)?.rawValue ?? "api")
        case .processing:
            return (.setup, "processing")
        case .translation(let engine):
            let location = engineLocation(engine, writing: false)
            return (location.page, location.anchor)
        case .refinement(let engine):
            let location = engineLocation(engine, writing: true)
            return (location.page, location.anchor)
        case .cliSignIn:
            return (.models, "cli")
        case .openOllama, .appleIntelligence:
            return (.refine, "writing-service")
        }
    }
    private func showVoiceSetup(_ destination: VoiceSetupDestination) {
        switch destination {
        case .openOllama:
            OllamaSuggestion.openApp(host: model.preferences.ollamaHost) {}
            return
        case .appleIntelligence:
            NSWorkspace.shared.open(AppleWriterPresentation.settingsURL)
            return
        // Allowed in System Settings: open its pane at once, not a Settings page that links there.
        case .microphone:
            PermissionSettingsBackend.system.openMicrophoneSettings()
            return
        case .accessibility:
            Model.openAccessibilitySettings()
            return
        // Terminal opens on the tool's own sign-in command; Services if Terminal can't.
        case .cliSignIn(let provider):
            guard !WritingServiceSetupEffects.live.signIn(provider) else { return }
        default: break
        }
        let location = Self.voiceSetupLocation(destination)
        let task: ModelTask?
        if case .translation(let engine) = destination, engine == "local" {
            task = .translation
        } else {
            task = nil
        }
        let previousOrigin = openingSettingsFromVoice
        openingSettingsFromVoice = true
        defer { openingSettingsFromVoice = previousOrigin }
        presentSettings(page: location.page, anchor: location.anchor, modelTask: task)
    }
    @objc func showAbout() { presentSettings(page: .about) }
    @objc func copyDiagnostics() {
        // The menu bar menu leaves the app the person was using in front.
        let front = NSWorkspace.shared.frontmostApplication.flatMap {
            $0.processIdentifier == ProcessInfo.processInfo.processIdentifier
                ? lastExternalPID.flatMap(NSRunningApplication.init(processIdentifier:)) : $0
        }
        DeliveryFallback.copy(AccessibilityDiagnostics.report(front: front))
    }
    // Opens the guide in Settings as Welcome's Set up Yullo does, at its saved step.
    @objc func showSetupGuide() { presentSettings(page: .setup, anchor: "experience-setup") }
    @objc func checkForUpdates() { AppUpdates.shared.check() }
    @objc func showWhereYulloWorks() { presentSettings(page: .setup, anchor: "processing") }
    private func presentSettings(
        page: SettingsPage, anchor: String? = nil, modelTask: ModelTask? = nil
    ) {
        guard !offerWelcomeIfNeeded() else { return }
        guard terminationTask == nil, !hasBlockingModalInteraction else { return }
        guard commitSettingsIfNeeded() else { return }
        discardSettingsContent()
        settingsInitialModelTask = modelTask
        UserDefaults.standard.set(page.rawValue, forKey: "yullo.settingsPage")
        settingsInitialAnchor = anchor
        showSettings()
    }
    @objc func showSettings() {
        guard !offerWelcomeIfNeeded() else { return }
        guard terminationTask == nil, !hasBlockingModalInteraction else { return }
        if settingsReturnContext == nil { settingsReturnContext = currentSettingsReturnContext() }
        AppTheme.apply(settingsPreviewAppearance ?? model.preferences.appearance, to: settingsWindow)
        if !settingsLoaded {
            let opensGuide = settingsInitialAnchor == "experience-setup"
            settingsCommits.reset()
            settingsCommits.finishEditing = { [weak self] in
                guard let window = self?.settingsWindow, window.firstResponder is NSTextView else { return }
                window.makeFirstResponder(nil)
            }
            settingsCommits.isPresented = { [weak self] in self?.settingsWindow.isVisible == true }
            var content = SettingsView(
                model: model, voiceInput: voiceInput, saveShortcuts: saveKeys,
                close: { [weak self] in self?.finishSettings() }, commitCoordinator: settingsCommits,
                initialAnchor: settingsInitialAnchor,
                initialPage: SettingsPage.stored(
                    UserDefaults.standard.string(forKey: "yullo.settingsPage") ?? "General"),
                initialModelTask: settingsInitialModelTask,
                tryDictation: { [weak self] in self?.startVoiceTrial() },
                tryGuidedDictation: { [weak self] completion in self?.startGuidedVoiceTrial(completion) },
                cancelGuidedDictation: { [weak self] in self?.cancelGuidedVoiceTrial() },
                prepareGuidedDictation: { [weak self] in self?.prepareGuidedVoiceTrial() },
                guideTour: guideTourActions(),
                openTranslator: { [weak self] in self?.openPanel() },
                openRecentResult: { [weak self] in self?.showRecentVoiceResult() },
                historyController: resultHistoryController,
                openHistoryResult: { [weak self] entry, translateAgain in
                    self?.openHistoryResult(entry, translateAgain: translateAgain)
                })
            content.setupFocusChanged = { [weak self] in self?.focusSettingsOnSetup($0) }
            content.trialFrameChanged = { [weak self] in self?.trialCardFrame = $0 }
            content.sampleFrameChanged = { [weak self] in self?.sampleCardFrame = $0 }
            let hosting = ThemeHostingView(
                rootView: content, theme: settingsPreviewAppearance ?? model.preferences.appearance,
                inheritedAppearance: settingsWindow.effectiveAppearance)
            settingsInitialAnchor = nil
            settingsInitialModelTask = nil
            hosting.sizingOptions = []
            SettingsWindowSurface.install(hosting, in: settingsWindow)
            AppWindowSizing.configure(settingsWindow, minimum: AppWindowSizing.settingsMinimum)
            settingsLoaded = true
            // Welcome's Set up Yullo opens straight into the focused guide.
            if opensGuide { focusSettingsOnSetup(true) }
        }
        if let screen = settingsWindow.screen ?? NSScreen.main {
            AppWindowSizing.fit(settingsWindow, in: screen.visibleFrame)
        }
        present(settingsWindow)
    }
    // A pending Welcome consumes only this opening. Starting setup never
    // replays the voice/selection action which opened it.
    @discardableResult private func offerWelcomeIfNeeded() -> Bool {
        guard welcomeStartup.shouldOfferWelcome else { return false }
        guard terminationTask == nil, let settingsWindow else { return true }
        if welcomeStartup.isPresenting {
            if !hasOtherBlockingModalInteraction {
                settingsWindow.makeKeyAndOrderFront(nil)
                AppDelegate.activateYullo()
            }
            return true
        }
        guard !hasOtherBlockingModalInteraction, commitSettingsIfNeeded() else { return true }
        discardSettingsContent()
        guard let welcomeID = welcomeStartup.beginWelcome() else { return true }
        let content = WelcomeView(
            entryPoints: welcomeEntryPoints(),
            startSetup: { [weak self] in
                guard let self, self.terminationTask == nil, !self.hasOtherBlockingModalInteraction,
                    self.welcomeStartup.completeWelcome(id: welcomeID)
                else { return }
                self.discardSettingsContent()
                UserDefaults.standard.set(SettingsPage.setup.rawValue, forKey: "yullo.settingsPage")
                self.settingsInitialAnchor = "experience-setup"
                self.showSettings()
            },
            notNow: { [weak self] in
                guard let self, self.welcomeStartup.welcomeID == welcomeID else { return }
                self.settingsWindow.close()
            })
        let hosting = ThemeHostingView(
            rootView: content, theme: model.preferences.appearance,
            inheritedAppearance: settingsWindow.effectiveAppearance)
        hosting.sizingOptions = []
        SettingsWindowSurface.install(hosting, in: settingsWindow)
        if let screen = settingsWindow.screen ?? NSScreen.main {
            AppWindowSizing.fit(settingsWindow, in: screen.visibleFrame)
        }
        if !present(settingsWindow, forWelcome: true) {
            welcomeStartup.cancelWelcome(id: welcomeID)
            discardSettingsContent()
        }
        return true
    }
    // Welcome reads no settings itself. Its ways back into this menu-bar app
    // arrive as plain values: the labels the menus show, only for assigned
    // global shortcuts that registered, and whether the menu-bar item shows.
    private func welcomeEntryPoints() -> WelcomeEntryPoints {
        func key(_ id: UInt32, _ shortcut: Shortcut) -> WelcomeEntryPoints.Key? {
            guard shortcut.isAssigned, !model.inactiveGlobalShortcutIDs.contains(id) else { return nil }
            return .init(label: shortcut.displayLabel, spokenLabel: shortcut.spokenLabel)
        }
        return WelcomeEntryPoints(
            showYullo: key(1, model.openKey), translateSelection: key(2, model.selectionKey),
            dictation: key(3, model.preferences.dictationShortcut),
            refineSelection: key(6, model.preferences.refineSelectionShortcut),
            menuBarItemVisible: model.preferences.showInMenuBar,
            oneLanguage: model.preferences.usesOneLanguage)
    }
    private func currentSettingsReturnContext() -> SettingsReturnContext {
        if let description = openingSettingsFromScenario { return .scenario(description) }
        // Source dictation belongs to its translator even while its HUD is up.
        if voiceInput.isSourceSession {
            if let surface = model.consumeQuickReturn() { return surface == .main ? .quickMain : .quickSelection }
            return model.selectionContext ? .selection : .main
        }
        if openingSettingsFromVoice, voiceInput.phase != .idle { return .voice }
        if sidebar.isVisible { return .selection }
        if panel.isVisible { return .main }
        if let surface = model.consumeQuickReturn() { return surface == .main ? .quickMain : .quickSelection }
        if voiceInput.phase != .idle { return .voice }
        return .noWindow
    }
    // Edit with voice named a missing writing service; once Settings has one,
    // returning doesn't repeat that request.
    private func clearResolvedVoiceEditNotice() {
        guard model.notice == VoiceEditIssue.connectionRequired.localizedDescription,
            VoiceEditService.isConfigured(model.preferences)
        else { return }
        model.notice = ""
    }
    private func restoreSettingsReturnContext(_ context: SettingsReturnContext?) {
        defer { retryAfterKeyAccess(context) }
        switch context {
        case .main:
            resumeMainPanel()
        case .selection:
            guard model.selectionContext, present(sidebar) else { return }
            if !model.canUseOutput && !model.translating && !model.refiningTranslation && !model.isTranslationPending
                && model.preferences.translateSelection
            {
                model.inputChanged(preserveOutput: true)
            }
        case .quickMain:
            model.prepareQuickReturnPresentation()
            _ = present(panel)
        case .quickSelection:
            guard model.selectionContext else { return }
            model.prepareQuickReturnPresentation()
            _ = present(sidebar)
        case .scenario(let description):
            presentScenarioPanel(description: description)
        case .voice, .noWindow, .none:
            break
        }
    }
    private func retryAfterKeyAccess(_ context: SettingsReturnContext?) {
        guard keyAccessAllowedInSettings else { return }
        keyAccessAllowedInSettings = false
        switch context {
        case .voice:
            voiceInput.retryAfterKeyAccess()
        case .main, .selection, .quickMain, .quickSelection:
            model.retryAfterKeyAccess()
        case .scenario, .noWindow, .none:
            break
        }
    }
    // Finishing setup throws a short burst where the guide closed. The window
    // Settings came from returns as it falls away, so it never covers the
    // burst; anything opened in the meantime takes its place.
    private func returnAfterSettings(_ context: SettingsReturnContext?) {
        let delay = SetupCelebration.returnDelay
        guard delay > 0, ![.voice, .noWindow, nil].contains(context) else {
            restoreSettingsReturnContext(context)
            return
        }
        let ticket = UUID()
        pendingSettingsReturn = ticket
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.pendingSettingsReturn == ticket else { return }
            self.pendingSettingsReturn = nil
            guard self.terminationTask == nil, self.settingsWindow?.isVisible != true, !self.panel.isVisible,
                !self.sidebar.isVisible, !self.hasBlockingModalInteraction
            else { return }
            self.restoreSettingsReturnContext(context)
        }
    }
    private func finishSettings() {
        guard !CredentialAccessInteraction.isActive, !KeyStore.isAuthorizing, settingsCommits.commit() else { return }
        // Done, the close button and Command-W share windowWillClose's return.
        settingsWindow.close()
    }
    // The guide's focused view lives in the Settings window. Ending the guide,
    // or closing or replacing the content, returns the Settings size and title.
    private func focusSettingsOnSetup(_ focused: Bool) {
        guard let settingsWindow else { return }
        let visible = (settingsWindow.screen ?? NSScreen.main)?.visibleFrame
        if focused {
            let previous = AppWindowSizing.focusSetup(settingsWindow, in: visible)
            if settingsSizeBeforeSetup == nil { settingsSizeBeforeSetup = previous }
            settingsWindow.title = L10n.tr("Set Up Yullo")
        } else if let size = settingsSizeBeforeSetup {
            settingsSizeBeforeSetup = nil
            AppWindowSizing.restoreSettings(settingsWindow, size: size, in: visible)
            settingsWindow.title = L10n.tr("Settings")
        }
    }
    private func discardSettingsContent() {
        focusSettingsOnSetup(false)
        cancelGuidedVoiceTrial()
        if settingsWindow?.isVisible != true { settingsReturnContext = nil }
        guard
            settingsLoaded || settingsWindow.contentView != nil || settingsPreviewAppearance != nil
                || settingsPreviewWindowStyle != nil
        else { return }
        settingsCommits.discardContent(in: settingsWindow)
        settingsLoaded = false
        settingsPreviewAppearance = nil
        settingsPreviewWindowStyle = nil
        applyAppearance()
    }
    private func commitSettingsIfNeeded() -> Bool {
        guard settingsLoaded else { return true }
        guard settingsCommits.commit() else {
            if settingsReturnContext == nil { settingsReturnContext = currentSettingsReturnContext() }
            voiceInput.setSettingsPresented(true)
            settingsWindow.makeKeyAndOrderFront(nil)
            AppDelegate.activateYullo()
            return false
        }
        return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender !== settingsWindow
            || (!CredentialAccessInteraction.isActive && !KeyStore.isAuthorizing && settingsCommits.commit())
    }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === voiceEditWindow {
            DispatchQueue.main.async { [weak self] in self?.updateActivationPolicy() }
            voiceEditSuspendedForSettings = false
            voiceEditReader?.invalidate()
            voiceEditReader = nil
            voiceEditWindow?.contentView = nil
            voiceEditWindow = nil
            voiceEditChip.dismiss()
            selectionVoiceEdit.cancel()
            voiceEditTyped = false
            if voiceEditFromGuide {
                voiceEditFromGuide = false
                guideSampleReplace = nil
                returnToGuide()
            } else if voiceEditSource != nil {
                releaseVoiceEditSource()
            } else {
                model.clearTranslatorDraft()
            }
        }
        if let window = notification.object as? NSWindow, window === panel || window === sidebar {
            returnToGuide()
            model.clearTranslatorDraft()
        }
        if notification.object as? NSWindow === settingsWindow {
            scheduleVoicePrewarm()
            // The window is still visible here; leave the Dock after it closes.
            DispatchQueue.main.async { [weak self] in self?.updateActivationPolicy() }
            let returnContext = settingsReturnContext
            settingsReturnContext = nil
            let postponedWelcomeID = welcomeStartup.welcomeID
            let postponedWelcome = postponedWelcomeID != nil
            if let id = postponedWelcomeID, terminationTask == nil {
                welcomeStartup.deferWelcome(id: id)
            }
            welcomeStartup.cancelWelcome()
            voiceInput.setSettingsPresented(false)
            discardSettingsContent()
            if voiceEditSuspendedForSettings, terminationTask == nil {
                voiceEditSuspendedForSettings = false
                selectionVoiceEdit.resumeAfterSettings(
                    TranslationSettings(model.preferences, engine: model.preferences.voiceRefinementEngine))
                return
            }
            if postponedWelcome, terminationTask == nil {
                // Keep text translation usable after Cancel without looping
                // through the still-pending Welcome or offering permissions.
                model.windowSession.resetPin()
                model.endSelection()
                positionMainPanel()
                present(panel)
                return
            }
            clearResolvedVoiceEditNotice()
            if terminationTask == nil { returnAfterSettings(returnContext) }
        }
    }
    @objc func quit() { NSApp.terminate(nil) }
}

// Standard Copy remains owned by an editor selection or input-method composition.
// In the selection window, plain Return commits the result: Replace where the
// selection can be written, else Copy, close and go back. Never while the
// source is being edited or composed, on key repeat, or within moments of the
// result appearing (a Return meant for something else).
enum TranslatorReturnRouting {
    enum Action: Equatable { case pass, ignore, replace, copyAndReturn }
    struct Context {
        var isSelectionWindow: Bool
        var offersReplacement: Bool
        var canReplace: Bool
        var canUseOutput: Bool
        var outputReadyAt: TimeInterval?
        var now: TimeInterval
    }
    static let settle: TimeInterval = 0.3
    static func isPlainReturn(_ event: NSEvent) -> Bool {
        (event.keyCode == 36 || event.keyCode == 76)
            && event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty
    }
    static func action(for event: NSEvent, firstResponder: NSResponder?, context: Context) -> Action {
        guard context.isSelectionWindow, event.type == .keyDown, isPlainReturn(event) else { return .pass }
        if let text = firstResponder as? NSTextView, text.isEditable || text.hasMarkedText() { return .pass }
        if event.isARepeat { return .ignore }
        guard context.canUseOutput, let ready = context.outputReadyAt, context.now - ready >= settle else {
            return .ignore
        }
        if context.offersReplacement { return context.canReplace ? .replace : .ignore }
        return .copyAndReturn
    }
}

enum TranslatorCopyRouting {
    static func isCommandCopy(_ event: NSEvent) -> Bool {
        event.charactersIgnoringModifiers?.lowercased() == "c"
            && event.modifierFlags.intersection([.command, .shift, .control, .option]) == .command
    }
    static func canCopyResult(firstResponder: NSResponder?, hasAcceptedOutput: Bool) -> Bool {
        guard hasAcceptedOutput else { return false }
        if let text = firstResponder as? NSTextView {
            return !text.hasMarkedText() && !text.selectedRanges.contains { $0.rangeValue.length > 0 }
        }
        return true
    }
}

extension SelectionVoiceEditReview {
    // The review's window: the Yullo window's kind, a rounded floating panel moved
    // by its surface. Nonactivating, as the Yullo selection window: it takes keys
    // at once while the app being edited stays active, so focus goes straight back.
    static func makePanel() -> FloatingPanel {
        let review = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 300),
            styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        review.isOpaque = false
        review.backgroundColor = .clear
        review.hasShadow = true
        review.hidesOnDeactivate = false
        review.level = .floating
        review.isMovableByWindowBackground = true
        review.isReleasedWhenClosed = false
        review.isRestorable = false
        return review
    }
}
