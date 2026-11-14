import Foundation
import Combine

enum QuickSetupRoute: String, CaseIterable { case onDevice, services }

struct QuickSetupModelChoice: Equatable, Identifiable {
    let id: String
    let name: String
    let sizeBytes: Int64
    let task: ModelTask
}

struct QuickSetupPlan: Equatable {
    let dictation: QuickSetupModelChoice
    let translation: QuickSetupModelChoice
    var models: [QuickSetupModelChoice] { [dictation, translation] }
    var modelIDs: [String] { models.map(\.id) }
}

// A setup applies only these reviewed choices to the latest configuration.
// Connection metadata, credentials, languages and shortcuts have no owner here.
// Either route sets each task's service from the same rows: on-device
// choices always, online ones too when online is allowed.
struct QuickSetupPatch: Equatable {
    let route: QuickSetupRoute
    let dictationModelID: String?
    let translationModelID: String?
    // Translate with and Read aloud as reviewed; nil leaves them as they are.
    let translationEngine: String?
    let speechEngine: String?
    // Write with, only when the review changed it.
    let writingEngine: String?
    // `models` names the tasks whose reviewed model is written; nil writes the plan's.
    init(
        route: QuickSetupRoute, plan: QuickSetupPlan? = nil, models: Set<ModelTask>? = nil,
        translationEngine: String? = nil, speechEngine: String? = nil, writer: String? = nil
    ) {
        self.route = route
        dictationModelID = models?.contains(.dictation) ?? true ? plan?.dictation.id : nil
        self.translationEngine = translationEngine ?? (route == .onDevice && plan != nil ? "local" : nil)
        translationModelID =
            self.translationEngine == "local" && models?.contains(.translation) ?? true ? plan?.translation.id : nil
        self.speechEngine = speechEngine ?? (route == .onDevice ? "macos" : nil)
        writingEngine = writer
    }
    func applying(to current: Preferences) -> Preferences {
        if route == .onDevice
            && (dictationModelID == nil || (translationEngine == "local" && translationModelID == nil))
        {
            return current
        }
        let policy: ProcessingPolicy = route == .onDevice ? .onDeviceOnly : .standard
        // Online choices set aside on this Mac only come back, or are set aside, as in Settings.
        var result = current.switchingProcessing(to: policy) { task, _ in
            switch task {
            case .translation: return translationEngine
            case .writing: return writingEngine
            case .readAloud: return speechEngine
            }
        }
        if let dictationModelID { result.voiceModelID = dictationModelID }
        if let translationModelID { result.localTranslationModelID = translationModelID }
        if let translationEngine { result.engine = translationEngine }
        if let speechEngine { result.speechEngine = speechEngine }
        if let writingEngine { result.voiceRefinementEngine = writingEngine }
        // Dictation that refines waits only when nothing on this Mac can write.
        if result.pausedTasks.contains(.writing), result.voiceOutputMode == "refine" {
            result.voiceOutputMode = "original"
        }
        return result
    }
}

enum QuickSetupModelState: Equatable {
    case downloadNeeded, downloading, verifying, ready, failed
}

@MainActor final class QuickSetupCoordinator: ObservableObject {
    // Each route keeps its choices fitted to what it can use.
    @Published var route: QuickSetupRoute = .onDevice {
        didSet {
            guard route != oldValue else { return }
            fitWriter()
            fitServices()
        }
    }
    @Published private(set) var plan: QuickSetupPlan?
    @Published private(set) var verifiedModelIDs = Set<String>()
    @Published private(set) var checkingModelIDs = Set<String>()
    @Published private(set) var missingVoiceLanguageIDs: [String] = []

    @Published private(set) var preparing = true
    @Published private(set) var isApplying = false
    @Published private(set) var verificationErrors: [String: String] = [:]
    // Hardware-fit suggestions marked beside choices; they never select a model.
    @Published private(set) var recommendedIDs: [ModelTask: String] = [:]
    // Writing: Write with as it is when it can write on the chosen route;
    // otherwise a writer that can is suggested here, for review before Apply.
    @Published private(set) var writer: String
    // Whether the person chose it; a suggestion is written only by Apply on this Mac only,
    // where the saved writer can't run.
    private(set) var writerPicked = false
    // Translate with and Read aloud: the saved service when the route can use
    // it, otherwise the on-device one; a pick stays while the route offers it.
    @Published private(set) var translationEngine = ""
    @Published private(set) var speechEngine = ""
    private var translationPick: String?
    private var speechPick: String?
    private let preferences: Preferences
    private let models: VoiceModelStore
    private let catalog: [LocalModelDescriptor]
    private let hasVoice: (String) -> Bool
    private let hardware: ModelHardwareProfile
    private let appleSpeechAvailability: @Sendable (String) async -> AppleSpeechAvailability
    private let appleSpeechDownload: @Sendable (String) async throws -> Void
    // Apple Speech's language as macOS last reported it, and its download from here.
    @Published private(set) var appleSpeechState: AppleSpeechAvailability.State?
    @Published private(set) var appleSpeechDownloading = false
    // Why the last download from here failed; kept until the person tries again.
    @Published private(set) var appleSpeechFailure: String?
    private var appleSpeechTask: Task<Void, Never>?
    private var appleSpeechLocale: String { VoiceRecognitionSettings(preferences).appleLocale }
    private var preparationRevision = 0
    private var readinessRevision = 0

    init(
        preferences: Preferences, models: VoiceModelStore, catalog: [LocalModelDescriptor] = ModelLibrary.catalog,
        hasVoice: @escaping (String) -> Bool = { !MacVoiceCatalog.voices(for: $0).isEmpty },
        hardware: ModelHardwareProfile? = nil,
        appleSpeech: @escaping @Sendable (String) async -> AppleSpeechAvailability = {
            await VoiceResources.appleSpeech.inspect(localeID: $0)
        },
        appleSpeechDownload: @escaping @Sendable (String) async throws -> Void = {
            try await VoiceResources.appleSpeech.downloadAssets(localeID: $0)
        }
    ) {
        self.appleSpeechAvailability = appleSpeech
        self.appleSpeechDownload = appleSpeechDownload
        self.preferences = preferences
        self.models = models
        self.catalog = catalog
        self.hasVoice = hasVoice
        self.hardware = hardware ?? .current()
        // Opens on where Yullo works now.
        route = preferences.processingPolicy == .onDeviceOnly ? .onDevice : .services
        writer = preferences.voiceRefinementEngine
        fitWriter()
        fitServices()
    }

    // The saved services as this route would see them: online choices set
    // aside on this Mac only return when online is allowed.
    private var routed: Preferences {
        preferences.switchingProcessing(to: route == .onDevice ? .onDeviceOnly : .standard) { _, _ in nil }
    }
    static func translationEngines(route: QuickSetupRoute, preferences: Preferences) -> [String] {
        ["local", "apple"]
            + ["ollama", "api", "cli"].filter { engine in
                var value = preferences
                value.processingPolicy = route == .onDevice ? .onDeviceOnly : .standard
                value.voiceRefinementEngine = engine
                return VoiceWritingConnection.isConfigured(value)
            }
    }
    static func speechEngines(route: QuickSetupRoute, preferences: Preferences) -> [String] {
        let online: [SpeechProvider] =
            route == .onDevice
            ? []
            : [.azure, .google, .elevenlabs, .speechAPI].filter {
                provider in
                if preferences.speechEngine == provider.rawValue { return true }
                if provider == .azure { return !preferences.azureVoiceIDsByLanguage.isEmpty }
                let saved = SpeechSettingsFields.configuration(preferences, provider: provider)
                return !saved.model.isEmpty || !saved.endpoint.isEmpty || !saved.voiceIDsByLanguage.isEmpty
            }
        return [SpeechProvider.macOS.rawValue]
            + (preferences.localSpeechModelID.isEmpty ? [] : [SpeechProvider.local.rawValue]) + online.map(\.rawValue)
    }
    var translationEngines: [String] { Self.translationEngines(route: route, preferences: routed) }
    var speechEngines: [String] { Self.speechEngines(route: route, preferences: routed) }
    func pickTranslation(_ engine: String) {
        translationPick = engine
        fitServices()
    }
    func pickSpeech(_ engine: String) {
        speechPick = engine
        fitServices()
    }
    // A pick the route can't use falls back to the saved service (on this Mac
    // only, the reviewed local model), then to Apple.
    func fitServices() {
        let saved = routed, translations = translationEngines, voices = speechEngines
        translationEngine =
            [translationPick, route == .onDevice ? "local" : saved.engine].compactMap { $0 }
            .first(where: translations.contains) ?? "apple"
        speechEngine = [speechPick, saved.speechEngine].compactMap { $0 }.first(where: voices.contains) ?? "macos"
    }
    // The models Apply needs. On this Mac only: voice input's, and
    // translation's when it translates here. Online allowed: only a model
    // picked here, or translation newly moved to a local model.
    var requiredModels: [QuickSetupModelChoice] {
        guard let plan else { return [] }
        let local = translationEngine == "local"
        if route == .onDevice { return local ? plan.models : [plan.dictation] }
        return (pickedModels.contains(.dictation) ? [plan.dictation] : [])
            + (local && (pickedModels.contains(.translation) || routed.engine != "local") ? [plan.translation] : [])
    }
    private var pickedModels = Set<ModelTask>()

    // Writers that can write on the route: Apple's model and Ollama on this Mac,
    // plus the saved online ones when the route allows them.
    static func writers(
        route: QuickSetupRoute, preferences: Preferences, apple: CoreAppleWriterAvailability
    ) -> [String] {
        var value = preferences
        value.processingPolicy = route == .onDevice ? .onDeviceOnly : .standard
        return (apple.canBecomeReady ? ["apple"] : [])
            + ["ollama", "api", "cli"].filter { engine in
                value.voiceRefinementEngine = engine
                return VoiceWritingConnection.isConfigured(value)
            }
    }
    var writers: [String] {
        Self.writers(route: route, preferences: routed, apple: AppleWriterStatus.availability())
    }
    var writerChanged: Bool {
        !writer.isEmpty && writer != routed.voiceRefinementEngine && (writerPicked || route == .onDevice)
    }
    func pickWriter(_ engine: String) {
        writer = engine
        writerPicked = true
    }
    // A choice the route can't use goes back to the saved writer, or to the first that can write.
    func fitWriter() {
        let saved = routed.voiceRefinementEngine, available = writers
        if !writerPicked { writer = saved }
        guard !available.contains(writer) else { return }
        writer = available.contains(saved) ? saved : available.first ?? ""
    }

    func prepare() async {
        preparationRevision += 1
        let expected = preparationRevision
        preparing = true
        let installed = await models.refresh()
        // Keep an enabled live transcript usable when the review needs a new
        // multilingual local recognizer. A verified explicit selection still wins.
        let liveDefault = catalog.first { $0.id == "qwen3-asr-06b-q4" && $0.runtime == .transcribe }
        let recognitionFallback =
            preferences.voiceLivePreview ? liveDefault?.id ?? ModelLibrary.defaultModelID : ModelLibrary.defaultModelID
        let candidates = ModelDiscoveryCatalog.hardwareCandidates(
            descriptors: catalog.filter { supports($0, for: $0.task) })
        let recognition = HardwareModelRecommendation.recommend(
            needs: .init(
                task: .dictation,
                languageIDs: preferences.voiceRecognitionLanguage == "auto"
                    ? preferences.modelSuggestionLanguageIDs : [preferences.voiceRecognitionLanguage],
                livePreview: preferences.voiceLivePreview,
                allowsRequiredLanguageHint: preferences.voiceRecognitionLanguage != "auto"),
            profile: hardware, candidates: candidates, installedIDs: Set(installed.map(\.id)))
        let text = HardwareModelRecommendation.recommend(
            needs: .init(task: .translation, languageIDs: preferences.modelSuggestionLanguageIDs),
            profile: hardware, candidates: candidates, installedIDs: Set(installed.map(\.id)))
        let dictation = await preferredChoice(
            id: preferences.voiceModelID, task: .dictation, installed: installed,
            fallback: recognition?.modelID ?? recognitionFallback)
        let translation = await preferredChoice(
            id: preferences.engine == "local" ? preferences.localTranslationModelID : "",
            task: .translation, installed: installed, fallback: text?.modelID ?? "hy-mt2-18b-q4")
        guard !Task.isCancelled, preparationRevision == expected else { return }
        recommendedIDs = [.dictation: recognition?.modelID, .translation: text?.modelID].compactMapValues { $0 }
        if let dictation, let translation { plan = QuickSetupPlan(dictation: dictation, translation: translation) }
        refreshVoices()
        preparing = false
        await refreshReadiness()
    }

    func refreshVoices() {
        missingVoiceLanguageIDs = Language.enabled(preferences.enabledLanguages).filter { !hasVoice($0.id) }.map(\.id)
    }

    // Apple Speech needs no model download, but its language may need one from macOS.
    static var appleSpeech: QuickSetupModelChoice {
        .init(
            id: VoiceRecognitionSettings.appleModelID, name: L10n.tr("Apple Speech · on device"), sizeBytes: 0,
            task: .dictation)
    }
    func choices(for task: ModelTask) -> [QuickSetupModelChoice] {
        guard task == .dictation || task == .translation else { return [] }
        var seen = Set<String>(), result: [QuickSetupModelChoice] = []
        if task == .dictation {
            seen.insert(Self.appleSpeech.id)
            result.append(Self.appleSpeech)
        }
        for installed in models.installed where supports(installed, for: task) {
            if seen.insert(installed.id).inserted {
                result.append(
                    .init(id: installed.id, name: installed.name, sizeBytes: installed.sizeBytes, task: task))
            }
        }
        result.sort { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
        for descriptor in catalog where supports(descriptor, for: task) {
            if seen.insert(descriptor.id).inserted {
                result.append(
                    .init(id: descriptor.id, name: descriptor.name, sizeBytes: descriptor.sizeBytes, task: task))
            }
        }
        return result
    }

    var canChangeModels: Bool { !preparing && !isApplying && plan != nil && ownedDownloadHandles.isEmpty }

    @discardableResult func selectModel(id: String, task: ModelTask) -> Bool {
        guard canChangeModels, let plan, let choice = choices(for: task).first(where: { $0.id == id }) else {
            return false
        }
        let updated: QuickSetupPlan
        switch task {
        case .dictation: updated = .init(dictation: choice, translation: plan.translation)
        case .translation: updated = .init(dictation: plan.dictation, translation: choice)
        case .readAloud: return false
        }
        pickedModels.insert(task)
        guard updated != plan else { return true }
        readinessRevision += 1
        verifiedModelIDs = []
        checkingModelIDs = Set(updated.modelIDs)
        verificationErrors = [:]
        self.plan = updated
        return true
    }

    @discardableResult func beginApplying() -> Bool {
        guard !isApplying, canApply else { return false }
        isApplying = true
        return true
    }

    func endApplying() { isApplying = false }

    private func supports(_ descriptor: LocalModelDescriptor, for task: ModelTask) -> Bool {
        descriptor.task == task && descriptor.runtime.task == task
            && allowsLanguageHint(id: descriptor.id, task: task, architecture: nil)
    }

    private func supports(_ installed: InstalledLocalModel, for task: ModelTask) -> Bool {
        installed.task == task && installed.runtime.task == task
            && allowsLanguageHint(id: installed.id, task: task, architecture: installed.architecture)
    }

    private func allowsLanguageHint(id: String, task: ModelTask, architecture: String?) -> Bool {
        task != .dictation || !VoiceRecognitionSettings.requiresLanguageHint(modelID: id, architecture: architecture)
            || VoiceRecognitionSettings.cohereLanguageIDs.contains(preferences.voiceRecognitionLanguage)
    }

    private func preferredChoice(id: String, task: ModelTask, installed: [InstalledLocalModel], fallback: String) async
        -> QuickSetupModelChoice?
    {
        if task == .dictation, id == VoiceRecognitionSettings.appleModelID { return Self.appleSpeech }
        if let installed = installed.first(where: { $0.id == id && supports($0, for: task) }),
            (try? await models.verifyModel(id)) != nil
        {
            return QuickSetupModelChoice(id: id, name: installed.name, sizeBytes: installed.sizeBytes, task: task)
        }
        return catalog.first(where: { $0.id == fallback && supports($0, for: task) }).map {
            QuickSetupModelChoice(id: $0.id, name: $0.name, sizeBytes: $0.sizeBytes, task: task)
        }
    }

    // Apply must use this pass's result: a newer observer may supersede it
    // while the published readiness still describes an earlier successful pass.
    @discardableResult func refreshReadiness() async -> Bool {
        guard let plan else { return false }
        readinessRevision += 1
        let expected = readinessRevision
        checkingModelIDs = Set(plan.modelIDs)
        defer {
            if readinessRevision == expected, self.plan == plan { checkingModelIDs = [] }
        }
        var verified = Set<String>(), errors: [String: String] = [:]
        for choice in plan.models where models.downloads[choice.id] == nil {
            if choice.id == VoiceRecognitionSettings.appleModelID {
                // A new Mac has the language's speech assets only once something asked for them.
                let state = await appleSpeechAvailability(appleSpeechLocale).state
                appleSpeechState = state
                switch state {
                case .ready: verified.insert(choice.id)
                // Offered as a download here, like a model.
                case .needsDownload, .downloading: break
                case .unsupportedLocale: errors[choice.id] = AppleSpeechError.unsupportedLocale.localizedDescription
                case .unavailableDevice: errors[choice.id] = AppleSpeechError.unavailable.localizedDescription
                }
                continue
            }
            do {
                try await models.verifyModel(choice.id)
                verified.insert(choice.id)
            } catch {
                if models.installed.contains(where: { $0.id == choice.id })
                    || !catalog.contains(where: { $0.id == choice.id })
                {
                    errors[choice.id] = error.localizedDescription
                }
            }
        }
        // Recheck the actual task and architecture after integrity validation.
        // An imported model can disappear or be replaced during this review.
        guard !Task.isCancelled, readinessRevision == expected, self.plan == plan else { return false }
        let installed = await models.refresh()
        for choice in plan.models
        where verified.contains(choice.id) && choice.id != VoiceRecognitionSettings.appleModelID {
            do {
                guard let current = installed.first(where: { $0.id == choice.id }) else {
                    throw ModelLibraryError.unavailable
                }
                guard current.task == choice.task, current.runtime.task == choice.task else {
                    throw ModelLibraryError.taskMismatch
                }
                guard allowsLanguageHint(id: choice.id, task: choice.task, architecture: current.architecture) else {
                    throw LocalTranscriptionError.languageRequired
                }
            } catch {
                verified.remove(choice.id)
                errors[choice.id] = error.localizedDescription
            }
        }
        guard !Task.isCancelled, readinessRevision == expected, self.plan == plan else { return false }
        verifiedModelIDs = verified
        verificationErrors = errors
        return Set(requiredModels.map(\.id)).isSubset(of: verified)
    }

    var canApply: Bool {
        if route == .services && requiredModels.isEmpty { return true }
        return !preparing && !hasActiveDownloads && plan != nil
            && Set(requiredModels.map(\.id)).isSubset(of: verifiedModelIDs)
    }
    var patch: QuickSetupPatch {
        QuickSetupPatch(
            route: route, plan: plan, models: Set(requiredModels.map(\.task)),
            translationEngine: plan == nil && route == .services ? nil : translationEngine,
            speechEngine: plan == nil && route == .services ? nil : speechEngine,
            writer: writerChanged ? writer : nil)
    }
    var missingModels: [QuickSetupModelChoice] { requiredModels.filter { !verifiedModelIDs.contains($0.id) } }
    var downloadSizeBytes: Int64 { missingModels.reduce(0) { $0 + $1.sizeBytes } }
    var hasActiveDownloads: Bool {
        appleSpeechDownloading || requiredModels.contains { models.downloads[$0.id] != nil }
    }
    private var appleSpeechCanDownload: Bool {
        missingModels.contains { $0.id == VoiceRecognitionSettings.appleModelID } && appleSpeechState == .needsDownload
            && !appleSpeechDownloading && !checkingModelIDs.contains(VoiceRecognitionSettings.appleModelID)
    }
    private var ownedDownloadHandles: [LocalModelDownloadHandle] {
        models.activeDownloadHandles(ownedBy: .quickSetup)
    }
    var hasOwnedActiveDownloads: Bool { appleSpeechDownloading || !ownedDownloadHandles.isEmpty }
    var canDownload: Bool {
        appleSpeechCanDownload
            || missingModels.contains { choice in
                !checkingModelIDs.contains(choice.id) && models.downloads[choice.id] == nil
                    && catalog.contains(where: { $0.id == choice.id })
            }
    }
    var hasFailedDownloads: Bool {
        missingModels.contains { error(for: $0.id) != nil }
    }
    func state(for id: String) -> QuickSetupModelState {
        if let progress = models.downloads[id] { return progress.phase == .downloading ? .downloading : .verifying }
        if id == VoiceRecognitionSettings.appleModelID, appleSpeechDownloading || appleSpeechState == .downloading {
            return .downloading
        }
        if checkingModelIDs.contains(id) { return .verifying }
        if verifiedModelIDs.contains(id) { return .ready }
        if error(for: id) != nil { return .failed }
        return .downloadNeeded
    }
    func error(for id: String) -> String? {
        models.errors[id] ?? verificationErrors[id]
            ?? (id == VoiceRecognitionSettings.appleModelID && !verifiedModelIDs.contains(id)
                ? appleSpeechFailure : nil)
    }
    func downloadMissing() {
        guard checkingModelIDs.isEmpty else { return }
        if appleSpeechCanDownload { downloadAppleSpeech() }
        for choice in missingModels
        where models.downloads[choice.id] == nil && catalog.contains(where: { $0.id == choice.id }) {
            verificationErrors[choice.id] = nil
            models.startOrJoinDownload(choice.id, owner: .quickSetup)
        }
    }
    func cancelDownloads() {
        appleSpeechTask?.cancel()
        for handle in ownedDownloadHandles { models.cancel(handle) }
    }
    // macOS downloads the language's speech assets; the row turns Ready when they are in.
    private func downloadAppleSpeech() {
        let locale = appleSpeechLocale, download = appleSpeechDownload
        appleSpeechFailure = nil
        appleSpeechDownloading = true
        appleSpeechTask = Task { @MainActor in
            do { try await download(locale) } catch is CancellationError {} catch {
                appleSpeechFailure = error.localizedDescription
            }
            appleSpeechDownloading = false
            appleSpeechTask = nil
            await refreshReadiness()
        }
    }
}
