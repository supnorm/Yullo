import SwiftUI
import Translation

// The connection editors a task page or the guide can open in place.
enum SettingsConnectionSheet: String, Identifiable {
    case ollama, api, cli, all = "text-services"
    var id: String { rawValue }
}

enum SettingsSetupSheet: String, Identifiable {
    case processing
    var id: String { rawValue }
}
private struct SettingsAppleLanguageManagerRequest: Identifiable {
    let id = UUID()
    let source: String
    let target: String
}

struct SettingsCustomizationSection<Content: View>: View {
    let group: SettingsCustomizationGroup
    let title: String
    let isExpanded: Binding<Bool>
    let summary: String?
    let nested: Bool
    let collapsible: Bool
    let content: Content

    init(
        _ group: SettingsCustomizationGroup, title: String, isExpanded: Binding<Bool>, summary: String? = nil,
        nested: Bool = false, collapsible: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.group = group
        self.title = title
        self.isExpanded = isExpanded
        self.summary = summary
        self.nested = nested
        self.collapsible = collapsible
        self.content = content()
    }

    var body: some View {
        SettingsSection(title, isExpanded: isExpanded, summary: summary, nested: nested, collapsible: collapsible) {
            content.background {
                #if YULLO_TESTING
                    YulloActionPresentationProbe(title: "Customization content: " + group.rawValue, action: {})
                #endif
            }
        }.accessibilityIdentifier("settings-customization-" + group.rawValue)
            .background {
                #if YULLO_TESTING
                    if collapsible {
                        YulloActionPresentationProbe(
                            title: "Customization toggle: " + group.rawValue,
                            action: { isExpanded.wrappedValue.toggle() })
                    }
                #endif
            }
            .id(group.rawValue)
    }
}

#if YULLO_TESTING
    struct SettingsAttachedBindings {
        let draft: Binding<Preferences>
        let voiceLanguage: Binding<String>
        let connections: [SettingsConnectionSection: Binding<Bool>]
        let localModelTask: Binding<ModelDiscoveryTask>
        let activateSearch: (SettingsSearchEntry) -> Void
        let applySetup: (QuickSetupPatch) -> String?
        let setupActions: SettingsAttachedSetupActions
        let tryDictation: () -> Void
        let canTryDictation: () -> Bool
        let openTrialRecognition: () -> Void
        let clearRecentResult: () -> Void
        let historySettingsPresented: Binding<Bool>
        let customizations: [SettingsCustomizationGroup: Binding<Bool>]
        let page: () -> SettingsPage
        let speechSession: SpeechSettingsSession
        let playbackSession: SpeechSettingsSession
        let setupSheet: () -> SettingsSetupSheet?
        let guidePresented: () -> Bool
        let openExperienceSetup: () -> Void
        let resumeGuide: () -> (() -> Void)?
        let guideDraft: () -> GuidedSetupDraft?
        let setupGuideTitle: () -> String
        let applyGuidedSetup: (GuidedSetupPatch) -> String?
        let appleLanguageManagerRequest: () -> (source: String, target: String)?
        let closeAppleLanguageManager: () -> Void
        let revealedSections: () -> Set<SettingsVisibilitySection>
    }
    struct SettingsAttachedSetupActions {
        let openGeneral: () -> Void
        let openRefinement: () -> Void
        let openSpeech: () -> Void
        let openTranslation: () -> Void
        let openServices: () -> Void
        let openService: (SettingsConnectionSection) -> Void
        let openLocalModels: (ModelDiscoveryTask) -> Void
    }
#endif

// Removes the Settings sidebar while the guide is focused, so neither its
// pages nor its search can be reached or read in that view.
private struct SettingsSidebarPresence: ViewModifier {
    let shown: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if shown { content }
    }
}

@MainActor
struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.solidWindowStyle) private var solidWindowStyle
    @State private var hoveredPage: SettingsPage?
    @ObservedObject var model: Model
    @ObservedObject var voiceInput: VoiceInputCoordinator
    @ObservedObject var voiceModels = VoiceModelStore.shared
    let saveShortcuts: (Shortcut, Shortcut, Shortcut, Shortcut, Shortcut, Shortcut) -> String?
    let close: () -> Void
    private let tryDictation: (() -> Void)?
    private let tryGuidedDictation: ((@escaping (VoiceTrialOutcome) -> Void) -> Void)?
    private let prepareGuidedDictation: (() -> Void)?
    private let cancelGuidedDictation: (() -> Void)?
    private let guideTour: GuidedTourActions?
    private let openTranslator: (() -> Void)?
    private let openRecentResult: (() -> Void)?
    private let historyController: ResultHistoryController?
    private let openHistoryResult: ((ResultHistoryEntry, Bool) -> Void)?
    var commitCoordinator = SettingsCommitCoordinator()
    var credentialCommitter = SettingsCredentialCommitter()
    var initialAnchor: String? = nil
    // The window owner sizes and titles the focused setup view. It is told
    // synchronously when the guide opens and when it ends.
    var setupFocusChanged: ((Bool) -> Void)? = nil
    var trialFrameChanged: ((CGRect) -> Void)? = nil
    var sampleFrameChanged: ((CGRect) -> Void)? = nil
    // Settings was opened from another window, which closing returns to; a
    // finished errand there (allowing saved key access) closes it too.
    private let requestedInitialPage: SettingsPage?
    #if YULLO_TESTING
        var yulloTestingCaptureAttachedSettingsBindings: ((SettingsAttachedBindings) -> Void)?
        var yulloTestingRecentClearEnabled: ((Bool) -> Void)?
    #endif
    @AppStorage("yullo.settingsPage") private var rememberedPage = "General"
    @AppStorage("yullo.settingsCommandLineExpanded") private var commandLineExpanded: Bool?
    @State private var ready = false
    @State private var settingsPresented = false
    @State private var page = SettingsPage.general
    @State private var search = ""
    // The result Return opens: the first one, moved with ↑ and ↓.
    @State private var searchSelection = 0
    @FocusState private var searchFocused: Bool
    @State private var navigationTarget: String?
    // The row a menu item or search result landed on, lit briefly so the eye finds it.
    @State private var landedAnchor: String?
    @State private var customizationOverrides: [SettingsCustomizationGroup: Bool] = [:]
    @State private var revealedSections: Set<SettingsVisibilitySection> = []
    @State private var moreShortcutsExpanded = false
    @FocusState private var connectionField: ConnectionField?
    private enum ConnectionField: Hashable { case apiEndpoint, apiModel, cliPath, cliModel }
    @State private var draft: Preferences
    @State private var appliedConfiguration: Preferences
    @State private var first: Shortcut
    @State private var second: Shortcut
    @State private var appliedOpenShortcut: Shortcut
    @State private var appliedSelectionShortcut: Shortcut
    @State private var apiKey = ""
    @FocusState private var apiKeyFocused: Bool
    @State private var speechKeys: [String: String] = [:]
    @State private var autosaveTask: Task<Void, Never>?
    @State private var isDraggingTextSize = false
    @State private var persistenceIssue = ""
    // A short-lived footer after the mode changed: which tasks moved to this
    // Mac, or which online choice allowed online, and the settings Undo returns to.
    @State private var switchNotice: (message: String, previous: Preferences)?
    @State private var skipSwitchNotice = false
    @State private var credentialIssue = ""
    @StateObject private var actionFeedback: SettingsActionFeedback
    @StateObject private var speechConnectionSession = SpeechSettingsSession()
    @StateObject private var speechPlaybackSession = SpeechSettingsSession()
    @State private var expandedConnections: Set<SettingsConnectionSection>
    @State private var setupSheet: SettingsSetupSheet?
    @State private var setupGeneration = UUID()
    @State private var guidedDraft: GuidedSetupDraft?
    @State private var guidePresented = false
    // A guide started from a Settings page returns there; one that opened Settings closes it.
    @State private var guideReturnsToSettings = false
    // Set when a guide link opened a Settings page; Done resumes
    // the guide at the step the person left.
    @State private var guideReturnAvailable = false
    @State private var guidedTrialGeneration: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Quick setup's own trial runs in place, like the guide's.
    @State private var quickTrialTicket: UUID?
    @State private var quickTrialText = ""
    @State private var quickTrialFailure: String?
    @State private var quickSetupConnection = SettingsConnectionSection.api
    @State private var localModelTask = ModelDiscoveryTask.dictation
    // Set when a link or search result asks for the model Browse list.
    @State private var modelBrowseRequest: UUID?
    @State private var showModelLibrary = false
    // A connection set up from a task page or the guide opens here, over the page.
    @State private var connectionSheet: SettingsConnectionSheet?
    // One silent check of the saved API key for every engine row on every page.
    @StateObject private var textKeyAccess = CredentialAccessController(backend: GuidedSetupView.keyBackend)
    @State private var speechConnectionProvider: SpeechProvider?
    @State private var testTask: Task<Void, Never>?
    @State private var showCLIGuide = false
    @State private var showThirdPartyNotices = false
    @State private var showPersonalVocabulary = false
    @State private var historySettingsPresented = false
    @FocusState private var thirdPartyNoticesFocused: Bool
    @State private var cliCatalog: CLIModelCatalog?
    @State private var cliDetectedPath: String?
    @State private var cliModelRevision = 0
    private let cliClient = CLIClient()
    @State private var confirmForgetKey = false
    @State private var voiceLanguage: String
    @State private var supportedAppleLanguages: [Locale.Language]?
    @State private var appleLanguageManagerRequest: SettingsAppleLanguageManagerRequest?
    init(
        model: Model, voiceInput: VoiceInputCoordinator, voiceModels: VoiceModelStore? = nil,
        saveShortcuts: @escaping (Shortcut, Shortcut, Shortcut, Shortcut, Shortcut, Shortcut) -> String?,
        close: @escaping () -> Void,
        commitCoordinator: SettingsCommitCoordinator? = nil,
        credentialCommitter: SettingsCredentialCommitter? = nil, initialAnchor: String? = nil,
        initialPage: SettingsPage? = nil, actionFeedback: SettingsActionFeedback? = nil,
        initialModelTask: ModelDiscoveryTask? = nil, tryDictation: (() -> Void)? = nil,
        tryGuidedDictation: ((@escaping (VoiceTrialOutcome) -> Void) -> Void)? = nil,
        cancelGuidedDictation: (() -> Void)? = nil, prepareGuidedDictation: (() -> Void)? = nil,
        guideTour: GuidedTourActions? = nil,
        openTranslator: (() -> Void)? = nil, openRecentResult: (() -> Void)? = nil,
        historyController: ResultHistoryController? = nil,
        openHistoryResult: ((ResultHistoryEntry, Bool) -> Void)? = nil
    ) {
        self.model = model
        self.voiceInput = voiceInput
        self.voiceModels = voiceModels ?? .shared
        self.saveShortcuts = saveShortcuts
        self.close = close
        self.tryDictation = tryDictation
        self.tryGuidedDictation = tryGuidedDictation
        self.prepareGuidedDictation = prepareGuidedDictation
        self.cancelGuidedDictation = cancelGuidedDictation
        self.guideTour = guideTour
        self.openTranslator = openTranslator
        self.openRecentResult = openRecentResult
        self.historyController = historyController
        self.openHistoryResult = openHistoryResult
        self.commitCoordinator = commitCoordinator ?? SettingsCommitCoordinator()
        self.credentialCommitter = credentialCommitter ?? SettingsCredentialCommitter()
        self.initialAnchor = initialAnchor
        self.requestedInitialPage = initialPage
        _guidedDraft = State(initialValue: GuidedSetupResume.draft)
        _draft = State(initialValue: model.preferences)
        _appliedConfiguration = State(initialValue: model.preferences)
        _first = State(initialValue: model.openKey)
        _second = State(initialValue: model.selectionKey)
        _appliedOpenShortcut = State(initialValue: model.openKey)
        _appliedSelectionShortcut = State(initialValue: model.selectionKey)
        _voiceLanguage = State(initialValue: model.targetLanguage)
        _localModelTask = State(
            initialValue: ModelCatalogPresentation.initialTask(
                preferences: model.preferences, requested: initialModelTask))
        _page = State(initialValue: initialPage ?? .general)
        _actionFeedback = StateObject(wrappedValue: actionFeedback ?? SettingsActionFeedback())
        // Services opens with every editor closed; only a connection with a result to show stays open.
        var expanded = Set<SettingsConnectionSection>()
        if actionFeedback?.message(for: .api) != nil { expanded.insert(.api) }
        if actionFeedback?.message(for: .cli) != nil { expanded.insert(.cli) }
        _expandedConnections = State(initialValue: expanded)
    }
    var body: some View {
        settingsConnections
            .environment(\.dictationTrialFrame, trialFrameChanged)
            .environment(\.guideSampleFrame, sampleFrameChanged)
            .environment(\.setUpWritingService, WritingServiceSetUp(open: openServices))
            .environment(\.allowOnline, AllowOnline(allow: { processingSelection.wrappedValue = .standard }))
            .environment(
                \.engineKeyAccess,
                EngineKeyAccess(
                    state: textKeyAccess.rows.first { $0.service == .textAPI }?.state,
                    working: textKeyAccess.isWorking, allow: { textKeyAccess.allowAccess(for: .textAPI) })
            )
            .onAppear { syncEngineKeyCheck() }
            .onChange(of: page) { _, _ in syncEngineKeyCheck() }
            .onChange(of: guidePresented) { _, _ in syncEngineKeyCheck() }
            .onDisappear { textKeyAccess.disappear() }
            .onChange(of: draft.endpoint) { _, _ in
                textKeyAccess.configure(CredentialAccessTargets.make(draft), inspecting: [.textAPI])
            }
            // A key saved in the setup sheet is checked again, without a prompt, as the sheet closes.
            .onChange(of: connectionSheet) { _, sheet in
                if sheet == nil, textKeyAccess.canCheck { textKeyAccess.check(.textAPI) }
            }
            .sheet(isPresented: $showCLIGuide) { cliGuide.glassSheet() }
            .sheet(isPresented: $showModelLibrary) { modelLibrarySheet.glassSheet() }
            .sheet(item: $connectionSheet) { connectionSheetContent($0).glassSheet() }
            .sheet(item: $setupSheet, onDismiss: finishSetupDismissal) { setupContent($0).glassSheet() }
            .sheet(isPresented: $showThirdPartyNotices, onDismiss: { thirdPartyNoticesFocused = true }) {
                ThirdPartyNoticesView { showThirdPartyNotices = false }.glassSheet()
            }
            .sheet(isPresented: $showPersonalVocabulary) {
                PersonalVocabularySettingsView(
                    configuration: $draft.personalVocabulary,
                    localizedLanguageNames: draft.showLocalizedLanguageNames,
                    close: { showPersonalVocabulary = false }
                ).glassSheet()
            }
            .sheet(item: $appleLanguageManagerRequest) { request in
                AppleTranslationAssetsView(
                    source: request.source, target: request.target,
                    localizedLanguageNames: draft.showLocalizedLanguageNames,
                    close: { appleLanguageManagerRequest = nil }
                ).glassSheet()
            }
    }
    // The selected row is the same white surface as the cards, so accent
    // stays on its icon alone. Hover is a faint neutral wash.
    @ViewBuilder private func rowBackground(_ section: SettingsPage) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if page == section && search.isEmpty {
            Color.clear.modifier(
                SettingsCardSurface(
                    cornerRadius: 8, darkFill: 0.11, solidDarkFill: 0.10, lightFill: 0.90, solidLightFill: 1))
        } else if hoveredPage == section {
            shape.fill(Color.primary.opacity(0.05))
        }
    }
    // While the guide is open it is the whole window: no sidebar or page
    // chrome, only the guide with its own step rail.
    private var setupFocused: Bool { page == .setup && guidePresented }
    private var settingsLayout: some View {
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Text(L10n.tr("Settings")).font(.system(size: 19, weight: .semibold)).lineLimit(1)
                        .minimumScaleFactor(0.85)
                }.padding(.horizontal, 6).padding(.top, 18)
                // The sidebar's fill is tuned to the window's glass or solid surface.
                SearchCapsule(
                    prompt: L10n.tr("Search Settings"), text: $search, focus: $searchFocused,
                    fill: AnyShapeStyle(
                        Color.primary.opacity(
                            colorScheme == .dark ? (solidWindowStyle ? 0.08 : 0.10) : (solidWindowStyle ? 0.05 : 0.06)))
                )
                .onChange(of: search) { searchSelection = 0 }
                .onSubmit {
                    let matches = SettingsSearch.results(
                        for: search, hiding: SettingsSearch.hiddenAnchors(draft))
                    if matches.indices.contains(searchSelection) {
                        activateSearchResult(matches[searchSelection])
                    }
                }
                .onKeyPress(.downArrow) { moveSearchSelection(1) }
                .onKeyPress(.upArrow) { moveSearchSelection(-1) }
                ScrollView {
                    VStack(spacing: 2) {
                        if !search.isEmpty {
                            searchResults
                        } else {
                            ForEach(SettingsPage.displayOrder) { section in
                                Button {
                                    if page != section { navigate(to: section) }
                                    search = ""
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: section.symbol)
                                            .font(.system(size: section == .translation ? 13 : 15, weight: .regular))
                                            .foregroundStyle(
                                                page == section && search.isEmpty
                                                    ? AnyShapeStyle(Palette.accent) : AnyShapeStyle(.primary)
                                            )
                                            .frame(width: 22, height: 22).accessibilityHidden(true)
                                        Text(section.title)
                                            .font(
                                                .system(
                                                    size: 13,
                                                    weight: page == section && search.isEmpty ? .semibold : .regular)
                                            )
                                            .lineLimit(2).multilineTextAlignment(.leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading).padding(
                                        .horizontal, 12
                                    )
                                    .accessibilityElement(children: .ignore).accessibilityLabel(section.title)
                                    .help(section.title)
                                    .contentShape(Rectangle())
                                    .background { rowBackground(section) }
                                    .onHover { inside in
                                        withAnimation(.easeOut(duration: 0.12)) {
                                            if inside {
                                                hoveredPage = section
                                            } else if hoveredPage == section {
                                                hoveredPage = nil
                                            }
                                        }
                                    }
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }.smallNativeScrollbars().frame(maxHeight: .infinity)
                HStack(spacing: 9) {
                    Image(
                        nsImage: colorScheme == .dark ? BrandArtwork.darkSettingsIcon : BrandArtwork.lightSettingsIcon
                    )
                    .resizable().frame(width: 24, height: 24).accessibilityHidden(true)
                    Text("Yullo").font(BrandTypography.wordmark(size: 19)).tracking(-0.5)
                }.padding(.horizontal, 12).padding(.vertical, 10)
                    .accessibilityElement(children: .combine).accessibilityIdentifier("settings-brand")
            }.padding(.horizontal, 6).frame(width: 194)
                .padding([.leading, .bottom], 8)
                .modifier(SettingsSidebarPresence(shown: !setupFocused))
            VStack(alignment: .leading, spacing: 0) {
                if setupFocused {
                    guideContent(embedded: false).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    HStack(alignment: .center) {
                        Text(page.title).font(.system(size: 22, weight: .semibold)).accessibilityAddTraits(.isHeader)
                        Spacer()
                        if page == .history, historyController != nil {
                            Button {
                                historySettingsPresented = true
                            } label: {
                                Image(systemName: "gearshape").foregroundStyle(.primary)
                            }
                            .buttonStyle(.borderless).frame(width: 28, height: 28)
                            .accessibilityLabel(L10n.tr("History settings")).help(L10n.tr("History settings"))
                            .accessibilityIdentifier("history-settings")
                            .popover(isPresented: $historySettingsPresented) {
                                if let historyController {
                                    ResultHistorySettingsView(
                                        controller: historyController, enabled: $draft.resultHistoryEnabled,
                                        retention: historyRetention)
                                }
                            }
                        }
                    }.padding(.bottom, 14)
                    if page == .history {
                        recentResultSettings.padding(.bottom, 16)
                        historySettings.frame(maxWidth: .infinity, maxHeight: .infinity)
                            .task(id: navigationTarget) {
                                guard !Task.isCancelled, page == .history, let target = navigationTarget else { return }
                                if target == "history-settings" { historySettingsPresented = true }
                                navigationTarget = nil
                            }
                    } else {
                        ScrollViewReader { reader in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 22) {
                                    switch page {
                                    case .translation: translationSettings
                                    case .refine: refineSettings
                                    case .dictation:
                                        VStack(alignment: .leading, spacing: 0) {
                                            DictationSettingsView(
                                                draft: $draft, models: voiceModels, voice: voiceInput,
                                                openModels: {
                                                    localModelTask = .dictation
                                                    navigate(to: .models, anchor: "model-browse")
                                                },
                                                revealedSections: revealedSections,
                                                isPresented: commitCoordinator.isPresented,
                                                takenShortcuts: takenShortcuts, openServices: openServices)
                                        }.id("dictation")
                                    case .models: modelsSettings
                                    // History owns its fill-space browser outside this scroll view.
                                    case .history: EmptyView()
                                    case .about: aboutSettings
                                    case .setup: setupSettings
                                    case .general: general
                                    case .languages: languageSettings.id("catalog")
                                    case .speech: voice
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 8).id("top")
                                    .smallNativeScrollbars()
                                    .environment(\.openSavedKeyAccess) { navigate(to: .setup, anchor: "keychain") }
                            }
                            // The scroller takes the page margin, so cards keep their edge.
                            .settingsScrollGutter().padding(.trailing, -NativeScrollGutter.width)
                            .task(id: page.rawValue + "|" + (navigationTarget ?? "")) {
                                guard let target = navigationTarget else { return }
                                let targetPage = page
                                await Task.yield()
                                guard !Task.isCancelled, page == targetPage, navigationTarget == target else { return }
                                reader.scrollTo(target, anchor: .top)
                                navigationTarget = nil
                                landedAnchor = target
                            }
                            .task(id: landedAnchor) {
                                guard landedAnchor != nil else { return }
                                try? await Task.sleep(for: .milliseconds(300))
                                guard !Task.isCancelled else { return }
                                withAnimation(.easeOut(duration: 0.6)) { landedAnchor = nil }
                            }
                            .environment(\.settingsLandedAnchor, landedAnchor)
                            .onChange(of: page) { _, _ in reader.scrollTo("top", anchor: .top) }
                        }
                    }
                    if !credentialIssue.isEmpty || !persistenceIssue.isEmpty {
                        Text(!credentialIssue.isEmpty ? credentialIssue : persistenceIssue)
                            .font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
                            .padding(.vertical, 9)
                    }
                    Divider().padding(.top, 10)
                    HStack {
                        if let switchNotice {
                            Text(switchNotice.message).font(.system(size: 12)).foregroundStyle(.secondary)
                                .lineLimit(2).accessibilityIdentifier("settings-switch-notice")
                            Button(L10n.tr("Undo"), action: undoSwitch).buttonStyle(.link).font(.system(size: 12))
                                .accessibilityIdentifier("settings-switch-undo")
                                .task(id: switchNotice.message) {
                                    // Said once: it fades after a few seconds.
                                    try? await Task.sleep(for: .seconds(8))
                                    guard !Task.isCancelled else { return }
                                    withAnimation(.easeOut(duration: 0.4)) { self.switchNotice = nil }
                                }
                        }
                        Spacer()
                        // Done returns to where Settings was entered from: the
                        // guide step a guide link left, otherwise the window
                        // Settings was opened from (handled as it closes).
                        Button {
                            if guideReturnAvailable {
                                cancelTest()
                                resumeGuide()
                                return
                            }
                            commitCoordinator.perform {
                                cancelTest()
                                close()
                            }
                        } label: {
                            // After a guide link, the way back says where it goes.
                            Text(L10n.tr(guideReturnAvailable ? "Back to Setup" : "Done"))
                        }.buttonStyle(.bordered).controlSize(.large).keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("settings-done")
                    }.padding(.top, 14)
                }
            }.padding(setupFocused ? 0 : 26).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.frame(
            minWidth: (setupFocused ? AppWindowSizing.setupMinimum : AppWindowSizing.settingsMinimum).width,
            maxWidth: .infinity,
            minHeight: (setupFocused ? AppWindowSizing.setupMinimum : AppWindowSizing.settingsMinimum).height,
            maxHeight: .infinity
        ).groupBoxStyle(SettingsCardGroupBoxStyle()).toggleStyle(SettingsRowToggleStyle())
            .environment(\.locale, L10n.locale)
            .environment(\.localizedLanguageNames, draft.showLocalizedLanguageNames)

    }
    private var settingsLifecycle: some View {
        settingsLayout
            .onAppear {
                settingsPresented = true
                let firstAppearance = !ready
                draft = model.preferences
                appliedConfiguration = model.preferences
                voiceInput.configureRecentResultRetention(model.preferences)
                voiceInput.configureResultPreferences(model.preferences)
                first = model.openKey
                second = model.selectionKey
                appliedOpenShortcut = model.openKey
                appliedSelectionShortcut = model.selectionKey
                voiceLanguage = model.targetLanguage
                page = SettingsPage.destination(
                    firstAppearance
                        ? (requestedInitialPage ?? SettingsPage.stored(rememberedPage) ?? .general)
                        : (SettingsPage.stored(rememberedPage) ?? .general), anchor: initialAnchor)
                normalizeLanguagePickers()
                ready = true
                commitCoordinator.commitDraft = { commitEdits() }
                commitCoordinator.focusSearch = { searchFocused = true }
                if firstAppearance {
                    let anchor = resolvedAnchor(initialAnchor)
                    reveal(anchor)
                    navigationTarget = anchor
                    if anchor == "experience-setup" { openGuide(resuming: false, fromSettings: false) }
                    // Opened plainly, Settings is ready to search: type a setting's name and ↩.
                    // Not when it opens at a row, or hosts the guide.
                    if initialAnchor == nil, !guidePresented {
                        DispatchQueue.main.async { if !guidePresented { searchFocused = true } }
                    }
                }
                #if YULLO_TESTING
                    yulloTestingCaptureAttachedSettingsBindings?(
                        .init(
                            draft: $draft, voiceLanguage: $voiceLanguage,
                            connections: [
                                .api: connectionExpansion(.api), .cli: connectionExpansion(.cli),
                                .speech: connectionExpansion(.speech)
                            ],
                            localModelTask: $localModelTask,
                            activateSearch: activateSearchResult, applySetup: applyQuickSetup,
                            setupActions: .init(
                                openGeneral: openQuickSetup, openRefinement: openRefinementServices,
                                openSpeech: openSpeechProcessingSetup, openTranslation: openTranslationProcessingSetup,
                                openServices: finishQuickSetupServices,
                                openService: openQuickSetupService, openLocalModels: openQuickSetupLocalModels),
                            tryDictation: startDictationTrial, canTryDictation: { trialCanStart },
                            openTrialRecognition: openTrialRecognition,
                            clearRecentResult: voiceInput.clearRecentResult,
                            historySettingsPresented: $historySettingsPresented,
                            customizations: Dictionary(
                                uniqueKeysWithValues: SettingsCustomizationGroup.allCases.map {
                                    ($0, customizationExpansion($0))
                                }),
                            page: { page }, speechSession: speechConnectionSession,
                            playbackSession: speechPlaybackSession, setupSheet: { setupSheet },
                            guidePresented: { guidePresented },
                            openExperienceSetup: openExperienceSetup,
                            resumeGuide: availableGuideReturn,
                            guideDraft: { guidedDraft }, setupGuideTitle: { setupGuideTitle },
                            applyGuidedSetup: applyGuidedSetup,
                            appleLanguageManagerRequest: {
                                appleLanguageManagerRequest.map { (source: $0.source, target: $0.target) }
                            }, closeAppleLanguageManager: { appleLanguageManagerRequest = nil },
                            revealedSections: { revealedSections }))
                #endif
            }
            .onChange(of: page) { _, value in
                rememberedPage = value.rawValue
                if value != .translation { appleLanguageManagerRequest = nil }
            }
            .onChange(of: draft) { old, new in
                // Choosing an online service on this Mac only allows online and
                // keeps the choice. A rebase onto saved settings isn't a choice.
                if let (allowed, task) = new.allowingOnline(after: old),
                    model.preferences[engineOf: task] != new[engineOf: task]
                {
                    draft = allowed
                    switchNotice = (
                        L10n.format("Online allowed, so %@ can use %@.", task.title, Self.serviceTitle(task, allowed)),
                        old
                    )
                    return
                }
                // Switching to on this Mac only says once which tasks moved here, with Undo.
                if skipSwitchNotice {
                    skipSwitchNotice = false
                } else if old.processingPolicy != new.processingPolicy, new.processingPolicy == .onDeviceOnly {
                    let moved = new.switchedTasks.map(\.title)
                    switchNotice =
                        moved.isEmpty
                        ? nil
                        : (
                            L10n.format(
                                moved.count == 1 ? "%@ now uses this Mac." : "%@ now use this Mac.", Self.list(moved)),
                            old
                        )
                }
                if old.apiStreamingEnabled != new.apiStreamingEnabled { cancelTest(scope: .api) }
                if !new.apiStreamingUnsupported.isEmpty, old.endpoint != new.endpoint || old.model != new.model {
                    draft.clearAPIStreamingSupport(ifConnectionChangedFrom: old)
                }
                if old.voiceResultComparisonEnabled != new.voiceResultComparisonEnabled {
                    voiceInput.configureResultComparison(enabled: new.voiceResultComparisonEnabled)
                }
                if !new.voiceKeepRecentResult || new.voiceRecentResultSeconds < old.voiceRecentResultSeconds {
                    voiceInput.restrictRecentResultRetention(
                        enabled: new.voiceKeepRecentResult, seconds: new.voiceRecentResultSeconds)
                }
                scheduleAutosave()
            }
            .onChange(of: first) { _, _ in scheduleAutosave() }
            .onChange(of: second) { _, _ in scheduleAutosave() }
            .onChange(of: apiKeyFocused) { old, focused in if old && !focused { commitCoordinator.commit() } }
            .onChange(of: page) { _, _ in
                historySettingsPresented = false
                switchNotice = nil
            }
            // Closing Settings with the guide open keeps where it was, like Set up later.
            .onChange(of: guidedDraft) { _, value in if guidePresented { GuidedSetupResume.draft = value } }
            .onDisappear {
                historySettingsPresented = false
                if model.previewTextSize != nil { model.previewTextSize = nil }
                if guidePresented { GuidedSetupResume.draft = guidedDraft }
                cancelGuideTrial()
                settingsPresented = false
                revealedSections.removeAll()
                appleLanguageManagerRequest = nil
                invalidateSetupActions()
                autosaveTask?.cancel()
                cancelTest()
            }
            .task(id: page) {
                guard !Task.isCancelled, page == .languages, supportedAppleLanguages?.isEmpty ?? true else { return }
                let requestPage = page
                let supported = await LanguageAvailability().supportedLanguages
                guard !Task.isCancelled, settingsPresented, page == requestPage else { return }
                supportedAppleLanguages = supported
            }

    }
    private var settingsConnections: some View {
        settingsLifecycle
            .onChange(of: model.preferences) { old, new in
                if old.voiceKeepRecentResult != new.voiceKeepRecentResult
                    || old.voiceRecentResultSeconds != new.voiceRecentResultSeconds
                {
                    voiceInput.configureRecentResultRetention(new)
                }
                guard !hasPendingCredentialEdits else {
                    draft.processingPolicy = new.processingPolicy
                    appliedConfiguration.processingPolicy = new.processingPolicy
                    return
                }
                let merged = rebasedDraft(onto: new)
                clearSavedKeysChangingScope(to: merged)
                draft = merged
                appliedConfiguration = new
            }
            .onChange(of: model.openKey) { _, _ in reconcileGlobalShortcuts() }
            .onChange(of: model.selectionKey) { _, _ in reconcileGlobalShortcuts() }
            .onChange(of: draft.appearance) { old, value in
                if old != value { model.previewSettingsAppearance?(value) }
            }
            .onChange(of: draft.windowStyle) { old, value in
                if old != value { model.previewSettingsWindowStyle?(value) }
            }
            .onChange(of: draft.enabledLanguages) { _, _ in normalizeLanguagePickers() }
            .onChange(of: draft.endpoint) { _, _ in
                apiKey = ""
                cancelTest(scope: .api)
            }
            .onChange(of: draft.engine) { _, _ in cancelTest() }
            .onChange(of: draft.engine) { _, value in
                if value == "api" { expandedConnections.insert(.api) }
                if value == "cli" { expandedConnections.insert(.cli) }
            }
            .onChange(of: draft.speechEngine) { _, value in
                if value != "macos" && value != "local" { expandedConnections.insert(.speech) }
            }
            .onChange(of: "\(draft.voiceTranslateEnabled)|\(draft.voiceOutputMode)|\(draft.voiceRefinementEngine)") {
                _, _ in
                if draft.voiceTranslateEnabled, draft.voiceOutputMode == "refine" {
                    if draft.voiceRefinementEngine == "api" { expandedConnections.insert(.api) }
                    if draft.voiceRefinementEngine == "cli" { expandedConnections.insert(.cli) }
                }
            }
            .onChange(of: draft.model) { _, _ in cancelTest(scope: .api) }
            .onChange(of: draft.cli) { _, configuration in
                if !actionFeedback.matchesCLIConfiguration(configuration) { cancelTest(scope: .cli) }
            }
            .onChange(of: apiKey) { _, value in
                if !actionFeedback.preservesKeyRemoval(value: value) { cancelTest(scope: .api) }
                scheduleAutosave()
            }
            .onChange(of: speechKeys) { _, _ in scheduleAutosave() }
            .confirmationDialog(L10n.tr("Forget this saved API key?"), isPresented: $confirmForgetKey) {
                Button(L10n.tr("Forget key"), role: .destructive) {
                    do {
                        let endpoint = try APIClient.endpoint(draft.endpoint).absoluteString
                        try KeyStore.remove(endpoint)
                        credentialCommitter.forget(account: endpoint)
                        draft.forgetWorking(.api)
                        apiKey = ""
                        cancelTest(scope: .api)
                        actionFeedback.show(
                            .api, message: L10n.tr("Saved key removed from this Mac."), kind: .keyRemoval)
                    } catch { actionFeedback.show(.api, message: error.localizedDescription, tone: .failure) }
                }
                Button(L10n.tr("Cancel"), role: .cancel) {}
            } message: {
                Text(L10n.tr("Removes the saved key from this Mac. Your provider’s key stays active."))
            }

    }

    @ViewBuilder private func setupContent(_ sheet: SettingsSetupSheet) -> some View {
        let generation = setupGeneration
        switch sheet {
        case .processing:
            QuickSetupView(
                preferences: model.preferences, models: voiceModels,
                apply: { patch in
                    guard setupIsCurrent(generation, sheet: .processing) else {
                        return L10n.tr("Setup changed. Reopen setup and try again.")
                    }
                    return applyQuickSetup(patch)
                },
                openServices: {
                    guard setupOwnerIsCurrent(generation) else { return }
                    finishQuickSetupServices()
                },
                openService: { section in
                    guard setupOwnerIsCurrent(generation) else { return }
                    openQuickSetupService(section)
                },
                openLocalModels: { task in
                    guard setupOwnerIsCurrent(generation) else { return }
                    openQuickSetupLocalModels(task)
                })
        }
    }
    private func guideOwnerIsCurrent(_ generation: UUID) -> Bool {
        setupOwnerIsCurrent(generation) && guidePresented
    }
    private func cancelGuideTrial(generation: UUID? = nil) {
        guard let current = guidedTrialGeneration, generation == nil || generation == current else { return }
        guidedTrialGeneration = nil
        cancelGuidedDictation?()
    }
    private func endGuide(keepingDraft: Bool = true) {
        cancelGuideTrial()
        guidePresented = false
        setupFocusChanged?(false)
        if !keepingDraft { guidedDraft = nil }
        GuidedSetupResume.draft = guidedDraft
        invalidateSetupActions()
    }
    private func guideTrialStarter(_ generation: UUID) -> ((@escaping (VoiceTrialOutcome) -> Void) -> Void)? {
        guard let start = tryGuidedDictation else { return nil }
        return { completion in
            guard guideOwnerIsCurrent(generation) else { return }
            guidedTrialGeneration = generation
            start { outcome in
                guard guideOwnerIsCurrent(generation), guidedTrialGeneration == generation else { return }
                guidedTrialGeneration = nil
                completion(outcome)
            }
        }
    }
    // A sample may start reading only while this guide is current.
    private func guideTourActions(_ generation: UUID) -> GuidedTourActions? {
        guard var actions = guideTour else { return nil }
        let speak = actions.speak
        actions.speak = { text, language in
            guard guideOwnerIsCurrent(generation) else { return }
            speak(text, language)
        }
        return actions
    }
    @ViewBuilder private func guideContent(embedded: Bool) -> some View {
        let generation = setupGeneration
        GuidedSetupView(
            model: model, models: voiceModels, voice: voiceInput,
            apply: { patch in
                guard guideOwnerIsCurrent(generation) else {
                    return L10n.tr("Setup changed. Reopen setup and try again.")
                }
                return applyGuidedSetup(patch)
            },
            tryDictation: {
                guard guideOwnerIsCurrent(generation) else { return }
                tryDictation?()
            },
            // The guide stays open behind the Yullo window, at its step, and comes
            // forward when that window goes.
            openTranslator: {
                guard guideOwnerIsCurrent(generation) else { return }
                cancelGuideTrial()
                (openTranslator ?? close)()
            },
            openSettings: { destination, anchor, task in
                guard guideOwnerIsCurrent(generation) else { return }
                endGuide()
                if let task { localModelTask = task }
                if navigate(to: destination, anchor: anchor) { guideReturnAvailable = guidedDraft != nil }
            },
            setUpService: { anchor in
                guard guideOwnerIsCurrent(generation) else { return }
                openServices(anchor)
            },
            close: {
                guard guideOwnerIsCurrent(generation) else { return }
                endGuide()
                // Not now from a guide started in Settings goes back to Quick setup.
                if !guideReturnsToSettings { close() }
            },
            finished: {
                guard guideOwnerIsCurrent(generation) else { return }
                endGuide(keepingDraft: false)
                close()
            }, draft: guidedDraft,
            rememberDraft: { value in
                guard guideOwnerIsCurrent(generation) else { return }
                guidedDraft = value
            }, embedded: embedded, startTrial: guideTrialStarter(generation),
            cancelTrial: { cancelGuideTrial(generation: generation) },
            prepareTrial: { if guideOwnerIsCurrent(generation) { prepareGuidedDictation?() } },
            tour: guideTourActions(generation))
    }
    private func setupIsCurrent(_ generation: UUID, sheet: SettingsSetupSheet) -> Bool {
        setupOwnerIsCurrent(generation) && setupSheet == sheet
    }
    private func setupOwnerIsCurrent(_ generation: UUID) -> Bool {
        settingsPresented && setupGeneration == generation && commitCoordinator.isPresented()
    }
    private var searchResults: some View {
        let matches = SettingsSearch.results(for: search, hiding: SettingsSearch.hiddenAnchors(draft))
        return VStack(spacing: 0) {
            if matches.isEmpty {
                Text(L10n.tr("No settings found.")).font(.system(size: 13)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 18)
            }
            ForEach(Array(matches.enumerated()), id: \.element.id) { index, entry in
                Button {
                    activateSearchResult(entry)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                        Text(entry.location).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }.frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 7).contentShape(Rectangle())
                        .background {
                            if index == searchSelection {
                                Color.clear.modifier(
                                    SettingsCardSurface(
                                        cornerRadius: 8, darkFill: 0.11, solidDarkFill: 0.10, lightFill: 0.90,
                                        solidLightFill: 1))
                            }
                        }
                }.buttonStyle(.plain)
                Divider()
            }
        }
    }
    private func field(_ title: String, hint: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L10n.tr(title)).font(.system(size: 13, weight: .medium))
            TextField(L10n.tr(hint), text: text).textFieldStyle(.roundedBorder).font(.system(size: 13))
                .autocorrectionDisabled().accessibilityLabel(L10n.tr(title))
        }
    }
    private var appleSettings: some View {
        HStack(spacing: 12) {
            Text(L10n.tr("Apple translation languages"))
            Spacer(minLength: 12)
            Button(L10n.tr("Manage languages…"), action: openAppleLanguageManager)
                .accessibilityIdentifier("settings-apple-language-manager")
                .background {
                    #if YULLO_TESTING
                        YulloActionPresentationProbe(
                            title: "Manage Apple translation languages", action: openAppleLanguageManager)
                    #endif
                }
        }.id("apple-language-manager")
    }
    private func openAppleLanguageManager() {
        guard settingsPresented, page == .translation, appleLanguageManagerRequest == nil else { return }
        appleLanguageManagerRequest = .init(source: model.sourceLanguage, target: model.targetLanguage)
    }
    private var apiSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("API URL", hint: "https://your-provider.example/v1", text: $draft.endpoint)
                .focused($connectionField, equals: .apiEndpoint)
            field("Model ID", hint: "Exact model name from your provider", text: $draft.model)
                .focused($connectionField, equals: .apiModel)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(L10n.tr("API key")).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Label(L10n.tr("Keychain"), systemImage: "lock.shield").font(.system(size: 10)).foregroundStyle(
                        .secondary)
                }
                SecureField(L10n.tr("Paste a new key, or leave blank to keep the saved key"), text: $apiKey)
                    .textFieldStyle(.roundedBorder).accessibilityLabel(L10n.tr("API key"))
                    .focused($apiKeyFocused).onSubmit { commitCoordinator.commit() }
                HStack(spacing: 14) {
                    // Keys also save on Return and when leaving the field; this
                    // makes it explicit and confirms where the key went.
                    Button(L10n.tr("Save key"), action: saveAPIKey).controlSize(.small)
                        .disabled(
                            apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.endpoint.isEmpty
                                || testing
                        )
                        .accessibilityIdentifier("api-key-save")
                    Button(L10n.tr("Forget saved key…")) { confirmForgetKey = true }.buttonStyle(.link)
                        .disabled(draft.endpoint.isEmpty || testing)
                }.font(.system(size: 12))
            }
            VStack(alignment: .leading, spacing: 4) {
                // A service known not to stream keeps the switch off until its endpoint or model changes.
                let unsupported = draft.apiStreamingKnownUnsupported
                Toggle(
                    L10n.tr("Stream translations"),
                    isOn: unsupported ? .constant(false) : $draft.apiStreamingEnabled
                )
                .font(.system(size: 13)).disabled(unsupported)
                .accessibilityIdentifier("api-response-streaming")
                if unsupported {
                    Text(L10n.tr("Not supported by this service."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 20)
                        .accessibilityIdentifier("api-response-streaming-unsupported")
                }
            }.id("api-response-streaming")
            HStack {
                Button(L10n.tr(actionFeedback.isRunning(.api) ? "Cancel test" : "Test translation")) {
                    if actionFeedback.isRunning(.api) { cancelTest(scope: .api) } else { test() }
                }.disabled(testing && !actionFeedback.isRunning(.api))
                Spacer()
            }
            feedbackLine(.api)
            connectionUse("api")
        }
    }
    private var cliSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker(
                L10n.tr("CLI provider"),
                selection: Binding(
                    get: { draft.cli.provider },
                    set: { provider in
                        let prior = draft.cli.provider
                        draft.cli.provider = provider
                        if draft.cli.executablePath == prior.suggestedExecutablePath {
                            draft.cli.executablePath = provider.suggestedExecutablePath
                        }
                        draft.cli.model = ""
                        cliDetectedPath = nil
                        cliCatalog = nil
                    })
            ) {
                ForEach(CLIProvider.allCases, id: \.self) { provider in Text(provider.displayName).tag(provider) }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(L10n.tr("Executable path")).font(.system(size: 13, weight: .medium))
                HStack {
                    TextField("", text: $draft.cli.executablePath).textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .accessibilityLabel(L10n.tr("Executable path"))
                        .focused($connectionField, equals: .cliPath)
                    Button(L10n.tr("Detect locally")) { detectCLI() }.disabled(testing)
                    Button(L10n.tr("Choose executable…")) {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = false
                        panel.allowsMultipleSelection = false
                        panel.directoryURL = URL(fileURLWithPath: draft.cli.executablePath).deletingLastPathComponent()
                        if panel.runModal() == .OK, let url = panel.url { draft.cli.executablePath = url.path }
                    }
                }
                if let path = cliDetectedPath, path != draft.cli.executablePath {
                    Button(path) { draft.cli.executablePath = path }.buttonStyle(.link).lineLimit(1).truncationMode(
                        .middle
                    )
                    .help(L10n.tr("Detected locally. Changes are saved automatically."))
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(L10n.tr("Model ID")).font(.system(size: 13, weight: .medium))
                HStack {
                    TextField(L10n.tr("Enter model ID…"), text: $draft.cli.model).textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .accessibilityLabel(L10n.tr("Model ID"))
                        .focused($connectionField, equals: .cliModel)
                    Menu(L10n.tr("Suggested models")) {
                        ForEach(cliCatalog?.provider == draft.cli.provider ? cliCatalog?.models ?? [] : []) { option in
                            Button(option.id + (option.recommended ? " · " + L10n.tr("Recommended") : "")) {
                                draft.cli.model = option.id
                            }
                        }
                        Divider()
                        Button(L10n.tr("Refresh models")) { cliModelRevision += 1 }
                    }.disabled(testing)
                        .help(
                            L10n.tr(
                                draft.cli.provider == .claude
                                    ? "Claude model aliases."
                                    : (cliCatalog?.provider == draft.cli.provider && cliCatalog?.source == .localCache)
                                        ? "Models from the local Codex cache."
                                        : "No model list found. Enter a model ID."))
                }
                if draft.cli.provider != .claude
                    && !(cliCatalog?.provider == draft.cli.provider && cliCatalog?.source == .localCache)
                {
                    Text(L10n.tr("No model list found. Enter a model ID."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Toggle(L10n.tr("Prefer faster responses"), isOn: $draft.cli.preferLowEffort)
                .toggleStyle(.checkbox).accessibilityIdentifier("cli-prefer-low-effort")
                .help(L10n.tr("When the model supports it, uses less reasoning to respond faster."))
            Text(L10n.tr("Uses your CLI’s own sign-in.")).font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack {
                Button(L10n.tr(actionFeedback.isRunning(.cli) ? "Cancel test" : "Check installation")) {
                    if actionFeedback.isRunning(.cli) { cancelTest(scope: .cli) } else { checkCLI() }
                }.disabled(testing && !actionFeedback.isRunning(.cli))
                Button(L10n.tr("Test translation")) { testCLI() }.disabled(testing)
                Spacer()
                Button(L10n.tr("Setup guide")) { showCLIGuide = true }.buttonStyle(.link)
            }
            .background {
                #if YULLO_TESTING
                    YulloActionPresentationProbe(title: "cli-explicit-check-and-guide-controls", action: {})
                    YulloActionPresentationProbe(title: "cli-test-translation", action: { testCLI() })
                #endif
            }
            feedbackLine(.cli)
            connectionUse("cli")
        }.font(.system(size: 13))
            .task(id: "\(draft.cli.provider.rawValue)|\(cliModelRevision)|\(expandedConnections.contains(.cli))") {
                guard expandedConnections.contains(.cli) else { return }
                let provider = draft.cli.provider
                let catalog = await cliClient.models(provider: provider)
                guard !Task.isCancelled, provider == draft.cli.provider else { return }
                cliCatalog = catalog
            }
    }
    // Once this shared connection has worked, say which tasks use it; the tasks
    // that don't yet are one explicit click away instead of another page.
    @ViewBuilder private func connectionUse(_ engine: String) -> some View {
        let translation = draft.engine == engine, writing = draft.voiceRefinementEngine == engine
        let offered = !(translation && writing)
        // On this Mac only, an online connection is in use for nothing.
        let runs =
            draft.processingPolicy == .standard
            || (engine == "ollama" && CoreOllama.isOnThisMac(host: draft.ollamaHost))
        // On this Mac only, Use for… allows online (one rule for every online choice).
        if ConnectedService.text(engine).map(draft.isWorking) == true, (runs && (translation || writing)) || offered {
            VStack(alignment: .leading, spacing: 6) {
                if runs, translation || writing {
                    Text(
                        L10n.tr(
                            translation && writing
                                ? "In use for translation and writing."
                                : translation ? "In use for translation." : "In use for writing.")
                    )
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("connection-use-" + engine)
                }
                if offered {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 14) { connectionUseActions(engine, translation: translation, writing: writing) }
                        VStack(alignment: .leading, spacing: 6) {
                            connectionUseActions(engine, translation: translation, writing: writing)
                        }
                    }
                }
            }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    @ViewBuilder private func connectionUseActions(_ engine: String, translation: Bool, writing: Bool) -> some View {
        if !translation {
            Button(L10n.tr("Use for translation")) { draft.engine = engine }.buttonStyle(.link).fixedSize()
                .accessibilityIdentifier("connection-use-translation-" + engine)
        }
        if !writing {
            Button(L10n.tr("Use for writing")) { draft.voiceRefinementEngine = engine }.buttonStyle(.link)
                .fixedSize().accessibilityIdentifier("connection-use-writing-" + engine)
        }
    }
    private var cliGuide: some View {
        CLISetupGuideView(close: { showCLIGuide = false })
    }
    // App-wide presence, window and keyboard choices, then data maintenance.
    // Every group is shown directly; search scrolls to its stable anchor.
    private var general: some View {
        VStack(alignment: .leading, spacing: 0) {
            appSettings
            appCustomization.padding(.top, 22)
            shortcuts.id("shortcuts").padding(.top, 22)
            SettingsSection(L10n.tr("Maintenance")) {
                cacheMaintenance.frame(maxWidth: .infinity, alignment: .leading)
            }.id("cache").padding(.top, 22).background { settingsGroupProbe("cache") }
        }
    }
    @ViewBuilder private func settingsGroupProbe(_ anchor: String) -> some View {
        #if YULLO_TESTING
            YulloActionPresentationProbe(title: "Settings group: " + anchor, action: {})
        #endif
    }
    private var setupSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection(L10n.tr("Get started")) {
                // Each row: what it is on the left, its one action on the right.
                SettingsRows {
                    whereYulloWorks.id("processing")
                    setupRow(L10n.tr("Set up Yullo"), detail: nil) {
                        // A guide left with Not now or Set up later continues at its step.
                        let action = guidedDraft == nil ? openExperienceSetup : resumeGuide
                        Button(setupGuideTitle, action: action)
                            .accessibilityIdentifier("settings-experience-setup")
                            .background {
                                #if YULLO_TESTING
                                    YulloActionPresentationProbe(title: "settings-experience-setup", action: action)
                                #endif
                            }
                    }.id("get-started")
                    dictationTrial.id("quick-setup")
                    setupRow(L10n.tr("When Yullo opens"), detail: nil) {
                        launchWindowPicker.labelsHidden().settingsControlWidth()
                    }.help(L10n.tr("Nothing opens at login.")).id("setup-launch-window")
                }
            }
            PermissionSettingsView().id("permissions")
            CredentialAccessView(
                preferences: draft, openService: openCredentialService)
        }
    }
    private var setupGuideTitle: String {
        guidedDraft == nil ? L10n.tr("Start guide…") : L10n.tr("Continue setup…")
    }
    // Where Yullo works: the choice itself, first, with Choose models… beside it
    // and any task that waits for online named on the same line.
    private var whereYulloWorks: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsTaskRow(title: L10n.tr("Where Yullo works"), stacksWhenNarrow: true) {
                Picker(L10n.tr("Where Yullo works"), selection: processingSelection) {
                    Text(L10n.tr("On this Mac only")).tag(ProcessingPolicy.onDeviceOnly)
                    Text(L10n.tr("On this Mac and online")).tag(ProcessingPolicy.standard)
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    .accessibilityIdentifier("settings-where-yullo-works")
            }
            // Choose models… is always the way in; a paused task is named beside it.
            let paused = draft.pausedTasks.map(\.title)
            HStack(spacing: 8) {
                if !paused.isEmpty {
                    Text(L10n.format("Paused until online is allowed: %@", Self.list(paused)))
                        .foregroundStyle(.secondary).accessibilityIdentifier("settings-where-paused")
                }
                Spacer(minLength: 8)
                Button(L10n.tr("Choose models…"), action: openQuickSetup).buttonStyle(.link)
                    .accessibilityIdentifier("settings-quick-setup")
                    .background {
                        #if YULLO_TESTING
                            YulloActionPresentationProbe(title: "settings-quick-setup", action: openQuickSetup)
                        #endif
                    }
            }.font(.system(size: 11)).accessibilityElement(children: .contain)
        }
    }
    // Choosing where Yullo works always sticks; services follow the choice.
    private var processingSelection: Binding<ProcessingPolicy> {
        Binding(
            get: { draft.processingPolicy },
            set: { policy in
                let previous = draft
                draft = draft.switchingProcessing(to: policy, onDevice: ProcessingTask.onDeviceAlternative)
                if policy == .standard {
                    // Online choices that came back are named once, with Undo.
                    let back = ProcessingTask.allCases.filter { previous.pausedOnlineChoices[$0.rawValue] != nil }
                        .filter { draft.usesOnlineService($0) }.map(\.title)
                    switchNotice =
                        back.isEmpty
                        ? nil
                        : (
                            L10n.format(
                                back.count == 1 ? "%@ uses online services again." : "%@ use online services again.",
                                Self.list(back)), previous
                        )
                }
                // Land where a choice is still needed; otherwise the line says enough.
                // One piece of feedback at a time: the sheet, not a footer behind it.
                if draft.needsServiceChoice {
                    switchNotice = nil
                    skipSwitchNotice = true
                    openQuickSetup()
                }
            })
    }
    static func serviceTitle(_ task: ProcessingTask, _ preferences: Preferences) -> String {
        let engine = preferences[engineOf: task]
        switch task {
        case .translation: return TranslateWithRow.title(engine, preferences: preferences)
        case .writing: return WritingServicePresentation.title(engine, preferences: preferences)
        case .readAloud: return SpeechProvider(rawValue: engine).map(SpeechSettingsFields.title) ?? engine
        }
    }
    // Undo returns to the services as they were before the change.
    private func undoSwitch() {
        guard let previous = switchNotice?.previous else { return }
        switchNotice = nil
        skipSwitchNotice = true
        draft = previous
    }
    static func list(_ items: [String]) -> String {
        let formatter = ListFormatter()
        formatter.locale = L10n.locale
        return formatter.string(from: items) ?? items.joined(separator: ", ")
    }
    private func setupRow<Action: View>(
        _ title: String, detail: String?, @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            action().fixedSize()
        }
    }
    private var appSettings: some View {
        SettingsSection(L10n.tr("Interface")) {
            SettingsRows {
                SettingsTaskRow(title: L10n.tr("Interface language")) {
                    Picker(
                        L10n.tr("Interface language"),
                        selection: Binding(
                            get: { draft.interfaceLanguage },
                            set: {
                                draft.interfaceLanguage = $0
                                model.setInterfaceLanguage($0)
                            })
                    ) {
                        ForEach(L10n.choices, id: \.id) { choice in
                            Text(choice.id == "system" ? L10n.tr("System") : choice.name).tag(choice.id)
                        }
                    }.labelsHidden().pickerStyle(.menu).settingsControlWidth()
                        // The pop-up keeps its menu titles; rebuild it so they follow the new language.
                        .id(draft.interfaceLanguage)
                        .accessibilityLabel(L10n.tr("Interface language"))
                }
                SettingsTaskRow(title: L10n.tr("Appearance")) {
                    Picker(L10n.tr("Appearance"), selection: $draft.appearance) {
                        Text(L10n.tr("System")).tag("system")
                        Text(L10n.tr("Light")).tag("light")
                        Text(L10n.tr("Dark")).tag("dark")
                    }.labelsHidden().pickerStyle(.segmented).settingsControlWidth()
                        .accessibilityLabel(L10n.tr("Appearance"))
                }
                SettingsTaskRow(title: L10n.tr("Window style")) {
                    Picker(L10n.tr("Window style"), selection: $draft.windowStyle) {
                        Text(L10n.tr("Liquid Glass")).tag("glass")
                        Text(L10n.tr("Solid")).tag(Preferences.solidWindowStyle)
                    }.labelsHidden().pickerStyle(.segmented).settingsControlWidth()
                        .accessibilityLabel(L10n.tr("Window style"))
                }.id("window-style")
                translatorTextSizeSetting.id("text-size")
                Toggle(L10n.tr("Bold text"), isOn: $draft.textBold).id("text-weight")
            }
        }.id("app")
    }
    private var translatorTextSizeSetting: some View {
        SettingsTaskRow(title: L10n.tr("Text size in Yullo windows")) {
            SettingsSliderControl(
                value: $draft.textSize, range: 16...28, step: 1, label: L10n.tr("Text size in Yullo windows"),
                text: L10n.format("%ld pt", Int(Preferences.normalizedTextSize(draft.textSize))),
                // Apply on release, not half a second later when the next click lands.
                onEditingChanged: { editing in
                    isDraggingTextSize = editing
                    guard !editing else { return }
                    autosaveTask?.cancel()
                    autosaveTask = nil
                    applyQuickSettings()
                    model.previewTextSize = nil
                }
            ).onChange(of: draft.textSize) { _, size in
                // Live while dragging; saving waits for release.
                if isDraggingTextSize { model.previewTextSize = Preferences.normalizedTextSize(size) }
            }
        }
    }
    private var appCustomization: some View {
        SettingsSection(L10n.tr("App")) {
            SettingsRows {
                LaunchAtLoginSetting().id("launch-at-login")
                AutomaticUpdatesSetting().id("automatic-updates")
                Toggle(
                    L10n.tr("Show in menu bar"),
                    isOn: Binding(
                        get: { draft.showInMenuBar },
                        set: {
                            draft.showInMenuBar = $0
                            model.setVisibility(showInMenuBar: $0)
                        }))
                Toggle(
                    L10n.tr("Show in Dock"),
                    isOn: Binding(
                        get: { draft.showInDock },
                        set: {
                            draft.showInDock = $0
                            model.setVisibility(showInDock: $0)
                        }))
                if !draft.showInDock && !draft.showInMenuBar {
                    Text(L10n.tr("Reopen Yullo from Applications or with your shortcut.")).font(
                        .system(size: 11)
                    ).foregroundStyle(.secondary).settingsRowAttached()
                }
                SettingsTaskRow(title: L10n.tr("When Yullo opens")) {
                    launchWindowPicker.labelsHidden().pickerStyle(.menu).settingsControlWidth()
                }.help(L10n.tr("Nothing opens at login."))
                // Window behavior shares this card; its anchor stays for links and search.
                Toggle(
                    L10n.tr("Hide when another app becomes active"),
                    isOn: Binding(
                        get: { draft.hideWhenClickingOutside },
                        set: {
                            draft.hideWhenClickingOutside = $0
                            model.setVisibility(hideWhenClickingOutside: $0)
                        })
                ).id("window").background { settingsGroupProbe("window") }
                SettingsTaskRow(title: L10n.tr("Main window position")) {
                    Picker(L10n.tr("Main window position"), selection: $draft.mainWindowPosition) {
                        Text(L10n.tr("Center on current screen")).tag("center")
                        Text(L10n.tr("Remember last position")).tag("last")
                    }.pickerStyle(.menu).labelsHidden().pickerStyle(.menu).settingsControlWidth()
                }
            }
        }.id("app-options")
    }
    // What opening Yullo shows; shared by General and Quick setup.
    private var launchWindowPicker: some View {
        Picker(L10n.tr("When Yullo opens"), selection: $draft.openYulloAtLaunch) {
            Text(L10n.tr("Yullo window")).tag(true)
            Text(L10n.tr("Settings")).tag(false)
        }.pickerStyle(.menu).accessibilityIdentifier("open-at-launch")
    }
    private var trialCanStart: Bool {
        tryDictation != nil && setupSheet == nil
            && VoiceTrial.canStart(isBusy: voiceInput.isBusy, result: voiceInput.result)
    }
    // Keep the last result: one memory aid, on History beside saved results.
    private var recentResultSettings: some View {
        GroupBox {
            SettingsRows {
                Toggle(isOn: $draft.voiceKeepRecentResult) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            L10n.format(
                                "Keep the last result for %@", durationLabel(draft.voiceRecentResultSeconds, full: true)
                            ))
                        Text(
                            L10n.tr(
                                draft.showInMenuBar
                                    ? "Adds Recent result to Yullo’s menu in the menu bar."
                                    : "Adds Recent result to the Yullo menu, next to the Apple menu while Yullo is open."
                            )
                        ).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("voice-recent-result-enabled")
                if draft.voiceKeepRecentResult {
                    SettingsTaskRow(title: L10n.tr("Keep for")) {
                        recentResultDurationPicker.labelsHidden().pickerStyle(.menu).settingsControlWidth()
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        if let metadata = voiceInput.recentResultMetadata {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(L10n.format("Available for %@", durationLabel(metadata.remainingSeconds)))
                                Text(L10n.tr(deliveryDescription(metadata.deliveryOutcome)))
                            }.font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.settingsRowAttached()
                }
                if draft.voiceKeepRecentResult || voiceInput.canClearRecentResult {
                    HStack(spacing: 12) {
                        Button(L10n.tr("Open recent result")) { openRecentResult?() }
                            .disabled(openRecentResult == nil || !voiceInput.canOpenRecentResult)
                            .accessibilityIdentifier("voice-recent-result-open")
                        Spacer(minLength: 8)
                        recentResultClearButton
                    }
                }
            }
        }.id("recent-result")
    }
    private func deliveryDescription(_ outcome: RecentVoiceResultStore.DeliveryOutcome) -> String {
        switch outcome {
        case .inserted: return "Inserted"
        case .notInserted: return "Not inserted"
        case .uncertain: return "Yullo couldn’t confirm the insertion. Check the original app before using it again."
        }
    }
    private var recentResultDurationPicker: some View {
        Picker(L10n.tr("Keep for"), selection: $draft.voiceRecentResultSeconds) {
            Text(L10n.tr("1 minute")).tag(60.0)
            Text(L10n.tr("5 minutes")).tag(300.0)
            Text(L10n.tr("15 minutes")).tag(900.0)
            Text(L10n.tr("30 minutes")).tag(1800.0)
            Text(L10n.tr("1 hour")).tag(3600.0)
            Text(L10n.tr("4 hours")).tag(14400.0)
            Text(L10n.tr("1 day")).tag(86400.0)
            if ![60.0, 300.0, 900.0, 1800.0, 3600.0, 14400.0, 86400.0].contains(draft.voiceRecentResultSeconds) {
                Text(L10n.format("Current: %@", recentResultDurationLabel)).tag(draft.voiceRecentResultSeconds)
            }
        }.pickerStyle(.menu).accessibilityIdentifier("voice-recent-result-duration")
    }
    private var recentResultClearButton: some View {
        Button(L10n.tr("Clear recent result")) { voiceInput.clearRecentResult() }
            .background {
                #if YULLO_TESTING
                    SettingsEnabledProbe(report: yulloTestingRecentClearEnabled)
                #endif
            }
            .disabled(!voiceInput.canClearRecentResult)
            .accessibilityIdentifier("voice-recent-result-clear")
    }
    private var recentResultDurationLabel: String { durationLabel(draft.voiceRecentResultSeconds) }
    private func durationLabel(_ seconds: TimeInterval, full: Bool = false) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = L10n.locale
        formatter.calendar = calendar
        formatter.allowedUnits =
            seconds >= 86400 ? [.day, .hour] : seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = full ? .full : .abbreviated
        return formatter.string(from: max(0, seconds)) ?? "\(max(0, seconds)) s"
    }
    // In place, Try dictation and Try again live in the trial card beside the
    // words they produce; without that trial, the result opens in a preview.
    private var dictationTrial: some View {
        VStack(alignment: .leading, spacing: 7) {
            if tryGuidedDictation != nil {
                DictationTrialCard(
                    running: quickTrialTicket != nil, text: quickTrialText,
                    showsPrevious: quickTrialTicket != nil || quickTrialFailure != nil,
                    phase: voiceInput.phase, level: { voiceInput.level },
                    finishHint: GuidedTrialStage.finishHint(
                        VoiceTrial.preferences(from: model.preferences),
                        shortcutAvailable: !model.inactiveGlobalShortcutIDs.contains(3)),
                    cancel: cancelQuickTrial, start: startDictationTrial, canStart: trialCanStart,
                    failed: quickTrialFailure != nil
                ).id("trial-details")
            } else {
                setupRow(L10n.tr("Try dictation"), detail: nil) {
                    Button(L10n.tr("Try"), action: startDictationTrial).disabled(!trialCanStart)
                        .help(L10n.format("Dictation shortcut: %@", draft.dictationShortcut.displayLabel))
                        .accessibilityIdentifier("settings-try-dictation")
                }.id("trial-details")
            }
            if let quickTrialFailure {
                Text(quickTrialFailure).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-trial-failure")
            }
            if !voiceInput.result.isEmpty {
                Text(L10n.tr("Copy the current result if needed, then close it before trying dictation."))
                    .foregroundStyle(.secondary).accessibilityIdentifier("settings-trial-existing-result")
            }
        }.font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            .task { await voiceModels.refresh() }
            .onDisappear {
                // A trial belongs to this visit; coming back starts fresh.
                cancelQuickTrial()
                quickTrialText = ""
                quickTrialFailure = nil
            }
    }
    // Sent here to allow saved key access from another window: once access is
    // allowed, go back there after the row has shown Allowed.
    private func openTrialRecognition() {
        navigate(to: .dictation, anchor: "recognition")
    }
    private func startDictationTrial() {
        guard trialCanStart, commitCoordinator.commit(), trialCanStart else { return }
        guard let start = tryGuidedDictation else {
            tryDictation?()
            return
        }
        let ticket = UUID()
        quickTrialTicket = ticket
        quickTrialFailure = nil
        start { outcome in
            Task { @MainActor in
                guard quickTrialTicket == ticket else { return }
                quickTrialTicket = nil
                switch outcome {
                case .recognized(let text):
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        quickTrialFailure = L10n.tr("No speech was recognized.")
                    } else {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { quickTrialText = text }
                    }
                case .failed(let message): quickTrialFailure = message
                case .cancelled: break
                }
            }
        }
    }
    private func cancelQuickTrial() {
        guard quickTrialTicket != nil else { return }
        quickTrialTicket = nil
        cancelGuidedDictation?()
    }
    // Global and translator-window bindings share one editor, grouped by where
    // they work; the recommended profile below reviews both groups together.
    private func shortcutGroupTitle(_ key: String) -> some View {
        Text(L10n.tr(key)).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).accessibilityAddTraits(.isHeader).settingsGroupLabel()
    }
    private var shortcuts: some View {
        SettingsSection(L10n.tr("Keyboard shortcuts")) {
            SettingsRows {
                shortcutRow("Show / hide Yullo", shortcut: $first)
                shortcutRow("Translate selected text", shortcut: $second)
                shortcutRow("Refine in Yullo window", shortcut: $draft.refineSelectionShortcut)
                    .id("refine-selection-shortcut")
                ForEach(Array(draft.outputs.refineInPlace.enumerated()), id: \.element.id) { index, row in
                    shortcutRow(
                        index == 0
                            ? L10n.tr("Refine in place")
                            : L10n.tr("Refine in place") + " · "
                                + OutputPresentation.name(row.output, preferences: draft),
                        shortcut: OutputSettingsPresentation.key(row.id, in: $draft), localized: true
                    ).id(index == 0 ? "refine-in-place-shortcut" : row.id)
                }
                shortcutRow("Start dictation", shortcut: $draft.dictationShortcut).id("voice-global-shortcuts")
                ForEach(draft.outputs.dictationShortcuts) { row in
                    shortcutRow(
                        L10n.format("Dictation · %@", OutputPresentation.name(row.output, preferences: draft)),
                        shortcut: OutputSettingsPresentation.key(row.id, in: $draft), localized: true
                    )
                    .id(
                        row.id == CoreOutputSettings.voiceTranslationShortcutID
                            ? "voice-translation-shortcut" : row.id)
                }
                shortcutRow("Temporary format", shortcut: $draft.scenarioShortcut).id("scenario-shortcut")
                // Keys that only work inside a result or the Yullo window stay folded.
                SettingsDisclosureRow(
                    title: L10n.tr("More shortcuts"), summary: "5", isExpanded: moreShortcutsExpansion
                ).id("more-shortcuts")
                if moreShortcutsExpansion.wrappedValue {
                    shortcutGroupTitle("While a result is showing")
                    shortcutRow("Copy result", shortcut: $draft.voiceResultCopyShortcut).id(
                        "voice-result-copy-shortcut")
                    shortcutRow("Replace selection", shortcut: $draft.replaceShortcut)
                    shortcutGroupTitle("In the Yullo window")
                    shortcutRow("Translate now", shortcut: $draft.localTranslateShortcut)
                        .id("translator-shortcuts").background { settingsGroupProbe("translator-shortcuts") }
                    shortcutRow("Copy translation", shortcut: $draft.copyShortcut)
                    shortcutRow("Hide Yullo", shortcut: $draft.closeShortcut, allowsEscape: true)
                }
                if !model.inactiveGlobalShortcutIDs.isEmpty {
                    Text(
                        ShortcutRegistry.unavailableNotice(
                            model.inactiveGlobalShortcutIDs, menuBarItemVisible: draft.showInMenuBar)
                    )
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(
                        "settings-shortcut-availability"
                    ).settingsRowAttached()
                }
            }
        }
    }
    // Closed on every visit; search for one of its keys opens it.
    private var moreShortcutsExpansion: Binding<Bool> {
        Binding(
            get: { moreShortcutsExpanded || revealedSections.contains(.moreShortcuts) },
            set: { expanded in
                moreShortcutsExpanded = expanded
                if !expanded { revealedSections.remove(.moreShortcuts) }
            })
    }
    private func shortcutRow(
        _ title: String, shortcut: Binding<Shortcut>, allowsEscape: Bool = false, localized: Bool = false
    ) -> some View {
        let label = localized ? title : L10n.tr(title)
        return HStack {
            Text(label).frame(maxWidth: .infinity, alignment: .leading)
            ShortcutRecorder(shortcut: shortcut, allowsEscape: allowsEscape, actionName: label).frame(
                width: SettingsKeyBox.width(for: shortcut.wrappedValue), height: SettingsKeyBox.height)
        }.font(.system(size: 13)).disabled(voiceInput.isBusy)
    }
    private var quickReturnRequirement: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(L10n.format("Needs “%@”.", L10n.tr("Hide when another app becomes active")))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(L10n.tr("Window behavior…")) { navigate(to: .general, anchor: "window") }
                .buttonStyle(.link).accessibilityIdentifier("translation-quick-return-window")
                .background {
                    #if YULLO_TESTING
                        YulloActionPresentationProbe(
                            title: "translation-quick-return-window",
                            action: { navigate(to: .general, anchor: "window") })
                    #endif
                }
        }.font(.system(size: 12))
    }
    private var voice: some View {
        SpeechPlaybackSettingsView(
            draft: $draft, enteredKeys: $speechKeys, voiceLanguage: $voiceLanguage,
            stopCurrentSpeech: { model.stopSpeaking() },
            openServices: {
                if draft.speechEngine == "local" {
                    // The library opens over Read aloud; downloading never changes the voice in use.
                    localModelTask = .readAloud
                    showModelLibrary = true
                } else {
                    navigate(to: .models, anchor: "speech-services")
                }
            },
            voiceInputActive: voiceInput.isBusy, localModels: voiceModels,
            openProcessingSetup: openSpeechProcessingSetup,
            voicesExpanded: customizationExpansion(.speechVoices), session: speechPlaybackSession,
            revealedSections: revealedSections)
    }
    // Every assigned key, so an empty box never suggests one already in use.
    private var takenShortcuts: [Shortcut] {
        [
            first, second, draft.dictationShortcut, draft.voiceTranslationShortcut, draft.scenarioShortcut,
            draft.refineSelectionShortcut, draft.voiceResultCopyShortcut, draft.copyShortcut, draft.replaceShortcut,
            draft.localTranslateShortcut, draft.closeShortcut
        ] + Array(draft.outputShortcutKeys.values)
    }
    // A shared engine's setup lives on Services; the anchor names its section.
    // A shared engine's setup opens over the page it was chosen from: the model library,
    // or the connection's own editor. Done returns to the page, where the pop-up shows the result.
    private func openServices(_ anchor: String) {
        let sheet = SettingsConnectionSheet(rawValue: anchor)
        guard anchor == "models" || sheet != nil else {
            _ = navigate(to: .models, anchor: anchor)
            return
        }
        // A sheet that asked for this (Choose a writing service) closes first.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard let sheet else {
                localModelTask = .translation
                showModelLibrary = true
                return
            }
            if sheet != .ollama { connectionExpansion(sheet == .cli ? .cli : .api).wrappedValue = true }
            if sheet == .all { expandedConnections.formUnion([.api, .cli]) }
            connectionSheet = sheet
        }
    }
    // Only pages with engine rows read the saved key; Quick setup and the guide own their own reads.
    private func syncEngineKeyCheck() {
        if [.translation, .refine, .dictation].contains(page) && !guidePresented {
            textKeyAccess.appear(targets: CredentialAccessTargets.make(draft), inspecting: [.textAPI])
        } else {
            textKeyAccess.disappear()
        }
    }
    private func connectionSheetContent(_ sheet: SettingsConnectionSheet) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                L10n.tr(
                    sheet == .all
                        ? "Services"
                        : sheet == .ollama ? "Ollama" : sheet == .api ? "API connection" : "Command-line tools")
            )
            .font(.system(size: 17, weight: .semibold))
            ScrollView {
                GroupBox {
                    SettingsRows {
                        if sheet == .all || sheet == .ollama {
                            OllamaSettingsView(host: $draft.ollamaHost, model: $draft.ollamaModel, startsEditing: true)
                        }
                        if sheet == .all || sheet == .api {
                            connectionRow(
                                .api, title: L10n.tr("API connection"),
                                status: apiConfigured
                                    ? Self.apiModelConfigurationSummary(draft.model) : L10n.tr("Not set up"),
                                configured: apiConfigured
                            ) { apiSettings }
                        }
                        if sheet == .all || sheet == .cli {
                            connectionRow(
                                .cli, title: L10n.tr("Command-line tools"),
                                status: cliConfigured
                                    ? Self.translationCLIConfigurationSummary(draft.cli) : L10n.tr("Not set up"),
                                configured: cliConfigured
                            ) { cliSettings }
                        }
                    }
                }.padding(.trailing, 8)
            }.smallNativeScrollbars()
            HStack {
                Spacer()
                Button(L10n.tr("Done")) {
                    guard commitCoordinator.commit() else { return }
                    connectionSheet = nil
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 560, height: 560).groupBoxStyle(SettingsCardGroupBoxStyle())
            .toggleStyle(SettingsRowToggleStyle())
    }
    private func pageRecorder(_ title: String, shortcut: Binding<Shortcut>) -> some View {
        ShortcutRecorder(shortcut: shortcut, actionName: L10n.tr(title)).frame(
            width: SettingsKeyBox.width(for: shortcut.wrappedValue), height: SettingsKeyBox.height
        )
        .disabled(voiceInput.isBusy)
    }
    // Every task page reads the same way: its keys and what they do, then the
    // engine that does the work, then rarely changed details.
    private var translationSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection(L10n.tr("Selected text")) {
                SettingsRows {
                    SettingsTaskRow(title: L10n.tr("Translate selected text")) {
                        pageRecorder("Translate selected text", shortcut: $second)
                    }
                    Toggle(L10n.tr("Translate right away"), isOn: $draft.translateSelection)
                    Toggle(L10n.tr("Let me edit the text first"), isOn: $draft.selectedTextStartsEditable)
                        .id("selection-editing")
                }
            }.id("selected-text")
            SettingsSection(L10n.tr("Yullo window")) {
                SettingsRows {
                    SettingsTaskRow(title: L10n.tr("Show / hide Yullo")) {
                        pageRecorder("Show / hide Yullo", shortcut: $first)
                    }
                    Toggle(L10n.tr("Translate as I type"), isOn: $draft.autoTranslate)
                    Toggle(
                        L10n.tr("Remember the last translation for 30 seconds"),
                        isOn: $draft.restoreTranslationOnQuickReturn
                    ).accessibilityIdentifier("translation-quick-return").id("quick-return")
                    // Only an automatic hide keeps a draft, so link its owning switch.
                    if !draft.hideWhenClickingOutside { quickReturnRequirement.settingsRowAttached() }
                    // One language has no direction to learn; the switch and what it learned wait.
                    if !draft.usesOneLanguage {
                        Toggle(L10n.tr("Suggest my usual languages"), isOn: $draft.learnTranslationDirections)
                            .id("language-suggestions")
                    }
                    if !draft.usesOneLanguage, draft.learnTranslationDirections {
                        SettingsTaskRow(title: L10n.tr("Remembered languages")) {
                            Button(L10n.tr("Reset")) {
                                model.resetLearnedDirections()
                                actionFeedback.show(
                                    .direction, message: L10n.tr("Remembered language choices cleared."))
                            }.accessibilityLabel(L10n.tr("Reset remembered languages"))
                        }
                    }
                    feedbackLine(.direction).settingsRowAttached()
                }
            }.id("yullo-window")
            SettingsSection(L10n.tr("Translator")) {
                SettingsRows {
                    TranslateWithRow(
                        draft: $draft, models: voiceModels,
                        caption: TranslateWithRow.caption(oneLanguage: draft.usesOneLanguage),
                        openServices: openServices)
                    if draft.engine != "apple" {
                        Toggle(L10n.tr("If it fails, use Apple"), isOn: $draft.appleFallback)
                            .id("apple")
                    }
                    if draft.engine == "apple" || draft.appleFallback { appleSettings }
                }
            }
            SettingsSection(L10n.tr("Writer")) {
                SettingsRows {
                    WriteWithRow(
                        draft: $draft,
                        caption: L10n.tr("For Refine and formats like Email."),
                        openServices: openServices)
                }
            }
            // The same trailing inset as Refine and Dictation, so shared rows line up page to page.
        }.environment(\.settingsTrailingInset, SettingsOutputColumns.removeInset)
    }
    // Refine: both selected-text actions with their keys and the Yullo window's
    // comparison, then the shared writer. The Refine button is always in the window.
    private var refineSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection(L10n.tr("Selected text")) {
                SettingsRows {
                    SettingsTaskRow(title: L10n.tr("Refine in Yullo window")) {
                        pageRecorder("Refine in Yullo window", shortcut: $draft.refineSelectionShortcut)
                    }.id("refine-selection")
                    Toggle(L10n.tr("Show before and after"), isOn: $draft.translationResultComparisonEnabled)
                        .accessibilityIdentifier("translation-result-comparison-enabled")
                        .id("translation-comparison").background { settingsGroupProbe("translation-comparison") }
                    RefineInPlaceSettings(draft: $draft, taken: takenShortcuts).disabled(voiceInput.isBusy)
                }
            }
            SettingsSection(L10n.tr("Writer")) {
                SettingsRows {
                    WriteWithRow(
                        draft: $draft, caption: L10n.tr("For Refine and formats like Email."),
                        openServices: openServices)
                }
            }.id("refine-writer")
        }.environment(\.settingsTrailingInset, SettingsOutputColumns.removeInset)
    }
    private var cacheMaintenance: some View {
        SettingsRows {
            SettingsTaskRow(
                title: L10n.tr("Clear cached translations and audio"),
                caption: L10n.tr(
                    "History and settings aren’t affected.")
            ) {
                Button(L10n.tr("Clear")) {
                    APIClient.clearCachedResponses()
                    SpeechService.clearCachedAudio()
                    actionFeedback.show(.cache, message: L10n.tr("Translation and audio cache cleared."))
                }
            }
            feedbackLine(.cache).settingsRowAttached()
        }
    }
    static let setUpServiceTag = "__set-up-service__"
    static func translationManagementAnchor(engine: String) -> String? {
        switch engine {
        case "api": return "api"
        case "cli": return "cli"
        case "local": return "models"
        default: return nil
        }
    }
    static func apiModelConfigurationSummary(_ value: String) -> String {
        // The same short name the engine menus use, without its provider prefix.
        let model =
            value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/").last.map(String.init) ?? ""
        return model.isEmpty ? L10n.tr("No model selected") : model
    }
    static func translationCLIConfigurationSummary(_ configuration: CLIConfiguration) -> String {
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = configuration.executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let selection =
            model.isEmpty
            ? L10n.tr(configuration.provider == .claude ? "Default model" : "No model selected") : model
        return configuration.provider.displayName + " · " + (path.isEmpty ? L10n.tr("Not set up") : selection)
    }
    static func offersAPISetup(_ preferences: Preferences) -> Bool {
        preferences.engine == "apple" && preferences.processingPolicy == .standard
            && (try? APIConnectionSettings(endpoint: preferences.endpoint, model: preferences.model)) == nil
    }
    // "5 models · 4.6 GB": what's on this Mac, with the library one click away in a sheet.
    private var localModelSummary: String {
        let installed = voiceModels.installed
        guard !installed.isEmpty else { return L10n.tr("No models yet") }
        let bytes = installed.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return L10n.format(
            installed.count == 1 ? "%ld model · %@" : "%ld models · %@", installed.count,
            L10n.size(bytes))
    }
    private var modelLibrarySheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView {
                LocalModelLibraryView(
                    selections: localModelSelections, task: $localModelTask,
                    selectedLanguageIDs: draft.enabledLanguages, livePreviewRequested: draft.voiceLivePreview,
                    models: voiceModels, voice: voiceInput, browseRequest: modelBrowseRequest
                ).padding(.trailing, 12)
            }.smallNativeScrollbars()
            HStack {
                Spacer()
                Button(L10n.tr("Done")) { showModelLibrary = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 600, height: 640)
    }
    private var modelsSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            // The page title names them; every connection is one row: name, state, one button.
            GroupBox {
                SettingsRows {
                    SettingsTaskRow(title: L10n.tr("On this Mac"), caption: localModelSummary) {
                        Button(L10n.tr("Manage models…")) { showModelLibrary = true }
                            .accessibilityIdentifier("manage-models")
                    }.id("models").task { await voiceModels.refresh() }
                    AppleModelServiceRow().id("apple-model")
                    // An extra option beside the models on this Mac, never in their place.
                    OllamaSettingsView(host: $draft.ollamaHost, model: $draft.ollamaModel).id("ollama")
                    connectionRow(
                        .api, title: L10n.tr("API connection"),
                        status: apiConfigured ? Self.apiModelConfigurationSummary(draft.model) : L10n.tr("Not set up"),
                        configured: apiConfigured
                    ) { apiSettings }.id("api")
                    connectionRow(
                        .cli, title: L10n.tr("Command-line tools"),
                        status: cliConfigured
                            ? Self.translationCLIConfigurationSummary(draft.cli) : L10n.tr("Not set up"),
                        configured: cliConfigured
                    ) { cliSettings }.id("cli")
                }
            }
            if draft.processingPolicy == .onDeviceOnly {
                Text(L10n.tr("Works on this Mac only. Choosing a service allows online."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("services-on-this-mac-only")
            }
            SettingsSection(L10n.tr("Cloud voices")) {
                SettingsRows {
                    ForEach(Self.cloudVoiceProviders, id: \.rawValue) { provider in
                        cloudVoiceRow(provider)
                    }
                }
            }.id("speech-services")
        }
    }
    private var apiConfigured: Bool {
        (try? APIConnectionSettings(endpoint: draft.endpoint, model: draft.model)) != nil
    }
    private var cliConfigured: Bool { CLIClient.hasConfiguredMetadata(draft.cli) }
    // A connection row: its name, its state and one button that opens its
    // existing editor under the row, inside the same card.
    private func connectionRow<Editor: View>(
        _ section: SettingsConnectionSection, title: String, status: String, configured: Bool,
        @ViewBuilder editor: () -> Editor
    ) -> some View {
        let expansion = connectionExpansion(section)
        return VStack(alignment: .leading, spacing: 10) {
            SettingsTaskRow(title: title, caption: status) {
                Button(L10n.tr(expansion.wrappedValue ? "Done" : configured ? "Edit…" : "Set up…")) {
                    expansion.wrappedValue.toggle()
                }.accessibilityIdentifier("connection-" + section.rawValue)
            }
            if expansion.wrappedValue {
                editor().padding(.bottom, 6)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    static let cloudVoiceProviders: [SpeechProvider] = [.azure, .google, .elevenlabs, .speechAPI]
    static func cloudVoiceTitle(_ provider: SpeechProvider) -> String {
        switch provider {
        case .google: return L10n.tr("Google Cloud Speech")
        case .speechAPI: return L10n.tr("Custom speech service")
        default: return SpeechSettingsFields.title(provider)
        }
    }
    // The cloud service whose editor is open: the one asked for, else the one in use.
    private var openCloudVoice: SpeechProvider? {
        guard expandedConnections.contains(.speech) else { return nil }
        if let speechConnectionProvider, Self.cloudVoiceProviders.contains(speechConnectionProvider) {
            return speechConnectionProvider
        }
        return SpeechProvider(rawValue: draft.speechEngine).flatMap { Self.cloudVoiceProviders.contains($0) ? $0 : nil }
            ?? .azure
    }
    private func cloudVoiceRow(_ provider: SpeechProvider) -> some View {
        let open = openCloudVoice == provider
        let working = ConnectedService.speech(provider).map(draft.isWorking) == true
        return VStack(alignment: .leading, spacing: 10) {
            SettingsTaskRow(title: Self.cloudVoiceTitle(provider), caption: L10n.tr(working ? "Ready" : "Not set up")) {
                Button(L10n.tr(open ? "Done" : working ? "Edit…" : "Set up…")) {
                    if open {
                        connectionExpansion(.speech).wrappedValue = false
                    } else {
                        speechConnectionProvider = provider
                        connectionExpansion(.speech).wrappedValue = true
                    }
                }
            }
            if open {
                CloudSpeechSettingsView(
                    draft: $draft, enteredKeys: $speechKeys, voiceLanguage: $voiceLanguage,
                    stopCurrentSpeech: { model.stopSpeaking() }, voiceInputActive: voiceInput.isBusy,
                    commitCredentials: { commitCoordinator.commit() },
                    credentialForgotten: { credentialCommitter.forget(account: $0) },
                    session: speechConnectionSession,
                    isExpanded: connectionExpansion(.speech), voicesExpanded: customizationExpansion(.speechVoices),
                    preferredProvider: provider, revealedSections: revealedSections, embedded: true
                ).padding(.bottom, 6)
            }
        }
    }
    private func openCredentialService(_ service: CredentialAccessService) {
        if service == .textAPI {
            _ = navigate(to: .models, anchor: "api")
            return
        }
        guard navigate(to: .models, anchor: "speech-services") else { return }
        switch service {
        case .azure: speechConnectionProvider = .azure
        case .google: speechConnectionProvider = .google
        case .elevenLabs: speechConnectionProvider = .elevenlabs
        case .speechAPI: speechConnectionProvider = .speechAPI
        case .textAPI: break
        }
    }
    private var localModelSelections: Binding<LocalModelSelection> {
        Binding(get: { LocalModelSelection(draft) }, set: { values in values.apply(to: &draft) })
    }
    private var aboutSettings: some View {
        AboutView(openLicenses: { showThirdPartyNotices = true }, licenseFocus: $thirdPartyNoticesFocused)
    }
    private var historyRetention: Binding<ResultHistoryRetention> {
        Binding(
            get: { ResultHistoryRetention(rawValue: draft.resultHistoryRetention) ?? .week },
            set: { draft.resultHistoryRetention = $0.rawValue })
    }
    @ViewBuilder private var historySettings: some View {
        if let historyController {
            ResultHistoryView(
                controller: historyController, enabled: $draft.resultHistoryEnabled,
                retention: historyRetention,
                useResult: { entry in
                    guard commitCoordinator.commit() else { return }
                    openHistoryResult?(entry, false)
                },
                translateAgain: { entry in
                    guard commitCoordinator.commit() else { return }
                    openHistoryResult?(entry, true)
                }, embedded: true, manageHistory: { historySettingsPresented = true })
        }
    }
    @discardableResult
    private func navigate(to target: SettingsPage, anchor: String? = nil) -> Bool {
        let anchor = resolvedAnchor(anchor)
        if guidePresented {
            guard commitCoordinator.commit() else { return false }
            endGuide()
        }
        if SettingsPage.destination(target, anchor: anchor) == page {
            reveal(anchor)
            search = ""
            navigationTarget = anchor
            return true
        }
        guard commitCoordinator.commit() else { return false }
        cancelRunningTest()
        reveal(anchor)
        search = ""
        page = SettingsPage.destination(target, anchor: anchor)
        navigationTarget = anchor
        return true
    }
    private func resolvedAnchor(_ anchor: String?) -> String? {
        switch anchor {
        case "selection": return "permissions"
        case "refine-setup", "translation-writing": return "writing-service"
        case "recognition-options": return "recognition"
        case "dictation-presets", "writing-presets": return "output"
        case "voice-translation", "voice-translation-shortcut-row": return "dictation-shortcuts"
        case "voice-output-choice", "voice-dictation-target", "voice-refine-style", "app-preferences": return "output"
        case "completion-mode", "completion": return "after-speaking"
        case "automatic": return "yullo-window"
        case "selection-editing": return "selected-text"
        case "direction": return "language-suggestions"
        default: return anchor
        }
    }
    private func moveSearchSelection(_ step: Int) -> KeyPress.Result {
        let count = SettingsSearch.results(for: search, hiding: SettingsSearch.hiddenAnchors(draft)).count
        guard count > 0 else { return .ignored }
        searchSelection = min(max(searchSelection + step, 0), count - 1)
        return .handled
    }
    private func activateSearchResult(_ entry: SettingsSearchEntry) {
        navigate(to: entry.page, anchor: entry.anchor)
    }
    private func reveal(_ anchor: String?) {
        if let anchor { revealedSections.formUnion(SettingsVisibilitySection.sections(forAnchor: anchor)) }
        if anchor == "api-response-streaming" { expandedConnections.insert(.api) }
        if anchor == "model-browse" { modelBrowseRequest = UUID() }
        if anchor == "model-browse" || anchor == "model-library" { showModelLibrary = true }
        // The guide's Review setup… for on-device processing opens the review itself.
        if anchor == "processing-review" { openQuickSetup() }
        if let anchor, let section = SettingsConnectionSection(rawValue: anchor) {
            expandedConnections.insert(section)
        }
        if let anchor, let group = SettingsCustomizationGroup.matching(anchor: anchor) {
            customizationOverrides[group] = true
        }
    }
    private func customizationExpanded(_ group: SettingsCustomizationGroup) -> Bool {
        if group == .speechVoices,
            speechConnectionSession.action != nil || speechConnectionSession.messageTone == .failure
                || speechPlaybackSession.action != nil || speechPlaybackSession.messageTone == .failure
        {
            return true
        }
        if group == .translationPreferences { return customizationOverrides[group] ?? true }
        let revealed = SettingsVisibilitySection(rawValue: group.rawValue).map(revealedSections.contains) ?? false
        return customizationOverrides[group] ?? revealed
    }
    private func customizationExpansion(_ group: SettingsCustomizationGroup) -> Binding<Bool> {
        Binding(
            get: { customizationExpanded(group) },
            set: { expanded in
                guard expanded || (commitCoordinator.commit() && credentialIssue.isEmpty && persistenceIssue.isEmpty)
                else {
                    return
                }
                customizationOverrides[group] = expanded
            })
    }
    private func openExperienceSetup() { openGuide(resuming: false, fromSettings: true) }
    private func resumeGuide() { openGuide(resuming: true, fromSettings: true) }
    private func availableGuideReturn() -> (() -> Void)? {
        guard guideReturnAvailable else { return nil }
        return { resumeGuide() }
    }
    // Start guide begins at its first step with any staged choices; Done
    // after a guide link continues at the step that link left.
    private func openGuide(resuming: Bool, fromSettings: Bool) {
        guard commitCoordinator.commit(), credentialIssue.isEmpty, persistenceIssue.isEmpty else { return }
        guideReturnsToSettings = fromSettings
        if !resuming { guidedDraft?.step = .choices }
        guideReturnAvailable = false
        // The guide has a separate reviewed draft. These entries have already
        // been saved; they must not keep owning a later service namespace.
        apiKey = ""
        speechKeys = [:]
        cancelGuideTrial()
        invalidateSetupActions()
        page = .setup
        guidePresented = true
        setupFocusChanged?(true)
    }
    private func finishSetupDismissal() {
        guard setupSheet == nil else { return }
        invalidateSetupActions()
    }
    private func invalidateSetupActions() {
        setupGeneration = UUID()
    }
    private func applyGuidedSetup(_ patch: GuidedSetupPatch) -> String? {
        guard commitCoordinator.commit(), credentialIssue.isEmpty, persistenceIssue.isEmpty else {
            if !credentialIssue.isEmpty { return credentialIssue }
            if !persistenceIssue.isEmpty { return persistenceIssue }
            return L10n.tr("Couldn’t save setup. Review your settings and try again.")
        }
        // The target must be in the list as the guide leaves it, languages added there included.
        let configuration = patch.applying(to: model.preferences)
        if let target = patch.targetLanguage,
            !Language.enabled(configuration.enabledLanguages).contains(where: { $0.id == target })
        {
            return L10n.tr("Choose a translation target from your languages.")
        }
        model.apply(configuration, restartAutomaticTranslation: false)
        if let target = patch.targetLanguage { _ = model.setTranslationTargetWithoutProcessing(target) }
        draft = configuration
        appliedConfiguration = configuration
        return nil
    }
    private func openQuickSetup() {
        openQuickSetup(returningTo: .api)
    }
    private func openQuickSetup(returningTo connection: SettingsConnectionSection) {
        guard commitCoordinator.commit() else { return }
        cancelTest()
        quickSetupConnection = connection
        invalidateSetupActions()
        setupSheet = .processing
    }
    private func openRefinementServices() {
        let connection: SettingsConnectionSection = draft.voiceRefinementEngine == "cli" ? .cli : .api
        if draft.processingPolicy == .onDeviceOnly {
            openQuickSetup(returningTo: connection)
        } else {
            navigate(to: .models, anchor: connection.rawValue)
        }
    }
    private func openSpeechProcessingSetup() { openQuickSetup(returningTo: .speech) }
    private func openTranslationProcessingSetup() { openQuickSetup(returningTo: draft.engine == "cli" ? .cli : .api) }
    private func finishQuickSetupServices() {
        openQuickSetupService(quickSetupConnection)
    }
    private func openQuickSetupService(_ section: SettingsConnectionSection) {
        if navigate(to: .models, anchor: section.rawValue) { setupSheet = nil }
    }
    private func openQuickSetupLocalModels(_ task: ModelDiscoveryTask) {
        guard navigate(to: .models, anchor: "model-browse") else { return }
        localModelTask = task
        setupSheet = nil
    }
    private func applyQuickSetup(_ patch: QuickSetupPatch) -> String? {
        let committed = commitCoordinator.commit()
        guard committed, persistenceIssue.isEmpty else {
            if !credentialIssue.isEmpty { return credentialIssue }
            if !persistenceIssue.isEmpty { return persistenceIssue }
            return L10n.tr("Couldn’t save setup. Review your settings and try again.")
        }
        autosaveTask?.cancel()
        autosaveTask = nil
        cancelTest()
        let configuration = patch.applying(to: model.preferences)
        model.apply(configuration, restartAutomaticTranslation: false)
        draft = configuration
        appliedConfiguration = configuration
        // Setup applied here is complete; a guide waiting to be continued
        // from one of its own links still continues.
        if !guidePresented && !guideReturnAvailable {
            guidedDraft = nil
            GuidedSetupResume.draft = nil
        }
        return nil
    }
    private func connectionExpansion(_ section: SettingsConnectionSection) -> Binding<Bool> {
        Binding(
            get: { expandedConnections.contains(section) },
            set: { expanded in
                if expanded {
                    expandedConnections.insert(section)
                } else {
                    guard commitCoordinator.commit() else { return }
                    if section == .api { cancelRunningTest(scope: .api) }
                    if section == .cli { cancelRunningTest(scope: .cli) }
                    if section == .speech { speechConnectionSession.cancel(clearCatalog: true) }
                    expandedConnections.remove(section)
                }
                if section == .cli { commandLineExpanded = expanded }
            })
    }
    private func scheduleAutosave() {
        guard ready else { return }
        autosaveTask?.cancel()
        autosaveTask = nil
        guard !isDraggingTextSize else { return }
        guard !hasPendingCredentialEdits else { return }
        guard
            draft != appliedConfiguration || model.preferences != appliedConfiguration
                || first != model.openKey || second != model.selectionKey
        else {
            voiceInput.configureRecentResultRetention(model.preferences)
            return
        }
        autosaveTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 450_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            applyQuickSettings()
            autosaveTask = nil
        }
    }
    private func applyQuickSettings() {
        guard !hasPendingCredentialEdits else { return }
        // A close can precede SwiftUI's change notification. Merge here too,
        // using the same baseline as the observer rather than a stale snapshot.
        reconcileGlobalShortcuts()
        var config = normalizedConfiguration(rebasedDraft(onto: model.preferences))
        clearSavedKeysChangingScope(to: config)
        do {
            try validateShortcuts(config)
            if shortcutsChanged(config),
                let error = saveShortcuts(
                    first, second, config.dictationShortcut, config.voiceTranslationShortcut, config.scenarioShortcut,
                    config.refineSelectionShortcut)
            {
                throw NSError(domain: "Yullo.Settings", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
            }
            persistenceIssue = ""
        } catch {
            // An unavailable shortcut is rejected immediately. Other valid
            // preferences still apply, and the recorder shows the saved value.
            persistenceIssue = error.localizedDescription
            first = model.openKey
            second = model.selectionKey
            config.voiceResultCopyShortcut = model.preferences.voiceResultCopyShortcut
            config.copyShortcut = model.preferences.copyShortcut
            config.localTranslateShortcut = model.preferences.localTranslateShortcut
            config.replaceShortcut = model.preferences.replaceShortcut
            config.closeShortcut = model.preferences.closeShortcut
            config.dictationShortcut = model.preferences.dictationShortcut
            config.voiceTranslationShortcut = model.preferences.voiceTranslationShortcut
            config.scenarioShortcut = model.preferences.scenarioShortcut
            config.refineSelectionShortcut = model.preferences.refineSelectionShortcut
            config.outputShortcutKeys = model.preferences.outputShortcutKeys
            draft.outputShortcutKeys = config.outputShortcutKeys
            draft.voiceResultCopyShortcut = config.voiceResultCopyShortcut
            draft.copyShortcut = config.copyShortcut
            draft.localTranslateShortcut = config.localTranslateShortcut
            draft.replaceShortcut = config.replaceShortcut
            draft.closeShortcut = config.closeShortcut
            draft.dictationShortcut = config.dictationShortcut
            draft.voiceTranslationShortcut = config.voiceTranslationShortcut
            draft.scenarioShortcut = config.scenarioShortcut
            draft.refineSelectionShortcut = config.refineSelectionShortcut
        }
        // Model invalidates only the selected route or automation that changed.
        // Settings never starts processing in a hidden translator. Presentation
        // preferences must leave unrelated pending input untouched.
        let rowsChanged = Self.rowBindingsChanged(from: model.preferences, to: config)
        let previousRows = (model.preferences.outputs, model.preferences.outputShortcutKeys)
        draft = config
        model.apply(config, restartAutomaticTranslation: false)
        // Row keys register from the saved preferences, so they re-register
        // once the edited rows are applied; a key that can't activate is undone.
        if rowsChanged, persistenceIssue.isEmpty,
            let error = saveShortcuts(
                model.openKey, model.selectionKey, config.dictationShortcut, config.voiceTranslationShortcut,
                config.scenarioShortcut, config.refineSelectionShortcut)
        {
            persistenceIssue = error
            config.outputShortcutKeys = previousRows.1
            config.outputs.refineInPlace = config.outputs.refineInPlace.filter { row in
                previousRows.0.refineInPlace.contains { $0.id == row.id }
            }
            config.outputs.dictationShortcuts = config.outputs.dictationShortcuts.filter { row in
                previousRows.0.dictationShortcuts.contains { $0.id == row.id }
            }
            draft = config
            model.apply(config, restartAutomaticTranslation: false)
            _ = saveShortcuts(
                model.openKey, model.selectionKey, config.dictationShortcut, config.voiceTranslationShortcut,
                config.scenarioShortcut, config.refineSelectionShortcut)
        }
        voiceInput.configureRecentResultRetention(model.preferences)
        appliedConfiguration = config
        appliedOpenShortcut = model.openKey
        appliedSelectionShortcut = model.selectionKey
    }
    // Whether the keys of Refine in place or dictation shortcut rows, or the rows holding them, changed.
    static func rowBindingsChanged(from old: Preferences, to new: Preferences) -> Bool {
        old.outputShortcutKeys != new.outputShortcutKeys
            || old.outputs.refineInPlace.map(\.id) != new.outputs.refineInPlace.map(\.id)
            || old.outputs.dictationShortcuts.map(\.id) != new.outputs.dictationShortcuts.map(\.id)
    }
    private func reconcileGlobalShortcuts() {
        if first == appliedOpenShortcut { first = model.openKey }
        if second == appliedSelectionShortcut { second = model.selectionKey }
        appliedOpenShortcut = model.openKey
        appliedSelectionShortcut = model.selectionKey
    }
    private func rebasedDraft(onto latest: Preferences) -> Preferences {
        // An unchanged draft follows the live policy; only choosing in Where
        // Yullo works changes it.
        draft.mergingEdits(since: appliedConfiguration, onto: latest)
    }
    private var hasPendingCredentialEdits: Bool {
        do {
            return try enteredCredentials(in: normalizedConfiguration()).contains {
                !credentialCommitter.hasWritten($0)
            }
        } catch { return true }
    }
    private func clearSavedKeysChangingScope(to configuration: Preferences) {
        let old = CredentialAccessTargets.make(draft)
        let next = CredentialAccessTargets.make(configuration)
        func changed(_ service: CredentialAccessService) -> Bool {
            old.first { $0.service == service } != next.first { $0.service == service }
        }
        if changed(.textAPI) { apiKey = "" }
        for (provider, service) in [
            (SpeechProvider.azure, CredentialAccessService.azure), (.google, .google),
            (.elevenlabs, .elevenLabs), (.speechAPI, .speechAPI)
        ] where changed(service) {
            speechKeys[provider.rawValue] = nil
        }
    }
    private func shortcutsChanged(_ config: Preferences) -> Bool {
        first != model.openKey || second != model.selectionKey
            || config.dictationShortcut != model.preferences.dictationShortcut
            || config.voiceTranslationShortcut != model.preferences.voiceTranslationShortcut
            || config.scenarioShortcut != model.preferences.scenarioShortcut
            || config.refineSelectionShortcut != model.preferences.refineSelectionShortcut
    }
    private func validateShortcuts(_ config: Preferences, open: Shortcut? = nil, selection: Shortcut? = nil) throws {
        let voiceCopy = config.voiceResultCopyShortcut
        guard voiceCopy.isValidVoiceResultCopy,
            ![
                open ?? first, selection ?? second, config.dictationShortcut, config.voiceTranslationShortcut,
                config.scenarioShortcut, config.refineSelectionShortcut
            ].contains(where: { voiceCopy.conflicts($0) })
        else { throw SettingsIssue.shortcutConflict }
        // Keys of rows that are gone no longer count. The voice translation
        // row's key is voiceTranslationShortcut, already counted below.
        let rowIDs = Set(
            config.outputs.refineInPlace.map(\.id) + config.outputs.dictationShortcuts.map(\.id)
                + Array(Shortcut.rememberedIDs)
        ).subtracting([CoreOutputSettings.voiceTranslationShortcutID])
        let bindings =
            [
                open ?? first, selection ?? second, config.copyShortcut, config.localTranslateShortcut,
                config.replaceShortcut,
                config.closeShortcut, config.dictationShortcut,
                config.voiceTranslationShortcut, config.scenarioShortcut, config.refineSelectionShortcut
            ] + config.outputShortcutKeys.filter { rowIDs.contains($0.key) }.map(\.value)
        for i in bindings.indices where bindings.dropFirst(i + 1).contains(where: { bindings[i].conflicts($0) }) {
            throw SettingsIssue.shortcutConflict
        }
    }
    private var languageSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSection(L10n.tr("Personalization")) {
                SettingsRows {
                    SignLettersRow(draft: $draft)
                    SettingsTaskRow(
                        title: L10n.tr("Personal vocabulary"),
                        caption: draft.personalVocabulary.enabled
                            ? L10n.format("Terms: %ld", draft.personalVocabulary.entries.filter(\.enabled).count)
                            : draft.personalVocabulary.entries.isEmpty ? L10n.tr("No terms yet") : L10n.tr("Off")
                    ) {
                        if draft.personalVocabulary.enabled {
                            Button(L10n.tr("Turn off")) { draft.personalVocabulary.enabled = false }
                                .buttonStyle(.link)
                        }
                        Button(L10n.tr("Edit vocabulary…")) {
                            guard commitCoordinator.commit() else { return }
                            showPersonalVocabulary = true
                        }.accessibilityIdentifier("settings-personal-vocabulary")
                    }.id("personal-vocabulary")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            LanguageSettingsSection(
                selected: $draft.enabledLanguages, showLocalizedNames: $draft.showLocalizedLanguageNames,
                supportedAppleLanguages: supportedAppleLanguages
            ).padding(.top, 22)
        }.environment(\.settingsTrailingInset, SettingsOutputColumns.removeInset)
    }
    private func normalizeLanguagePickers() {
        let enabled = Language.enabled(draft.enabledLanguages)
        if !enabled.contains(where: { $0.id == draft.voiceTarget }) { draft.voiceTarget = enabled.first?.id ?? "en" }
        draft.voiceDictationTarget = VoiceOutputTargetPolicy.normalized(
            draft.voiceDictationTarget, mode: draft.voiceOutputMode, languages: enabled)
        if !Language.catalog.contains(where: { $0.id == voiceLanguage }) { voiceLanguage = "en" }
    }
    private func normalizedConfiguration(_ source: Preferences? = nil) -> Preferences {
        var config = source ?? draft
        config.enabledLanguages = Language.enabled(config.enabledLanguages).map(\.id)
        config.endpoint = config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        config.model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        // Optional connections may be set up a field at a time. Keep their
        // partial values without making unrelated preferences depend on them.
        config.cli.executablePath = config.cli.executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        config.cli.model = config.cli.model.trimmingCharacters(in: .whitespacesAndNewlines)
        config.azureRegion = config.azureRegion.trimmingCharacters(in: .whitespacesAndNewlines)
        config.voiceSilenceSeconds = min(10, max(1, config.voiceSilenceSeconds))
        config.normalizeVoiceFinishMethods()
        return config
    }
    private var testing: Bool { actionFeedback.runningConnection != nil }
    @ViewBuilder private func feedbackLine(_ scope: SettingsFeedbackScope) -> some View {
        if actionFeedback.isRunning(scope), let message = actionFeedback.message(for: scope) {
            // A running test names its step and, once slow, how long it has waited.
            ActivityStatus(title: message).accessibilityIdentifier("settings-progress-" + scope.rawValue)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let message = actionFeedback.message(for: scope), !message.isEmpty {
            let tone = actionFeedback.tone(for: scope)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if tone != .neutral {
                    Image(systemName: tone == .success ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .accessibilityHidden(true)
                }
                Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(tone == .success ? Color.green : tone == .failure ? .orange : .secondary)
                // The test ran without changing the mode; using the service needs online.
                if draft.processingPolicy == .onDeviceOnly {
                    Spacer(minLength: 8)
                    Button(L10n.tr("Allow online")) { processingSelection.wrappedValue = .standard }
                        .buttonStyle(.link).accessibilityIdentifier("settings-feedback-allow-online-" + scope.rawValue)
                }
            }.font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("settings-feedback-" + scope.rawValue)
        }
    }
    private func cancelRunningTest(scope: SettingsFeedbackScope? = nil) {
        guard let running = actionFeedback.runningConnection, scope == nil || scope == running else { return }
        cancelTest(scope: running)
    }
    private func cancelTest(scope: SettingsFeedbackScope? = nil) {
        if scope == nil || scope == actionFeedback.runningConnection {
            testTask?.cancel()
            testTask = nil
        }
        actionFeedback.clear(scope)
    }
    private func beginTest(_ scope: SettingsFeedbackScope, message: String, configuration: CLIConfiguration? = nil)
        -> SettingsFeedbackTicket
    {
        if let active = actionFeedback.runningConnection { cancelTest(scope: active) }
        return actionFeedback.begin(scope, message: message, configuration: configuration)
    }
    private func commitEdits() -> Bool {
        autosaveTask?.cancel()
        autosaveTask = nil
        do {
            // Resolve every entered key against the editor's original account
            // before merging newer unrelated settings. Failed writes retain it.
            try credentialCommitter.commit(enteredCredentials(in: normalizedConfiguration()))
            credentialIssue = ""
            applyQuickSettings()
            return persistenceIssue.isEmpty
        } catch {
            credentialIssue = error.localizedDescription
            return false
        }
    }
    private func enteredCredentials(in config: Preferences) throws -> [SettingsCredential] {
        var credentials: [SettingsCredential] = []
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            credentials.append(.init(account: try APIClient.endpoint(config.endpoint).absoluteString, value: key))
        }
        for provider in SpeechProvider.allCases where provider != .macOS && provider != .local {
            let key = (speechKeys[provider.rawValue] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                let account = try SpeechService.keyAccount(
                    provider: provider,
                    configuration: SpeechSettingsFields.configuration(config, provider: provider),
                    region: config.azureRegion)
                credentials.append(.init(account: account, value: key))
            }
        }
        return credentials
    }
    private func test() {
        cancelTest(scope: .api)
        let authorization = ProcessingPolicyController.shared.connectionTestAuthorization()
        do {
            let config = try APIConnectionSettings(endpoint: draft.endpoint, model: draft.model)
            let enteredKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let requestedEndpoint = draft.endpoint, requestedModel = draft.model
            let requestedStreaming = draft.apiStreamingEnabled
            let streamObserver: (@Sendable (APITextProgress) -> Void)?
            let streamingRejected = APIStreamingRejectionFlag()
            if draft.apiStreamsTranslations {
                streamObserver = { @Sendable (_: APITextProgress) -> Void in }
            } else {
                streamObserver = nil
            }
            let sample = ConnectionTestSample.current
            let ticket = beginTest(.api, message: L10n.format("Translating “%@”…", sample.text))
            testTask = Task { @MainActor in
                do {
                    let text = try await ProcessingPolicyController.shared.performExternalAction(
                        authorization: authorization
                    ) {
                        KeyStore.retry(config.endpoint)
                        let key =
                            enteredKey.isEmpty
                            ? try await KeyStore.readAsync(config.endpoint, allowInteraction: true) : enteredKey
                        try Task.checkCancellation()
                        guard actionFeedback.isCurrent(ticket), draft.endpoint == requestedEndpoint,
                            draft.model == requestedModel, draft.apiStreamingEnabled == requestedStreaming,
                            apiKey.trimmingCharacters(in: .whitespacesAndNewlines) == enteredKey
                        else { throw CancellationError() }
                        return try await APIClient(streamingRejected: { _, _ in streamingRejected.set() }).translate(
                            endpoint: config.endpoint, model: config.model, key: key, text: sample.text,
                            source: sample.source,
                            target: sample.target, useCache: false,
                            progress: streamObserver)
                    }
                    guard !Task.isCancelled, actionFeedback.isCurrent(ticket), draft.endpoint == requestedEndpoint,
                        draft.model == requestedModel, draft.apiStreamingEnabled == requestedStreaming,
                        apiKey.trimmingCharacters(in: .whitespacesAndNewlines) == enteredKey
                    else { return }
                    draft.recordWorking(.api)
                    if streamingRejected.value { draft.recordAPIStreamingUnsupported() }
                    if actionFeedback.complete(
                        ticket, message: sample.result(String(text.prefix(120))),
                        tone: .success)
                    {
                        testTask = nil
                    }
                } catch {
                    guard !Task.isCancelled, actionFeedback.isCurrent(ticket), draft.endpoint == requestedEndpoint,
                        draft.model == requestedModel, draft.apiStreamingEnabled == requestedStreaming,
                        apiKey.trimmingCharacters(in: .whitespacesAndNewlines) == enteredKey
                    else { return }
                    let message =
                        error is APIError || error is ProcessingPolicyIssue
                        ? error.localizedDescription : L10n.tr("Couldn’t connect. Check the URL, network and model.")
                    if actionFeedback.complete(ticket, message: message, tone: .failure) { testTask = nil }
                }
            }
        } catch { actionFeedback.show(.api, message: error.localizedDescription, tone: .failure) }
    }
    private func saveAPIKey() {
        guard commitCoordinator.commit(), credentialIssue.isEmpty, persistenceIssue.isEmpty else {
            let issue = credentialIssue.isEmpty ? persistenceIssue : credentialIssue
            actionFeedback.show(
                .api, message: issue.isEmpty ? L10n.tr("Couldn’t save the key to Keychain.") : issue, tone: .failure)
            return
        }
        apiKey = ""
        actionFeedback.show(.api, message: L10n.tr("Saved to Keychain."), kind: .keySaved, tone: .success)
    }
    private func checkCLI() {
        let authorization = ProcessingPolicyController.shared.connectionTestAuthorization()
        let config = draft.cli
        let client = cliClient
        let ticket = beginTest(.cli, message: L10n.tr("Checking installation…"), configuration: config)
        testTask = Task { @MainActor in
            let inspection: CLIInspection
            do {
                inspection = try await ProcessingPolicyController.shared.performExternal(authorization: authorization) {
                    await client.inspect(configuration: config, refresh: true)
                }
            } catch {
                guard !Task.isCancelled, actionFeedback.isCurrent(ticket), draft.cli == config else { return }
                if actionFeedback.complete(
                    ticket, message: error.localizedDescription, configuration: config, tone: .failure)
                {
                    testTask = nil
                }
                return
            }
            guard !Task.isCancelled, actionFeedback.isCurrent(ticket), draft.cli == config else { return }
            let message =
                inspection.supported
                ? L10n.format(
                    "Found %1$@ (%2$@). Sign-in and translation haven’t been tested yet.",
                    config.provider.displayName, inspection.version ?? "")
                : (inspection.issue?.localizedDescription
                    ?? L10n.tr("Translation failed. Check the translation service in Settings."))
            if actionFeedback.complete(
                ticket, message: message, configuration: config, tone: inspection.supported ? .success : .failure)
            {
                testTask = nil
            }
        }
    }
    private func detectCLI() {
        let authorization = ProcessingPolicyController.shared.connectionTestAuthorization()
        let config = draft.cli
        let client = cliClient
        let ticket = beginTest(.cli, message: L10n.tr("Checking installation…"), configuration: config)
        testTask = Task { @MainActor in
            let discovered: CLILocalDiscovery
            do {
                discovered = try await ProcessingPolicyController.shared.performExternal(authorization: authorization) {
                    await client.discover(configuration: config)
                }
            } catch {
                guard !Task.isCancelled, actionFeedback.isCurrent(ticket), draft.cli == config else { return }
                if actionFeedback.complete(
                    ticket, message: error.localizedDescription, configuration: config, tone: .failure)
                {
                    testTask = nil
                }
                return
            }
            guard !Task.isCancelled, actionFeedback.isCurrent(ticket), draft.cli == config else { return }
            var resulting = config
            let message: String
            if let path = discovered.path, discovered.inspection?.supported == true {
                if config.executablePath.isEmpty || config.executablePath == config.provider.suggestedExecutablePath {
                    resulting.executablePath = path
                }
                message = L10n.tr("Detected locally. Changes are saved automatically.")
            } else {
                message =
                    discovered.inspection?.issue?.localizedDescription
                    ?? L10n.tr("No compatible CLI found. Choose its executable manually.")
            }
            // Stamp the configuration produced by detection before its binding
            // notification arrives; a later user edit still invalidates it.
            if actionFeedback.complete(
                ticket, message: message, configuration: resulting,
                tone: discovered.path != nil && discovered.inspection?.supported == true ? .success : .failure)
            {
                testTask = nil
                cliCatalog = discovered.catalog
                cliDetectedPath = discovered.path
                draft.cli = resulting
            }
        }
    }
    private func testCLI() {
        let authorization = ProcessingPolicyController.shared.connectionTestAuthorization()
        let config = draft.cli
        let client = cliClient
        let sample = ConnectionTestSample.current
        let ticket = beginTest(.cli, message: L10n.format("Translating “%@”…", sample.text), configuration: config)
        testTask = Task { @MainActor in
            do {
                let translated = try await ProcessingPolicyController.shared.performExternal(
                    authorization: authorization
                ) {
                    try await client.translate(
                        text: sample.text, source: sample.source, target: sample.target, configuration: config)
                }
                guard !Task.isCancelled, actionFeedback.isCurrent(ticket), draft.cli == config else { return }
                draft.recordWorking(.cli)
                if actionFeedback.complete(
                    ticket, message: sample.result(String(translated.prefix(120))),
                    configuration: config, tone: .success)
                {
                    testTask = nil
                }
            } catch {
                guard !Task.isCancelled, actionFeedback.isCurrent(ticket), draft.cli == config else { return }
                if actionFeedback.complete(
                    ticket, message: error.localizedDescription, configuration: config, tone: .failure)
                {
                    testTask = nil
                }
            }
        }
    }

}

#if YULLO_TESTING
    private struct SettingsEnabledProbe: NSViewRepresentable {
        @Environment(\.isEnabled) private var isEnabled
        var report: ((Bool) -> Void)?
        func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
        func updateNSView(_ nsView: NSView, context: Context) { report?(isEnabled) }
    }
#endif

enum SettingsFeedbackScope: String, CaseIterable { case api, cli, apple, direction, cache }
struct SettingsFeedbackTicket: Equatable {
    let scope: SettingsFeedbackScope
    fileprivate let id: UUID
}

// Transient action results belong to the control that produced them. Tickets
// are independent per section, so another card cannot relabel or revive a task.
@MainActor final class SettingsActionFeedback: ObservableObject {
    enum Kind: Equatable { case action, keyRemoval, keySaved }
    enum Tone: Equatable { case neutral, success, failure }
    private struct Entry {
        let ticket: SettingsFeedbackTicket
        var message: String
        var running: Bool
        var configuration: CLIConfiguration?
        var kind: Kind
        var tone: Tone = .neutral
    }
    @Published private var entries: [SettingsFeedbackScope: Entry] = [:]
    var runningConnection: SettingsFeedbackScope? { [.api, .cli].first { isRunning($0) } }
    func message(for scope: SettingsFeedbackScope) -> String? { entries[scope]?.message }
    func tone(for scope: SettingsFeedbackScope) -> Tone { entries[scope]?.tone ?? .neutral }
    func isRunning(_ scope: SettingsFeedbackScope) -> Bool { entries[scope]?.running == true }
    func isCurrent(_ ticket: SettingsFeedbackTicket) -> Bool {
        entries[ticket.scope]?.ticket == ticket && entries[ticket.scope]?.running == true
    }
    @discardableResult func begin(
        _ scope: SettingsFeedbackScope, message: String, configuration: CLIConfiguration? = nil
    ) -> SettingsFeedbackTicket {
        let ticket = SettingsFeedbackTicket(scope: scope, id: UUID())
        entries[scope] = Entry(
            ticket: ticket, message: message, running: true, configuration: configuration, kind: .action)
        return ticket
    }
    @discardableResult func complete(
        _ ticket: SettingsFeedbackTicket, message: String, configuration: CLIConfiguration? = nil,
        tone: Tone = .neutral
    ) -> Bool {
        guard isCurrent(ticket), var entry = entries[ticket.scope] else { return false }
        entry.message = message
        entry.running = false
        entry.tone = tone
        if let configuration { entry.configuration = configuration }
        entries[ticket.scope] = entry
        return true
    }
    func show(_ scope: SettingsFeedbackScope, message: String, kind: Kind = .action, tone: Tone = .neutral) {
        let ticket = begin(scope, message: message)
        _ = complete(ticket, message: message, tone: tone)
        if var entry = entries[scope] {
            entry.kind = kind
            entries[scope] = entry
        }
    }
    func clear(_ scope: SettingsFeedbackScope? = nil) {
        if let scope { entries.removeValue(forKey: scope) } else { entries.removeAll() }
    }
    func matchesCLIConfiguration(_ configuration: CLIConfiguration) -> Bool {
        entries[.cli]?.configuration == configuration
    }
    // Removing or saving a key clears the field; its confirmation stays.
    func preservesKeyRemoval(value: String) -> Bool {
        value.isEmpty && (entries[.api]?.kind == .keyRemoval || entries[.api]?.kind == .keySaved)
    }
}

private struct LaunchAtLoginSetting: View {
    @StateObject private var login = LaunchAtLogin()
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle(
                "Launch at login",
                isOn: Binding(
                    get: { login.isEnabled },
                    set: { enabled in
                        Task { await login.setEnabled(enabled) }
                    })
            ).font(.system(size: 13)).foregroundStyle(.primary).disabled(!login.canChange)
                .help("Start quietly when you log in to your Mac.")
            if let failure = login.failure {
                Text("Could not change launch at login: \(failure)").textSelection(.enabled)
            } else if login.status == .requiresApproval {
                Text("Allow Yullo in System Settings to finish enabling launch at login.")
                Button("Open Login Items Settings") { login.openSettings() }.buttonStyle(.link)
            }
        }.font(.system(size: 12)).foregroundStyle(.secondary)
            .task { await login.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await login.refresh() }
            }
    }
}

private struct AutomaticUpdatesSetting: View {
    @ObservedObject private var updates = AppUpdates.shared
    var body: some View {
        Toggle(
            L10n.tr("Automatically check for updates"),
            isOn: Binding(get: { updates.automaticChecks }, set: { updates.setAutomaticChecks($0) })
        ).font(.system(size: 13)).foregroundStyle(.primary)
    }
}

private enum SettingsIssue: Error, LocalizedError {
    case shortcutConflict
    var errorDescription: String? { L10n.tr("Choose a different shortcut for each action.") }
}

// Lights a row for a moment after Settings scrolls to it.
private struct SettingsLandedAnchorKey: EnvironmentKey {
    static let defaultValue: String? = nil
}
extension EnvironmentValues {
    var settingsLandedAnchor: String? {
        get { self[SettingsLandedAnchorKey.self] }
        set { self[SettingsLandedAnchorKey.self] = newValue }
    }
}
// The whole row lights, through the page's reserved remove slot, as System Settings does.
private struct SettingsLanding: ViewModifier {
    let anchor: String
    let ownsTrailing: Bool
    @Environment(\.settingsLandedAnchor) private var landed
    @Environment(\.settingsTrailingInset) private var trailingInset
    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.accent.opacity(0.14))
                .padding(.leading, -6).padding(.trailing, -6 - (ownsTrailing ? 0 : trailingInset))
                .opacity(landed == anchor ? 1 : 0).allowsHitTesting(false)
        }
    }
}
extension View {
    // ownsTrailing matches settingsRowOwnsTrailing() on the same row.
    func settingsLanding(_ anchor: String, ownsTrailing: Bool = false) -> some View {
        modifier(SettingsLanding(anchor: anchor, ownsTrailing: ownsTrailing))
    }
}

// The connection test translates "Hello" in the interface language into English,
// or into French when the interface is English, and shows that pair.
struct ConnectionTestSample: Equatable {
    let text: String
    let source: String
    let target: String
    static func forInterface(_ language: String) -> ConnectionTestSample {
        let words = ["zh-Hans": "你好", "zh-Hant": "你好", "fr": "Bonjour", "de": "Hallo", "it": "Ciao", "es": "Hola"]
        guard let word = words[language] else { return .init(text: "Hello", source: "en", target: "fr") }
        return .init(text: word, source: language == "zh-Hans" ? "zh" : language, target: "en")
    }
    static var current: ConnectionTestSample { forInterface(L10n.language) }
    func result(_ output: String) -> String { L10n.format("Connected. “%1$@” → “%2$@”", text, output) }
}

extension ProcessingTask {
    // The on-device service a task moves to on this Mac only: Apple
    // Translation, Apple's writing model when this Mac has it, macOS voices.
    @MainActor static func onDeviceAlternative(_ task: ProcessingTask, _ preferences: Preferences) -> String? {
        switch task {
        case .translation: return "apple"
        case .writing: return AppleWriterStatus.availability().canBecomeReady ? "apple" : nil
        case .readAloud: return "macos"
        }
    }
}

extension SettingsSearch {
    /// Rows that choose between languages wait for a second one, and search never opens a hidden row.
    static func hiddenAnchors(_ preferences: Preferences) -> Set<String> {
        var hidden: Set<String> = []
        if preferences.usesOneLanguage { hidden.insert("language-suggestions") }
        if !preferences.offersDictationLanguages { hidden.formUnion(["language-switch", "quick-languages"]) }
        return hidden
    }
}
