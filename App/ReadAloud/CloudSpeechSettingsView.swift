import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct SpeechSettingsSnapshot: Equatable, Sendable {
    let provider: SpeechProvider
    let configuration: SpeechAPIConfiguration
    let region: String
    let language: String
    let rate: Double
    var localReferenceAudioURL: URL? = nil
    var authorization = ProcessingPolicyController.shared.authorization(for: .standard)
    var cloud: CloudSpeechConfiguration {
        .init(
            provider: provider, endpoint: configuration.endpoint, region: region,
            modelID: configuration.model, voiceID: configuration.voice(for: language))
    }
}

struct SpeechSettingsBackend {
    var readKey: (String) async throws -> String
    var forgetKey: (String) throws -> Void
    // The Bool asks for a fresh list rather than the shared cached one.
    var voices: (CloudSpeechConfiguration, String, Bool) async throws -> [SpeechVoice]
    var models: (CloudSpeechConfiguration, String) async throws -> [SpeechModel]
    var preview: (SpeechSettingsSnapshot, String) async throws -> Data
    static let system = SpeechSettingsBackend(
        readKey: { account in
            try await KeyStore.readAsync(account, allowInteraction: false)
        }, forgetKey: { try KeyStore.remove($0) },
        voices: { try await CloudSpeechProviders.voiceCatalog(configuration: $0, key: $1, refresh: $2) },
        models: { try await CloudSpeechProviders.listModels(configuration: $0, key: $1) },
        preview: { snapshot, key in
            let sample = Language.catalog.first { $0.id == snapshot.language }?.speechSample ?? "Hello."
            if snapshot.provider == .local {
                let model = snapshot.configuration.model, voice = snapshot.configuration.voice(for: snapshot.language)
                let reference = LocalSpeechSynthesizer.requiresReferenceAudio(modelID: model)
                // Automatic and the explicit recommended voice share one sample.
                let resolved =
                    reference
                    ? ""
                    : voice.isEmpty
                        ? LocalSpeechVoiceCatalog.voiceIDs(modelID: model, language: snapshot.language).first ?? ""
                        : voice
                let key = SpeechService.localSampleKey(
                    modelID: model, voiceID: resolved, language: snapshot.language, rate: snapshot.rate,
                    reference: reference ? snapshot.localReferenceAudioURL : nil)
                return try await SpeechService.localSample(key: key) {
                    try await LocalSpeechSynthesizer.shared.synthesize(
                        text: sample, language: snapshot.language, modelID: model, voiceID: voice,
                        rate: snapshot.rate, referenceAudioURL: snapshot.localReferenceAudioURL)
                }
            }
            return try await SpeechService.synthesize(
                provider: snapshot.provider, configuration: snapshot.configuration,
                region: snapshot.region, key: key, text: sample, language: snapshot.language, rate: snapshot.rate,
                useCache: false,
                authorization: snapshot.authorization)
        })
}

@MainActor protocol SpeechPreviewPlaying: AnyObject {
    func play(_ data: Data, rate: Float, completion: @escaping (Bool) -> Void) throws
    func stop()
}

@MainActor private final class SpeechPreviewPlayer: NSObject, SpeechPreviewPlaying, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var completion: ((Bool) -> Void)?
    func play(_ data: Data, rate: Float, completion: @escaping (Bool) -> Void) throws {
        stop()
        let candidate = try AVAudioPlayer(data: data)
        candidate.delegate = self
        candidate.enableRate = true
        candidate.rate = rate
        player = candidate
        self.completion = completion
        guard candidate.play() else {
            stop()
            throw CloudSpeechError.audio
        }
    }
    func stop() {
        player?.delegate = nil
        player?.stop()
        player = nil
        completion = nil
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self, weak player] in
            guard let self, let player, self.player === player else { return }
            self.finish(flag)
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self, weak player] in
            guard let self, let player, self.player === player else { return }
            self.finish(false)
        }
    }
    private func finish(_ success: Bool) {
        let callback = completion
        stop()
        callback?(success)
    }
}

@MainActor final class SpeechSettingsSession: ObservableObject {
    enum Action: Equatable { case voices, models, preview }
    enum FeedbackTone { case neutral, success, failure }
    // Background voice loads report nothing; a chooser's own first load reports
    // only failures; explicit actions report both.
    enum Feedback { case all, failures, none }
    private enum Response: Sendable { case voices([SpeechVoice]), models([SpeechModel]), audio(Data) }
    @Published private(set) var voices: [SpeechVoice] = []
    @Published private(set) var hasLoadedVoices = false
    @Published private(set) var voiceCatalogRevision = UUID()
    @Published private(set) var models: [SpeechModel] = []
    @Published private(set) var action: Action?
    // A quiet voice-list load leaves `action` empty, so the page keeps its
    // controls; an opened chooser waits for it instead of fetching again.
    @Published private(set) var loadingInBackground = false
    // Changes each time a service answers with the current settings: a voice
    // list or a sample. The page records that service as working.
    struct Worked: Equatable {
        let provider: SpeechProvider
        let id = UUID()
    }
    @Published private(set) var worked: Worked?
    @Published private(set) var isPlaying = false
    @Published private(set) var previewVoiceID: String?
    @Published private(set) var needsKeyAccess = false
    @Published private(set) var message = ""
    @Published private(set) var messageTone = FeedbackTone.neutral
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private let backend: SpeechSettingsBackend
    private let playback: any SpeechPreviewPlaying
    init(
        backend: SpeechSettingsBackend = .system, playback: (any SpeechPreviewPlaying)? = nil,
        initialVoices: [SpeechVoice]? = nil
    ) {
        self.backend = backend
        self.playback = playback ?? SpeechPreviewPlayer()
        if let initialVoices {
            voices = initialVoices
            hasLoadedVoices = true
        }
    }
    func cancel(request: UUID?) {
        guard let request, requestID == request else { return }
        cancel()
    }
    func cancel(clearCatalog: Bool = false, preservingMessage: Bool = false) {
        requestID = UUID()
        task?.cancel()
        task = nil
        action = nil
        loadingInBackground = false
        playback.stop()
        isPlaying = false
        previewVoiceID = nil
        needsKeyAccess = false
        if !preservingMessage {
            message = ""
            messageTone = .neutral
        }
        if clearCatalog {
            voices = []
            hasLoadedVoices = false
            voiceCatalogRevision = UUID()
            models = []
        }
    }
    @discardableResult func run(
        _ action: Action, snapshot: SpeechSettingsSnapshot, enteredKey: String, stopCurrentSpeech: () -> Void,
        isCurrent: @escaping () -> Bool = { true }, refresh: Bool = true, feedback: Feedback = .all,
        previewTag: String? = nil
    ) -> UUID {
        cancel()
        if action == .preview { stopCurrentSpeech() }
        let background = feedback == .none && action == .voices
        self.action = background ? nil : action
        loadingInBackground = background
        // A row that is not a voice ID, such as a reference recording, names itself.
        previewVoiceID = action == .preview ? previewTag ?? snapshot.configuration.voice(for: snapshot.language) : nil
        let id = requestID, backend = backend
        task = Task { @MainActor [weak self] in
            defer {
                if let self, self.requestID == id {
                    self.task = nil
                    self.loadingInBackground = false
                    if !self.isPlaying {
                        self.action = nil
                        self.previewVoiceID = nil
                    }
                }
            }
            do {
                guard !Task.isCancelled, isCurrent() else { return }
                let execute: @MainActor @Sendable () async throws -> Response = {
                    let key: String
                    if snapshot.provider == .local {
                        key = ""
                    } else {
                        let account = try SpeechService.keyAccount(
                            provider: snapshot.provider, configuration: snapshot.configuration, region: snapshot.region)
                        let entered = enteredKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        key = entered.isEmpty ? try await backend.readKey(account) : entered
                    }
                    try Task.checkCancellation()
                    switch action {
                    case .voices: return .voices(try await backend.voices(snapshot.cloud, key, refresh))
                    case .models: return .models(try await backend.models(snapshot.cloud, key))
                    case .preview: return .audio(try await backend.preview(snapshot, key))
                    }
                }
                let response: Response
                if snapshot.provider == .local {
                    response = try await execute()
                } else {
                    response = try await ProcessingPolicyController.shared.performExternalAction(
                        authorization: snapshot.authorization, operation: execute)
                }
                guard !Task.isCancelled, isCurrent(), let self, self.requestID == id else { return }
                switch response {
                case .voices(let values):
                    self.worked = Worked(provider: snapshot.provider)
                    self.voices = values
                    self.hasLoadedVoices = true
                    self.voiceCatalogRevision = UUID()
                    if feedback == .all {
                        self.message = L10n.format("Loaded %ld voices.", values.count)
                        self.messageTone = .success
                    }
                case .models(let values):
                    self.models = values
                    self.message = L10n.format(
                        values.count == 1 ? "Loaded %ld model." : "Loaded %ld models.", values.count)
                    self.messageTone = .success
                case .audio(let data):
                    self.worked = Worked(provider: snapshot.provider)
                    let rate = SpeechService.playbackRate(
                        provider: snapshot.provider, configuration: snapshot.configuration,
                        region: snapshot.region, language: snapshot.language, rate: snapshot.rate)
                    self.isPlaying = true
                    self.message = L10n.tr("Playing sample")
                    try self.playback.play(data, rate: rate) { [weak self] success in
                        guard let self, self.requestID == id, self.isPlaying else { return }
                        guard isCurrent() else {
                            self.cancel()
                            return
                        }
                        self.playback.stop()
                        self.isPlaying = false
                        self.previewVoiceID = nil
                        self.action = nil
                        self.message =
                            success ? L10n.tr("Sample played") : CloudSpeechError.audio.localizedDescription
                        self.messageTone = success ? .success : .failure
                    }
                }
            } catch {
                guard let self, self.requestID == id else { return }
                self.playback.stop()
                self.isPlaying = false
                self.previewVoiceID = nil
                self.message = !Task.isCancelled && isCurrent() && feedback != .none ? error.localizedDescription : ""
                if case APIError.keychain = error { self.needsKeyAccess = !self.message.isEmpty }
                self.messageTone = self.message.isEmpty ? .neutral : .failure
            }
        }
        return id
    }
    @discardableResult func forget(account: String) -> Bool {
        cancel(clearCatalog: true)
        do {
            try backend.forgetKey(account)
            message = L10n.tr("Saved key removed from this Mac.")
            messageTone = .success
            return true
        } catch {
            message = error.localizedDescription
            messageTone = .failure
            return false
        }
    }
    func report(_ error: Error) {
        cancel()
        message = error.localizedDescription
        messageTone = .failure
    }
    var voiceCatalogActionTitle: String { hasLoadedVoices ? "Refresh voice list" : "Load available voices" }
}

// Read aloud supplies the way to the service's key line in Services, which goes on
// to Allow access; inside that editor the key line itself is the fix.
private struct OpenSavedKeyAccessKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}
extension EnvironmentValues {
    var openSavedKeyAccess: (@MainActor () -> Void)? {
        get { self[OpenSavedKeyAccessKey.self] }
        set { self[OpenSavedKeyAccessKey.self] = newValue }
    }
}

private struct SpeechSettingsFeedback: View {
    @ObservedObject var session: SpeechSettingsSession
    @Environment(\.openSavedKeyAccess) private var openSavedKeyAccess
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if session.messageTone != .neutral {
                    Image(
                        systemName: session.messageTone == .success ? "checkmark.circle.fill" : "exclamationmark.circle"
                    )
                    .accessibilityHidden(true)
                }
                Text(session.message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: 12))
                .foregroundStyle(
                    session.messageTone == .success
                        ? Color.green : session.messageTone == .failure ? .orange : .secondary
                )
                .accessibilityIdentifier("speech-settings-feedback")
            if session.needsKeyAccess, let openSavedKeyAccess {
                Button(L10n.tr("Allow access…"), action: openSavedKeyAccess).buttonStyle(.link)
                    .font(.system(size: 11)).accessibilityIdentifier("speech-settings-key-access-open")
                    .background {
                        #if YULLO_TESTING
                            YulloActionPresentationProbe(
                                title: "speech-key-access-guidance", action: openSavedKeyAccess)
                        #endif
                    }
            }
        }
    }
}

// The Services editor's selection is separate from the playback provider.
// Visiting/editing a service never changes the active read-aloud engine.
struct CloudSpeechSettingsView: View {
    @Binding var draft: Preferences
    @Binding var enteredKeys: [String: String]
    @Binding var voiceLanguage: String
    let stopCurrentSpeech: () -> Void
    var voiceInputActive = false
    var commitCredentials: () -> Bool = { true }
    var credentialForgotten: (String) -> Void = { _ in }
    // Allow access pressed where Read aloud stopped for this key.
    @Binding var keyAllowRequest: CredentialAccessService?
    let isExpanded: Binding<Bool>?
    let voicesExpanded: Binding<Bool>?
    let preferredProvider: SpeechProvider?
    var revealedSections: Set<SettingsVisibilitySection>
    let interactionChanged: (Bool) -> Void
    // Inside a Services row: no heading or service picker; the row named the service.
    var embedded = false
    @State private var localVoicesExpanded = false
    @State private var voiceInteraction = false
    @State private var presented = false
    @FocusState private var keyFocused: Bool
    @FocusState private var connectionFieldFocused: Bool
    @StateObject private var session: SpeechSettingsSession
    // This service's saved key, read silently as the editor opens.
    @StateObject private var keyAccess = CredentialAccessController(backend: GuidedSetupView.keyBackend)
    @State private var provider = SpeechProvider.azure
    @State private var forgetTarget: SpeechKeyRemovalTarget?
    @State private var successfulForgetTransition: SpeechKeyRemovalTransition?
    @State private var confirmingForget = false
    @State private var keySaveResult: Bool?
    #if YULLO_TESTING
        var yulloTestingCaptureAttachedSpeechKeyRemoval: ((@escaping () -> (() -> Bool)?) -> Void)?
    #endif
    @MainActor init(
        draft: Binding<Preferences>, enteredKeys: Binding<[String: String]>, voiceLanguage: Binding<String>,
        stopCurrentSpeech: @escaping () -> Void, voiceInputActive: Bool = false,
        commitCredentials: @escaping () -> Bool = { true },
        keyAllowRequest: Binding<CredentialAccessService?> = .constant(nil),
        credentialForgotten: @escaping (String) -> Void = { _ in },
        session: SpeechSettingsSession? = nil, isExpanded: Binding<Bool>? = nil,
        voicesExpanded: Binding<Bool>? = nil, preferredProvider: SpeechProvider? = nil,
        revealedSections: Set<SettingsVisibilitySection> = [],
        interactionChanged: @escaping (Bool) -> Void = { _ in }, embedded: Bool = false
    ) {
        self.embedded = embedded
        _draft = draft
        _enteredKeys = enteredKeys
        _voiceLanguage = voiceLanguage
        self.stopCurrentSpeech = stopCurrentSpeech
        self.voiceInputActive = voiceInputActive
        self.commitCredentials = commitCredentials
        self.credentialForgotten = credentialForgotten
        _keyAllowRequest = keyAllowRequest
        self.isExpanded = isExpanded
        self.voicesExpanded = voicesExpanded
        self.preferredProvider = preferredProvider
        self.revealedSections = revealedSections
        self.interactionChanged = interactionChanged
        _session = StateObject(wrappedValue: session ?? SpeechSettingsSession())
    }
    private var configuration: SpeechAPIConfiguration { SpeechSettingsFields.configuration(draft, provider: provider) }
    private var voicesExpansion: Binding<Bool> { voicesExpanded ?? $localVoicesExpanded }
    private var keyInspection: Set<CredentialAccessService> {
        CredentialAccessService(speech: provider).map { [$0] } ?? []
    }
    // What names this service's saved key: the service and where it is.
    private struct KeyScope: Equatable {
        let provider: SpeechProvider, region: String, endpoints: [String]
        init(draft: Preferences, provider: SpeechProvider) {
            self.provider = provider
            region = draft.azureRegion
            endpoints = [draft.googleSpeech.endpoint, draft.elevenLabsSpeech.endpoint, draft.speechAPI.endpoint]
        }
    }
    private var hasInteraction: Bool {
        presented && (keyFocused || connectionFieldFocused || confirmingForget || voiceInteraction)
    }
    private var scope: SpeechCatalogScope {
        .init(
            provider: provider, endpoint: configuration.endpoint, region: provider == .azure ? draft.azureRegion : "",
            enteredKey: enteredKeys[provider.rawValue] ?? "")
    }
    @ViewBuilder private func section(@ViewBuilder _ content: () -> some View) -> some View {
        if embedded {
            content()
        } else {
            SettingsSection(L10n.tr("Cloud voice"), isExpanded: isExpanded, nested: true, content: content)
        }
    }
    var body: some View {
        section {
            VStack(alignment: .leading, spacing: 14) {
                if !embedded {
                    Picker(
                        L10n.tr("Service to configure"),
                        selection: Binding(
                            get: { provider },
                            set: {
                                session.cancel(clearCatalog: true)
                                provider = $0
                            })
                    ) {
                        ForEach(SpeechProvider.allCases.filter { $0 != .macOS && $0 != .local }, id: \.rawValue) {
                            Text(SpeechSettingsFields.title($0)).tag($0)
                        }
                    }
                }
                if provider == .azure {
                    // No example region: one would read as a default. Say where to find it.
                    VStack(alignment: .leading, spacing: 5) {
                        speechField(
                            "Region", hint: "Your Speech resource’s region",
                            text: Binding(
                                get: { draft.azureRegion },
                                set: {
                                    session.cancel(clearCatalog: true)
                                    enteredKeys[SpeechProvider.azure.rawValue] = ""
                                    draft.azureRegion = $0
                                }), focused: $connectionFieldFocused)
                        Text(L10n.tr("Short name from Keys and Endpoint in Azure, no spaces."))
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(
                                horizontal: false, vertical: true)
                    }
                } else {
                    speechField(
                        "Service URL", hint: "https://your-service.example/v1", text: configurationBinding(\.endpoint),
                        focused: $connectionFieldFocused)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text(L10n.tr("Speech API key")).font(.system(size: 13, weight: .medium))
                    SecureField(
                        L10n.tr("Paste a new key, or leave blank to keep the saved key"), text: enteredKeyBinding
                    )
                    .textFieldStyle(.roundedBorder).accessibilityLabel(L10n.tr("Speech API key"))
                    .focused($keyFocused).onSubmit { _ = commitCredentials() }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Spacer(minLength: 0)
                        Button(L10n.tr("Save key")) {
                            let saved = commitCredentials()
                            if saved { enteredKeys[provider.rawValue] = "" }
                            keySaveResult = saved
                        }.controlSize(.small)
                            .disabled(
                                (enteredKeys[provider.rawValue] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                            )
                            .accessibilityIdentifier("speech-key-save")
                    }
                    if let keySaveResult {
                        Label(
                            L10n.tr(keySaveResult ? "Saved to Keychain." : "Couldn’t save the key to Keychain."),
                            systemImage: keySaveResult ? "checkmark.circle.fill" : "exclamationmark.circle"
                        )
                        .font(.system(size: 12)).foregroundStyle(keySaveResult ? Color.green : Color.orange)
                    }
                    if let service = CredentialAccessService(speech: provider) {
                        SavedKeyAccessLine(access: keyAccess, service: service, allowRequest: $keyAllowRequest)
                    }
                    if provider == .google {
                        Text(L10n.tr("Enable Cloud Text-to-Speech and use an API key for that project."))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                if provider == .speechAPI {
                    Text(
                        L10n.tr("A key is optional for local servers.")
                    )
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    Picker(L10n.tr("Audio format"), selection: configurationBinding(\.responseFormat)) {
                        Text("MP3").tag("mp3")
                        Text("WAV").tag("wav")
                    }
                }
                SpeechVoiceConfiguration(
                    draft: $draft, enteredKeys: $enteredKeys, voiceLanguage: $voiceLanguage,
                    provider: provider, session: session, stopCurrentSpeech: stopCurrentSpeech,
                    voicesExpanded: voicesExpansion,
                    revealedSections: revealedSections, interactionChanged: { voiceInteraction = $0 })
                serviceUse
                HStack {
                    Link(L10n.tr("Setup guide"), destination: SpeechSettingsFields.setupURL(provider))
                    Spacer()
                    Button(L10n.tr("Forget saved key…")) {
                        do {
                            forgetTarget = try keyRemovalTarget()
                            confirmingForget = true
                        } catch { session.report(error) }
                    }.buttonStyle(.link)
                }.font(.system(size: 12))
            }.font(.system(size: 13)).padding(embedded ? 0 : 12)
                .environment(\.openSavedKeyAccess, nil)
        }.disabled(voiceInputActive)
            .onAppear {
                presented = true
                interactionChanged(hasInteraction)
                if let preferredProvider, preferredProvider != .macOS, preferredProvider != .local {
                    provider = preferredProvider
                } else if let active = SpeechProvider(rawValue: draft.speechEngine),
                    active != .macOS && active != .local
                {
                    provider = active
                }
                keyAccess.appear(targets: CredentialAccessTargets.make(draft), inspecting: keyInspection)
                #if YULLO_TESTING
                    yulloTestingCaptureAttachedSpeechKeyRemoval? {
                        guard let target = try? keyRemovalTarget() else { return nil }
                        return { confirmKeyRemoval(target) }
                    }
                #endif
            }
            .onChange(of: preferredProvider) { _, value in
                guard let value, value != .macOS, value != .local, value != provider else { return }
                session.cancel(clearCatalog: true)
                provider = value
            }
            .onChange(of: voiceInputActive) { _, active in if active { session.cancel() } }
            .onChange(of: KeyScope(draft: draft, provider: provider)) { _, _ in
                keyAccess.configure(CredentialAccessTargets.make(draft), inspecting: keyInspection)
            }
            // A key saved here, or a read that macOS refused, is read again silently.
            .onChange(of: keySaveResult) { _, saved in
                if saved == true, let service = CredentialAccessService(speech: provider) { keyAccess.check(service) }
            }
            .onChange(of: session.needsKeyAccess) { _, needs in
                if needs, let service = CredentialAccessService(speech: provider) { keyAccess.check(service) }
            }
            .onChange(of: keyFocused) { old, focused in if old && !focused { _ = commitCredentials() } }
            .onChange(of: provider) { _, _ in keySaveResult = nil }
            .onChange(of: enteredKeys) { _, keys in
                // Typing another key replaces an earlier save confirmation.
                if !(keys[provider.rawValue] ?? "").isEmpty { keySaveResult = nil }
            }
            .onChange(of: hasInteraction) { _, active in interactionChanged(active) }
            .onChange(of: scope) { old, updated in
                let preserve = successfulForgetTransition?.matches(old: old, updated: updated) == true
                successfulForgetTransition = nil
                session.cancel(clearCatalog: true, preservingMessage: preserve)
            }
            .onDisappear {
                presented = false
                interactionChanged(false)
                session.cancel(clearCatalog: true)
                keyAccess.disappear()
            }
            .confirmationDialog(L10n.tr("Forget this saved API key?"), isPresented: $confirmingForget) {
                Button(L10n.tr("Forget key"), role: .destructive) {
                    guard let target = forgetTarget else { return }
                    _ = confirmKeyRemoval(target)
                    forgetTarget = nil
                }
                Button(L10n.tr("Cancel"), role: .cancel) { forgetTarget = nil }
            } message: {
                Text(L10n.tr("Removes the saved key from this Mac. Your provider’s key stays active."))
            }
    }
    // Once this service has worked, Read aloud can use it with one explicit
    // click; configuring or testing a service never switches it by itself.
    @ViewBuilder private var serviceUse: some View {
        if let service = ConnectedService.speech(provider), draft.isWorking(service) {
            if draft.speechEngine == provider.rawValue {
                // On this Mac only, a paused cloud voice is in use for nothing.
                if !draft.pausedTasks.contains(.readAloud) {
                    Text(L10n.tr("In use for read aloud.")).font(.system(size: 12)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("speech-service-in-use")
                }
            } else {
                Button(L10n.tr("Use for read aloud")) { draft.speechEngine = provider.rawValue }
                    .buttonStyle(.link).font(.system(size: 12))
                    .accessibilityIdentifier("speech-service-use")
            }
        }
    }
    private func keyRemovalTarget() throws -> SpeechKeyRemovalTarget {
        .init(
            scope: scope,
            account: try SpeechService.keyAccount(
                provider: provider, configuration: configuration, region: draft.azureRegion))
    }
    private func confirmKeyRemoval(_ target: SpeechKeyRemovalTarget) -> Bool {
        guard scope == target.scope, session.forget(account: target.account) else { return false }
        if !target.scope.enteredKey.isEmpty {
            successfulForgetTransition = .init(previous: target.scope)
        }
        enteredKeys[target.scope.provider.rawValue] = ""
        if let service = ConnectedService.speech(target.scope.provider) { draft.forgetWorking(service) }
        credentialForgotten(target.account)
        return true
    }
    private var enteredKeyBinding: Binding<String> {
        let selected = provider
        return Binding(
            get: { enteredKeys[selected.rawValue] ?? "" },
            set: {
                session.cancel(clearCatalog: true)
                enteredKeys[selected.rawValue] = $0
            })
    }
    private func configurationBinding(_ key: WritableKeyPath<SpeechAPIConfiguration, String>) -> Binding<String> {
        let selected = provider
        return Binding(
            get: { SpeechSettingsFields.configuration(draft, provider: selected)[keyPath: key] },
            set: { value in
                session.cancel(clearCatalog: key == \SpeechAPIConfiguration.endpoint)
                if key == \SpeechAPIConfiguration.endpoint { enteredKeys[selected.rawValue] = "" }
                var updated = SpeechSettingsFields.configuration(draft, provider: selected)
                updated[keyPath: key] = value
                SpeechSettingsFields.set(updated, provider: selected, draft: &draft)
            })
    }
}

struct SpeechPlaybackSettingsView: View {
    @Binding var draft: Preferences
    @Binding var enteredKeys: [String: String]
    @Binding var voiceLanguage: String
    let stopCurrentSpeech: () -> Void
    let openServices: () -> Void
    var voiceInputActive = false
    @ObservedObject var localModels = VoiceModelStore.shared
    var openProcessingSetup: (() -> Void)? = nil
    let voicesExpanded: Binding<Bool>?
    var revealedSections: Set<SettingsVisibilitySection>
    @State private var localVoicesExpanded = false
    @StateObject private var session: SpeechSettingsSession
    @State private var nativeRevision = 0
    @MainActor init(
        draft: Binding<Preferences>, enteredKeys: Binding<[String: String]>, voiceLanguage: Binding<String>,
        stopCurrentSpeech: @escaping () -> Void, openServices: @escaping () -> Void, voiceInputActive: Bool = false,
        localModels: VoiceModelStore? = nil, openProcessingSetup: (() -> Void)? = nil,
        voicesExpanded: Binding<Bool>? = nil, session: SpeechSettingsSession? = nil,
        revealedSections: Set<SettingsVisibilitySection> = []
    ) {
        _draft = draft
        _enteredKeys = enteredKeys
        _voiceLanguage = voiceLanguage
        self.stopCurrentSpeech = stopCurrentSpeech
        self.openServices = openServices
        self.voiceInputActive = voiceInputActive
        self.localModels = localModels ?? .shared
        self.openProcessingSetup = openProcessingSetup
        self.voicesExpanded = voicesExpanded
        self.revealedSections = revealedSections
        _session = StateObject(wrappedValue: session ?? SpeechSettingsSession())
    }
    private var provider: SpeechProvider { SpeechProvider(rawValue: draft.speechEngine) ?? .macOS }
    private var configuration: SpeechAPIConfiguration { SpeechSettingsFields.configuration(draft, provider: provider) }
    private var voicesExpansion: Binding<Bool> { voicesExpanded ?? $localVoicesExpanded }
    private var scope: SpeechCatalogScope {
        .init(
            provider: provider, endpoint: configuration.endpoint, region: provider == .azure ? draft.azureRegion : "",
            enteredKey: enteredKeys[provider.rawValue] ?? "")
    }
    private var nativeVoices: [AVSpeechSynthesisVoice] {
        _ = nativeRevision
        return MacVoiceCatalog.voices(for: voiceLanguage)
    }
    private var unavailableNativeVoiceLanguages: [String] {
        _ = nativeRevision
        return draft.voiceIDs.keys.filter { language in
            guard let voice = draft.voiceIDs[language], !voice.isEmpty else { return false }
            return !MacVoiceCatalog.voices(for: language).contains { $0.identifier == voice }
        }.sorted()
    }
    private var mustShowNativeVoiceDetails: Bool { !unavailableNativeVoiceLanguages.isEmpty }
    private var nativeVoicesExpansion: Binding<Bool> {
        Binding(
            get: { mustShowNativeVoiceDetails || voicesExpansion.wrappedValue },
            set: { voicesExpansion.wrappedValue = $0 })
    }
    private var hasNativeOverrides: Bool {
        draft.voiceIDs.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    static let setUpServiceTag = "__set-up-service__"
    private var serviceChoice: some View {
        Picker(
            L10n.tr("Voice service"),
            selection: Binding(
                get: { draft.speechEngine },
                set: {
                    // The last item opens Services without changing the selection.
                    guard $0 != Self.setUpServiceTag else { return openServices() }
                    session.cancel(clearCatalog: true)
                    draft.speechEngine = $0
                })
        ) {
            if SpeechProvider(rawValue: draft.speechEngine) == nil {
                Text(L10n.tr("Choose a service")).tag(draft.speechEngine)
            }
            // Ready services only: macOS, an installed local model, and connected
            // services that have worked. Setup stays on the Services page.
            let choices = ServiceChoices.speech(
                draft, hasLocalModel: localModels.installed.contains { $0.task == .readAloud })
            ForEach(choices, id: \.rawValue) { provider in
                Text(SpeechSettingsFields.title(provider)).tag(provider.rawValue)
            }
            if ServiceChoices.omitsSpeech(choices) {
                Divider()
                Text(L10n.tr("Set up another service…")).tag(Self.setUpServiceTag)
            }
        }.labelsHidden().help(
            SpeechProvider(rawValue: draft.speechEngine) == nil
                ? L10n.tr("Choose a service") : SpeechSettingsFields.title(provider))
    }
    @ViewBuilder private var manageService: some View {
        if SpeechProvider(rawValue: draft.speechEngine) != nil, provider != .macOS {
            Button(L10n.tr(provider == .local ? "Manage models…" : "Manage voice service…"), action: openServices)
                .buttonStyle(.link)
                .accessibilityLabel(L10n.tr(provider == .local ? "Manage models…" : "Manage voice service…"))
        }
    }
    // The service on the control column; managing it is a quiet line under the row.
    @ViewBuilder private var serviceSelection: some View {
        SettingsTaskRow(title: L10n.tr("Voice service")) { serviceChoice.settingsControlWidth() }
        if SpeechProvider(rawValue: draft.speechEngine) != nil, provider != .macOS {
            HStack {
                Spacer(minLength: 0)
                manageService.font(.system(size: 11))
            }.settingsRowAttached()
        }
    }
    // Automatic follows the text's language; choosing a voice per language is folded.
    @ViewBuilder private var nativeVoiceSettings: some View {
        let expanded = mustShowNativeVoiceDetails || nativeVoicesExpansion.wrappedValue
        if mustShowNativeVoiceDetails {
            Text(L10n.tr("Voice")).id("macos")
        } else {
            SettingsDisclosureRow(
                title: L10n.tr("Voice"),
                summary: hasNativeOverrides
                    ? speechVoiceCustomizationSummary(draft.voiceIDs) : L10n.tr("Automatic"),
                isExpanded: nativeVoicesExpansion
            )
            .help(L10n.tr("Follows text language"))
            .accessibilityIdentifier("settings-customization-speech-voices")
            .background {
                #if YULLO_TESTING
                    YulloActionPresentationProbe(
                        title: "Customization toggle: speech-voices",
                        action: { nativeVoicesExpansion.wrappedValue.toggle() })
                #endif
            }.id("macos")
        }
        if expanded {
            if !unavailableNativeVoiceLanguages.isEmpty {
                Text(
                    speechUnavailableVoiceSummary(
                        unavailableNativeVoiceLanguages, localizedNames: draft.showLocalizedLanguageNames)
                )
                .font(.system(size: 11)).foregroundStyle(.secondary).settingsRowAttached()
            }
            SettingsTaskRow(title: L10n.tr("Voice language")) {
                speechLanguagePicker(selection: $voiceLanguage, localizedNames: draft.showLocalizedLanguageNames)
                    .labelsHidden().pickerStyle(.menu).settingsControlWidth()
            }.background {
                #if YULLO_TESTING
                    YulloActionPresentationProbe(title: "Customization content: speech-voices", action: {})
                #endif
            }
            SettingsTaskRow(title: L10n.tr("Voice")) {
                Picker(
                    L10n.tr("Voice"),
                    selection: Binding(
                        get: { draft.voiceIDs[voiceLanguage] ?? "" },
                        set: { draft.voiceIDs[voiceLanguage] = $0 })
                ) {
                    Text(L10n.tr("Automatic")).tag("")
                    if let stored = draft.voiceIDs[voiceLanguage], !stored.isEmpty,
                        !nativeVoices.contains(where: { $0.identifier == stored })
                    {
                        Text(L10n.tr("Unavailable voice")).tag(stored)
                    }
                    let showsLocale = Set(nativeVoices.map(\.language)).count > 1
                    ForEach(nativeVoices, id: \.identifier) {
                        Text(SpeechSettingsFields.macVoiceLabel($0, showsLocale: showsLocale)).tag($0.identifier)
                    }
                }.labelsHidden().pickerStyle(.menu).settingsControlWidth()
            }.accessibilityIdentifier("speech-custom-voices")
            if nativeVoices.isEmpty {
                Text(
                    L10n.tr(
                        "No Mac voice is installed. Add one in System Settings → Accessibility → Read & Speak."
                    )
                ).font(.system(size: 11)).foregroundStyle(.secondary).settingsRowAttached()
            }
        }
    }
    // One card; the page title names it.
    var body: some View {
        GroupBox {
            SettingsRows {
                serviceSelection
                if draft.pausedTasks.contains(.readAloud) {
                    PausedLine().settingsRowAttached()
                }
                if SpeechProvider(rawValue: draft.speechEngine) == nil {
                    SpeechPlaybackSpeed(draft: $draft, session: session)
                } else if provider == .macOS {
                    nativeVoiceSettings
                    SpeechPlaybackSpeed(draft: $draft, session: session)
                } else {
                    SpeechVoiceConfiguration(
                        draft: $draft, enteredKeys: $enteredKeys, voiceLanguage: $voiceLanguage,
                        provider: provider, session: session, stopCurrentSpeech: stopCurrentSpeech,
                        localModels: localModels, voicesExpanded: voicesExpansion,
                        revealedSections: revealedSections,
                        showsPlaybackSpeed: true)
                    Text(L10n.tr("Falls back to macOS voices.")).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .settingsRowAttached()
                }
            }
        }.id("playback").font(.system(size: 13)).disabled(voiceInputActive)
            .onChange(of: voiceInputActive) { _, active in if active { session.cancel() } }
            .onChange(of: scope) { _, _ in session.cancel(clearCatalog: true) }
            .onDisappear { session.cancel(clearCatalog: true) }
            .onAppear { if revealedSections.contains(.speechVoices) { voicesExpansion.wrappedValue = true } }
            .onChange(of: revealedSections) { old, sections in
                if sections.contains(.speechVoices), !old.contains(.speechVoices) {
                    voicesExpansion.wrappedValue = true
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(for: AVSpeechSynthesizer.availableVoicesDidChangeNotification)
                    .receive(on: RunLoop.main)
            ) { _ in nativeRevision &+= 1 }
    }
}

private struct SpeechCatalogScope: Equatable {
    let provider: SpeechProvider
    let endpoint: String
    let region: String
    let enteredKey: String
}

private struct SpeechKeyRemovalTarget {
    let scope: SpeechCatalogScope
    let account: String
}

private struct SpeechKeyRemovalTransition {
    let previous: SpeechCatalogScope
    func matches(old: SpeechCatalogScope, updated: SpeechCatalogScope) -> Bool {
        old == previous
            && updated
                == SpeechCatalogScope(
                    provider: previous.provider,
                    endpoint: previous.endpoint, region: previous.region, enteredKey: "")
    }
}

private struct SpeechPlaybackSpeed: View {
    @Binding var draft: Preferences
    @ObservedObject var session: SpeechSettingsSession
    var body: some View {
        SettingsTaskRow(title: L10n.tr("Speed")) {
            SettingsSliderControl(
                value: Binding(
                    get: { draft.speechRate },
                    set: {
                        session.cancel()
                        draft.speechRate = $0
                    }), range: 0.6...1.2, step: 0.05, label: L10n.tr("Speed"),
                text: L10n.format("%.2f×", draft.speechRate))
        }
    }
}

private struct AutomaticSpeechVoiceSummary: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L10n.tr("Voice"))
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(L10n.tr("Automatic")).foregroundStyle(.secondary)
                Text(L10n.tr("Follows text language"))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityIdentifier("speech-automatic-language")
    }
}

private struct SpeechVoiceConfiguration: View {
    @Environment(\.allowOnline) private var allowOnline
    @Binding var draft: Preferences
    @Binding var enteredKeys: [String: String]
    @Binding var voiceLanguage: String
    let provider: SpeechProvider
    @ObservedObject var session: SpeechSettingsSession
    let stopCurrentSpeech: () -> Void
    @ObservedObject var localModels = VoiceModelStore.shared
    let voicesExpanded: Binding<Bool>
    var revealedSections: Set<SettingsVisibilitySection> = []
    var interactionChanged: (Bool) -> Void = { _ in }
    var showsPlaybackSpeed = false
    @FocusState private var primaryFieldFocused: Bool
    @FocusState private var overrideFocused: Bool
    @State private var choosingDefaultVoice = false
    @State private var choosingOverrideVoice = false
    @State private var manualModel = false
    @State private var prefetchedVoices: SpeechSettingsSnapshot?
    private var hasInteraction: Bool {
        (usesDefaultVoice && primaryFieldFocused) || (!requiresReference && overrideFocused)
            || choosingDefaultVoice || choosingOverrideVoice || (provider == .elevenlabs && manualModel)
    }
    private var configuration: SpeechAPIConfiguration { SpeechSettingsFields.configuration(draft, provider: provider) }
    private var snapshot: SpeechSettingsSnapshot {
        SpeechSettingsFields.snapshot(draft, provider: provider, language: voiceLanguage)
    }
    private var selectedModel: Binding<String> { configurationBinding(\.model) }
    private var defaultVoice: Binding<String> { configurationBinding(\.voice) }
    // Empty removes only this language's customization. The global default voice
    // remains intact for services that require a voice ID.
    private var voiceOverride: Binding<String> {
        SpeechSettingsFields.voiceBinding(
            provider: provider, draft: $draft, language: voiceLanguage, beforeSet: { session.cancel() })
    }
    private var usesDefaultVoice: Bool { provider == .elevenlabs || provider == .speechAPI }
    // A local model speaks only its listed languages; Traditional Chinese text
    // uses its Mandarin voices.
    private var localSpeechLanguages: Set<String>? {
        guard provider == .local,
            let entry = ModelDiscoveryCatalog.entries.first(where: {
                $0.managedModelIDs.contains(draft.localSpeechModelID)
            })
        else { return nil }
        var ids = Set(entry.languageIDs)
        if ids.contains("zh") { ids.insert("zh-Hant") }
        return ids
    }
    private var unsupportedLocalLanguages: String? {
        guard let allowed = localSpeechLanguages else { return nil }
        let names = Language.enabled(draft.enabledLanguages).filter { !allowed.contains($0.id) }.map {
            $0.displayName(localized: draft.showLocalizedLanguageNames, locale: L10n.locale)
        }
        guard !names.isEmpty else { return nil }
        let formatter = ListFormatter()
        formatter.locale = L10n.locale
        return formatter.string(from: names) ?? names.joined(separator: ", ")
    }
    // Keep the voice language on one the selected local model can speak.
    private func keepLocalVoiceLanguage() {
        guard let allowed = localSpeechLanguages, !allowed.contains(voiceLanguage) else { return }
        let preferred = Language.enabled(draft.enabledLanguages).map(\.id).first(where: allowed.contains)
        if let next = preferred ?? Language.catalog.map(\.id).first(where: allowed.contains) { voiceLanguage = next }
    }
    private var requiresReference: Bool {
        provider == .local && LocalSpeechSynthesizer.requiresReferenceAudio(modelID: draft.localSpeechModelID)
    }
    private var unavailableVoiceLanguages: [String] {
        configuration.voiceIDsByLanguage.keys.filter { language in
            guard let voice = configuration.voiceIDsByLanguage[language], !voice.isEmpty else { return false }
            if provider == .local {
                return !LocalSpeechSynthesizer.voices(modelID: draft.localSpeechModelID, language: language).contains {
                    $0.id == voice
                }
            }
            // An unopened remote catalog is unknown, not evidence that a saved
            // voice is missing. Inspect only a catalog explicitly fetched here.
            guard session.hasLoadedVoices else { return false }
            return !session.voices.contains { $0.id == voice }
        }.sorted()
    }
    private var mustShowVoiceDetails: Bool {
        overrideFocused || choosingOverrideVoice
            || ((!choosingDefaultVoice && !choosingOverrideVoice)
                && (session.action != nil || session.messageTone == .failure))
            || !unavailableVoiceLanguages.isEmpty
    }
    private var customizationExpansion: Binding<Bool> {
        Binding(
            get: { voicesExpanded.wrappedValue || mustShowVoiceDetails },
            set: { voicesExpanded.wrappedValue = $0 })
    }
    private var hasOverrides: Bool {
        configuration.voiceIDsByLanguage.values.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    // Whether this service may run now; background loads wait for it.
    private var allowsServiceActions: Bool {
        provider == .local || provider == .macOS || draft.processingPolicy == .standard
    }
    // A test or refresh the person starts sends only a fixed sample, so it
    // runs wherever Yullo works; background loads wait for online.
    private var startsServiceActions: Bool { true }
    private var essentialVoiceSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            if provider == .local {
                LocalTaskModelPicker(
                    task: .readAloud, selected: $draft.localSpeechModelID, models: localModels,
                    languageIDs: draft.modelSuggestionLanguageIDs)
            }
            if usesDefaultVoice {
                modelFields
                HStack(alignment: .bottom, spacing: 12) {
                    speechField("Default voice", hint: "Voice ID", text: defaultVoice, focused: $primaryFieldFocused)
                    Button(L10n.tr("Choose voice…")) { choosingDefaultVoice = true }.buttonStyle(.link).padding(
                        .bottom, 5
                    )
                    .popover(isPresented: $choosingDefaultVoice, arrowEdge: .bottom) {
                        voiceChooser(selection: defaultVoice, automatic: false) { choosingDefaultVoice = false }
                    }
                }
                modelCatalogButton
            } else if provider != .local {
                AutomaticSpeechVoiceSummary()
            }
        }
    }
    // A local model shows its voices directly: the choice is the main setting.
    @ViewBuilder private var localVoiceSettings: some View {
        LocalVoiceSettings(
            draft: $draft, voiceLanguage: $voiceLanguage, selection: voiceOverride, session: session,
            snapshot: snapshot,
            languages: LocalVoicePresentation.languages(
                supported: localSpeechLanguages ?? [], enabled: Language.enabled(draft.enabledLanguages).map(\.id),
                current: voiceLanguage),
            allowsActions: allowsServiceActions, preview: previewLocalVoice, chooseReference: chooseReferenceAudio
        ).padding(.top, 14)
        if !unavailableVoiceLanguages.isEmpty {
            Text(
                speechUnavailableVoiceSummary(
                    unavailableVoiceLanguages, localizedNames: draft.showLocalizedLanguageNames)
            )
            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
        }
        if let unsupported = unsupportedLocalLanguages {
            Text(L10n.format("For %@, Yullo uses a Mac voice.", unsupported))
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }
    private func previewLocalVoice(_ candidate: SpeechSettingsSnapshot, tag: String) {
        let frozen = snapshot
        session.run(
            .preview, snapshot: candidate, enteredKey: "", stopCurrentSpeech: stopCurrentSpeech,
            isCurrent: { snapshot == frozen }, previewTag: tag)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            essentialVoiceSettings
            if provider == .local {
                localVoiceSettings
            } else {
                SettingsCustomizationSection(
                    .speechVoices, title: L10n.tr("Customize voices"), isExpanded: customizationExpansion,
                    summary: hasOverrides ? speechVoiceCustomizationSummary(configuration.voiceIDsByLanguage) : nil,
                    nested: true, collapsible: !mustShowVoiceDetails
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        if !unavailableVoiceLanguages.isEmpty {
                            Text(
                                speechUnavailableVoiceSummary(
                                    unavailableVoiceLanguages, localizedNames: draft.showLocalizedLanguageNames)
                            )
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        speechLanguagePicker(
                            selection: Binding(
                                get: { voiceLanguage },
                                set: {
                                    session.cancel()
                                    voiceLanguage = $0
                                }), localizedNames: draft.showLocalizedLanguageNames)
                        HStack(alignment: .bottom, spacing: 12) {
                            speechField(
                                "Voice override", hint: usesDefaultVoice ? "Default voice" : "Automatic",
                                text: voiceOverride, focused: $overrideFocused)
                            Button(L10n.tr("Choose voice…")) { choosingOverrideVoice = true }.buttonStyle(.link)
                                .padding(.bottom, 5)
                                .popover(isPresented: $choosingOverrideVoice, arrowEdge: .bottom) {
                                    voiceChooser(selection: voiceOverride, automatic: true) {
                                        choosingOverrideVoice = false
                                    }
                                }
                        }
                        Text(L10n.tr("This language only."))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }.padding(.top, 10)
                }.accessibilityIdentifier("speech-custom-voices").padding(.top, 14)
            }
            if showsPlaybackSpeed { SpeechPlaybackSpeed(draft: $draft, session: session).padding(.top, 14) }
            HStack {
                Button(L10n.tr("Test voice")) { run(.preview) }
                    .background {
                        #if YULLO_TESTING
                            YulloActionPresentationProbe(title: "Test voice", action: { run(.preview) })
                        #endif
                    }.disabled(session.action != nil || !startsServiceActions)
                if session.action != nil {
                    if session.isPlaying {
                        ActivityMark(glyph: .playing)
                    } else {
                        ActivityStatus(
                            title: L10n.tr(session.action == .preview ? "Preparing sample…" : "Loading…"),
                            slowNote: provider == .local ? L10n.tr("The voice model loads on first use.") : nil
                        )
                    }
                    Button(L10n.tr("Cancel")) { session.cancel() }
                        .background {
                            #if YULLO_TESTING
                                YulloActionPresentationProbe(title: "Cancel", action: { session.cancel() })
                            #endif
                        }.buttonStyle(.link)
                }
                Spacer(minLength: 0)
                Text(
                    L10n.format(
                        "Sample: %@",
                        Language.displayName(
                            for: voiceLanguage, localized: draft.showLocalizedLanguageNames, locale: L10n.locale))
                )
                .font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(.top, 14)
            if !session.message.isEmpty && !choosingDefaultVoice && !choosingOverrideVoice {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    SpeechSettingsFeedback(session: session)
                    // The test ran without changing the mode; using the voice needs online.
                    if !allowsServiceActions, let allow = allowOnline.allow {
                        Spacer(minLength: 8)
                        Button(L10n.tr("Allow online"), action: allow).buttonStyle(.link).font(.system(size: 12))
                            .accessibilityIdentifier("speech-feedback-allow-online")
                    }
                }.padding(.top, 14)
            }
        }.font(.system(size: 13))
            .onAppear { interactionChanged(hasInteraction) }
            .onChange(of: hasInteraction) { _, active in interactionChanged(active) }
            .onDisappear { interactionChanged(false) }
            .onAppear { if revealedSections.contains(.speechVoices) { voicesExpanded.wrappedValue = true } }
            .onChange(of: revealedSections) { old, sections in
                if sections.contains(.speechVoices), !old.contains(.speechVoices) {
                    voicesExpanded.wrappedValue = true
                }
            }
            .onChange(of: snapshot) { _, _ in
                choosingDefaultVoice = false
                choosingOverrideVoice = false
                session.cancel()
            }
            .onAppear(perform: prefetchVoices)
            .onAppear(perform: keepLocalVoiceLanguage)
            .onChange(of: draft.localSpeechModelID) { _, _ in keepLocalVoiceLanguage() }
            .onChange(of: provider) { _, _ in keepLocalVoiceLanguage() }
            .onChange(of: customizationExpansion.wrappedValue) { _, _ in prefetchVoices() }
            .onChange(of: session.worked) { _, worked in
                if let worked, worked.provider == provider, let service = ConnectedService.speech(provider) {
                    draft.recordWorking(service)
                }
            }
    }
    // Opening Customize voices loads a working service's voice list once, quietly
    // and from the shared cache when it is fresh, so unavailable voices show at once.
    // Typing in connection fields never triggers it.
    private func prefetchVoices() {
        // Only a service that has worked is worth a background load; others
        // load when their chooser opens.
        guard customizationExpansion.wrappedValue, [.azure, .google, .elevenlabs].contains(provider),
            ConnectedService.speech(provider).map(draft.isWorking) == true,
            allowsServiceActions, !session.hasLoadedVoices, session.action == nil, !session.loadingInBackground,
            prefetchedVoices != snapshot
        else { return }
        prefetchedVoices = snapshot
        let frozen = snapshot, key = enteredKeys[provider.rawValue] ?? ""
        session.run(
            .voices, snapshot: frozen, enteredKey: key, stopCurrentSpeech: stopCurrentSpeech,
            isCurrent: { snapshot == frozen && (enteredKeys[provider.rawValue] ?? "") == key },
            refresh: false, feedback: .none)
    }
    @ViewBuilder private var modelFields: some View {
        if provider == .elevenlabs, !session.models.isEmpty {
            Picker(
                L10n.tr("Speech model"),
                selection: Binding(
                    get: {
                        manualModel || !session.models.contains(where: { $0.id == configuration.model })
                            ? "__manual__" : configuration.model
                    },
                    set: { value in
                        manualModel = value == "__manual__"
                        if !manualModel { selectedModel.wrappedValue = value }
                    })
            ) {
                ForEach(session.models) { Text($0.name + " · " + $0.id).tag($0.id) }
                Text(L10n.tr("Other model…")).tag("__manual__")
            }
        }
        if provider != .elevenlabs || session.models.isEmpty || manualModel
            || !session.models.contains(where: { $0.id == configuration.model })
        {
            speechField(
                "Model ID", hint: provider == .elevenlabs ? "eleven_multilingual_v2" : "Model ID", text: selectedModel,
                focused: $primaryFieldFocused)
        }
    }
    @ViewBuilder private var modelCatalogButton: some View {
        if provider == .elevenlabs {
            Button(L10n.tr("Refresh models")) { run(.models) }.buttonStyle(.link)
                .background {
                    #if YULLO_TESTING
                        YulloActionPresentationProbe(title: "Refresh models", action: { run(.models) })
                    #endif
                }
                .disabled(session.action != nil || !startsServiceActions)
        }
    }
    private func voiceChooser(selection: Binding<String>, automatic: Bool, close: @escaping () -> Void) -> some View {
        let frozen = snapshot, key = enteredKeys[provider.rawValue] ?? ""
        return SpeechVoiceChooser(
            session: session, snapshot: frozen, enteredKey: key, selected: selection,
            allowsAutomatic: automatic, allowsServiceActions: allowsServiceActions,
            localizedLanguageNames: draft.showLocalizedLanguageNames,
            isCurrent: {
                (automatic ? choosingOverrideVoice : choosingDefaultVoice) && snapshot == frozen
                    && (enteredKeys[provider.rawValue] ?? "") == key
            }, stopCurrentSpeech: stopCurrentSpeech, close: close)
    }
    private func run(_ action: SpeechSettingsSession.Action) {
        if action == .voices || action == .models { voicesExpanded.wrappedValue = true }
        let frozen = snapshot, key = enteredKeys[provider.rawValue] ?? ""
        session.run(
            action, snapshot: frozen, enteredKey: key, stopCurrentSpeech: stopCurrentSpeech,
            isCurrent: { snapshot == frozen && (enteredKeys[provider.rawValue] ?? "") == key })
    }
    private func chooseReferenceAudio() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let type = UTType(filenameExtension: "wav") { panel.allowedContentTypes = [type] }
        if panel.runModal() == .OK, let url = panel.url {
            session.cancel()
            draft.localSpeechReferencePath = url.path
        }
    }
    private func configurationBinding(_ key: WritableKeyPath<SpeechAPIConfiguration, String>) -> Binding<String> {
        SpeechSettingsFields.binding(key, provider: provider, draft: $draft, beforeSet: { session.cancel() })
    }
}

#if YULLO_TESTING
    struct SpeechVoiceChooserAttachedActions {
        let search: Binding<String>
        let allLanguages: Binding<Bool>
        let focusedVoice: Binding<String?>
        let groups: () -> [SpeechVoiceCatalogPresentation.Group]
        let ready: () -> Bool
        let choose: (String) -> Bool
        let commitFocused: () -> Bool
        let preview: (String) -> Bool
        let stop: () -> Void
        let load: () -> Bool
        let catalogRevision: () -> UUID
        let chooseFromRevision: (String, UUID) -> Bool
    }
#endif
private struct SpeechVoiceChooserCatalogRequest: Equatable {
    let voices: [SpeechVoice]
    let revision: UUID
    let locale: String
    let localizedLanguageNames: Bool
}

struct SpeechVoiceChooser: View {
    @ObservedObject var session: SpeechSettingsSession
    let snapshot: SpeechSettingsSnapshot
    let enteredKey: String
    @Binding var selected: String
    var allowsAutomatic = true
    var allowsServiceActions = true
    var localizedLanguageNames = true
    var isCurrent: () -> Bool = { true }
    let stopCurrentSpeech: () -> Void
    let close: () -> Void
    @State private var search = ""
    @State private var allLanguages = false
    @State private var presentation: SpeechVoiceCatalogPresentation?
    @State private var presentationRevision: UUID?
    @State private var focusedVoice: String?
    @State private var committed = false
    @State private var ownedRequest: UUID?
    @State private var visible = false
    @State private var attemptedInitialLoad = false
    #if YULLO_TESTING
        var yulloTestingCaptureActions: ((SpeechVoiceChooserAttachedActions) -> Void)?
    #endif
    private var provider: SpeechProvider { snapshot.provider }
    private var language: String { snapshot.language }
    private var supportsCatalog: Bool { [.azure, .google, .elevenlabs].contains(provider) }
    private var voices: [SpeechVoice] {
        if provider == .speechAPI {
            let ids = Set(
                [snapshot.configuration.voice, selected] + Array(snapshot.configuration.voiceIDsByLanguage.values))
            return ids.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.sorted().map {
                SpeechVoice(id: $0, name: $0, languageCodes: [])
            }
        }
        return session.voices
    }
    private var ready: Bool { presentation != nil && presentationRevision == session.voiceCatalogRevision }
    private var groups: [SpeechVoiceCatalogPresentation.Group] {
        ready ? presentation?.groups(language: language, allLanguages: allLanguages, query: search) ?? [] : []
    }
    private var languageName: String {
        Language.displayName(for: language, localized: localizedLanguageNames, locale: L10n.locale)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 12) {
                Text(L10n.tr(allowsAutomatic ? "Voice" : "Default voice"))
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if supportsCatalog {
                    if session.action == .voices, ownedRequest != nil {
                        Button(L10n.tr("Cancel"), action: stopOwned)
                            .accessibilityIdentifier("speech-voice-cancel-load")
                    } else {
                        Button {
                            _ = load()
                        } label: {
                            Label(
                                L10n.tr(
                                    session.messageTone == .failure && !session.hasLoadedVoices ? "Retry" : "Refresh"),
                                systemImage: "arrow.clockwise")
                        }
                        .disabled(!allowsServiceActions || session.action == .voices || session.action == .models)
                        .accessibilityIdentifier("speech-voice-refresh")
                        .help(L10n.tr(session.voiceCatalogActionTitle))
                    }
                }
                Button(L10n.tr("Done"), action: close).keyboardShortcut(.cancelAction)
            }.buttonStyle(.bordered)
            if session.action == .voices || session.loadingInBackground {
                ActivityStatus(title: L10n.tr("Loading voices…")).accessibilityIdentifier("speech-voice-loading")
            }
            if !session.message.isEmpty, session.action != .preview {
                SpeechSettingsFeedback(session: session)
            }
            if supportsCatalog {
                Picker(L10n.tr("Show voices"), selection: $allLanguages) {
                    Text(L10n.format("For %@", languageName)).tag(false)
                    Text(L10n.tr("All languages")).tag(true)
                }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("speech-voice-filter")
            }
            TextField(L10n.tr("Search voices"), text: $search).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("speech-voice-search")
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.tr("Current voice")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                if selected.isEmpty {
                    Text(L10n.tr("Automatic")).font(.system(size: 13, weight: .medium))
                } else if let current = presentation?.voices.first(where: { $0.id == selected }) {
                    Text(current.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if current.id != current.name {
                        Text(current.id).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            .truncationMode(.middle).help(current.id)
                    }
                } else {
                    Text(selected).font(.system(size: 12)).lineLimit(1).truncationMode(.middle).help(selected)
                    if session.hasLoadedVoices {
                        Text(L10n.tr("The saved voice isn’t in this list.")).font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }.accessibilityElement(children: .combine).accessibilityIdentifier("speech-current-voice")
            List(selection: $focusedVoice) {
                if allowsAutomatic {
                    HStack(spacing: 8) {
                        selectionButton(id: "", name: L10n.tr("Automatic"), detail: "", revision: nil)
                        previewButton(id: "", name: L10n.tr("Automatic"))
                    }.tag("")
                }
                ForEach(groups) { group in
                    Section {
                        ForEach(group.voices) { voice in
                            HStack(spacing: 8) {
                                selectionButton(
                                    id: voice.id, name: voice.name, detail: detail(voice),
                                    revision: session.voiceCatalogRevision)
                                previewButton(id: voice.id, name: voice.name)
                            }.tag(voice.id)
                        }
                    } header: {
                        Text(provider == .speechAPI ? L10n.tr("Saved voices") : presentation?.name(for: group) ?? "")
                    }
                }
            }.listStyle(.inset).glassList().frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("speech-voice-results")
                .onKeyPress(.return) { commitFocused() ? .handled : .ignored }
            if session.action == .preview {
                HStack(spacing: 8) {
                    ActivityStatus(
                        title: L10n.tr("Test voice") + ": " + previewName,
                        glyph: session.isPlaying ? .playing : .working,
                        elapsedAfter: session.isPlaying ? nil : 3, size: 11)
                    Spacer(minLength: 4)
                    Button(L10n.tr("Stop")) {
                        session.cancel()
                        ownedRequest = nil
                    }.buttonStyle(.link)
                }
            }
            if provider == .speechAPI {
                Text(L10n.tr("This service doesn’t list its voices. Type a voice ID in the field instead."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(14).frame(width: 420, height: 510).environment(\.locale, L10n.locale)
            .task(
                id: SpeechVoiceChooserCatalogRequest(
                    voices: voices, revision: session.voiceCatalogRevision,
                    locale: L10n.locale.identifier, localizedLanguageNames: localizedLanguageNames)
            ) {
                let values = voices, locale = L10n.locale, localized = localizedLanguageNames
                let revision = session.voiceCatalogRevision
                let work = Task.detached(priority: .userInitiated) {
                    SpeechVoiceCatalogPresentation(values, locale: locale, localizedLanguageNames: localized)
                }
                let value = await withTaskCancellationHandler(
                    operation: { await work.value }, onCancel: { work.cancel() })
                guard !Task.isCancelled, isCurrent(), session.voiceCatalogRevision == revision else { return }
                presentation = value
                presentationRevision = revision
                focusedVoice = nil
            }
            .onChange(of: search) { _, _ in focusedVoice = nil }
            .onChange(of: allLanguages) { _, _ in focusedVoice = nil }
            .onChange(of: session.action) { _, _ in loadInitialCatalogIfNeeded() }
            .onChange(of: session.loadingInBackground) { _, _ in loadInitialCatalogIfNeeded() }
            .onDisappear {
                visible = false
                stopOwned()
            }
            .onAppear {
                visible = true
                loadInitialCatalogIfNeeded()
                #if YULLO_TESTING
                    yulloTestingCaptureActions?(
                        .init(
                            search: $search, allLanguages: $allLanguages,
                            focusedVoice: $focusedVoice, groups: { groups }, ready: { ready }, choose: choose,
                            commitFocused: commitFocused, preview: preview, stop: stopOwned, load: { load() },
                            catalogRevision: { session.voiceCatalogRevision },
                            chooseFromRevision: { choose($0, revision: $1) }))
                #endif
            }
    }
    private func selectionButton(id: String, name: String, detail: String, revision: UUID?) -> some View {
        Button {
            _ = choose(id, revision: revision)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if selected == id { Image(systemName: "checkmark").accessibilityHidden(true) }
            }.padding(.vertical, 3).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(name).accessibilityValue(detail)
            .accessibilityAddTraits(selected == id ? .isSelected : [])
    }
    private func previewButton(id: String, name: String) -> some View {
        let active = session.action == .preview && session.previewVoiceID == previewVoiceID(id)
        return Button {
            if active {
                session.cancel()
                ownedRequest = nil
            } else {
                _ = preview(id)
            }
        } label: {
            Image(systemName: active ? "stop.fill" : "play.fill").frame(width: 22, height: 24)
        }.buttonStyle(.borderless)
            .disabled(!allowsServiceActions)
            .accessibilityLabel(L10n.tr(active ? "Stop" : "Test voice") + ": " + name)
            .help(L10n.tr(active ? "Stop" : "Test voice") + ": " + name)
    }
    private func detail(_ voice: SpeechVoiceCatalogPresentation.Voice) -> String {
        if provider == .speechAPI { return "" }
        let languages =
            voice.languageDescription.isEmpty ? L10n.tr("Language not specified") : voice.languageDescription
        return voice.detail.isEmpty ? languages : languages + " · " + voice.detail
    }
    @discardableResult private func choose(_ id: String) -> Bool { choose(id, revision: session.voiceCatalogRevision) }
    @discardableResult private func choose(_ id: String, revision: UUID?) -> Bool {
        guard visible, !committed, isCurrent() else { return false }
        if id.isEmpty {
            guard allowsAutomatic else { return false }
        } else {
            guard revision == session.voiceCatalogRevision, ready,
                groups.contains(where: { $0.voices.contains(where: { $0.id == id }) }),
                voices.contains(where: { $0.id == id })
            else { return false }
        }
        committed = true
        selected = id
        close()
        return true
    }
    @discardableResult private func commitFocused() -> Bool { focusedVoice.map(choose) ?? false }
    private var previewName: String {
        guard let id = session.previewVoiceID, !id.isEmpty else { return L10n.tr("Automatic") }
        return presentation?.voices.first(where: { $0.id == id })?.name ?? id
    }
    private func previewVoiceID(_ id: String) -> String {
        id.isEmpty ? snapshot.configuration.voice : id
    }
    @discardableResult private func preview(_ id: String) -> Bool {
        guard visible, !committed, isCurrent(), allowsServiceActions else { return false }
        if id.isEmpty {
            guard allowsAutomatic else { return false }
        } else {
            guard ready, voices.contains(where: { $0.id == id }) else { return false }
        }
        var configuration = snapshot.configuration
        configuration.voiceIDsByLanguage.removeValue(forKey: language)
        if !id.isEmpty { configuration.voiceIDsByLanguage[language] = id }
        let candidate = SpeechSettingsSnapshot(
            provider: snapshot.provider, configuration: configuration,
            region: snapshot.region, language: snapshot.language, rate: snapshot.rate,
            localReferenceAudioURL: snapshot.localReferenceAudioURL, authorization: snapshot.authorization)
        ownedRequest = session.run(
            .preview, snapshot: candidate, enteredKey: enteredKey,
            stopCurrentSpeech: stopCurrentSpeech, isCurrent: isCurrent)
        return true
    }
    private func loadInitialCatalogIfNeeded() {
        guard visible, !attemptedInitialLoad, !session.hasLoadedVoices, session.action == nil,
            !session.loadingInBackground,
            supportsCatalog, allowsServiceActions, isCurrent()
        else { return }
        attemptedInitialLoad = true
        _ = load(refresh: false, feedback: .failures)
    }
    @discardableResult private func load(
        refresh: Bool = true, feedback: SpeechSettingsSession.Feedback = .all
    ) -> Bool {
        guard visible, !committed, isCurrent(), allowsServiceActions, supportsCatalog,
            session.action != .voices && session.action != .models
        else { return false }
        ownedRequest = session.run(
            .voices, snapshot: snapshot, enteredKey: enteredKey,
            stopCurrentSpeech: stopCurrentSpeech, isCurrent: isCurrent, refresh: refresh, feedback: feedback)
        return true
    }
    private func stopOwned() {
        session.cancel(request: ownedRequest)
        ownedRequest = nil
    }
}

enum SpeechSettingsFields {
    // "Daniel · English (United Kingdom) · Male · Enhanced": the locale only
    // when the list mixes several, and gender only when macOS reports it.
    static func macVoiceLabel(_ voice: AVSpeechSynthesisVoice, showsLocale: Bool) -> String {
        var parts = [voice.name]
        if showsLocale, let locale = L10n.locale.localizedString(forIdentifier: voice.language) {
            parts.append(locale)
        }
        switch voice.gender {
        case .female: parts.append(LocalSpeechVoiceCatalog.genderName(.female))
        case .male: parts.append(LocalSpeechVoiceCatalog.genderName(.male))
        default: break
        }
        if voice.quality == .premium { parts.append(L10n.tr("Premium")) }
        if voice.quality == .enhanced { parts.append(L10n.tr("Enhanced")) }
        return parts.joined(separator: " · ")
    }
    static func voiceDetail(_ voice: SpeechVoice) -> String {
        ([
            SpeechVoiceCatalogPresentation.accentName(voice.accent),
            SpeechVoiceCatalogPresentation.genderName(voice.gender), voice.name == voice.id ? nil : voice.id
        ].compactMap { $0 }).joined(separator: " · ")
    }
    static func voiceChoices(_ voices: [SpeechVoice], provider: SpeechProvider, language: String, query: String)
        -> [SpeechVoice]
    {
        let terms = query.split(whereSeparator: \.isWhitespace)
        return voices.filter { voice in
            let searchable = voice.displayLabel + " " + voiceDetail(voice)
            return (provider == .elevenlabs || voice.supports(language: language))
                && terms.allSatisfy { searchable.localizedStandardContains(String($0)) }
        }.sorted { first, second in
            let firstNative = first.supports(language: language), secondNative = second.supports(language: language)
            if provider == .elevenlabs, firstNative != secondNative { return firstNative }
            let order = first.name.localizedStandardCompare(second.name)
            return order == .orderedSame ? first.id < second.id : order == .orderedAscending
        }
    }
    static func title(_ provider: SpeechProvider) -> String {
        switch provider {
        case .macOS: return "macOS"
        case .local: return L10n.tr("Local model")
        case .azure: return "Azure Speech"
        case .google: return "Google Cloud Text-to-Speech"
        case .elevenlabs: return "ElevenLabs"
        case .speechAPI: return L10n.tr("Custom speech service")
        }
    }
    static func configuration(_ draft: Preferences, provider: SpeechProvider) -> SpeechAPIConfiguration {
        switch provider {
        case .azure: return .init(voiceIDsByLanguage: draft.azureVoiceIDsByLanguage)
        case .google: return draft.googleSpeech
        case .elevenlabs: return draft.elevenLabsSpeech
        case .speechAPI: return draft.speechAPI
        case .macOS: return .init()
        case .local:
            return .init(
                model: draft.localSpeechModelID,
                voiceIDsByLanguage: draft.localSpeechVoices(forModel: draft.localSpeechModelID))
        }
    }
    static func set(_ configuration: SpeechAPIConfiguration, provider: SpeechProvider, draft: inout Preferences) {
        switch provider {
        case .azure: draft.azureVoiceIDsByLanguage = configuration.voiceIDsByLanguage
        case .google: draft.googleSpeech = configuration
        case .elevenlabs: draft.elevenLabsSpeech = configuration
        case .speechAPI: draft.speechAPI = configuration
        case .macOS: break
        case .local:
            if draft.localSpeechModelID == configuration.model {
                draft.setLocalSpeechVoices(configuration.voiceIDsByLanguage, forModel: configuration.model)
            } else {
                // Changing models must not copy the former model's voice IDs.
                draft.localSpeechModelID = configuration.model
            }
        }
    }
    @MainActor static func binding(
        _ key: WritableKeyPath<SpeechAPIConfiguration, String>, provider: SpeechProvider, draft: Binding<Preferences>,
        beforeSet: @escaping () -> Void
    ) -> Binding<String> {
        Binding(
            get: { configuration(draft.wrappedValue, provider: provider)[keyPath: key] },
            set: { value in
                beforeSet()
                var updatedDraft = draft.wrappedValue
                var updated = configuration(updatedDraft, provider: provider)
                updated[keyPath: key] = value
                set(updated, provider: provider, draft: &updatedDraft)
                draft.wrappedValue = updatedDraft
            })
    }
    @MainActor static func voiceBinding(
        provider: SpeechProvider, draft: Binding<Preferences>, language: String, beforeSet: @escaping () -> Void
    ) -> Binding<String> {
        let model = provider == .local ? draft.wrappedValue.localSpeechModelID : nil
        return Binding(
            get: {
                if let model { return draft.wrappedValue.localSpeechVoices(forModel: model)[language] ?? "" }
                return configuration(draft.wrappedValue, provider: provider).voiceIDsByLanguage[language] ?? ""
            },
            set: { value in
                guard model == nil || draft.wrappedValue.localSpeechModelID == model else { return }
                beforeSet()
                var updatedDraft = draft.wrappedValue
                var updated = configuration(updatedDraft, provider: provider)
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    updated.voiceIDsByLanguage.removeValue(forKey: language)
                } else {
                    updated.voiceIDsByLanguage[language] = value
                }
                set(updated, provider: provider, draft: &updatedDraft)
                draft.wrappedValue = updatedDraft
            })
    }
    static func snapshot(_ draft: Preferences, provider: SpeechProvider, language: String) -> SpeechSettingsSnapshot {
        .init(
            provider: provider, configuration: configuration(draft, provider: provider),
            region: provider == .azure ? draft.azureRegion : "", language: language, rate: draft.speechRate,
            localReferenceAudioURL: provider == .local && !draft.localSpeechReferencePath.isEmpty
                ? URL(fileURLWithPath: draft.localSpeechReferencePath) : nil,
            authorization: ProcessingPolicyController.shared.connectionTestAuthorization())
    }
    static func setupURL(_ provider: SpeechProvider) -> URL {
        switch provider {
        case .azure:
            return URL(
                string: "https://learn.microsoft.com/azure/ai-services/speech-service/get-started-text-to-speech")!
        case .google: return URL(string: "https://docs.cloud.google.com/docs/authentication/api-keys")!
        case .elevenlabs: return URL(string: "https://elevenlabs.io/docs/developers/quickstart")!
        case .speechAPI: return URL(string: "https://github.com/remsky/Kokoro-FastAPI")!
        case .macOS:
            return URL(string: "https://support.apple.com/guide/mac-help/change-spoken-content-settings-mchlp2290/mac")!
        case .local: return URL(string: "https://huggingface.co/hexgrad/Kokoro-82M")!
        }
    }
}

private func speechVoiceCustomizationSummary(_ voices: [String: String]) -> String {
    let count = voices.values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    return count == 0 ? L10n.tr("No language-specific voices") : L10n.format("Languages with custom voices: %ld", count)
}

private func speechUnavailableVoiceSummary(_ languages: [String], localizedNames: Bool) -> String {
    L10n.tr("Unavailable voice") + ": "
        + languages.map { id in
            Language.displayName(for: id, localized: localizedNames, locale: L10n.locale)
        }.joined(separator: localizedNames ? " · " : ", ")
}

private func speechField(
    _ title: String, hint: String, text: Binding<String>, focused: FocusState<Bool>.Binding? = nil
) -> some View {
    VStack(alignment: .leading, spacing: 7) {
        Text(L10n.tr(title)).font(.system(size: 13, weight: .medium))
        if let focused {
            TextField(L10n.tr(hint), text: text).textFieldStyle(.roundedBorder).font(.system(size: 13))
                .autocorrectionDisabled().accessibilityLabel(L10n.tr(title)).focused(focused)
        } else {
            TextField(L10n.tr(hint), text: text).textFieldStyle(.roundedBorder).font(.system(size: 13))
                .autocorrectionDisabled().accessibilityLabel(L10n.tr(title))
        }
    }
}
private func speechLanguagePicker(selection: Binding<String>, localizedNames: Bool) -> some View {
    Picker(L10n.tr("Voice language"), selection: selection) {
        ForEach(Language.sorted(Language.catalog, localized: localizedNames, locale: L10n.locale)) {
            Text($0.displayName(localized: localizedNames, locale: L10n.locale)).tag($0.id)
        }
    }.accessibilityIdentifier("speech-voice-language")
}
