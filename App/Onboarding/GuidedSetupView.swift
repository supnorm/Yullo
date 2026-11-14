import SwiftUI
import AppKit

// The guide left with Not now or Set up later, kept so Quick setup and the menu
// continue it. The step outlives a quit; the choices behind it were applied
// when the person left Languages, so they come back from the preferences.
@MainActor enum GuidedSetupResume {
    static var draft: GuidedSetupDraft? {
        didSet {
            if let step = draft?.step {
                defaults.set(step.rawValue, forKey: stepKey)
            } else {
                defaults.removeObject(forKey: stepKey)
            }
        }
    }
    static let stepKey = "yullo.guideStep"
    #if YULLO_TESTING
        static var defaults = UserDefaults.standard
    #else
        static let defaults = UserDefaults.standard
    #endif
    // The guide as it was left in an earlier launch, or nil when it was finished or never started.
    static func restored(_ preferences: Preferences, target: String) -> GuidedSetupDraft? {
        if let draft { return draft }
        guard defaults.object(forKey: stepKey) != nil,
            let step = GuidedSetupStep(rawValue: defaults.integer(forKey: stepKey))
        else { return nil }
        return .init(
            plan: .init(preferences: preferences, targetLanguage: target), usesBuiltInMacSetup: false, step: step)
    }
}

struct GuidedSetupDraft: Equatable {
    var plan: GuidedSetupPlan
    var usesBuiltInMacSetup: Bool
    // Where the guide opens with this draft.
    var step = GuidedSetupStep.choices
}

#if YULLO_TESTING
    struct GuidedSetupAttachedActions {
        let plan: Binding<GuidedSetupPlan>
        let recordingDisplay: Binding<Bool>
        let otherLanguagesShown: Binding<Bool>
        let usesBuiltInMacSetup: () -> Bool
        let useBuiltInMacSetup: () -> Void
        let readiness: () -> GuidedRecognitionReadiness
        let applyAndTry: () -> Void
        let applyAndOpenTranslator: () -> Void
        let skip: () -> Void
        let openSettings: (SettingsPage, String?, ModelDiscoveryTask?) -> Void
        let canTry: () -> Bool
        let issue: () -> String?
        let step: () -> GuidedSetupStep
        let next: () -> Void
        let back: () -> Void
        let permissions: () -> PermissionSettingsController
        let microphone: () -> Void
        let close: () -> Void
        let trialActive: () -> Bool
        let trialText: () -> String
        let trialIssue: () -> String?
        let showMoreWays: () -> Void
        let tryFeature: (GuidedTourTask) -> Void
        let cancelFeature: () -> Void
        let feature: () -> GuidedTourSession
        let finish: () -> Void
    }
#endif

@MainActor struct GuidedSetupView: View {
    @ObservedObject var model: Model
    @ObservedObject var models: VoiceModelStore
    // An installed command-line tool can write with one click, without leaving the guide.
    @ObservedObject private var installedCLIs = InstalledCLIs.shared
    @ObservedObject var voice: VoiceInputCoordinator
    let apply: (GuidedSetupPatch) -> String?
    let tryDictation: () -> Void
    let openTranslator: () -> Void
    let openSettings: (SettingsPage, String?, ModelDiscoveryTask?) -> Void
    // Opens a connection's editor or the model library over the guide, without leaving it.
    let setUpService: ((String) -> Void)?
    let close: () -> Void
    // Done after setup: leaves like close unless the host ends a finished guide differently.
    let finished: (() -> Void)?
    let rememberDraft: (GuidedSetupDraft) -> Void
    let embedded: Bool
    let startTrial: ((@escaping (VoiceTrialOutcome) -> Void) -> Void)?
    let cancelTrial: () -> Void
    // Starts loading the trial's recognizer when its step appears; no audio is sent.
    let prepareTrial: () -> Void
    // Each Try on the last step runs only its own route on the sample.
    let tour: GuidedTourActions?
    private let verifyRecognitionModel: (String) async throws -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var headingFocused: Bool
    @State private var plan: GuidedSetupPlan
    @State private var useBuiltInMacSetup = false
    @State private var reviewingBuiltInMacSetup = false
    // I also use: your languages, then the Mac's, in the order set in Language & Region; a row unchecked stays.
    @State private var languageRows: [String] = []
    private enum LanguageSheet: Identifiable {
        case speak, other, target
        var id: Self { self }
    }
    @State private var languageSheet: LanguageSheet?
    // I also use other languages: folded on arrival, open for the rest of the visit once opened.
    @State private var otherLanguagesShown = false
    // The translation model the guide is downloading; it becomes the translator when it arrives.
    @State private var translationDownload: String?
    @State private var hardware: ModelHardwareProfile?
    // Other writing services, folded under the one recommended for this Mac.
    @State private var otherWritersShown = false
    @State private var recognitionShown = false
    // The step's own height and the room it has; the window follows the difference.
    @State private var stepHeight: CGFloat = 0
    @State private var stepRoom: CGFloat = 0
    private static let moreLanguagesTag = "__more-languages__"
    @State private var recordingDisplayExpanded = false
    @State private var progress = GuidedSetupProgress()
    @State private var applyIssue: String?
    @State private var visible = false
    @State private var isClosing = false
    @State private var appleSpeechActivation: UInt64 = 0
    @State private var verificationRetry: UInt64 = 0
    @State private var localVerification = GuidedModelVerification.checking
    @State private var verifiedKey = ""
    @State private var verificationRequest = UUID()
    @State private var availableWidth: CGFloat = 0
    @State private var trialTicket: UUID?
    @State private var trialRunning = false
    @State private var acceptedTrialText = ""
    @State private var trialFailure: String?
    @StateObject private var tourSession = GuidedTourSession()
    // Looked up once when Explore appears, not on every view update.
    @State private var mailApplication: MailApplication?
    @State private var emailIssue: String?
    @StateObject private var appleSpeech = AppleSpeechSettingsStore()
    @StateObject private var recognitionDownload = RecognitionModelDownloadChoice()
    @StateObject private var permissions: PermissionSettingsController
    @State private var voiceAccessRevisited = false
    // Reads whether a saved API key can be used, without prompting, so no Try fails on it.
    @StateObject private var keyAccess = CredentialAccessController(backend: Self.keyBackend)
    #if YULLO_TESTING
        // Generated checks answer key reads themselves; they never read the real Keychain.
        static var keyBackend: CredentialAccessBackend?
    #else
        static let keyBackend: CredentialAccessBackend? = nil
    #endif
    #if YULLO_TESTING
        var yulloTestingCaptureAttachedActions: ((GuidedSetupAttachedActions) -> Void)?
    #endif

    init(
        model: Model, models: VoiceModelStore, voice: VoiceInputCoordinator,
        apply: @escaping (GuidedSetupPatch) -> String?, tryDictation: @escaping () -> Void,
        openTranslator: @escaping () -> Void,
        openSettings: @escaping (SettingsPage, String?, ModelDiscoveryTask?) -> Void,
        setUpService: ((String) -> Void)? = nil,
        close: @escaping () -> Void, finished: (() -> Void)? = nil, draft: GuidedSetupDraft? = nil,
        rememberDraft: @escaping (GuidedSetupDraft) -> Void = { _ in },
        embedded: Bool = false,
        startTrial: ((@escaping (VoiceTrialOutcome) -> Void) -> Void)? = nil,
        cancelTrial: @escaping () -> Void = {}, prepareTrial: @escaping () -> Void = {},
        tour: GuidedTourActions? = nil,
        permissionBackend: PermissionSettingsBackend? = nil,
        verifyModel: ((String) async throws -> Void)? = nil
    ) {
        self.model = model
        self.models = models
        self.voice = voice
        self.apply = apply
        self.tryDictation = tryDictation
        self.openTranslator = openTranslator
        self.openSettings = openSettings
        self.setUpService = setUpService
        self.close = close
        self.finished = finished
        self.rememberDraft = rememberDraft
        self.embedded = embedded
        self.startTrial = startTrial
        self.cancelTrial = cancelTrial
        self.prepareTrial = prepareTrial
        self.tour = tour
        verifyRecognitionModel = verifyModel ?? { try await models.verifyModel($0) }
        _permissions = StateObject(wrappedValue: PermissionSettingsController(backend: permissionBackend))
        _plan = State(
            initialValue: draft?.plan
                ?? GuidedSetupPlan(preferences: model.preferences, targetLanguage: model.ordinaryTranslationTarget))
        _useBuiltInMacSetup = State(initialValue: draft?.usesBuiltInMacSetup ?? false)
        _progress = State(initialValue: GuidedSetupProgress(step: draft?.step ?? .choices))
    }

    private var reviewedPreferences: Preferences {
        plan.patch(useBuiltInMacSetup: useBuiltInMacSetup).applying(to: model.preferences)
    }
    private var needsAppleSpeech: Bool {
        GuidedRecognitionReadiness.needsAppleSpeech(preferences: reviewedPreferences, installed: models.installed)
    }
    private var readiness: GuidedRecognitionReadiness {
        GuidedRecognitionReadiness.resolve(
            preferences: reviewedPreferences, installed: models.installed,
            apple: needsAppleSpeech ? appleSpeech.availability(for: plan.appleLocale) : nil)
    }
    private var selectedLocalModel: InstalledLocalModel? {
        guard reviewedPreferences.voiceModelID != VoiceRecognitionSettings.appleModelID else { return nil }
        return models.installed.first {
            $0.id == reviewedPreferences.voiceModelID && $0.task == .dictation && $0.runtime.task == .dictation
        }
    }
    private var verificationKey: String {
        let local = selectedLocalModel
        return "\(plan.recognitionModelID)|\(local?.url.path ?? "")|\(local?.sizeBytes ?? 0)|\(verificationRetry)"
    }
    private var localVerified: Bool {
        selectedLocalModel == nil || (verifiedKey == verificationKey && localVerification == .verified)
    }
    private var recognitionReady: Bool { readiness.canTry && localVerified }
    private var canTry: Bool {
        recognitionReady && !trialRunning && VoiceTrial.canStart(isBusy: voice.isBusy, result: voice.result)
    }
    private var trialSucceeded: Bool {
        progress.step == .trial && !acceptedTrialText.isEmpty && !trialRunning && trialFailure == nil
    }
    private var requiresLanguageHint: Bool {
        VoiceRecognitionSettings.requiresLanguageHint(
            modelID: reviewedPreferences.voiceModelID,
            architecture: models.installed.first { $0.id == reviewedPreferences.voiceModelID }?.architecture)
    }
    private var microphoneAllowed: Bool {
        permissions.status?.microphone == .authorized && !permissions.isRequestingMicrophone
    }
    private var editedPlan: Binding<GuidedSetupPlan> {
        Binding(
            get: { plan },
            set: { updated in
                guard updated != plan else { return }
                invalidatePendingActions()
                applyIssue = nil
                plan = updated
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            brandHeader
            if availableWidth >= 600 {
                HStack(alignment: .top, spacing: 22) {
                    phaseRail(vertical: true).frame(width: 150)
                    workingSurface
                }
            } else {
                VStack(alignment: .leading, spacing: 22) {
                    phaseRail(vertical: false)
                    workingSurface
                }
            }
            if let applyIssue { inlineIssue(applyIssue) }
            if appleSpeech.downloading || recognitionDownload.downloadingID != nil {
                Text(L10n.tr("Downloads continue when you close setup."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().padding(.top, 2)
            footer.controlSize(.large)
        }
        .font(.system(size: 13)).padding(embedded ? 18 : 26)
        .frame(
            minWidth: embedded ? nil : 520, idealWidth: embedded ? nil : 620,
            maxWidth: embedded ? .infinity : 740,
            minHeight: embedded ? 420 : 360, idealHeight: 550, maxHeight: .infinity,
            alignment: .topLeading
        )
        .background {
            GeometryReader { geometry in
                Color.clear.onAppear { availableWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in availableWidth = width }
            }
        }
        .environment(\.locale, L10n.locale)
        .environment(
            \.engineKeyAccess,
            EngineKeyAccess(
                state: apiKeyState, working: keyAccess.isWorking, allow: { keyAccess.allowAccess(for: .textAPI) })
        )
        .sheet(item: $languageSheet) { sheet in
            MoreLanguagesSheet(
                localizedNames: model.preferences.showLocalizedLanguageNames,
                excluded: sheet == .speak ? [plan.spokenLanguage] : plan.languages,
                choose: { id, _ in addLanguage(id, for: sheet) }, cancel: { languageSheet = nil },
                offersAdding: false
            ).glassSheet()
        }
        .onAppear {
            visible = true
            permissions.appear()
            keyAccess.appear(targets: CredentialAccessTargets.make(reviewedPreferences), inspecting: [.textAPI])
            rebasePlan()
            if languageRows.isEmpty {
                languageRows = plan.otherLanguages + Language.systemDefaultIDs.filter { !plan.languages.contains($0) }
            }
            #if YULLO_TESTING
                yulloTestingCaptureAttachedActions?(
                    .init(
                        plan: editedPlan, recordingDisplay: $recordingDisplayExpanded,
                        otherLanguagesShown: $otherLanguagesShown,
                        usesBuiltInMacSetup: { useBuiltInMacSetup },
                        useBuiltInMacSetup: stageBuiltInMacSetup, readiness: { readiness },
                        applyAndTry: applyAndTry, applyAndOpenTranslator: applyAndOpenTranslator,
                        skip: closeSetup, openSettings: openGuideSettings, canTry: { canTry }, issue: { applyIssue },
                        step: { progress.step }, next: nextStep, back: previousStep,
                        permissions: { permissions }, microphone: enableMicrophone, close: closeSetup,
                        trialActive: { trialRunning }, trialText: { acceptedTrialText }, trialIssue: { trialFailure },
                        showMoreWays: showMoreWays, tryFeature: tryFeature, cancelFeature: tourSession.cancel,
                        feature: { tourSession }, finish: finishSetup))
            #endif
        }
        .task { await models.refresh() }
        .task { await installedCLIs.refresh(model.preferences) }
        .task(id: verificationKey) { await verifySelectedModel() }
        .task(id: "\(needsAppleSpeech)|\(plan.appleLocale)|\(appleSpeechActivation)") {
            await appleSpeech.refresh(plan.appleLocale, isVisible: { visible && needsAppleSpeech })
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
            // Back from Terminal: a tool installed or signed in there is recommended at once.
            let current = model.preferences
            Task { await installedCLIs.rescan(current) }
            if visible && needsAppleSpeech { appleSpeechActivation &+= 1 }
        }
        // Both voice rows allowed while on Voice access, back in Yullo: on to Try it.
        .onChange(of: permissions.status) { previous, current in
            guard visible,
                GuidedVoiceAccessAdvance.advances(
                    step: progress.step, previous: previous, current: current, revisited: voiceAccessRevisited,
                    appActive: NSApp.isActive)
            else { return }
            move(to: .trial)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if AppleSpeechSettingsStore.shouldRefresh(
                notification, settingsVisible: visible, appleVisible: needsAppleSpeech)
            {
                appleSpeechActivation &+= 1
            }
        }
        .onDisappear {
            visible = false
            invalidatePendingActions()
            permissions.disappear()
            keyAccess.disappear()
            appleSpeech.deactivate()
        }
        .onExitCommand(perform: closeSetup)
        .onChange(of: plan) { _, _ in
            saveDraft()
        }
        .onChange(of: useBuiltInMacSetup) { _, _ in
            saveDraft()
        }
        .onChange(of: model.preferences) { _, _ in
            rebasePlan()
            keyAccess.configure(CredentialAccessTargets.make(reviewedPreferences), inspecting: [.textAPI])
            if keyAccess.canCheck { keyAccess.check(.textAPI) }
        }
        .onChange(of: model.ordinaryTranslationTarget) { _, _ in rebasePlan() }
        .onChange(of: plan.recognitionModelID) { _, modelID in
            if modelID != VoiceRecognitionSettings.appleModelID { useBuiltInMacSetup = false }
        }
    }

    private var brandHeader: some View {
        HStack(spacing: 8) {
            Image(nsImage: colorScheme == .dark ? BrandArtwork.darkSettingsIcon : BrandArtwork.lightSettingsIcon)
                .resizable().frame(width: 24, height: 24).accessibilityHidden(true)
            Text("Yullo").font(BrandTypography.wordmark(size: 19)).tracking(-0.5)
            Spacer(minLength: 12)
        }.padding(.bottom, 4)
    }

    // The step rail reads like the Settings sidebar: plain rows, the current one on
    // the card surface with its number in the accent colour.
    private func phaseRail(vertical: Bool) -> some View {
        let layout =
            vertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 4))
        return layout {
            ForEach(GuidedSetupStep.allCases, id: \.rawValue) { item in
                let current = item == progress.step
                // A step left behind earns its check only once its task works; a skipped one keeps its number.
                let done = item.rawValue < progress.step.rawValue && stepWorks(item)
                Button {
                    revisit(item)
                } label: {
                    HStack(spacing: 8) {
                        Image(
                            systemName: done
                                ? "checkmark.circle.fill"
                                : current ? "\(item.rawValue + 1).circle.fill" : "\(item.rawValue + 1).circle"
                        )
                        .font(.system(size: 15))
                        .foregroundStyle(
                            current
                                ? AnyShapeStyle(Color.accentColor)
                                : done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary)
                        )
                        .frame(width: 22)
                        // Across the top, six titles don't fit: the current one names itself, the rest are numbers.
                        if vertical || current {
                            Text(phaseTitle(item)).font(.system(size: 13, weight: current ? .semibold : .regular))
                                .foregroundStyle(item.rawValue > progress.step.rawValue ? .secondary : .primary)
                                .lineLimit(1).minimumScaleFactor(0.85)
                        }
                        if vertical { Spacer(minLength: 0) }
                    }
                    .padding(.horizontal, vertical ? 10 : 6).frame(height: 32)
                    .background {
                        if current {
                            Color.clear.modifier(
                                SettingsCardSurface(
                                    cornerRadius: 8, darkFill: 0.11, solidDarkFill: 0.10, lightFill: 0.90,
                                    solidLightFill: 1))
                        }
                    }
                    .contentShape(Rectangle()).fixedSize(horizontal: !vertical, vertical: false)
                }.buttonStyle(.plain).disabled(item.rawValue > progress.step.rawValue)
                    .accessibilityLabel(
                        L10n.format(
                            "%@, step %ld of %ld", phaseTitle(item), item.rawValue + 1, GuidedSetupStep.allCases.count)
                    )
                    .accessibilityValue(
                        L10n.tr(
                            current
                                ? "Current"
                                : done
                                    ? "Complete" : item.rawValue < progress.step.rawValue ? "Not set up" : "Not started"
                        ))
            }
            if !vertical { Spacer(minLength: 0) }
        }.padding(.top, 3)
    }

    private var workingSurface: some View {
        ScrollViewReader { reader in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(stageTitle).font(.system(size: 22, weight: .semibold))
                            .accessibilityAddTraits(.isHeader).accessibilityFocused($headingFocused)
                        if !stageIntroduction.isEmpty {
                            Text(stageIntroduction).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.id("guide-top")
                    switch progress.step {
                    case .choices: basics
                    case .translation: translationStep
                    case .writing: writingStep
                    case .permissions: voiceAccess
                    case .trial: trial.onAppear { if recognitionReady { prepareTrial() } }
                    case .more: moreWays
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 9).padding(.bottom, 4)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { stepHeight = $0 }
            }.smallNativeScrollbars()
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { stepRoom = $0 }
                // Taller than its room (the smallest window): the last lines fade out at the
                // edge instead of being cut at full ink; scrolling brings them in.
                .mask {
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: stepHeight > stepRoom + 1 ? 22 : 0)
                    }
                }
                .background {
                    // On its own, the guide's window is as tall as the step; it scrolls only
                    // when the screen is too short for it.
                    if !embedded { GuideWindowFit(step: stepHeight, room: stepRoom) }
                }
                .onChange(of: tourSession.running) { _, running in
                    guard running != nil else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                        reader.scrollTo("guide-tour-sample", anchor: nil)
                    }
                }
                .onChange(of: progress.step) { _, _ in
                    reader.scrollTo("guide-top", anchor: .top)
                    let visit = progress.visit
                    Task { @MainActor in
                        await Task.yield()
                        guard visible, progress.visit == visit else { return }
                        headingFocused = true
                    }
                }
                .task(id: recordingDisplayExpanded) {
                    guard recordingDisplayExpanded, progress.step == .trial else { return }
                    let visit = progress.visit
                    // The options sit at the end of the step; wait for the
                    // disclosure to open so the scroll reaches its full height.
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled, visible, recordingDisplayExpanded, progress.visit == visit,
                        progress.step == .trial, !trialRunning, !trialSucceeded
                    else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                        reader.scrollTo("guide-recording-display-options", anchor: .bottom)
                    }
                }
        }
    }

    // Languages first; each service they need is set up on its own step after this one.
    private var basics: some View {
        SettingsSection(L10n.tr("Languages")) {
            SettingsRows { languagesSetup }
        }
    }

    private func languageName(_ id: String) -> String {
        Language.displayName(for: id, localized: model.preferences.showLocalizedLanguageNames, locale: L10n.locale)
    }
    // Yullo's own language comes first and applies at once, so the rest of the
    // guide reads in it; the same setting as Settings › General › Interface language.
    private var interfaceLanguageRow: some View {
        SettingsTaskRow(title: L10n.tr("Interface language")) {
            Picker(
                L10n.tr("Interface language"),
                selection: Binding(
                    get: { model.preferences.interfaceLanguage },
                    set: { model.setInterfaceLanguage($0) })
            ) {
                ForEach(L10n.choices, id: \.id) { choice in
                    Text(choice.id == "system" ? L10n.tr("System") : choice.name).tag(choice.id)
                }
            }.labelsHidden().pickerStyle(.menu).settingsControlWidth()
                // The pop-up keeps its menu titles; rebuild it so they follow the new language.
                .id(model.preferences.interfaceLanguage)
                .accessibilityIdentifier("guide-interface-language")
        }
    }
    // Your languages, from the Mac on a new installation: the one spoken, then the others.
    @ViewBuilder private var languagesSetup: some View {
        interfaceLanguageRow
        SettingsTaskRow(title: L10n.tr("I speak")) {
            Picker(
                L10n.tr("I speak"),
                selection: Binding(
                    get: { plan.spokenLanguage },
                    set: { value in
                        if value == Self.moreLanguagesTag { return languageSheet = .speak }
                        speak(value)
                    })
            ) {
                ForEach(plan.languages, id: \.self) { Text(languageName($0)).tag($0) }
                Divider()
                Text(L10n.tr("More languages…")).tag(Self.moreLanguagesTag)
            }.labelsHidden().pickerStyle(.menu).settingsControlWidth()
                .accessibilityIdentifier("guide-spoken-language")
        }
        // One language is the whole story until the person says otherwise; the others,
        // checked or offered from the Mac, wait behind one row that names them.
        SettingsDisclosureRow(
            title: L10n.tr("I also use other languages"),
            summary: plan.otherLanguages.map(languageName).joined(separator: L10n.listSeparator),
            isExpanded: $otherLanguagesShown
        ).accessibilityIdentifier("guide-other-languages")
        // One compact checklist: no hairlines between languages, one after Add language….
        if otherLanguagesShown {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(languageRows.filter { $0 != plan.spokenLanguage }, id: \.self) { id in
                    Toggle(
                        languageName(id),
                        isOn: Binding(
                            get: { plan.otherLanguages.contains(id) },
                            set: { _ in editedPlan.wrappedValue = toggled(id) })
                    ).toggleStyle(.checkbox).accessibilityIdentifier("guide-language-" + id)
                }
                Button(L10n.tr("Add language…")) { languageSheet = .other }
                    .accessibilityIdentifier("guide-add-language").padding(.top, 2)
            }.padding(.bottom, 4).settingsRowAttached()
        }
        // With one language, translation goes into it; a target appears once there is another.
        if !plan.otherLanguages.isEmpty {
            SettingsTaskRow(title: L10n.tr("Translation target")) {
                Picker(
                    L10n.tr("Translation target"),
                    selection: Binding(
                        // A saved target that is the spoken language shows the first of the others, never a blank menu.
                        get: {
                            plan.otherLanguages.contains(plan.targetLanguage)
                                ? plan.targetLanguage : (plan.otherLanguages.first ?? "")
                        },
                        set: { value in
                            if value == Self.moreLanguagesTag { return languageSheet = .target }
                            if !value.isEmpty { editedPlan.targetLanguage.wrappedValue = value }
                        })
                ) {
                    ForEach(plan.otherLanguages, id: \.self) { Text(languageName($0)).tag($0) }
                    Divider()
                    // The same words as every other translation target menu.
                    Text(L10n.tr("More languages…")).tag(Self.moreLanguagesTag)
                }.labelsHidden().pickerStyle(.menu).settingsControlWidth()
                    .accessibilityIdentifier("guide-translation-target")
            }
        }
    }
    private func toggled(_ id: String) -> GuidedSetupPlan {
        var staged = plan
        staged.toggleOther(id)
        return staged
    }
    private func speak(_ id: String) {
        let previous = plan.spokenLanguage
        var staged = plan
        staged.speak(id)
        editedPlan.wrappedValue = staged
        // The one it replaces joins the others in place of the new one; nothing else moves.
        if let index = languageRows.firstIndex(of: id) {
            languageRows[index] = previous
        } else if !languageRows.contains(previous) {
            languageRows.insert(previous, at: 0)
        }
    }
    private func addLanguage(_ id: String, for sheet: LanguageSheet) {
        languageSheet = nil
        switch sheet {
        case .speak: speak(id)
        case .other, .target:
            if !languageRows.contains(id) { languageRows.append(id) }
            var staged = plan
            if !staged.otherLanguages.contains(id) { staged.toggleOther(id) }
            if sheet == .target { staged.targetLanguage = id }
            editedPlan.wrappedValue = staged
        }
    }

    // Translation: the model that runs on this Mac, downloaded here with its size, then a
    // Try on the sample. Translate with keeps every other choice, as in Settings.
    private var translationStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox {
                SettingsRows {
                    if let offer = translationOffer { translationModelRow(offer) }
                    TranslateWithRow(
                        draft: Binding(
                            get: { reviewedPreferences },
                            set: { value in stageNow { $0.stageTranslator(value) } }),
                        models: models, openServices: { setUp($0) }, showsDetails: false)
                }
            }
            sampleCard(.translate, title: "Translate", blocked: fix(for: translationReadiness)?.status)
        }.task { if hardware == nil { hardware = await ModelHardwareProfile.load() } }
    }
    // The translation model this Mac should use, while none is on it yet.
    private var translationOffer: LocalModelDescriptor? {
        guard !models.installed.contains(where: { $0.task == .translation }) else { return nil }
        return GuidedTranslationOffer.model(languages: plan.languages, hardware: hardware)
    }
    private func translationModelRow(_ offer: LocalModelDescriptor) -> some View {
        let room = GuidedTranslationOffer.hasRoom(offer, hardware: hardware)
        return VStack(alignment: .leading, spacing: 6) {
            SettingsTaskRow(title: offer.name, caption: L10n.tr("Runs on this Mac")) {
                if models.downloads[offer.id] == nil {
                    Button(RecognitionModelMenu.downloadTitle(offer.id)) { downloadTranslationModel(offer.id) }
                        .keyboardShortcut(.defaultAction).disabled(!room)
                        .accessibilityIdentifier("guide-translation-download")
                        .background {
                            guideExitProbe("guide-translation-download") { downloadTranslationModel(offer.id) }
                        }
                }
            }
            if let progress = models.downloads[offer.id] {
                VStack(alignment: .leading, spacing: 5) {
                    if let fraction = progress.fraction, fraction.isFinite, progress.phase != .verifying {
                        ProgressView(value: min(1, max(0, fraction))).controlSize(.small)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(RecognitionModelMenu.progressLabel(progress)).foregroundStyle(.secondary).monospacedDigit()
                        Spacer(minLength: 8)
                        Button(L10n.tr("Cancel")) { models.cancel(offer.id) }.buttonStyle(.link)
                    }
                }.font(.system(size: 11)).accessibilityIdentifier("guide-translation-progress")
            } else if let message = models.errors[offer.id] {
                inlineIssue(message).font(.system(size: 11))
            } else if !room {
                // The one reason; Translate with below still offers Apple's translation.
                inlineIssue(
                    L10n.tr("Not enough free space to download this model. Free up space on this Mac and try again.")
                ).font(.system(size: 11)).accessibilityIdentifier("guide-translation-no-room")
            }
        }
    }
    private func downloadTranslationModel(_ id: String) {
        guard visible, progress.step == .translation, models.downloads[id] == nil else { return }
        let handle = models.startOrJoinDownload(id)
        // Download here chooses this model, as a pending choice in a model menu does:
        // it translates once it arrives, unless Translate with changed meanwhile.
        let baseline = reviewedPreferences.engine
        translationDownload = id
        Task { @MainActor in
            let installed = await models.waitForDownload(handle)
            guard translationDownload == id else { return }
            translationDownload = nil
            guard installed, reviewedPreferences.engine == baseline else { return }
            stageNow { staged in
                var value = reviewedPreferences
                value.engine = "local"
                value.localTranslationModelID = id
                staged.stageTranslator(value)
            }
        }
    }

    // Writing: the service that suits this Mac, used with one press; the others below,
    // set up in place as in the chooser. Then a Try on the sample.
    private var writingStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            if writingReadiness == .ready {
                GroupBox {
                    SettingsRows {
                        WriteWithRow(
                            draft: Binding(
                                get: { reviewedPreferences },
                                set: { value in stageNow { $0.stageWriter(value) } }),
                            caption: L10n.tr("For Refine and formats like Email."), openServices: { setUp($0) },
                            showsFallback: false)
                    }
                }
            } else {
                // One service leads: Apple's model or a tool already on this Mac with Use,
                // else the one that fits Where Yullo works: Ollama on this Mac only, an online
                // service (its form open) otherwise. The others fold under it.
                if let recommended = recommendedWriter {
                    GroupBox { SettingsRows { recommendedWriterRow(recommended) } }
                } else {
                    writerChooser(shown: [onDeviceOnly ? "ollama" : "api"], opensAPIForm: !onDeviceOnly)
                }
                SettingsDisclosureRow(title: L10n.tr("Other services"), summary: nil, isExpanded: $otherWritersShown)
                    .padding(.horizontal, 4).accessibilityIdentifier("guide-other-writers")
                if otherWritersShown {
                    writerChooser(shown: otherWriterKinds)
                }
            }
            sampleCard(
                .refine, title: "Refine",
                blocked: writingReadiness == .ready ? nil : L10n.tr("Needs a writing service."))
        }
    }
    // Every kind but the one leading: Apple's model, a tool on this Mac, or the online service.
    private var otherWriterKinds: Set<String> {
        switch recommendedWriter {
        case .apple: return ["ollama", "api", "cli"]
        case .cli: return ["apple", "ollama", "api"]
        case nil: return onDeviceOnly ? ["apple", "api", "cli"] : ["apple", "ollama", "cli"]
        }
    }
    private var onDeviceOnly: Bool { reviewedPreferences.processingPolicy == .onDeviceOnly }
    private func writerChooser(shown: Set<String>, opensAPIForm: Bool = false) -> some View {
        WritingServiceChooser(
            draft: Binding(get: { reviewedPreferences }, set: { value in stageNow { $0.stageWriter(value) } }),
            setUp: { setUp($0) }, close: {}, inline: true, shown: shown, opensAPIForm: opensAPIForm)
    }
    // Apple's model where it runs on this Mac, else a command-line tool already signed in here.
    private var recommendedWriter: GuidedWriterRecommendation? {
        GuidedWriterRecommendation.make(
            apple: AppleWriterStatus.availability(), installed: installedCLIs.offers(reviewedPreferences),
            signedIn: installedCLIs.signedIn, onDeviceOnly: onDeviceOnly)
    }
    private func recommendedWriterRow(_ recommended: GuidedWriterRecommendation) -> some View {
        SettingsTaskRow(title: recommended.title, caption: recommended.caption) {
            Button(L10n.tr("Use")) { useWriter(recommended) }.keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("guide-use-writer")
                .background { guideExitProbe("guide-use-writer") { useWriter(recommended) } }
        }
    }
    private func useWriter(_ recommended: GuidedWriterRecommendation) {
        guard visible, progress.step == .writing else { return }
        switch recommended {
        case .apple:
            stageNow { staged in
                var value = reviewedPreferences
                value.voiceRefinementEngine = "apple"
                staged.stageWriter(value)
            }
        case .cli(let setup):
            stageNow { $0.stageWriter(InstalledCLIs.choose(setup, writing: true, in: reviewedPreferences)) }
        }
    }
    // A choice made on the Translation or Writing step applies at once, so its Try uses it.
    private func stageNow(_ change: (inout GuidedSetupPlan) -> Void) {
        var staged = plan
        change(&staged)
        guard staged != plan else { return }
        editedPlan.wrappedValue = staged
        _ = applyPlan()
    }
    // The step's Sample card: the sample, the Try that shows this step working, and its result.
    private func sampleCard(_ task: GuidedTourTask, title: String, blocked: String?) -> some View {
        GuideSampleCard(
            session: tourSession, speech: tourSpeech, cancel: tourSession.cancel,
            setUpWriting: { otherWritersShown = true },
            tryAction: tour == nil
                ? nil
                : .init(
                    title: title, enabled: blocked == nil && tourSession.running == nil, help: blocked,
                    action: { tryFeature(task) })
        ).id("guide-tour-sample")
    }

    private var recognitionNeedsAttention: Bool {
        recognitionDownload.pendingID == nil && (!recognitionReady || verificationIssue != nil)
            && readiness != .checking
    }
    // What recognizes now: the chosen model on this Mac, or Apple Speech.
    private var recognitionSummary: String? {
        if let selectedLocalModel { return selectedLocalModel.name }
        return readiness.canTry ? L10n.tr("Apple Speech · on device") : nil
    }
    @ViewBuilder private var recognitionSetup: some View {
        recognitionPicker
        if requiresLanguageHint {
            RecognitionLanguageSetting(
                selected: editedPlan.recognitionLanguage, modelID: plan.recognitionModelID,
                personal: plan.languages,
                localizedNames: model.preferences.showLocalizedLanguageNames)
        }
        if needsAppleSpeech {
            SettingsTaskRow(title: L10n.tr("Apple Speech language")) {
                Picker(L10n.tr("Apple Speech language"), selection: editedPlan.appleLocale) {
                    Text(L10n.tr("System language")).tag("system")
                    if plan.appleLocale != "system", !appleSpeech.locales.contains(where: { $0.id == plan.appleLocale })
                    {
                        Text(plan.appleLocale).tag(plan.appleLocale)
                    }
                    ForEach(appleSpeech.locales) { Text($0.name).tag($0.id) }
                }.labelsHidden().pickerStyle(.menu).settingsControlWidth().disabled(appleSpeech.downloading)
            }.help(
                L10n.tr(
                    "Apple Speech recognizes one language at a time. For mixed languages, use a multilingual model."))
        }
        // Readiness shows only when something is missing; a pending choice states it in the picker.
        if recognitionDownload.pendingID == nil, !recognitionReady || verificationIssue != nil {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verificationIssue ?? readinessMessage).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if verificationIssue != nil {
                    Button(L10n.tr("Retry")) { verificationRetry &+= 1 }.buttonStyle(.link)
                }
            }.font(.system(size: 11)).settingsRowAttached()
        }
        if readiness == .needsAppleDownload || readiness == .appleDownloading || appleSpeech.downloading {
            HStack {
                Spacer(minLength: 0)
                if appleSpeech.downloading || readiness == .appleDownloading { ProgressView().controlSize(.small) }
                Button(
                    L10n.tr(
                        appleSpeech.downloading
                            ? "Downloading Apple Speech language…" : "Download Apple Speech language")
                ) {
                    appleSpeech.download(plan.appleLocale)
                }.disabled(appleSpeech.downloading || readiness == .appleDownloading)
            }.settingsRowAttached()
        }
        if !appleSpeech.message.isEmpty { inlineIssue(appleSpeech.message).settingsRowAttached() }
        Toggle(L10n.tr("Review before inserting"), isOn: editedPlan.previewFirst)
        SettingsDisclosureRow(
            title: L10n.tr("Built-in Mac setup"), summary: useBuiltInMacSetup ? L10n.tr("Selected") : nil,
            isExpanded: $reviewingBuiltInMacSetup)
        if reviewingBuiltInMacSetup {
            Text(
                L10n.tr("Apple translation, Apple Speech and macOS voices. Dictation types exactly what you say.")
            )
            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .settingsRowAttached()
            HStack {
                Spacer(minLength: 0)
                Button(L10n.tr(useBuiltInMacSetup ? "Selected" : "Use this setup"), action: stageBuiltInMacSetup)
                    .disabled(useBuiltInMacSetup)
            }.settingsRowAttached()
        }
    }

    // The same menu as Voice input settings. A finished download never
    // switches the recognizer during a running trial.
    private var recognitionPicker: some View {
        RecognitionModelPicker(
            selected: Binding(
                get: { plan.recognitionModelID },
                set: { if !trialRunning { editedPlan.recognitionModelID.wrappedValue = $0 } }),
            models: models, download: recognitionDownload, languageIDs: plan.languages,
            openLibrary: { openGuideSettings(.models, "models", .dictation) })
    }

    // One card in the Quick setup permissions grammar: name and purpose, one item on the right.
    private var voiceAccess: some View {
        VStack(alignment: .leading, spacing: 8) {
            GroupBox {
                SettingsRows {
                    permissionRow(
                        title: "Microphone", detail: nil, allowed: microphoneAllowed,
                        status: microphoneStatus, action: microphoneAllowed ? nil : microphoneAction,
                        perform: enableMicrophone)
                    // The same words and check as Settings: listed but not active has its own fix.
                    permissionRow(
                        title: "Accessibility",
                        detail: AccessibilityRowText.purpose(permissions.status, asked: permissions.askedAccessibility),
                        allowed: permissions.status?.accessibility == true,
                        status: permissions.status == nil
                            ? "Checking…" : permissions.status?.accessibility == true ? "Allowed" : "Not allowed",
                        action: AccessibilityRowText.action(permissions.status),
                        perform: permissions.accessibilityAction)
                }
            }
            // Only a denied microphone needs words: the switch is now in System Settings.
            if !microphoneAllowed, permissions.status?.microphone.needsSettings == true {
                Text(
                    L10n.tr(
                        "Enable microphone access in System Settings, or click Show Yullo to use Yullo without voice input."
                    )
                )
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("guide-microphone-required")
            }
        }
    }

    private func permissionRow(
        title: String, detail: String?, allowed: Bool, status: String,
        action: String?, perform: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr(title))
                if let detail {
                    Text(L10n.tr(detail)).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let action {
                Button(L10n.tr(action), action: perform)
                    .disabled(permissions.status == nil || permissions.isRequestingMicrophone)
                    .help(L10n.tr(status))
                    .accessibilityLabel(L10n.tr(title) + ": " + L10n.tr(action))
                    .background { guideExitProbe("guide-permission-" + title, action: perform) }
            } else if allowed {
                Label(L10n.tr(status), systemImage: "checkmark.circle.fill").font(.system(size: 12))
                    .foregroundStyle(.green)
            } else {
                Text(L10n.tr(status)).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    // The trial first; under it one card with the recognizer, the key that starts
    // dictation and the indicator's placement, folded.
    private var trial: some View {
        VStack(alignment: .leading, spacing: 14) {
            trialCard
            if let trialFailure { inlineIssue(trialFailure) }
            if !voice.result.isEmpty {
                Text(L10n.tr("Copy the current result if needed, then close it before trying dictation."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            // Accessibility is asked once, in Voice access; here its state alone, with the way back.
            if trialSucceeded, !model.preferences.voicePreviewFirst, permissions.status?.accessibility == false {
                accessibilityPointer(L10n.tr("To type into other apps, Yullo needs Accessibility."))
                    .accessibilityIdentifier("guide-enable-insertion")
            }
            if !trialSucceeded {
                GroupBox {
                    SettingsRows {
                        // The recognizer, on one row; it opens itself when it can't recognize yet,
                        // so its fix (a download, a language) is never hidden.
                        SettingsDisclosureRow(
                            title: L10n.tr("Recognition model"), summary: recognitionSummary,
                            isExpanded: Binding(
                                get: { recognitionShown || recognitionNeedsAttention }, set: { recognitionShown = $0 })
                        ).disabled(trialRunning).accessibilityIdentifier("guide-recognition")
                        if recognitionShown || recognitionNeedsAttention { recognitionSetup }
                        SettingsDisclosureRow(
                            title: L10n.tr("Recording indicator"),
                            summary: VoiceOverlayPlacement(rawValue: plan.voicePlacement).map(
                                RecordingIndicatorPlacementPicker.title),
                            isExpanded: $recordingDisplayExpanded
                        ).disabled(trialRunning || voice.isBusy)
                            .accessibilityIdentifier("guide-recording-display")
                        if recordingDisplayExpanded {
                            RecordingIndicatorPlacementPicker(
                                placement: editedPlan.voicePlacement,
                                isEnabled: !trialRunning && !voice.isBusy, showsTitle: false
                            ).padding(.vertical, 4).id("guide-recording-display-options")
                        }
                    }
                }
            }
        }
    }
    // A permission's state and the step that asks for it; never a second request.
    private func accessibilityPointer(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            // Asked here, in place: the step and its results stay.
            Button(L10n.tr("Allow Accessibility…"), action: permissions.accessibilityAction).buttonStyle(.link)
                .fixedSize()
        }.font(.system(size: 12))
    }

    private var trialCard: some View {
        DictationTrialCard(
            running: trialRunning, text: acceptedTrialText, showsPrevious: trialRunning || trialFailure != nil,
            phase: voice.phase, level: { voice.level },
            finishHint: GuidedTrialStage.finishHint(
                VoiceTrial.preferences(from: model.preferences),
                shortcutAvailable: !model.inactiveGlobalShortcutIDs.contains(3)),
            cancel: cancelOwnedTrial, start: applyAndTry, canStart: canTry, failed: trialFailure != nil,
            startKey: GuidedTourSample.key(3, model.preferences.dictationShortcut, model: model),
            returnStarts: true
        ).onAppear { GuidedTrialShortcut.start = { if canTry { applyAndTry() } } }
            .onDisappear { GuidedTrialShortcut.start = nil }
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                backwardButton
                Spacer(minLength: 8)
                forwardButtons
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    backwardButton
                    Spacer(minLength: 0)
                }
                HStack {
                    Spacer(minLength: 0)
                    forwardButtons
                }
            }
        }
    }
    @ViewBuilder private var backwardButton: some View {
        if progress.step != .choices {
            Button(L10n.tr("Back"), action: previousStep).fixedSize()
        }
    }
    // One way to leave on every step, beside the way on: Finish later keeps the step
    // and the choices, and Quick setup or Setup Guide… continues there.
    private var forwardButtons: some View {
        HStack(spacing: 16) {
            if progress.step != .more {
                Button(L10n.tr("Finish later"), action: closeSetup).buttonStyle(.link).fixedSize()
                    .background { guideExitProbe("guide-set-up-later", action: closeSetup) }
            }
            stepForwardButtons
        }
    }
    @ViewBuilder private var stepForwardButtons: some View {
        if progress.step == .more {
            Button(L10n.tr("Done"), action: finishSetup).keyboardShortcut(.defaultAction).fixedSize()
        } else if progress.step == .trial {
            // Trying lives in the card; the footer only moves on or leaves.
            if acceptedTrialText.isEmpty {
                HStack(spacing: 16) {
                    // Only a denied microphone needs the way on to typing in Yullo.
                    if permissions.status?.microphone.needsSettings == true {
                        Button(L10n.tr("Show Yullo"), action: applyAndOpenTranslator).buttonStyle(.link).fixedSize()
                    }
                    Button(L10n.tr("Skip"), action: showMoreWays).keyboardShortcut(.return, modifiers: .command)
                        .help(L10n.tr("Skip") + " · ⌘↩").fixedSize()
                        .background { guideExitProbe("guide-step-forward", action: showMoreWays) }
                }
            } else {
                Button(L10n.tr("Continue"), action: showMoreWays)
                    .keyboardShortcut(.defaultAction).fixedSize()
                    .background { guideExitProbe("guide-step-forward", action: showMoreWays) }
            }
        } else if progress.step == .translation || progress.step == .writing {
            // Continue once the step's task works, Skip while it doesn't. A step with its
            // own primary button (Download, Use) leaves Return to that button.
            let ready = progress.step == .translation ? translationReadiness == .ready : writingReadiness == .ready
            let primary =
                progress.step == .translation
                ? translationOffer != nil && translationDownload == nil
                : !ready && recommendedWriter != nil
            Group {
                if primary || !ready {
                    Button(L10n.tr(ready ? "Continue" : "Skip"), action: nextStep)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help(L10n.tr(ready ? "Continue" : "Skip") + " · ⌘↩").fixedSize()
                        .background { guideExitProbe("guide-step-forward", action: nextStep) }
                } else {
                    Button(L10n.tr("Continue"), action: nextStep).keyboardShortcut(.defaultAction).fixedSize()
                        .background { guideExitProbe("guide-step-forward", action: nextStep) }
                }
            }
        } else {
            // A denied microphone still leaves everything but voice input, as its note says.
            if progress.step == .permissions, permissions.status?.microphone.needsSettings == true {
                Button(L10n.tr("Show Yullo"), action: applyAndOpenTranslator).buttonStyle(.link).fixedSize()
                    .background { guideExitProbe("guide-show-yullo", action: applyAndOpenTranslator) }
            }
            if progress.step == .choices {
                Button(L10n.tr("Continue"), action: nextStep).keyboardShortcut(.defaultAction).fixedSize()
                    .background { guideExitProbe("guide-step-forward", action: nextStep) }
            } else {
                // Both rows are optional: typing in Yullo works without them, as the step says.
                Button(L10n.tr("Continue"), action: nextStep).keyboardShortcut(.defaultAction)
                    .disabled(permissions.isRequestingMicrophone).fixedSize()
                    .background { guideExitProbe("guide-step-forward", action: nextStep) }
            }
        }
    }

    @ViewBuilder private func guideExitProbe(_ title: String, action: @escaping () -> Void) -> some View {
        #if YULLO_TESTING
            YulloActionPresentationProbe(title: title, action: action)
        #endif
    }

    private func phaseTitle(_ step: GuidedSetupStep) -> String {
        switch step {
        case .choices: return L10n.tr("Languages")
        case .translation: return L10n.tr("Translation")
        case .writing: return L10n.tr("Writing")
        case .permissions: return L10n.tr("Permissions")
        case .trial: return L10n.tr("Dictation")
        case .more: return L10n.tr("Shortcuts")
        }
    }
    private var stageTitle: String {
        switch progress.step {
        case .choices: return L10n.tr("Start with your words")
        case .translation: return L10n.format("Translate into %@", languageName(translationTarget))
        case .writing: return L10n.tr("Choose how Yullo writes")
        case .permissions: return L10n.tr("Allow Yullo to listen and type")
        case .trial: return L10n.tr(trialSucceeded ? "Your words are ready" : "Try one sentence")
        case .more: return L10n.tr("Shortcuts")
        }
    }
    private var stageIntroduction: String {
        switch progress.step {
        case .choices, .translation, .writing: return ""
        case .permissions:
            return L10n.tr("Typing in Yullo works without these.")
        case .trial: return ""
        case .more: return L10n.tr("Try each on the sample.")
        }
    }
    private func stepWorks(_ step: GuidedSetupStep) -> Bool {
        switch step {
        case .choices, .more: return true
        case .translation: return translationReadiness == .ready
        case .writing: return writingReadiness == .ready
        case .permissions: return microphoneAllowed && permissions.status?.accessibility == true
        case .trial: return !acceptedTrialText.isEmpty
        }
    }
    // Where the Translation step's Try sends the sample, named in its title.
    private var translationTarget: String {
        GuidedTourSample.target(reviewedPreferences, ordinaryTarget: plan.targetLanguage)
    }
    private var verificationIssue: String? {
        guard selectedLocalModel != nil, verifiedKey == verificationKey, case .failed(let message) = localVerification
        else { return nil }
        return message
    }
    private var readinessMessage: String {
        if selectedLocalModel != nil {
            if verifiedKey != verificationKey || localVerification == .checking {
                return L10n.tr("Checking speech recognition…")
            }
            if verificationIssue != nil { return L10n.tr("Couldn’t check this recognition model.") }
        }
        switch readiness {
        case .checking: return L10n.tr("Checking speech recognition…")
        case .ready: return L10n.tr("Recognizer available")
        case .appleFallback: return L10n.tr("Apple Speech fallback is available for this language.")
        case .missingModel: return L10n.tr("Choose or download a recognition model.")
        case .languageRequired: return L10n.tr("Choose a spoken language for this recognizer.")
        case .needsAppleDownload: return L10n.tr("Apple Speech needs a language download.")
        case .appleDownloading: return L10n.tr("Apple Speech is downloading this language.")
        case .unsupportedApple: return L10n.tr("Choose a supported Apple Speech language.")
        case .unavailableApple: return L10n.tr("Apple Speech is unavailable on this Mac.")
        }
    }
    private var microphoneStatus: String {
        if permissions.isRequestingMicrophone { return "Requesting access…" }
        guard let microphone = permissions.status?.microphone else { return "Checking…" }
        switch microphone {
        case .authorized: return "Allowed"
        case .notDetermined: return "Not requested"
        case .denied: return "Not allowed"
        case .restricted: return "Restricted"
        }
    }
    private var microphoneAction: String {
        permissions.status?.microphone.needsSettings == true ? "Open Microphone Settings" : "Enable…"
    }
    private func inlineIssue(_ message: String) -> some View {
        Text(message).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func verifySelectedModel() async {
        let expected = verificationKey
        let request = UUID()
        verificationRequest = request
        guard let selected = selectedLocalModel else {
            verifiedKey = expected
            localVerification = .checking
            return
        }
        verifiedKey = expected
        localVerification = .checking
        do {
            try await verifyRecognitionModel(selected.id)
            guard !Task.isCancelled, visible, verificationKey == expected, verificationRequest == request else {
                return
            }
            localVerification = .verified
        } catch {
            guard !Task.isCancelled, visible, verificationKey == expected, verificationRequest == request else {
                return
            }
            localVerification = .failed(error.localizedDescription)
        }
    }
    // Continue or Skip: the choices apply, and the next step opens. Nothing waits on a
    // download or a service; each step says what is missing and offers its fix.
    private func nextStep() {
        invalidatePendingActions()
        applyIssue = nil
        guard applyPlan() else { return }
        switch progress.step {
        case .choices: move(to: .translation)
        case .translation: move(to: .writing)
        // Voice access is skipped only when both rows are already allowed.
        case .writing:
            move(to: microphoneAllowed && permissions.status?.accessibility == true ? .trial : .permissions)
        // A denied microphone can't try dictation: on to the shortcuts, where
        // the voice rows say what they need.
        case .permissions: move(to: permissions.status?.microphone.needsSettings == true ? .more : .trial)
        case .trial: move(to: .more)
        case .more: break
        }
    }
    // A grant only updates its row. Continue stays the user's choice, so
    // Accessibility can still be enabled after the microphone.
    private func enableMicrophone() {
        guard visible, progress.step == .permissions, !microphoneAllowed else { return }
        permissions.microphoneAction()
    }
    private func move(to step: GuidedSetupStep) {
        // A step's results belong to its visit: the Explore results always,
        // and a trial result once the person goes back before the trial
        // (where its choices can change).
        if step != progress.step { tourSession.reset() }
        if step.rawValue < GuidedSetupStep.trial.rawValue {
            acceptedTrialText = ""
            trialFailure = nil
        }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { progress.move(to: step) }
        applyIssue = nil
        voiceAccessRevisited = false
        // Saved as it moves, so Settings closing at once still continues here next time.
        saveDraft()
    }
    private func revisit(_ step: GuidedSetupStep) {
        guard step.rawValue <= progress.step.rawValue, step != progress.step else { return }
        invalidatePendingActions()
        move(to: step)
        // Gone back to on purpose: Voice access waits for Continue.
        if step == .permissions { voiceAccessRevisited = true }
    }
    private func previousStep() {
        guard let previous = GuidedSetupStep(rawValue: progress.step.rawValue - 1) else { return }
        invalidatePendingActions()
        move(to: previous)
    }
    private func invalidatePendingActions() {
        progress.invalidate()
        cancelOwnedTrial()
        tourSession.cancel()
    }
    private func cancelOwnedTrial() {
        let wasRunning = trialRunning && trialTicket != nil
        trialTicket = nil
        trialRunning = false
        if wasRunning { cancelTrial() }
    }
    private func stageBuiltInMacSetup() {
        invalidatePendingActions()
        useBuiltInMacSetup = true
        plan.recognitionModelID = VoiceRecognitionSettings.appleModelID
        reviewingBuiltInMacSetup = true
        applyIssue = nil
    }
    private func applyPlan() -> Bool {
        // Nothing staged: nothing to save, and the guide moves on.
        if !useBuiltInMacSetup, reviewedPreferences == model.preferences { return true }
        applyIssue = apply(plan.patch(useBuiltInMacSetup: useBuiltInMacSetup))
        guard applyIssue == nil else { return false }
        plan = GuidedSetupPlan(preferences: model.preferences, targetLanguage: model.ordinaryTranslationTarget)
        useBuiltInMacSetup = false
        return true
    }
    private func applyAndTry() {
        guard canTry else { return }
        let ticket = progress.beginForward()
        let step = progress.step
        if selectedLocalModel != nil {
            Task { @MainActor in
                await verifySelectedModel()
                guard visible, progress.accepts(ticket, at: step), recognitionReady else { return }
                launchTrial()
            }
        } else {
            launchTrial()
        }
    }
    private func launchTrial() {
        guard canTry, applyPlan() else { return }
        progress.invalidate()
        guard let startTrial else {
            tryDictation()
            return
        }
        let ticket = UUID()
        let visit = progress.visit
        trialTicket = ticket
        trialRunning = true
        trialFailure = nil
        startTrial { outcome in
            Task { @MainActor in
                guard visible, progress.step == .trial, progress.visit == visit, trialTicket == ticket else { return }
                trialTicket = nil
                trialRunning = false
                switch outcome {
                case .recognized(let text):
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        trialFailure = L10n.tr("No speech was recognized.")
                    } else {
                        // Only new words ease in; cancelling or leaving never waits on an animation.
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { acceptedTrialText = text }
                    }
                case .failed(let message): trialFailure = message
                case .cancelled: break
                }
            }
        }
    }
    // Skip, or Continue after a trial: the reviewed choices apply as for Try.
    private func showMoreWays() {
        guard visible, progress.step == .trial else { return }
        invalidatePendingActions()
        guard applyPlan() else { return }
        move(to: .more)
    }
    private func tryFeature(_ task: GuidedTourTask) {
        guard visible, [.translation, .writing, .more].contains(progress.step), let tour, tourSession.running == nil
        else { return }
        let sample = GuidedTourSample.text, language = GuidedTourSample.language
        switch task {
        case .translate:
            let target = GuidedTourSample.target(model.preferences, ordinaryTarget: model.ordinaryTranslationTarget)
            let caption = languageName(target)
            // Never a language into itself: with one language, the sample arrives in another.
            if let foreign = GuidedTourSample.foreign(into: target) {
                tourSession.run(
                    .translate, caption: L10n.format("%1$@ → %2$@", languageName(foreign.language), caption),
                    language: target, source: GuidedTourSession.Source(text: foreign.text)
                ) { try await tour.translate(foreign.text, foreign.language, target) }
            } else {
                tourSession.run(.translate, caption: caption, language: target) {
                    try await tour.translate(sample, language, target)
                }
            }
        case .refine:
            guard writingReadiness == .ready else { return }
            let choice = model.selectionWritingChoice
            let caption =
                choice.preset.map(DictationPresetPresentation.activeTitle)
                ?? WritingStylePresentation.title(choice.style)
            tourSession.run(.refine, caption: caption, language: language) { try await tour.refine(sample) }
        case .refineInPlace:
            guard writingReadiness == .ready, let row = model.preferences.outputs.refineInPlace.first else {
                return
            }
            let caption = OutputPresentation.name(row.output, preferences: model.preferences)
            tourSession.run(
                .refineInPlace, caption: caption, language: row.output.language ?? language, inPlace: true
            ) {
                try await tour.refineInPlace(sample)
            }
        case .readAloud:
            // Reads the shown result when there is one, otherwise the sample.
            let text = tourSession.outcome?.text ?? tourSession.rewritten ?? sample
            let spoken = tourSession.outcome?.language ?? language
            tourSession.speak(start: { tour.speak(text, spoken) }, stop: tour.stopSpeaking)
            if case .failed(let message) = tour.speech() { tourSession.speechEnded(issue: message) }
        case .editWithVoice, .editWithText:
            // The review window opens over the guide, which waits behind it at this step.
            guard writingReadiness == .ready, applyPlan() else { return }
            tourSession.beginRewrite()
            let session = tourSession
            let start = task == .editWithText ? tour.editWithText : tour.editWithVoice
            if !start(sample, { session.rewrite($0) }) {
                tourSession.refuse(L10n.tr("Finish or close the current dictation first."))
            }
        }
    }
    // An explicit click adds the mail app's What dictation writes row through the
    // same owner as the guide's other choices.
    private func addEmailRule() {
        guard visible, progress.step == .more, let mail = mailApplication,
            case .available = GuidedEmailRule.state(model.preferences, mail: mail)
        else { return }
        emailIssue = apply(emailPatch(add: mail))
    }
    // A paused row is turned on with its own click.
    private func turnOnEmailRule() {
        guard visible, progress.step == .more, let mail = mailApplication,
            case .added(enabled: false) = GuidedEmailRule.state(model.preferences, mail: mail)
        else { return }
        emailIssue = apply(emailPatch(enable: mail))
    }
    private func emailPatch(add: MailApplication? = nil, enable: MailApplication? = nil) -> GuidedSetupPatch {
        GuidedSetupPatch(
            targetLanguage: nil, recognitionModelID: nil, recognitionLanguage: nil, appleLocale: nil,
            previewFirst: nil, voicePlacement: nil, usesBuiltInMacSetup: false,
            emailRule: add, enablesEmailRule: enable)
    }
    private var tourSpeech: GuidedTourSpeech { tour?.speech() ?? .idle }
    private var apiKeyState: CredentialAccessState? { keyAccess.rows.first { $0.service == .textAPI }?.state }
    private var translationReadiness: GuidedEngineReadiness {
        GuidedEngineReadiness.resolve(
            engine: reviewedPreferences.engine, preferences: reviewedPreferences, keyState: apiKeyState)
    }
    private var writingReadiness: GuidedEngineReadiness {
        guard
            VoiceWritingConnection.isConfigured(reviewedPreferences)
                || reviewedPreferences.voiceRefinementEngine == "api"
        else { return .needsSetup(anchor: "text-services") }
        return GuidedEngineReadiness.resolve(
            engine: reviewedPreferences.voiceRefinementEngine, preferences: reviewedPreferences, keyState: apiKeyState)
    }
    // The button that makes a task runnable: allow the saved key, or set the service up here.
    // No writer yet, but Claude Code or Codex CLI is installed: one click uses it and the
    // Tries work at once; otherwise the service is set up as before.
    private var writeFix: GuidedTourFix? {
        if case .needsSetup = writingReadiness, let setup = installedCLIs.offers(reviewedPreferences).first {
            return .init(
                title: L10n.format("Use %@", setup.provider.displayName), status: L10n.tr("Not set up")
            ) { useInstalledCLI(setup) }
        }
        // Not set up: the Writing step sets it up (the tour's Set up… goes back there).
        if case .needsSetup = writingReadiness { return nil }
        return fix(for: writingReadiness)
    }
    private func useInstalledCLI(_ setup: CLIConfiguration) {
        guard visible else { return }
        var staged = plan
        staged.stageWriter(InstalledCLIs.choose(setup, writing: true, in: reviewedPreferences))
        editedPlan.wrappedValue = staged
        _ = applyPlan()
    }
    private func fix(for readiness: GuidedEngineReadiness) -> GuidedTourFix? {
        switch readiness {
        case .ready: return nil
        case .needsKeyAccess:
            return .init(title: L10n.tr("Allow access…"), status: L10n.tr("Needs access")) {
                keyAccess.allowAccess(for: .textAPI)
            }
        case .needsSetup(let anchor):
            // An API that is filled in but has no usable key says so, not "Not set up".
            let status =
                anchor == "api" && apiKeyState.map({ $0 == .noSavedKey }) == true
                ? L10n.tr("No saved key") : L10n.tr("Not set up")
            return .init(title: L10n.tr("Set up…"), status: status) { setUp(anchor) }
        }
    }
    private func setUp(_ anchor: String) {
        if let setUpService {
            setUpService(anchor)
        } else {
            openGuideSettings(.models, anchor, nil)
        }
    }
    // Refine in place's first row key, shown only while it registered.
    private var refineInPlaceKey: WelcomeEntryPoints.Key? {
        guard let row = model.preferences.outputs.refineInPlace.first,
            let key = model.preferences.outputShortcutKeys[row.id]
        else { return nil }
        return GuidedTourSample.key(ShortcutRegistry.refineRowBase, key, model: model)
    }
    private var moreWays: some View {
        GuidedTourStep(
            session: tourSession, canTry: tour != nil, speech: tourSpeech,
            yulloKey: GuidedTourSample.key(1, model.openKey, model: model),
            translateKey: GuidedTourSample.key(2, model.selectionKey, model: model),
            refineKey: GuidedTourSample.key(6, model.preferences.refineSelectionShortcut, model: model),
            refineInPlaceKey: refineInPlaceKey,
            writingAvailable: writingReadiness == .ready,
            translateFix: fix(for: translationReadiness), writeFix: writeFix,
            accessibilityMissing: permissions.status?.accessibility == false,
            microphoneMissing: permissions.status?.microphone.needsSettings == true,
            oneLanguage: model.preferences.usesOneLanguage,
            tryFeature: tryFeature, cancel: tourSession.cancel, showYullo: applyAndOpenTranslator,
            setUpWriting: { revisit(.writing) },
            enableAccessibility: permissions.accessibilityAction,
            mail: mailApplication,
            emailRule: mailApplication.map { GuidedEmailRule.state(model.preferences, mail: $0) } ?? .available,
            emailIssue: emailIssue, addEmailRule: addEmailRule, turnOnEmailRule: turnOnEmailRule,
            dictationKey: GuidedTourSample.key(3, model.preferences.dictationShortcut, model: model),
            editWithVoiceKey: model.preferences.outputShortcutKeys[Shortcut.editWithVoiceID].flatMap {
                GuidedTourSample.key(ShortcutRegistry.editWithVoiceID, $0, model: model)
            },
            editWithTextKey: model.preferences.outputShortcutKeys[Shortcut.editWithTextID].flatMap {
                GuidedTourSample.key(ShortcutRegistry.editWithTextID, $0, model: model)
            },
            dictationTried: !acceptedTrialText.isEmpty,
            tryDictation: { revisit(.trial) },
            openMicrophoneSettings: permissions.microphoneAction,
            openFormats: { openGuideSettings(.dictation, "output", nil) }
        )
        .onAppear { if mailApplication == nil { mailApplication = DefaultMailApplication.resolve() } }
        .onChange(of: tourSpeech) { previous, speech in
            guard tourSession.running == .readAloud else { return }
            if case .failed(let message) = speech {
                tourSession.speechEnded(issue: message)
            } else if speech == .idle, previous != .idle {
                tourSession.speechEnded(issue: nil, note: tour?.speechNote())
            }
        }
    }
    private func applyAndOpenTranslator() {
        guard applyPlan() else { return }
        invalidatePendingActions()
        openTranslator()
    }
    private func saveDraft() {
        guard !isClosing else { return }
        rememberDraft(.init(plan: plan, usesBuiltInMacSetup: useBuiltInMacSetup, step: progress.step))
    }
    private func openGuideSettings(_ page: SettingsPage, _ anchor: String?, _ task: ModelDiscoveryTask?) {
        saveDraft()
        invalidatePendingActions()
        isClosing = true
        openSettings(page, anchor, task)
    }
    private func closeSetup() {
        saveDraft()
        invalidatePendingActions()
        isClosing = true
        visible = false
        close()
    }
    // Done after a successful trial: setup is complete, so celebrate it.
    private func finishSetup() {
        #if !YULLO_TESTING
            SetupCelebration.playFromCurrentEvent()
        #endif
        invalidatePendingActions()
        isClosing = true
        visible = false
        (finished ?? close)()
    }
    private func rebasePlan() {
        let patch = plan.patch(useBuiltInMacSetup: useBuiltInMacSetup)
        let preferences = patch.applying(to: model.preferences)
        var rebased = GuidedSetupPlan(preferences: model.preferences, targetLanguage: model.ordinaryTranslationTarget)
        rebased.targetLanguage = patch.targetLanguage ?? model.ordinaryTranslationTarget
        rebased.recognitionModelID = preferences.voiceModelID
        rebased.recognitionLanguage = preferences.voiceRecognitionLanguage
        rebased.appleLocale = preferences.voiceAppleLocale
        rebased.previewFirst = preferences.voicePreviewFirst
        rebased.voicePlacement = preferences.voicePlacement
        rebased.keepLanguages(preferences.enabledLanguages)
        if plan != rebased {
            invalidatePendingActions()
            plan = rebased
        }
    }
}

// The guide's own recording: getting ready, listening, then turning speech
// into text. The guide starts before the recorder reports a phase, so an idle
// recorder still reads as getting ready.
enum GuidedTrialStage: Int, CaseIterable {
    case starting, listening, writing
    init(_ phase: VoiceInputPhase) {
        switch phase {
        case .recording, .paused: self = .listening
        case .transcribing, .translating, .refining, .delivering, .preview: self = .writing
        case .idle, .preparing, .cancelling, .error: self = .starting
        }
    }
    // Names every way this recording actually finishes: the pause with its
    // saved length, the dictation shortcut (left out when it failed to
    // register, as the recorder leaves it out) and Return, and that
    // transcribing follows.
    static func finishHint(_ preferences: Preferences, shortcutAvailable: Bool = true) -> String {
        let policy = preferences.effectiveVoiceFinishPolicy(
            forVoiceTranslation: false, shortcutAvailable: shortcutAvailable)
        let keys = [
            policy.finishOnShortcut ? preferences.dictationShortcut.displayLabel : nil,
            policy.finishOnReturn ? L10n.tr("Return") : nil
        ].compactMap { $0 }
        if policy.finishAfterPause {
            let pause = silence(preferences.voiceSilenceSeconds)
            switch keys.count {
            case 0: return L10n.format("Speak now. Stops after %@ of silence.", pause)
            case 1: return L10n.format("Speak now. Stops after %1$@ of silence or %2$@.", pause, keys[0])
            default:
                return L10n.format("Speak now. Stops after %1$@ of silence, %2$@ or %3$@.", pause, keys[0], keys[1])
            }
        }
        if keys.count == 2 {
            return L10n.format("Speak now. Press %1$@ or %2$@ to stop and transcribe.", keys[0], keys[1])
        }
        return L10n.format("Speak now. Press %@ to stop and transcribe.", keys.first ?? L10n.tr("Return"))
    }
    // "3 seconds", "2.5 seconds", in the interface language, kept on one line.
    static func silence(_ seconds: Double) -> String {
        Measurement(value: Preferences.normalizedVoiceSilenceSeconds(seconds), unit: UnitDuration.seconds).formatted(
            .measurement(width: .wide, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0...1)))
                .locale(L10n.locale)
        ).replacingOccurrences(of: " ", with: "\u{00A0}")
    }
}

// A trial has no text caret; with Near the caret, the recording indicator
// sits under this card instead. Settings reports its frame to the app.
private struct DictationTrialFrameKey: EnvironmentKey {
    static let defaultValue: ((CGRect) -> Void)? = nil
}
// The guide's Sample card reports its own frame, so a Try's window and pill sit by it.
private struct GuideSampleFrameKey: EnvironmentKey {
    static let defaultValue: ((CGRect) -> Void)? = nil
}
extension EnvironmentValues {
    var dictationTrialFrame: ((CGRect) -> Void)? {
        get { self[DictationTrialFrameKey.self] }
        set { self[DictationTrialFrameKey.self] = newValue }
    }
    var guideSampleFrame: ((CGRect) -> Void)? {
        get { self[GuideSampleFrameKey.self] }
        set { self[GuideSampleFrameKey.self] = newValue }
    }
}

// One surface for a dictation trial in Settings and the guide: Try dictation
// beside a quiet placeholder, then the running recording's stage, then the
// recognized words with Try again and Copy. A failure keeps the card empty
// or keeps the previous words, and offers Try again in the same place.
// Return on the guide's empty Try card starts the first try, but not a Return
// that came within moments of the step appearing (meant for Continue) or a
// held key's repeat.
// Voice access moves on by itself only when both rows become allowed while
// the person is on it and Yullo is in front again; never on a microphone
// alone, never when they came back to the step on purpose.
enum GuidedVoiceAccessAdvance {
    static func advances(
        step: GuidedSetupStep, previous: VoicePermissionStatus?, current: VoicePermissionStatus?, revisited: Bool,
        appActive: Bool
    ) -> Bool {
        guard step == .permissions, !revisited, appActive, let previous, let current else { return false }
        func both(_ value: VoicePermissionStatus) -> Bool { value.microphone == .authorized && value.accessibility }
        return both(current) && !both(previous)
    }
}
enum GuidedTrialReturn {
    static let settle: TimeInterval = 0.3
    static func accepts(sinceShown: TimeInterval, isRepeat: Bool) -> Bool { !isRepeat && sinceShown >= settle }
}
extension View {
    @ViewBuilder fileprivate func returnStarts(_ on: Bool) -> some View {
        if on { keyboardShortcut(.defaultAction) } else { self }
    }
}
struct DictationTrialCard: View {
    let running: Bool
    let text: String
    let showsPrevious: Bool
    let phase: VoiceInputPhase
    let level: @MainActor () -> Double
    let finishHint: String
    let cancel: () -> Void
    let start: () -> Void
    let canStart: Bool
    let failed: Bool
    // The dictation key as it is set now; with it, the empty card asks for the key itself.
    var startKey: WelcomeEntryPoints.Key? = nil
    // In the guide, ↩ starts the first try while the card is empty.
    var returnStarts = false
    @State private var shownAt = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dictationTrialFrame) private var reportFrame
    private func startFromReturn() {
        if returnStarts, let event = NSApp.currentEvent, event.type == .keyDown,
            !GuidedTrialReturn.accepts(sinceShown: Date().timeIntervalSince(shownAt), isRepeat: event.isARepeat)
        {
            return
        }
        start()
    }
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let empty = !running && text.isEmpty
        return VStack(alignment: .leading, spacing: 12) {
            if running {
                GuidedTrialActivity(phase: phase, level: level, finishHint: finishHint, cancel: cancel)
            }
            if !text.isEmpty {
                if running { Divider() }
                VStack(alignment: .leading, spacing: 6) {
                    if showsPrevious {
                        Text(L10n.tr("Previous result")).font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(text).font(.system(size: 14)).lineSpacing(2).textSelection(.enabled)
                        .foregroundStyle(running ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        .id(text)
                        .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 4)))
                    HStack(alignment: .top, spacing: 14) {
                        Spacer(minLength: 0)
                        if !running {
                            Button(action: start) {
                                Label(L10n.tr("Try Again"), systemImage: "arrow.clockwise")
                            }.buttonStyle(.borderless).font(.system(size: 12)).disabled(!canStart)
                                .background { startProbe }
                        }
                        GuideCopyButton(text: text)
                    }
                }
            } else if empty {
                // The real key first, so the first dictation is also the first use of it;
                // the button stays for a key that did not register or a mouse.
                HStack(spacing: 12) {
                    if let startKey, !failed {
                        GuideKeycap(key: startKey)
                        Text(L10n.tr("Press the dictation shortcut and say one sentence."))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button(L10n.tr("Try dictation"), action: startFromReturn).disabled(!canStart).fixedSize()
                            .returnStarts(returnStarts).background { startProbe }
                    } else {
                        Button(action: startFromReturn) {
                            Label(L10n.tr(failed ? "Try Again" : "Try dictation"), systemImage: "mic")
                        }.disabled(!canStart).fixedSize().returnStarts(returnStarts).background { startProbe }
                    }
                }
            }
        }
        // Only the running stage keeps a minimum height; empty and with
        // words, the card is its content plus 14 pt on every side.
        .padding(14).frame(maxWidth: .infinity, minHeight: running ? 78 : nil, alignment: .topLeading)
        .onAppear { shownAt = Date() }
        .background {
            // A faint tint over either theme reads as a field without a heavy box.
            if !empty { shape.fill(Color.primary.opacity(0.035)) }
        }
        .overlay {
            shape.strokeBorder(
                Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1, dash: empty ? [4, 3] : []))
        }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { reportFrame?($0) }
        .onDisappear { reportFrame?(.null) }
    }
    @ViewBuilder private var startProbe: some View {
        #if YULLO_TESTING
            YulloActionPresentationProbe(title: "trial-start", action: start)
        #endif
    }
}

private struct GuidedTrialActivity: View {
    let phase: VoiceInputPhase
    let level: @MainActor () -> Double
    let finishHint: String
    let cancel: () -> Void
    private var stage: GuidedTrialStage { GuidedTrialStage(phase) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            rail
            HStack(alignment: .center, spacing: 8) {
                status.frame(maxWidth: .infinity, alignment: .leading)
                Button(L10n.tr("Cancel"), action: cancel).controlSize(.small)
            }
        }
    }
    private func title(_ item: GuidedTrialStage) -> String {
        switch item {
        case .starting: return L10n.tr("Get ready")
        case .listening: return L10n.tr("Speak")
        case .writing:
            return L10n.tr(phase == .translating ? "Translate" : phase == .refining ? "Refine" : "Transcribe")
        }
    }
    private var rail: some View {
        HStack(spacing: 6) {
            ForEach(GuidedTrialStage.allCases, id: \.self) { item in
                if item != .starting {
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 14, height: 1)
                }
                HStack(spacing: 4) {
                    Image(
                        systemName: item.rawValue < stage.rawValue
                            ? "checkmark.circle.fill" : item == stage ? "circle.inset.filled" : "circle"
                    ).font(.system(size: 10))
                        .foregroundStyle(item.rawValue <= stage.rawValue ? Color.accentColor : Color.secondary)
                    Text(title(item)).font(.system(size: 11, weight: item == stage ? .semibold : .regular))
                        .foregroundStyle(item == stage ? .primary : .secondary).lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            L10n.format("%@, step %ld of %ld", title(stage), stage.rawValue + 1, GuidedTrialStage.allCases.count))
    }
    @ViewBuilder private var status: some View {
        switch stage {
        case .starting: ActivityStatus(title: L10n.tr("Preparing microphone…"))
        case .listening where phase == .paused:
            ActivityStatus(
                title: L10n.tr("Paused. Resume in the recording indicator."), glyph: .paused, elapsedAfter: nil)
        case .listening:
            HStack(spacing: 6) {
                ActivityLevelBars(sample: level)
                Text(finishHint).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }.accessibilityElement(children: .combine)
        case .writing:
            ActivityStatus(
                title: L10n.tr(phase == .transcribing ? "Turning your speech into text…" : "Finishing your text…"))
        }
    }
}

// Copy feedback belongs to this trial result and never replaces its error or readiness state.
@MainActor struct GuideCopyButton: View {
    let text: String
    var write: (String) -> Bool = { value in
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(value, forType: .string)
    }
    #if YULLO_TESTING
        var report: ((Bool?) -> Void)?
    #endif
    @State private var feedback: Bool?
    @State private var receipt = UUID()
    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Button(action: copy) {
                Label(
                    L10n.tr(feedback == true ? "Copied" : "Copy"),
                    systemImage: feedback == true ? "checkmark" : "doc.on.doc")
            }.buttonStyle(.borderless).font(.system(size: 12))
                .background {
                    #if YULLO_TESTING
                        YulloActionPresentationProbe(title: "Copy trial result", action: copy)
                    #endif
                }
                .disabled(text.isEmpty)
            if feedback == false {
                Text(L10n.tr("Couldn’t copy. Try again."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: text) { _, _ in
            feedback = nil
            receipt = UUID()
        }
        .task(id: receipt) {
            guard feedback != nil else { return }
            let current = receipt
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard !Task.isCancelled, receipt == current else { return }
            feedback = nil
        }
        #if YULLO_TESTING
            .onAppear { report?(feedback) }
            .onChange(of: feedback) { _, value in report?(value) }
        #endif
    }
    private func copy() {
        guard !text.isEmpty else { return }
        feedback = write(text)
        receipt = UUID()
    }
}

// Sizes the guide's window so the step fits: the window's height less the
// step's room, plus the step's own height. The target is absolute, so repeated
// updates settle on one height; it keeps the top edge, the minimum and the screen.
private struct GuideWindowFit: NSViewRepresentable {
    let step: CGFloat
    let room: CGFloat
    final class Coordinator { var generation = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        guard step > 0, room > 0, abs(step - room) >= 1 else { return }
        let (step, room) = (step, room)
        let coordinator = context.coordinator
        coordinator.generation &+= 1
        let generation = coordinator.generation
        // Only the latest measurement applies, once the view is in its window.
        DispatchQueue.main.async {
            // Only a window set up for setup follows the step (Settings focused on setup).
            guard coordinator.generation == generation, let window = view.window,
                GuideWindowFollowing.contains(window)
            else { return }
            let content = window.contentRect(forFrameRect: window.frame)
            let chrome = window.frame.height - content.height
            let screen = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? .greatestFiniteMagnitude
            let target = min(
                max(content.height - room + step, window.contentMinSize.height, 360), screen - chrome)
            guard abs(target - content.height) >= 1 else { return }
            var frame = window.frame
            frame.origin.y += frame.height - (target + chrome)
            frame.size.height = target + chrome
            window.setFrame(frame, display: true)
        }
    }
}

// Windows focused on setup, whose height follows the guide's step.
// Held weakly, so a closed window never stands in for a later one.
enum GuideWindowFollowing {
    nonisolated(unsafe) private static let windows = NSHashTable<NSWindow>.weakObjects()
    static func add(_ window: NSWindow) { windows.add(window) }
    static func remove(_ window: NSWindow) { windows.remove(window) }
    static func contains(_ window: NSWindow) -> Bool { windows.contains(window) }
}
