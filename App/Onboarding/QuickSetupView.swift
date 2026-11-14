import SwiftUI
import AppKit

#if YULLO_TESTING
    struct QuickSetupAttachedActions {
        let coordinator: QuickSetupCoordinator
        let isApplying: () -> Bool
        let applyIssue: Binding<String?>
        let apply: () -> Void
        let primary: () -> Void
        let secondary: () -> Void
        let close: () -> Void
        let configure: (SettingsConnectionSection) -> Void
        let browse: (ModelDiscoveryTask) -> Void
        let selectModel: (String, ModelTask) -> Void
    }
#endif

enum QuickSetupPrimaryAction: Equatable {
    case download, retry, downloading, verifying, apply, services, blocked
    static func resolve(
        route: QuickSetupRoute, preparing: Bool, applying: Bool, active: Bool,
        downloading: Bool, canApply: Bool, canDownload: Bool, failed: Bool
    ) -> Self {
        if route == .services { return .services }
        if preparing || applying { return .verifying }
        if active { return downloading ? .downloading : .verifying }
        if canApply { return .apply }
        if canDownload { return failed ? .retry : .download }
        return .blocked
    }
    var isEnabled: Bool {
        switch self {
        case .download, .retry, .apply, .services: return true
        default: return false
        }
    }
    func title(size: String) -> String {
        switch self {
        case .download: return L10n.format("Download models (%@)", size)
        case .retry: return L10n.format("Retry downloads (%@)", size)
        case .downloading: return L10n.tr("Downloading…")
        case .verifying: return L10n.tr("Verifying…")
        case .apply, .blocked: return L10n.tr("Apply setup")
        case .services: return L10n.tr("Allow online services")
        }
    }
}

struct QuickSetupView: View {
    @ObservedObject var models: VoiceModelStore
    let apply: (QuickSetupPatch) -> String?
    let openServices: () -> Void
    let openService: ((SettingsConnectionSection) -> Void)?
    let openLocalModels: (ModelDiscoveryTask) -> Void
    private let preferences: Preferences
    private let selectedLanguageIDs: [String]
    private let livePreviewRequested: Bool
    @Environment(\.dismiss) private var dismiss
    @StateObject private var setup: QuickSetupCoordinator
    private var applying: Bool { setup.isApplying }
    @State private var applyIssue: String?
    @State private var applyTask: Task<Void, Never>?
    #if YULLO_TESTING
        var yulloTestingCaptureAttachedActions: ((QuickSetupAttachedActions) -> Void)?
    #endif
    init(
        preferences: Preferences, models: VoiceModelStore, apply: @escaping (QuickSetupPatch) -> String?,
        openServices: @escaping () -> Void,
        openService: ((SettingsConnectionSection) -> Void)? = nil,
        openLocalModels: @escaping (ModelDiscoveryTask) -> Void,
        coordinator: QuickSetupCoordinator? = nil
    ) {
        self.models = models
        self.apply = apply
        self.openServices = openServices
        self.openService = openService
        self.openLocalModels = openLocalModels
        self.preferences = preferences
        selectedLanguageIDs = preferences.enabledLanguages
        livePreviewRequested = preferences.voiceLivePreview
        _setup = StateObject(
            wrappedValue: coordinator ?? QuickSetupCoordinator(preferences: preferences, models: models))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.tr("Quick setup")).font(.system(size: 20, weight: .semibold))
            Picker(L10n.tr("Where Yullo works"), selection: $setup.route) {
                Text(L10n.tr("On this Mac only")).tag(QuickSetupRoute.onDevice)
                Text(L10n.tr("On this Mac and online")).tag(QuickSetupRoute.services)
            }.pickerStyle(.segmented).labelsHidden().disabled(applying)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { taskSetup }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 10)
            }
            .scrollIndicators(.visible)
            Divider()
            if setup.hasActiveDownloads || setup.hasOwnedActiveDownloads {
                Text(L10n.tr("Downloads continue when you close setup."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("quick-setup-download-notice")
            }
            if let applyIssue {
                Text(applyIssue).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .accessibilityIdentifier("quick-setup-apply-issue")
            }
            HStack(spacing: 12) {
                // Each model row has its own Browse link; the footer only cancels downloads.
                if setup.hasOwnedActiveDownloads {
                    Button(L10n.tr("Cancel downloads"), action: performSecondaryAction)
                        .buttonStyle(.link).disabled(applying).accessibilityIdentifier("quick-setup-secondary")
                }
                Spacer()
                // Done already closes when nothing would change.
                if !(primaryAction == .services && changesNothing) {
                    Button(L10n.tr("Close"), action: closeSetup).keyboardShortcut(.cancelAction)
                }
                Button(
                    primaryTitle,
                    action: performPrimaryAction
                )
                .disabled(!primaryAction.isEnabled || applying).keyboardShortcut(.defaultAction)
                // The download size is never cut off.
                .fixedSize()
                .accessibilityIdentifier("quick-setup-primary")
            }
        }.font(.system(size: 13)).padding(24)
            .frame(width: 550, height: 510)
            .environment(\.locale, L10n.locale)
            .onExitCommand(perform: closeSetup)
            .task {
                #if YULLO_TESTING
                    yulloTestingCaptureAttachedActions?(
                        .init(
                            coordinator: setup, isApplying: { setup.isApplying }, applyIssue: $applyIssue,
                            apply: applySetup,
                            primary: performPrimaryAction, secondary: performSecondaryAction, close: closeSetup,
                            configure: configureService, browse: browseModels, selectModel: selectModel))
                #endif
                await setup.prepare()
            }
            .onChange(of: setup.route) { _, _ in
                applyIssue = nil
            }
            .onChange(of: setup.translationEngine) { _, _ in refreshReadiness() }
            .onChange(of: plannedInstalledModels) { _, _ in refreshReadiness() }
            .onChange(of: setup.plan) { _, _ in refreshReadiness() }
            .onChange(of: plannedDownloadIDs) { _, _ in refreshReadiness() }
            .onChange(of: plannedErrors) { _, _ in refreshReadiness() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                setup.refreshVoices()
            }
            .onDisappear { applyTask?.cancel() }
    }
    private func closeSetup() {
        applyTask?.cancel()
        dismiss()
    }
    private var primaryAction: QuickSetupPrimaryAction {
        let downloading =
            setup.appleSpeechDownloading
            || setup.plan?.modelIDs.contains { models.downloads[$0]?.phase == .downloading } == true
        // Online allowed waits only for a model picked here.
        return .resolve(
            route: setup.route == .services && setup.requiredModels.isEmpty ? .services : .onDevice,
            preparing: setup.preparing || (!setup.checkingModelIDs.isEmpty && !setup.hasActiveDownloads),
            applying: applying,
            active: setup.hasActiveDownloads, downloading: downloading, canApply: setup.canApply,
            canDownload: setup.canDownload, failed: setup.hasFailedDownloads)
    }
    private var primaryTitle: String {
        if primaryAction == .services && preferences.processingPolicy == .standard {
            return L10n.tr(changesNothing ? "Done" : "Apply setup")
        }
        // Only Apple Speech's language is missing: macOS sizes it, not Yullo.
        if [.download, .retry].contains(primaryAction), setup.downloadSizeBytes == 0 {
            return L10n.tr("Download Apple Speech language")
        }
        return primaryAction.title(
            size: L10n.size(setup.downloadSizeBytes))
    }
    private func performPrimaryAction() {
        guard !applying else { return }
        switch primaryAction {
        case .download, .retry: setup.downloadMissing()
        case .apply: applySetup()
        case .services: if changesNothing { closeSetup() } else { applySetup() }
        default: break
        }
    }
    private var changesNothing: Bool {
        preferences.processingPolicy == .standard && setup.patch.applying(to: preferences) == preferences
    }
    private func performSecondaryAction() {
        guard !applying else { return }
        if setup.hasOwnedActiveDownloads { setup.cancelDownloads() }
    }
    private func browseModels(_ task: ModelDiscoveryTask) {
        guard !applying else { return }
        openLocalModels(task)
    }
    private func configureService(_ section: SettingsConnectionSection) {
        guard !applying else { return }
        // Online is allowed first when this review can apply; otherwise the
        // service opens as it is.
        if preferences.processingPolicy == .onDeviceOnly, setup.canApply {
            applySetup(openSection: section)
        } else {
            openServiceSection(section)
        }
    }
    private func openServiceSection(_ section: SettingsConnectionSection) {
        if let openService { openService(section) } else { openServices() }
    }
    private func applySetup() { applySetup(openSection: nil) }
    private func applySetup(openSection: SettingsConnectionSection?) {
        guard setup.beginApplying() else { return }
        applyIssue = nil
        applyTask = Task { @MainActor in
            defer { setup.endApplying() }
            var verified = true
            if !setup.requiredModels.isEmpty { verified = await setup.refreshReadiness() }
            guard !Task.isCancelled else { return }
            guard verified, setup.canApply else {
                applyIssue = L10n.tr("Model status changed. Review setup and try again.")
                return
            }
            if let issue = apply(setup.patch) {
                applyIssue = issue
                return
            }
            dismiss()
            if let openSection { openServiceSection(openSection) }
        }
    }
    private func selectModel(_ id: String, task: ModelTask) {
        guard !applying else { return }
        if setup.selectModel(id: id, task: task) { applyIssue = nil }
    }
    // Writing: what Write with will use, with its real state and one fix.
    private var writingRow: some View {
        let writers = setup.writers
        let apple = AppleWriterStatus.availability()
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "pencil.line").frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L10n.tr("Writing")).fontWeight(.medium)
                    Spacer()
                    Text(writerStatus(apple)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if writers.isEmpty {
                    Button(L10n.tr("Set up…")) { configureWriter() }.buttonStyle(.link).disabled(applying)
                        .accessibilityIdentifier("quick-setup-writing-set-up")
                } else {
                    Picker(
                        L10n.tr("Writing"), selection: Binding(get: { setup.writer }, set: { setup.pickWriter($0) })
                    ) {
                        ForEach(writers, id: \.self) { engine in
                            Text(WritingServicePresentation.title(engine, preferences: preferences)).tag(engine)
                        }
                    }.pickerStyle(.menu).labelsHidden().disabled(applying)
                        .accessibilityIdentifier("quick-setup-writing")
                    if setup.writer == "apple", apple == .intelligenceOff {
                        Button(L10n.tr("Open Settings…")) {
                            NSWorkspace.shared.open(AppleWriterPresentation.settingsURL)
                        }.buttonStyle(.link).font(.system(size: 12))
                    }
                }
            }
        }.accessibilityIdentifier("quick-setup-writing-row")
    }
    private func writerStatus(_ apple: CoreAppleWriterAvailability) -> String {
        if setup.writers.isEmpty { return L10n.tr("Not set up") }
        if setup.writer == "apple" { return AppleWriterPresentation.status(apple) ?? L10n.tr("Ready") }
        return L10n.tr("Ready")
    }
    // Nothing can write yet: Services lists Apple's model and Ollama, each with its fix.
    private func configureWriter() {
        guard !applying else { return }
        openServices()
    }
    // Every task with its on-device choices; online allowed adds the
    // configured online ones beside them.
    private var taskSetup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                L10n.tr(
                    setup.route == .onDevice
                        ? "Audio and text stay on this Mac. Downloads need an internet connection."
                        : "Online services and command-line tools can process text outside Yullo.")
            )
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if setup.preparing { ActivityStatus(title: L10n.tr("Choosing models for this Mac…")) }
            if let plan = setup.plan {
                modelRow(plan.dictation, title: "Voice input", symbol: "mic")
                modelRow(plan.translation, title: "Translation", symbol: "translate")
                readAloudRow
                writingRow
            }
        }
    }
    private var readAloudRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "speaker.wave.2").frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("Read aloud")).fontWeight(.medium)
                let engines = setup.speechEngines
                if engines.count > 1 {
                    Picker(
                        L10n.tr("Read aloud"),
                        selection: Binding(get: { setup.speechEngine }, set: { setup.pickSpeech($0) })
                    ) {
                        ForEach(engines, id: \.self) { engine in Text(speechTitle(engine)).tag(engine) }
                    }.pickerStyle(.menu).labelsHidden().disabled(applying)
                        .accessibilityIdentifier("quick-setup-read-aloud")
                } else {
                    Text(L10n.tr("macOS voices")).foregroundStyle(.secondary)
                }
                if setup.speechEngine == SpeechProvider.macOS.rawValue, !setup.missingVoiceLanguageIDs.isEmpty {
                    Text(
                        L10n.format(
                            "Add voices for %@",
                            setup.missingVoiceLanguageIDs.map {
                                Language.displayName(
                                    for: $0, localized: preferences.showLocalizedLanguageNames,
                                    locale: L10n.locale)
                            }.joined(separator: preferences.showLocalizedLanguageNames ? " · " : ", "))
                    )
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(
                        horizontal: false, vertical: true)
                    Button(L10n.tr("Open voice settings")) {
                        if let url = URL(
                            string:
                                "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent"
                        ) {
                            NSWorkspace.shared.open(url)
                        }
                    }.buttonStyle(.link)
                }
                if setup.route == .services { configureLink(.speech) }
            }
            Spacer()
        }.accessibilityIdentifier("quick-setup-read-aloud-row")
    }
    private func speechTitle(_ engine: String) -> String {
        guard let provider = SpeechProvider(rawValue: engine) else { return L10n.tr("Choose a service") }
        switch provider {
        case .macOS: return L10n.tr("macOS voices")
        case .local: return modelName(preferences.localSpeechModelID)
        default: return SpeechSettingsFields.title(provider)
        }
    }
    private func translationTitle(_ engine: String) -> String {
        engine == "local" ? L10n.tr("Local model") : TranslateWithRow.title(engine, preferences: preferences)
    }
    private func configureLink(_ section: SettingsConnectionSection) -> some View {
        Button(L10n.tr("Configure…")) { configureService(section) }
            .buttonStyle(.link).font(.system(size: 12)).disabled(applying)
            .accessibilityIdentifier("quick-setup-configure-" + section.rawValue)
    }
    private func modelName(_ id: String) -> String {
        models.installed.first { $0.id == id }?.name ?? ModelLibrary.catalog.first { $0.id == id }?.name ?? id
    }
    // Voice input's model, or Translation's service and, on this Mac, its model.
    private func modelRow(_ choice: QuickSetupModelChoice, title: String, symbol: String) -> some View {
        let local = choice.task != .translation || setup.translationEngine == "local"
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L10n.tr(title)).fontWeight(.medium)
                    Spacer()
                    // A state only for a model Apply will use.
                    if local, setup.requiredModels.contains(where: { $0.id == choice.id }) {
                        Text(stateLabel(setup.state(for: choice.id))).font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                if choice.task == .translation {
                    Picker(
                        L10n.tr(title),
                        selection: Binding(get: { setup.translationEngine }, set: { setup.pickTranslation($0) })
                    ) {
                        ForEach(setup.translationEngines, id: \.self) { engine in
                            Text(translationTitle(engine)).tag(engine)
                        }
                    }.pickerStyle(.menu).labelsHidden().disabled(applying)
                        .accessibilityIdentifier("quick-setup-translation-engine")
                    if setup.route == .services { configureLink(.api) }
                }
                if local { modelDetails(choice, title: title) }
            }
        }
    }
    @ViewBuilder private func modelDetails(_ choice: QuickSetupModelChoice, title: String) -> some View {
        modelPicker(choice, title: title)
        ModelRatingSummary(modelID: choice.id, recommended: setup.recommendedIDs[choice.task] == choice.id)
        Button(L10n.tr("Browse local models…")) {
            browseModels(choice.task == .translation ? .translation : .dictation)
        }.buttonStyle(.link).font(.system(size: 12)).disabled(applying)
            .accessibilityIdentifier("quick-setup-browse-" + choice.task.rawValue)
        if choice.task == .dictation, livePreviewRequested,
            LiveRecognitionSupport.mode(
                modelID: choice.id,
                architecture: models.installed.first { $0.id == choice.id }?.architecture) == nil
        {
            Text(LiveRecognitionIssue.unsupported.localizedDescription)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let languages = ModelCatalogPresentation.languageSummary(
            modelID: choice.id, selectedLanguageIDs: selectedLanguageIDs,
            localized: preferences.showLocalizedLanguageNames)
        {
            Text(languages).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let progress = models.downloads[choice.id] {
            if let fraction = progress.fraction, fraction.isFinite {
                ProgressView(value: min(1, max(0, fraction)))
            } else {
                ProgressView().controlSize(.small)
            }
            Text(ModelCatalogPresentation.progressLabel(progress)).font(.system(size: 12)).foregroundStyle(
                .secondary)
        }
        if let issue = setup.error(for: choice.id) {
            Text(issue).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
        }
    }
    private func modelPicker(_ choice: QuickSetupModelChoice, title: String) -> some View {
        let options = setup.choices(for: choice.task)
        let installedIDs = Set(models.installed.map(\.id))
        let installed = options.filter {
            installedIDs.contains($0.id) || $0.id == VoiceRecognitionSettings.appleModelID
        }
        let downloadable = options.filter { !installedIDs.contains($0.id) }
        return Picker(
            L10n.tr(title), selection: Binding(get: { choice.id }, set: { selectModel($0, task: choice.task) })
        ) {
            if !options.contains(where: { $0.id == choice.id }) { Text(choice.name).tag(choice.id).disabled(true) }
            if !installed.isEmpty {
                Section(L10n.tr("On this Mac")) {
                    ForEach(installed) { option in modelOption(option) }
                }
            }
            if !downloadable.isEmpty {
                Section(L10n.tr("Download models")) {
                    ForEach(downloadable) { option in modelOption(option) }
                }
            }
        }.pickerStyle(.menu).labelsHidden().disabled(!setup.canChangeModels)
            .accessibilityIdentifier("quick-setup-model-" + choice.task.rawValue)
    }
    private func modelOption(_ option: QuickSetupModelChoice) -> some View {
        Text(
            ModelCatalogPresentation.optionLabel(
                // Apple Speech has no size of Yullo's to show.
                option.sizeBytes > 0 ? option.name + " · " + L10n.size(option.sizeBytes) : option.name,
                recommended: setup.recommendedIDs[option.task] == option.id)
        )
        .tag(option.id)
    }
    private func stateLabel(_ state: QuickSetupModelState) -> String {
        switch state {
        case .downloadNeeded: return L10n.tr("Download needed")
        case .downloading: return L10n.tr("Downloading…")
        case .verifying: return L10n.tr("Verifying…")
        case .ready: return L10n.tr("Ready")
        case .failed: return L10n.tr("Failed")
        }
    }
    private var plannedModelIDs: Set<String> { Set(setup.plan?.modelIDs ?? []) }
    private var plannedInstalledModels: [InstalledLocalModel] {
        models.installed.filter { plannedModelIDs.contains($0.id) }
    }
    private var plannedDownloadIDs: [String] {
        models.downloads.keys.filter { plannedModelIDs.contains($0) }.sorted()
    }
    private var plannedErrors: [String: String] {
        models.errors.filter { plannedModelIDs.contains($0.key) }
    }
    private func refreshReadiness() { Task { await setup.refreshReadiness() } }
}
