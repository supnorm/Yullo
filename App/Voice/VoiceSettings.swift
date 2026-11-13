import SwiftUI
import AppKit

struct AppleSpeechSettingsBackend: Sendable {
    var locales: @Sendable () async -> [AppleSpeechLocale]
    var inspect: @Sendable (String) async -> AppleSpeechAvailability
    var download: @Sendable (String) async throws -> Void
    static let system = AppleSpeechSettingsBackend(
        locales: { await VoiceResources.appleSpeech.supportedLocales() },
        inspect: { await VoiceResources.appleSpeech.inspect(localeID: $0) },
        download: { try await VoiceResources.appleSpeech.downloadAssets(localeID: $0) })
}

@MainActor final class AppleSpeechSettingsStore: ObservableObject {
    @Published private(set) var locales: [AppleSpeechLocale] = []
    @Published private(set) var availability: AppleSpeechAvailability?
    @Published private(set) var downloading = false
    @Published private(set) var message = ""
    private let backend: AppleSpeechSettingsBackend
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let pollingLimit: Int
    private var revision: UInt64 = 0
    private var preference: String?
    private var isVisible: () -> Bool = { false }
    private var refreshTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    init(
        backend: AppleSpeechSettingsBackend = .system, pollingLimit: Int = 20,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        }
    ) {
        self.backend = backend
        self.pollingLimit = min(20, max(0, pollingLimit))
        self.sleep = sleep
    }
    nonisolated static func shouldRefresh(_ notification: Notification, settingsVisible: Bool, appleVisible: Bool)
        -> Bool
    {
        settingsVisible && appleVisible
            && (notification.name == NSApplication.didBecomeActiveNotification
                || notification.name == NSWindow.didBecomeKeyNotification)
    }
    func refresh(_ preference: String, isVisible: @escaping () -> Bool = { true }) async {
        let work = startRefresh(preference, isVisible: isVisible)
        await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
    }
    func availability(for preference: String) -> AppleSpeechAvailability? {
        self.preference == preference ? availability : nil
    }
    func deactivate() {
        revision &+= 1
        preference = nil
        isVisible = { false }
        refreshTask?.cancel()
        refreshTask = nil
    }
    private func startRefresh(_ preference: String, isVisible: @escaping () -> Bool) -> Task<Void, Never> {
        refreshTask?.cancel()
        revision &+= 1
        let expected = revision
        if self.preference != preference {
            availability = nil
            message = ""
        }
        self.preference = preference
        self.isVisible = isVisible
        let work = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.inspect(preference, expected: expected)
            if self.revision == expected { self.refreshTask = nil }
        }
        refreshTask = work
        return work
    }
    private func inspect(_ preference: String, expected: UInt64) async {
        func current() -> Bool { !Task.isCancelled && revision == expected && isVisible() }
        guard current() else { return }
        let values = await backend.locales()
        guard current() else { return }
        let locale = Self.resolved(preference)
        // External system downloads have no public notification stream. Read
        // metadata only while pending and visible; do not create reservations.
        let delays: [TimeInterval] = [1, 2, 4, 8, 15, 30]
        for attempt in 0...pollingLimit {
            guard current() else { return }
            let value = await backend.inspect(locale)
            guard current() else { return }
            locales = values
            availability = value
            if value.state == .ready { message = "" }
            guard value.state == .downloading, attempt < pollingLimit else { return }
            do { try await sleep(delays[min(attempt, delays.count - 1)]) } catch { return }
        }
    }
    func download(_ preference: String) {
        guard !downloading else { return }
        downloading = true
        message = ""
        let locale = Self.resolved(preference)
        downloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.backend.download(locale) } catch {
                if self.preference == preference { self.message = error.localizedDescription }
            }
            self.downloading = false
            self.downloadTask = nil
            if let latest = self.preference, self.isVisible() {
                _ = self.startRefresh(latest, isVisible: self.isVisible)
            }
        }
    }
    private static func resolved(_ preference: String) -> String {
        preference == "system" ? Locale.current.identifier : preference
    }
}

// The recognition menu lists what works now, then every managed model that is
// not on this Mac yet, with its size; there is no size limit, and the
// recommendation marks what runs well here. Choosing one only shows it as a
// pending choice; its Download button is the explicit step.
@MainActor enum RecognitionModelMenu {
    struct Item: Identifiable, Equatable {
        let tag: String
        let title: String
        var id: String { tag }
    }
    static let libraryTag = "yullo.menu.model-library"
    static func available(installed: [InstalledLocalModel]) -> [LocalModelDescriptor] {
        let present = Set(installed.map(\.id))
        return ModelLibrary.catalog.filter {
            $0.task == .dictation && !present.contains($0.id)
        }
    }
    static func choices(selected: String, installed: [InstalledLocalModel], recommendedID: String?) -> [Item] {
        let models = installed.filter { $0.task == .dictation }
        var items = [Item(tag: VoiceRecognitionSettings.appleModelID, title: L10n.tr("Apple Speech · on device"))]
        // A saved choice that is neither here nor offered below stays visible.
        if selected != VoiceRecognitionSettings.appleModelID && !models.contains(where: { $0.id == selected })
            && !available(installed: installed).contains(where: { $0.id == selected })
        {
            items.append(
                Item(
                    tag: selected,
                    title: ModelCatalogPresentation.choiceLabel(id: selected, task: .dictation, installed: models)))
        }
        return items
            + models.map {
                Item(
                    tag: $0.id,
                    title: ModelCatalogPresentation.optionLabel($0.name, recommended: $0.id == recommendedID))
            }
    }
    // Recommended first, then smaller downloads first.
    static func downloads(installed: [InstalledLocalModel], recommendedID: String?) -> [Item] {
        available(installed: installed).sorted {
            ($0.id == recommendedID ? 0 : 1, $0.sizeBytes, $0.id) < (
                $1.id == recommendedID ? 0 : 1, $1.sizeBytes, $1.id
            )
        }
        .map {
            Item(
                tag: $0.id,
                title: ModelCatalogPresentation.optionLabel($0.name, recommended: $0.id == recommendedID) + " · "
                    + size($0.id))
        }
    }
    static func size(_ id: String) -> String {
        L10n.size(ModelLibrary.catalog.first { $0.id == id }?.sizeBytes ?? 0)
    }
    static func downloadTitle(_ id: String) -> String { L10n.format("Download (%@)", size(id)) }
    static func keptRecognizerNote(_ selected: String, installed: [InstalledLocalModel]) -> String {
        let name =
            selected == VoiceRecognitionSettings.appleModelID
            ? L10n.tr("Apple Speech")
            : installed.first { $0.id == selected }?.name ?? L10n.tr("Local model")
        return L10n.format("Dictation uses %@ until it’s downloaded.", name)
    }
    static func progressLabel(_ progress: ModelDownloadProgress?) -> String {
        if progress?.phase == .verifying { return L10n.tr("Verifying…") }
        guard let fraction = progress?.fraction, fraction.isFinite else { return L10n.tr("Downloading…") }
        let percent = min(1, max(0, fraction)).formatted(
            .percent.precision(.fractionLength(0)).locale(L10n.locale))
        return L10n.format("Downloading… %@", percent)
    }
}

// A model that is not on this Mac is only a pending choice, kept here and
// never in preferences. Its Download button is the explicit step: once the
// model is verified and installed, it becomes the saved selection, unless the
// person picked something else meanwhile. Downloading alone never changes a
// selection; the previous recognizer stays in use until then.
@MainActor final class RecognitionModelDownloadChoice: ObservableObject {
    @Published private(set) var pendingID: String?
    @Published private(set) var downloadingID: String?
    private var generation = UUID()

    func pick(_ id: String, installed: Bool, models: VoiceModelStore, selection: Binding<String>) {
        generation = UUID()
        downloadingID = nil
        if installed || id == selection.wrappedValue {
            pendingID = nil
            selection.wrappedValue = id
        } else {
            pendingID = id
            // A download already under way, from the Model library, still counts.
            if models.downloads[id] != nil { download(id, models: models, selection: selection) }
        }
    }
    func download(_ id: String, models: VoiceModelStore, selection: Binding<String>) {
        let baseline = selection.wrappedValue
        let handle = models.startOrJoinDownload(id)
        let expected = UUID()
        generation = expected
        downloadingID = id
        Task { @MainActor [weak self] in
            let installed = await models.waitForDownload(handle)
            guard let self, self.generation == expected else { return }
            self.downloadingID = nil
            guard installed, self.pendingID == id else { return }
            self.pendingID = nil
            if selection.wrappedValue == baseline { selection.wrappedValue = id }
        }
    }
}

struct RecognitionModelPicker: View {
    @Binding var selected: String
    @ObservedObject var models: VoiceModelStore
    @ObservedObject var download: RecognitionModelDownloadChoice
    var languageIDs: [String]
    let openLibrary: () -> Void
    @State private var hardware: ModelHardwareProfile?
    init(
        selected: Binding<String>, models: VoiceModelStore, download: RecognitionModelDownloadChoice,
        languageIDs: [String] = [], hardwareProfile: ModelHardwareProfile? = nil,
        openLibrary: @escaping () -> Void
    ) {
        _selected = selected
        self.models = models
        self.download = download
        self.languageIDs = languageIDs
        self.openLibrary = openLibrary
        _hardware = State(initialValue: hardwareProfile)
    }
    private var installed: [InstalledLocalModel] { models.installed.filter { $0.task == .dictation } }
    private func isInstalled(_ id: String) -> Bool {
        id == VoiceRecognitionSettings.appleModelID || installed.contains { $0.id == id }
    }
    // The pending choice shows until it is installed or replaced.
    private var shownID: String {
        guard let pending = download.pendingID, !isInstalled(pending) else { return selected }
        return pending
    }
    private var choiceLabel: String {
        shownID == VoiceRecognitionSettings.appleModelID
            ? L10n.tr("Apple Speech · on device")
            : ModelCatalogPresentation.choiceLabel(id: shownID, task: .dictation, installed: installed)
    }
    private var menuSelection: Binding<String> {
        Binding(
            get: { shownID },
            set: { tag in
                if tag == RecognitionModelMenu.libraryTag {
                    openLibrary()
                } else {
                    download.pick(tag, installed: isInstalled(tag), models: models, selection: $selected)
                }
            })
    }
    var body: some View {
        let recommendedID = hardware.flatMap {
            ModelCatalogPresentation.recommendation(
                for: .dictation, languageIDs: languageIDs, profile: $0, installed: models.installed)?.modelID
        }
        let downloads = RecognitionModelMenu.downloads(installed: models.installed, recommendedID: recommendedID)
        let shown = shownID
        VStack(alignment: .leading, spacing: 4) {
            SettingsTaskRow(title: L10n.tr("Recognition model")) {
                Picker(L10n.tr("Recognition model"), selection: menuSelection) {
                    ForEach(
                        RecognitionModelMenu.choices(
                            selected: selected, installed: models.installed, recommendedID: recommendedID)
                    ) { Text($0.title).tag($0.tag) }
                    if !downloads.isEmpty {
                        Divider()
                        Section(L10n.tr("Not downloaded")) {
                            ForEach(downloads) { Label($0.title, systemImage: "arrow.down.circle").tag($0.tag) }
                        }
                    }
                    Divider()
                    Text(L10n.tr("Browse models…")).tag(RecognitionModelMenu.libraryTag)
                }.labelsHidden().pickerStyle(.menu).settingsControlWidth().help(choiceLabel)
            }
            ModelRatingSummary(modelID: shown, recommended: shown == recommendedID)
            if !isInstalled(shown), ModelLibrary.catalog.contains(where: { $0.id == shown && $0.task == .dictation }) {
                downloadStatus(shown)
            }
        }.task { if hardware == nil { hardware = await ModelHardwareProfile.load() } }
    }
    @ViewBuilder private func downloadStatus(_ id: String) -> some View {
        Group {
            if let progress = models.downloads[id] {
                VStack(alignment: .leading, spacing: 5) {
                    if let fraction = progress.fraction, fraction.isFinite, progress.phase != .verifying {
                        ProgressView(value: min(1, max(0, fraction))).controlSize(.small)
                    } else {
                        ProgressView().progressViewStyle(.linear).controlSize(.small)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(RecognitionModelMenu.progressLabel(progress)).foregroundStyle(.secondary)
                            .monospacedDigit()
                        Spacer(minLength: 8)
                        Button(L10n.tr("Cancel")) { models.cancel(id) }.buttonStyle(.link)
                    }
                }.accessibilityIdentifier("recognition-model-download")
            } else if let message = models.errors[id] {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(message).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(L10n.tr("Retry")) { download.download(id, models: models, selection: $selected) }
                        .buttonStyle(.link)
                }.accessibilityIdentifier("recognition-model-download-failure")
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L10n.tr("Not downloaded")).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button(RecognitionModelMenu.downloadTitle(id)) {
                        download.download(id, models: models, selection: $selected)
                    }
                    .controlSize(.small).accessibilityIdentifier("recognition-model-download-action")
                }
            }
            if id != selected {
                Text(RecognitionModelMenu.keptRecognizerNote(selected, installed: installed))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.font(.system(size: 11))
    }
}

struct VoiceLivePreviewSettingsView: View {
    @Binding var enabled: Bool
    @Binding var size: String
    let isSupported: Bool
    let openModels: () -> Void
    var embedded = false
    var revealSize = false
    var recentSpeechOnly = false
    init(
        enabled: Binding<Bool>, isSupported: Bool, openModels: @escaping () -> Void,
        embedded: Bool = false, size: Binding<String> = .constant("compact"), revealSize: Bool = false,
        recentSpeechOnly: Bool = false
    ) {
        _enabled = enabled
        _size = size
        self.isSupported = isSupported
        self.openModels = openModels
        self.embedded = embedded
        self.revealSize = revealSize
        self.recentSpeechOnly = recentSpeechOnly
    }
    private var sizeSelection: Binding<String> {
        Binding(
            get: { (VoiceLivePreviewSize(rawValue: size) ?? .compact).rawValue },
            set: { value in
                guard VoiceLivePreviewSize(rawValue: value) != nil else { return }
                size = value
            })
    }
    var body: some View {
        Group {
            if embedded {
                content
            } else {
                SettingsSection(L10n.tr("Live preview")) {
                    SettingsRows { content }.background {
                        #if YULLO_TESTING
                            YulloActionPresentationProbe(title: "Live preview content", action: {})
                        #endif
                    }
                }
            }
        }
    }
    // Rows for the Recording card. A model without live words offers another model
    // in the switch's place; the reason is its help.
    // The switch stays on its row; with a model that has no live words it is off and
    // unavailable, and the quiet line under it opens the model choice.
    @ViewBuilder private var content: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tr("Show words while listening"))
                    .foregroundStyle(isSupported || enabled ? .primary : .tertiary)
                if !isSupported { needsModel }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Toggle(L10n.tr("Show words while listening"), isOn: $enabled).labelsHidden().toggleStyle(.switch)
                .controlSize(.mini)
                .background {
                    #if YULLO_TESTING
                        YulloActionPresentationProbe(title: "Show words while listening", action: {})
                    #endif
                }
                .disabled(!isSupported && !enabled).accessibilityIdentifier("voice-live-preview")
        }.id("recognition-live")
        if (enabled && isSupported) || revealSize {
            SettingsTaskRow(title: L10n.tr("Preview size")) {
                Picker(L10n.tr("Preview size"), selection: sizeSelection) {
                    ForEach(VoiceLivePreviewSize.allCases, id: \.rawValue) { option in
                        Text(L10n.tr(option.titleKey)).tag(option.rawValue)
                    }
                }.labelsHidden().pickerStyle(.menu).settingsControlWidth().disabled(!isSupported)
                    .accessibilityIdentifier("voice-live-preview-size")
            }
            if recentSpeechOnly, sizeSelection.wrappedValue == VoiceLivePreviewSize.scrolling.rawValue {
                Text(L10n.tr("Shows recent speech only."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).settingsRowAttached()
            }
        }
    }
    // The reason under the label; clicking it opens the model choice.
    private var needsModel: some View {
        Button(action: openModels) {
            Text(L10n.tr("Needs a model with live preview.")).font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.leading).contentShape(Rectangle())
        }.buttonStyle(.plain).help(LiveRecognitionIssue.unsupported.localizedDescription)
            .accessibilityIdentifier("voice-live-preview-models")
            .background {
                #if YULLO_TESTING
                    YulloActionPresentationProbe(title: "Choose a model with live preview…", action: openModels)
                #endif
            }
    }
}

struct DictationSettingsView: View {
    // Seconds in the interface language: "2.5 s", "2.5 秒".
    private static func seconds(_ value: Double) -> String {
        L10n.format("%@ s", value.formatted(.number.precision(.fractionLength(0...1)).locale(L10n.locale)))
    }
    @Binding var draft: Preferences
    @ObservedObject var models: VoiceModelStore
    @ObservedObject var voice: VoiceInputCoordinator
    let openModels: () -> Void
    var revealedSections: Set<SettingsVisibilitySection> = []
    var isPresented: () -> Bool = { true }
    // Every assigned key, so a row's suggestion never offers one in use.
    var takenShortcuts: [Shortcut] = []
    // Opens Services at an anchor for a shared engine's setup.
    var openServices: (String) -> Void = { _ in }
    @StateObject private var appleSpeech = AppleSpeechSettingsStore()
    @StateObject private var recognitionDownload = RecognitionModelDownloadChoice()
    @State private var appleSpeechActivation: UInt64 = 0
    private var showsAppleSpeechSettings: Bool {
        draft.voiceModelID == VoiceRecognitionSettings.appleModelID || draft.voiceAppleFallback
            || revealedSections.contains(.recognitionOptions)
    }
    private var livePreviewMode: LiveRecognitionSupport.Mode? {
        LiveRecognitionSupport.mode(
            modelID: draft.voiceModelID,
            architecture: models.installed.first { $0.id == draft.voiceModelID }?.architecture)
    }
    private var supportsLivePreview: Bool { livePreviewMode != nil }
    private var appleSpeechOfflineNote: String? {
        guard let value = appleSpeech.availability, value.state == .ready else { return nil }
        return L10n.tr("Available offline")
    }
    @ViewBuilder private var appleSpeechConfiguration: some View {
        SettingsTaskRow(title: L10n.tr("Apple Speech language"), caption: appleSpeechOfflineNote) {
            Picker(L10n.tr("Apple Speech language"), selection: $draft.voiceAppleLocale) {
                Text(L10n.tr("System language")).tag("system")
                if draft.voiceAppleLocale != "system"
                    && !appleSpeech.locales.contains(where: { $0.id == draft.voiceAppleLocale })
                {
                    Text(draft.voiceAppleLocale).tag(draft.voiceAppleLocale)
                }
                ForEach(appleSpeech.locales) { Text($0.name).tag($0.id) }
            }.labelsHidden().pickerStyle(.menu).settingsControlWidth().disabled(appleSpeech.downloading)
        }.id("recognition-language")
        if let value = appleSpeech.availability {
            switch value.state {
            case .ready:
                EmptyView()
            case .needsDownload, .downloading:
                HStack {
                    Spacer(minLength: 0)
                    if appleSpeech.downloading || value.state == .downloading {
                        ProgressView().controlSize(.small)
                    }
                    Button(
                        L10n.tr(
                            appleSpeech.downloading || value.state == .downloading
                                ? "Downloading Apple Speech language…" : "Download Apple Speech language")
                    ) { appleSpeech.download(draft.voiceAppleLocale) }
                    .disabled(appleSpeech.downloading || value.state == .downloading)
                }.settingsRowAttached()
            case .unsupportedLocale:
                Text(L10n.tr("Choose another Apple Speech language or use a local model.")).font(
                    .system(size: 11)
                ).foregroundStyle(.secondary).settingsRowAttached()
            case .unavailableDevice:
                Text(L10n.tr("Apple Speech isn’t available on this Mac. Choose a local model."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).settingsRowAttached()
            }
        }
        if !appleSpeech.message.isEmpty {
            Text(appleSpeech.message).font(.system(size: 11)).foregroundStyle(.secondary).settingsRowAttached()
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Like every task page: keys and what they write, the engine that does the
            // work, then how a recording runs and what happens after it.
            DictationOutputsSettings(
                draft: $draft, models: models, taken: takenShortcuts, openServices: openServices,
                revealedSections: revealedSections)
            recognitionSection.padding(.top, 22)
            recordingSection.padding(.top, 22)
            afterSpeakingSection.padding(.top, 22)
        }.font(.system(size: 13)).environment(\.settingsTrailingInset, SettingsOutputColumns.removeInset)
            .disabled(voice.isBusy).task { await models.refresh() }
            .task(
                id: AppleSpeechRefreshID(
                    preference: draft.voiceAppleLocale, activation: appleSpeechActivation,
                    visible: showsAppleSpeechSettings)
            ) {
                await appleSpeech.refresh(
                    draft.voiceAppleLocale, isVisible: { isPresented() && showsAppleSpeechSettings })
            }
            .onReceive(
                NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                    .merge(with: NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification))
            ) { notification in
                if AppleSpeechSettingsStore.shouldRefresh(
                    notification, settingsVisible: isPresented(), appleVisible: showsAppleSpeechSettings)
                {
                    appleSpeechActivation &+= 1
                }
            }
            .onDisappear { appleSpeech.deactivate() }
    }
    private var recognitionSection: some View {
        SettingsSection(L10n.tr("Speech recognition")) {
            SettingsRows {
                RecognitionModelPicker(
                    selected: $draft.voiceModelID, models: models, download: recognitionDownload,
                    languageIDs: draft.voiceRecognitionLanguage == "auto"
                        ? draft.modelSuggestionLanguageIDs : [draft.voiceRecognitionLanguage],
                    openLibrary: openModels)
                if VoiceRecognitionSettings.requiresLanguageHint(
                    modelID: draft.voiceModelID,
                    architecture: models.installed.first { $0.id == draft.voiceModelID }?.architecture)
                {
                    RecognitionLanguageSetting(
                        selected: $draft.voiceRecognitionLanguage, modelID: draft.voiceModelID,
                        personal: draft.modelSuggestionLanguageIDs,
                        localizedNames: draft.showLocalizedLanguageNames)
                } else if WhisperLanguageSetting.applies(to: draft.voiceModelID, installed: models.installed) {
                    WhisperLanguageSetting(
                        selected: $draft.voiceRecognitionLanguage,
                        languageIDs: WhisperLanguageSetting.choices(
                            modelID: draft.voiceModelID, personal: draft.modelSuggestionLanguageIDs),
                        localizedNames: draft.showLocalizedLanguageNames)
                }
                if draft.voiceModelID == VoiceRecognitionSettings.appleModelID {
                    appleSpeechConfiguration
                } else {
                    Toggle(
                        L10n.tr("Use Apple Speech if local recognition fails"),
                        isOn: $draft.voiceAppleFallback
                    ).id("apple-fallback")
                    if showsAppleSpeechSettings || appleSpeech.downloading || !appleSpeech.message.isEmpty {
                        appleSpeechConfiguration
                    }
                }
            }
        }.id("recognition")
    }
    // How a recording runs: live words, how it ends, and where its indicator sits.
    // A dependent row shows only while the switch it qualifies is on.
    private var recordingSection: some View {
        SettingsSection(L10n.tr("Recording")) {
            SettingsRows {
                VoiceLivePreviewSettingsView(
                    enabled: $draft.voiceLivePreview, isSupported: supportsLivePreview,
                    openModels: openModels, embedded: true, size: $draft.voiceLivePreviewSize,
                    revealSize: revealedSections.contains(.livePreview),
                    recentSpeechOnly: livePreviewMode == .recentWindow
                )
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(L10n.tr("End recording")).frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(L10n.tr("Press Return"), isOn: $draft.voiceFinishOnReturn)
                            .disabled(
                                !draft.voiceAutoFinish && !draft.voiceFinishOnShortcut && draft.voiceFinishOnReturn)
                        Toggle(
                            draft.dictationShortcut.isAssigned
                                ? L10n.format("Press %@ again", draft.dictationShortcut.displayLabel)
                                : L10n.tr("Press shortcut again"), isOn: $draft.voiceFinishOnShortcut
                        )
                        .help(L10n.tr("Press the shortcut that started recording."))
                        .accessibilityIdentifier("voice-finish-shortcut")
                        .disabled(
                            !draft.voiceFinishOnReturn && !draft.voiceAutoFinish && draft.voiceFinishOnShortcut)
                        Toggle(L10n.tr("After a pause"), isOn: $draft.voiceAutoFinish)
                            .disabled(
                                !draft.voiceFinishOnReturn && !draft.voiceFinishOnShortcut && draft.voiceAutoFinish)
                    }.toggleStyle(.checkbox).frame(width: SettingsControl.width, alignment: .leading)
                }.padding(.vertical, 3).id("finish")
                if draft.voiceAutoFinish {
                    SettingsTaskRow(title: L10n.tr("Pause duration")) {
                        SettingsSliderControl(
                            value: $draft.voiceSilenceSeconds, range: 1...10, step: 0.5,
                            label: L10n.tr("Pause duration"),
                            text: Self.seconds(draft.voiceSilenceSeconds))
                    }
                }
                if draft.effectiveVoiceFinishPolicy(forVoiceTranslation: false).usesReturnFallback
                    || draft.effectiveVoiceFinishPolicy(forVoiceTranslation: true).usesReturnFallback
                {
                    Text(L10n.tr("Return ends recording when no other option is selected."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).settingsRowAttached()
                }
                RecordingIndicatorPlacementPicker(placement: $draft.voicePlacement, isEnabled: !voice.isBusy)
                    .padding(.bottom, 4).id("indicator")
            }
        }.id("recording")
    }
    // Review first, then the comparison that only a reviewed result can show.
    private var afterSpeakingSection: some View {
        SettingsSection(L10n.tr("After you speak")) {
            SettingsRows {
                Toggle(L10n.tr("Review before inserting"), isOn: $draft.voicePreviewFirst)
                    .id("completion-mode").accessibilityIdentifier("voice-review-before-inserting")
                // Only a reviewed result can show the comparison, so it appears with Review.
                if draft.voicePreviewFirst {
                    Toggle(L10n.tr("Show before and after"), isOn: $draft.voiceResultComparisonEnabled)
                        .accessibilityIdentifier("voice-result-comparison-enabled")
                }
            }
        }.id("after-speaking")
    }

}

extension Preferences {
    // One language is the default story: controls that only choose between languages
    // wait until there is another. Derived, never saved; adding one brings them back as left.
    var usesOneLanguage: Bool { Language.enabled(enabledLanguages).count <= 1 }
    // The language button, Quick languages and the menu bar's Dictation Language: with
    // one language, only while some dictation output already writes another language.
    var offersDictationLanguages: Bool {
        guard usesOneLanguage else { return true }
        let yours = Set(Language.enabled(enabledLanguages).map(\.id))
        let written = [outputs.everywhere] + outputs.rules.map(\.output) + outputs.dictationShortcuts.map(\.output)
        return written.contains { $0.language.map { !yours.contains($0) } ?? false }
    }
    // The same, for a recording: also while it writes a language that isn't one of yours.
    func offersDictationLanguages(writing language: String?) -> Bool {
        offersDictationLanguages
            || language.map { id in !Language.enabled(enabledLanguages).contains { $0.id == id } } == true
    }
    // Quick languages: the dictation languages the language button cycles through and
    // the menu bar offers, in the order of Your languages. Empty means your first two.
    var quickLanguageIDs: [String] {
        let yours = Language.enabled(enabledLanguages).map(\.id)
        let chosen = Language.switchIDs(voiceLanguageSwitchLanguages)
        guard !chosen.isEmpty else { return Array(yours.prefix(2)) }
        return chosen.sorted { (yours.firstIndex(of: $0) ?? .max) < (yours.firstIndex(of: $1) ?? .max) }
    }
}

// What dictation writes: the language button on the recording indicator, then the
// quick languages it and the menu bar offer, a checklist of Your languages (up to three).
struct QuickLanguagesRow: View {
    @Binding var draft: Preferences
    @State private var browsing = false
    private var chosen: [String] { draft.quickLanguageIDs }
    // Named as everywhere else: Names in English decides.
    private func name(_ id: String) -> String {
        OutputPresentation.languageTitle(id, localized: draft.showLocalizedLanguageNames)
    }
    // Whole names only: short names without their variant ("Chinese"), then the
    // leading names and a count when they still don't fit the control.
    private var summary: String {
        guard !chosen.isEmpty else { return L10n.tr("Same as I speak") }
        let names = chosen.map { name($0).components(separatedBy: " (").first ?? name($0) }
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let fits = { (text: String) in (text as NSString).size(withAttributes: [.font: font]).width <= 180 }
        let separator = L10n.listSeparator
        for count in stride(from: names.count, through: 1, by: -1) {
            let shown = names.prefix(count).joined(separator: separator)
            let text = count == names.count ? shown : shown + " + \(names.count - count)"
            if fits(text) || count == 1 { return text }
        }
        return names[0]
    }
    var body: some View {
        if draft.offersDictationLanguages {
            rows
        }
    }
    @ViewBuilder private var rows: some View {
        Toggle(L10n.tr("Show language button"), isOn: $draft.voiceLanguageSwitch)
            .accessibilityIdentifier("voice-language-switch").id("language-switch")
        SettingsTaskRow(title: L10n.tr("Quick languages")) {
            Menu(summary) {
                ForEach(Language.enabled(draft.enabledLanguages)) { language in
                    Toggle(
                        name(language.id),
                        isOn: Binding(
                            get: { chosen.contains(language.id) }, set: { toggle(language.id, on: $0) })
                    )
                    // Plain menu checkmarks: the Settings row toggle style would split each item in two.
                    .toggleStyle(.automatic)
                    .disabled(!chosen.contains(language.id) && chosen.count >= Language.maximumSwitchCount)
                }
                Divider()
                Button(L10n.tr("More languages…")) { browsing = true }
            }.labelsHidden().settingsControlWidth()
                .help(L10n.tr("The language button cycles through these in this order, then Same as I speak."))
                .accessibilityIdentifier("voice-quick-languages")
        }.settingsLanding("quick-languages").id("quick-languages")
            .sheet(isPresented: $browsing) {
                MoreLanguagesSheet(
                    localizedNames: draft.showLocalizedLanguageNames, excluded: chosen,
                    choose: { id, _ in
                        // The list follows Your languages, so a new one joins them too.
                        if !draft.enabledLanguages.contains(id) { draft.enabledLanguages.append(id) }
                        toggle(id, on: true)
                        browsing = false
                    }, cancel: { browsing = false }
                ).glassSheet()
            }
    }
    private func toggle(_ id: String, on: Bool) {
        var ids = chosen
        if on {
            guard !ids.contains(id), ids.count < Language.maximumSwitchCount else { return }
            ids.append(id)
        } else {
            ids.removeAll { $0 == id }
        }
        draft.voiceLanguageSwitchLanguages = ids
    }
}

// A pure preference control: its illustrations never open an overlay or request access.
// Each placement is a card showing where the indicator appears, so the choice is
// made by looking rather than by reading a menu and expanding a preview.
struct RecordingIndicatorPlacementPicker: View {
    @Binding var placement: String
    let isEnabled: Bool
    var previewNote: String? = nil
    // Off where a row that opens the picker already names it.
    var showsTitle = true
    private let positions: [VoiceOverlayPlacement] = [.notch, .bottom, .caret]
    var selection: Binding<String> {
        Binding(
            get: { placement },
            set: { value in
                guard isEnabled, positions.contains(where: { $0.rawValue == value }) else { return }
                placement = value
            })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsTitle { Text(L10n.tr("Recording indicator")) }
            HStack(spacing: 10) {
                ForEach(positions, id: \.rawValue) { position in
                    RecordingIndicatorPlacementCard(
                        position: position, selected: placement == position.rawValue
                    ) { selection.wrappedValue = position.rawValue }
                }
            }.disabled(!isEnabled)
            if let note = previewNote ?? placementNote {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.id("indicator-placement")
    }
    private var placementNote: String? {
        switch VoiceOverlayPlacement(rawValue: placement) {
        case .notch: return L10n.tr("Top center without a notch.")
        case .caret: return L10n.tr("Bottom bar when there’s no text field.")
        default: return nil
        }
    }
    static func title(_ position: VoiceOverlayPlacement) -> String {
        switch position {
        case .notch: return L10n.tr("Notch")
        case .bottom: return L10n.tr("Bottom bar")
        case .caret: return L10n.tr("Near caret")
        }
    }
}

struct RecordingIndicatorPlacementCard: View {
    let position: VoiceOverlayPlacement
    let selected: Bool
    let choose: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        Button(action: choose) {
            VStack(spacing: 5) {
                // A small thumbnail: the choice is made by looking, without a large block on the page.
                RecordingIndicatorPlacementPreview(placement: position).scaleEffect(0.72).frame(width: 66, height: 40)
                Text(RecordingIndicatorPlacementPicker.title(position))
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }.padding(6).frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(selected ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.03))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 9).strokeBorder(
                        selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain).opacity(isEnabled ? 1 : 0.5)
            .accessibilityLabel(RecordingIndicatorPlacementPicker.title(position))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .help(RecordingIndicatorPlacementPicker.title(position))
            .background {
                #if YULLO_TESTING
                    YulloActionPresentationProbe(
                        title: "Recording placement \(position.rawValue)", action: choose)
                #endif
            }
    }
}

// A miniature screen with a text window and the indicator in its place, drawn
// like the real one: a black band grown out of the notch, or the flat dark HUD
// pill (black at 0.78 in light mode, rgb(58, 58, 62) at 0.92 in dark mode).
// Fixed geometry keeps it visible in any container, including disclosures.
struct RecordingIndicatorPlacementPreview: View {
    let placement: VoiceOverlayPlacement
    @Environment(\.colorScheme) private var colorScheme
    private let width: CGFloat = 92
    private let height: CGFloat = 56
    private let window = CGRect(x: 16, y: 14, width: 60, height: 32)
    private var caret: CGPoint { CGPoint(x: window.minX + 27, y: window.minY + 23) }
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.04))
            Rectangle().fill(.primary.opacity(0.06)).frame(width: width - 2, height: 5).position(x: width / 2, y: 3.5)
            RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.25))
            VStack(alignment: .leading, spacing: 4) {
                ForEach([0.8, 0.6], id: \.self) { fraction in
                    RoundedRectangle(cornerRadius: 1).fill(.secondary.opacity(0.3))
                        .frame(width: 48 * fraction, height: 2.5)
                }
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 1).fill(.secondary.opacity(0.3)).frame(width: 18, height: 2.5)
                    Rectangle().fill(Color.accentColor).frame(width: 1, height: 7)
                }
            }.padding(6).frame(width: window.width, height: window.height, alignment: .topLeading)
                .background(.background, in: RoundedRectangle(cornerRadius: 3))
                .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(0.18)) }
                .position(x: window.midX, y: window.midY)
            switch placement {
            case .notch: notchBand.position(x: width / 2, y: 6)
            case .bottom: pill.position(x: width / 2, y: height - 8)
            case .caret: pill.position(x: caret.x + 12, y: caret.y + 9)
            }
        }.frame(width: width, height: height)
            .accessibilityHidden(true)
    }
    // The camera housing sits in the middle; activity and Stop occupy the wings.
    private var notchBand: some View {
        HStack(spacing: 0) {
            Image(systemName: "waveform").font(.system(size: 5.5, weight: .bold)).frame(maxWidth: .infinity)
            Color.clear.frame(width: 14)
            Circle().fill(.white.opacity(0.85)).frame(width: 4, height: 4).frame(maxWidth: .infinity)
        }.foregroundStyle(.white.opacity(0.92)).frame(width: 48, height: 12)
            .background(
                Color(white: 0.025),
                in: UnevenRoundedRectangle(bottomLeadingRadius: 5, bottomTrailingRadius: 5))
    }
    private var pill: some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform").font(.system(size: 5.5, weight: .bold))
            Circle().fill(.white.opacity(0.85)).frame(width: 4, height: 4)
        }.foregroundStyle(.white.opacity(0.92)).frame(width: 24, height: 10)
            .background(VoiceHUDFill.color(dark: colorScheme == .dark, opaque: false), in: Capsule())
            .overlay { Capsule().strokeBorder(.white.opacity(colorScheme == .dark ? 0.18 : 0)) }
    }
}

private struct AppleSpeechRefreshID: Equatable {
    let preference: String
    let activation: UInt64
    let visible: Bool
}

// A model that needs a stated language offers only the languages it lists:
// the user's own first, then the rest. A saved value outside the list stays
// visible rather than silently changing.
struct RecognitionLanguageSetting: View {
    @Binding var selected: String
    var modelID = "cohere-transcribe-q4"
    var personal: [String] = []
    var localizedNames: Bool = false
    static func choices(modelID: String, personal: [String]) -> (personal: [String], others: [String]) {
        let accepted = VoiceRecognitionSettings.cohereLanguageIDs
        let listed = ModelDiscoveryCatalog.entries.first(where: { $0.managedModelIDs.contains(modelID) })?.languageIDs
        let supported = listed.map { $0.filter(accepted.contains) } ?? accepted
        let own = personal.filter(supported.contains)
        return (own, supported.filter { !own.contains($0) })
    }
    var body: some View {
        let options = Self.choices(modelID: modelID, personal: personal)
        SettingsTaskRow(title: L10n.tr("Spoken language")) {
            Picker(L10n.tr("Spoken language"), selection: $selected) {
                Text(L10n.tr("Choose language")).tag("auto")
                if selected != "auto", !(options.personal + options.others).contains(selected) {
                    Text(Self.languageName(selected, localized: localizedNames)).tag(selected)
                }
                ForEach(options.personal, id: \.self) { code in
                    Text(Self.languageName(code, localized: localizedNames)).tag(code)
                }
                if !options.personal.isEmpty, !options.others.isEmpty { Divider() }
                ForEach(options.others, id: \.self) { code in
                    Text(Self.languageName(code, localized: localizedNames)).tag(code)
                }
            }.labelsHidden().pickerStyle(.menu).settingsControlWidth().accessibilityIdentifier(
                "recognition-spoken-language")
        }
    }
    static func languageName(_ code: String, localized: Bool, locale: Locale = L10n.locale) -> String {
        if localized, let name = locale.localizedString(forLanguageCode: code) { return name }
        return Language.catalog.first { $0.id == code }?.name ?? code
    }
}

// Whisper detects the spoken language unless one is chosen. Detection encodes
// the first 30-second window a second time, which with the larger models adds
// about a second after Stop. A fixed language can mistranscribe other or mixed
// languages, so the caption names that trade-off for the current choice.
struct WhisperLanguageSetting: View {
    @Binding var selected: String
    let languageIDs: [String]
    var localizedNames: Bool = false
    static func applies(to modelID: String, installed: [InstalledLocalModel]) -> Bool {
        (ModelLibrary.catalog.first { $0.id == modelID }?.runtime ?? installed.first { $0.id == modelID }?.runtime)
            == .whisper
    }
    // The user's own languages that the model lists, in their order.
    static func choices(modelID: String, personal: [String]) -> [String] {
        guard
            let supported = ModelDiscoveryCatalog.entries.first(where: { $0.managedModelIDs.contains(modelID) })?
                .languageIDs
        else { return personal }
        return personal.filter(supported.contains)
    }
    private var options: [String] {
        selected == "auto" || languageIDs.contains(selected) ? languageIDs : languageIDs + [selected]
    }
    private func name(_ code: String) -> String {
        RecognitionLanguageSetting.languageName(code, localized: localizedNames)
    }
    // The trade-off of the current choice is the row's help, not a caption.
    @ViewBuilder var body: some View {
        SettingsTaskRow(title: L10n.tr("Spoken language")) {
            Picker(L10n.tr("Spoken language"), selection: $selected) {
                Text(L10n.tr("Detect automatically")).tag("auto")
                ForEach(options, id: \.self) { code in Text(name(code)).tag(code) }
            }.labelsHidden().pickerStyle(.menu).settingsControlWidth().accessibilityIdentifier(
                "recognition-whisper-language")
        }.help(
            selected == "auto"
                ? L10n.tr(
                    "Detecting the language adds a second recognition pass after you stop, about a second with larger models. If you dictate in one language, choose it."
                )
                : L10n.tr(
                    "Text arrives sooner. Speech in another language, or mixing languages, may be transcribed incorrectly."
                ))
        if selected == "auto", languageIDs.count == 1, let only = languageIDs.first {
            HStack {
                Spacer(minLength: 0)
                Button(L10n.format("Choose %@", name(only))) { selected = only }.buttonStyle(.link)
                    .font(.system(size: 11))
            }.settingsRowAttached()
        }
    }
}

enum VoiceOutputTargetPolicy {
    static func normalized(_ current: String, mode: String, languages: [Language]) -> String {
        if languages.contains(where: { $0.id == current }) { return current }
        return mode == "translate" ? languages.first?.id ?? Language.fallbackIDs[0] : "original"
    }
}

// "On this Mac" on Services: the installed models for one task, then the
// catalog's models not yet installed behind "Browse models (N)". One task
// control drives both, and a finished download stays in Browse until the
// task changes or Browse closes, so nothing moves under the pointer.
struct LocalModelLibraryView: View {
    @Binding var selections: LocalModelSelection
    @Binding var task: ModelDiscoveryTask
    var selectedLanguageIDs: [String] = Language.fallbackIDs
    var recommendationLanguageIDs: [String]? = nil
    var livePreviewRequested = false
    @ObservedObject var models: VoiceModelStore
    @ObservedObject var voice: VoiceInputCoordinator
    // A link or search result that asks for Browse opens it.
    var browseRequest: UUID? = nil
    @State private var browsing: Bool
    @State private var hardware: ModelHardwareProfile?
    init(
        selections: Binding<LocalModelSelection>, task: Binding<ModelDiscoveryTask>,
        selectedLanguageIDs: [String] = Language.fallbackIDs, recommendationLanguageIDs: [String]? = nil,
        livePreviewRequested: Bool = false, models: VoiceModelStore, voice: VoiceInputCoordinator,
        browseRequest: UUID? = nil, browsing: Bool = false, hardwareProfile: ModelHardwareProfile? = nil
    ) {
        _selections = selections
        _task = task
        self.selectedLanguageIDs = selectedLanguageIDs
        self.recommendationLanguageIDs = recommendationLanguageIDs
        self.livePreviewRequested = livePreviewRequested
        self.models = models
        self.voice = voice
        self.browseRequest = browseRequest
        _browsing = State(initialValue: browsing || browseRequest != nil)
        _hardware = State(initialValue: hardwareProfile)
    }
    private func selection(for task: ModelDiscoveryTask) -> Binding<String> {
        LocalModelSelection.binding($selections, task: task)
    }
    private var recommendedEntryName: String? {
        guard let hardware,
            let id = ModelCatalogPresentation.recommendation(
                for: task, languageIDs: recommendationLanguageIDs ?? selectedLanguageIDs, profile: hardware,
                installed: models.installed, livePreview: livePreviewRequested)?.modelID,
            !models.installed.contains(where: { $0.id == id && $0.task == task })
        else { return nil }
        return ModelDiscoveryCatalog.entries.first { $0.task == task && $0.managedModelIDs.contains(id) }?.name
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(L10n.tr("On this Mac")).font(.system(size: 14, weight: .semibold)).fixedSize()
                Spacer(minLength: 0)
                importButton
            }.frame(maxWidth: .infinity, alignment: .leading)
            Picker(L10n.tr("Task"), selection: $task) {
                Text(L10n.tr("Dictation")).tag(ModelDiscoveryTask.dictation)
                Text(L10n.tr("Translation")).tag(ModelDiscoveryTask.translation)
                Text(L10n.tr("Read aloud")).tag(ModelDiscoveryTask.readAloud)
            }.pickerStyle(.segmented).labelsHidden()
            let rows = ModelCatalogPresentation.localRows(
                installed: models.installed, downloads: models.downloads, errors: models.errors,
                selected: selections.id(for: task), task: task
            )
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("Installed")).font(.system(size: 12)).foregroundStyle(.secondary)
                if rows.isEmpty {
                    Text(L10n.tr("No models yet.")).font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                } else {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            LocalVoiceModelRow(
                                row: row, selected: selection(for: row.task), models: models, voice: voice)
                            if row.id != rows.last?.id { Divider() }
                        }
                    }.padding(.horizontal, 10).settingsCard()
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                browseToggle
                if browsing {
                    Divider()
                    ModelCatalogView(
                        selections: $selections, task: $task, selectedLanguageIDs: selectedLanguageIDs,
                        models: models, voice: voice, livePreviewRequested: livePreviewRequested,
                        hardwareProfile: hardware, recommendationLanguageIDs: recommendationLanguageIDs)
                }
            }.padding(.horizontal, 10).settingsCard().id("model-browse")
            if !models.message.isEmpty {
                Text(models.message).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.task {
            if hardware == nil { hardware = await ModelHardwareProfile.load() }
            await models.refresh()
        }
        .onChange(of: browseRequest) { _, request in if request != nil { browsing = true } }
        .onDisappear { models.dismissImportMessage() }
    }
    private var browseToggle: some View {
        Button {
            browsing.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary).rotationEffect(.degrees(browsing ? 90 : 0))
                Text(
                    L10n.format(
                        "Browse models (%ld)",
                        ModelCatalogPresentation.browseCount(task: task, installed: models.installed))
                ).fixedSize()
                Spacer(minLength: 8)
                // The suggestion gives way first; the title never truncates.
                if !browsing, let name = recommendedEntryName {
                    Text(L10n.format("Recommended: %@", name)).font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }.contentShape(Rectangle()).padding(.vertical, 10)
        }.buttonStyle(.plain)
            .accessibilityAddTraits(browsing ? .isSelected : [])
            .accessibilityIdentifier("browse-models")
    }
    private var importButton: some View {
        Button(
            L10n.tr(
                models.importing
                    ? "Importing…"
                    : task == .dictation
                        ? "Import speech model…"
                        : task == .translation ? "Import translation model…" : "Import voice model…")
        ) { ModelImportPanel.open(models: models, task: task) }
        .buttonStyle(.link).fixedSize().disabled(voice.isBusy || models.importing)
    }
}
