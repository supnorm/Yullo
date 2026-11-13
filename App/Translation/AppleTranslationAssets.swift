import Foundation
import Combine
import Translation

struct AppleTranslationAssetLanguage: Identifiable, Equatable, Sendable {
    let id: String
    init(_ language: Locale.Language) { id = language.minimalIdentifier }
    init(id: String) { self.id = id }
    var language: Locale.Language { Locale.Language(identifier: id) }
    func name(localized: Bool, locale: Locale = L10n.locale) -> String {
        let displayLocale = localized ? locale : Locale(identifier: id)
        return displayLocale.localizedString(forIdentifier: id) ?? id
    }
}

struct AppleTranslationAssetPair: Hashable, Sendable {
    let source: String
    let target: String
}

enum AppleTranslationAssetStatus: Equatable, Sendable {
    case checking, installed, supported, unsupported, unavailable(String)
}

struct AppleTranslationAssetsBackend: Sendable {
    var catalog: @Sendable () async throws -> [AppleTranslationAssetLanguage]
    var status: @Sendable (AppleTranslationAssetPair) async throws -> AppleTranslationAssetStatus
    static var system: Self {
        Self(
            catalog: {
                try Task.checkCancellation()
                let languages = await LanguageAvailability().supportedLanguages
                try Task.checkCancellation()
                return languages.map(AppleTranslationAssetLanguage.init)
            },
            status: { pair in
                try Task.checkCancellation()
                let status = await LanguageAvailability().status(
                    from: Locale.Language(identifier: pair.source), to: Locale.Language(identifier: pair.target))
                try Task.checkCancellation()
                switch status {
                case .installed: return .installed
                case .supported: return .supported
                case .unsupported: return .unsupported
                @unknown default: return .unavailable("")
                }
            })
    }
}

struct AppleTranslationAssetDownloadRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let pair: AppleTranslationAssetPair
}

struct AppleTranslationAssetFeedback: Equatable {
    enum Outcome: Equatable { case installed, notReady, failed(String), cancelled }
    let pair: AppleTranslationAssetPair
    let outcome: Outcome
}

// Metadata only: inspecting a source queries its N directional pairs, with at
// most four requests in flight across source revisions. Download approval is
// owned by the visible translationTask host after an explicit button action.
@MainActor final class AppleTranslationAssets: ObservableObject {
    @Published private(set) var languages: [AppleTranslationAssetLanguage] = []
    @Published private(set) var source: String?
    @Published private(set) var preferredTarget: String?
    @Published private(set) var statuses: [String: AppleTranslationAssetStatus] = [:]
    @Published private(set) var loadingCatalog = false
    @Published private(set) var catalogError: String?
    @Published private(set) var downloadRequest: AppleTranslationAssetDownloadRequest?
    @Published private(set) var verifyingDownload = false
    @Published private(set) var feedback: AppleTranslationAssetFeedback?
    private let backend: AppleTranslationAssetsBackend
    private let initialSource: String
    private let initialTarget: String
    private var active = false
    private var revision: UInt64 = 0
    private var catalogTask: Task<Void, Never>?
    private var checks: [UUID: Task<Void, Never>] = [:]
    private struct Job {
        let pair: AppleTranslationAssetPair
        let revision: UInt64
        var downloadID: UUID?
    }
    private var jobs: [Job] = []
    private var jobIndex = 0
    static let maximumConcurrentChecks = 4

    init(source: String, target: String, backend: AppleTranslationAssetsBackend = .system) {
        initialSource = source
        initialTarget = target
        self.backend = backend
    }

    deinit {
        catalogTask?.cancel()
        checks.values.forEach { $0.cancel() }
    }

    func activate() {
        guard !active else { return }
        active = true
        if languages.isEmpty { loadCatalog() } else { checkSource() }
    }

    func deactivate() {
        active = false
        revision &+= 1
        catalogTask?.cancel()
        checks.values.forEach { $0.cancel() }
        jobs = []
        jobIndex = 0
        downloadRequest = nil
        verifyingDownload = false
    }

    func reloadCatalog() {
        guard active, !loadingCatalog, downloadRequest == nil else { return }
        loadCatalog()
    }

    private func loadCatalog() {
        guard active, catalogTask == nil else { return }
        loadingCatalog = true
        catalogError = nil
        let backend = backend
        catalogTask = Task { [weak self] in
            do {
                let values = try await backend.catalog()
                let cancelled = Task.isCancelled
                self?.receivedCatalog(values, error: nil, cancelled: cancelled)
            } catch {
                self?.receivedCatalog([], error: error.localizedDescription, cancelled: Task.isCancelled)
            }
        }
    }

    private func receivedCatalog(_ values: [AppleTranslationAssetLanguage], error: String?, cancelled: Bool) {
        catalogTask = nil
        loadingCatalog = false
        guard active else { return }
        if cancelled {
            loadCatalog()
            return
        }
        var seen: Set<String> = []
        languages = values.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        guard !languages.isEmpty else {
            catalogError = error.map(Self.boundedMessage) ?? ""
            return
        }
        source = source.flatMap { match($0) } ?? match(initialSource)
        preferredTarget = match(initialTarget)
        checkSource()
    }

    private func match(_ id: String) -> String? {
        guard id != "auto", !id.isEmpty else { return nil }
        let maximal = Locale.Language(identifier: id).maximalIdentifier
        return languages.first { $0.language.maximalIdentifier == maximal }?.id
    }

    func selectSource(_ id: String?) {
        guard active, downloadRequest == nil, id == nil || languages.contains(where: { $0.id == id }), source != id
        else { return }
        source = id
        feedback = nil
        checkSource()
    }

    func refresh() {
        guard active, downloadRequest == nil else { return }
        feedback = nil
        if languages.isEmpty { reloadCatalog() } else { checkSource() }
    }

    private func checkSource(verifying request: AppleTranslationAssetDownloadRequest? = nil) {
        revision &+= 1
        checks.values.forEach { $0.cancel() }
        jobs = []
        jobIndex = 0
        statuses = [:]
        guard active, let source else { return }
        var ordered = languages.map(\.id)
        if let priority = request?.pair.target ?? preferredTarget, let index = ordered.firstIndex(of: priority) {
            ordered.remove(at: index)
            ordered.insert(priority, at: 0)
        }
        statuses = Dictionary(uniqueKeysWithValues: ordered.map { ($0, .checking) })
        jobs = ordered.map { target in
            Job(
                pair: .init(source: source, target: target), revision: revision,
                downloadID: request?.pair.target == target ? request?.id : nil)
        }
        pump()
    }

    func retry(_ target: String) {
        guard active, downloadRequest == nil, let source, languages.contains(where: { $0.id == target }) else { return }
        if statuses[target] == .checking { return }
        statuses[target] = .checking
        jobs.insert(.init(pair: .init(source: source, target: target), revision: revision), at: jobIndex)
        pump()
    }

    private func pump() {
        guard active else { return }
        let backend = backend
        while checks.count < Self.maximumConcurrentChecks, jobIndex < jobs.count {
            let job = jobs[jobIndex], id = UUID()
            jobIndex += 1
            checks[id] = Task { [weak self] in
                let status: AppleTranslationAssetStatus
                do { status = try await backend.status(job.pair) } catch {
                    status = .unavailable(Self.boundedMessage(error.localizedDescription))
                }
                self?.received(status, for: job, id: id, cancelled: Task.isCancelled)
            }
        }
        if jobIndex == jobs.count {
            jobs = []
            jobIndex = 0
        }
    }

    private func received(_ status: AppleTranslationAssetStatus, for job: Job, id: UUID, cancelled: Bool) {
        checks.removeValue(forKey: id)
        defer { pump() }
        guard active, !cancelled, revision == job.revision, source == job.pair.source else { return }
        let status: AppleTranslationAssetStatus = {
            switch status {
            case .checking: return .unavailable("")
            case .unavailable(let message): return .unavailable(Self.boundedMessage(message))
            default: return status
            }
        }()
        statuses[job.pair.target] = status
        guard let downloadID = job.downloadID, downloadRequest?.id == downloadID else { return }
        downloadRequest = nil
        verifyingDownload = false
        let outcome: AppleTranslationAssetFeedback.Outcome
        switch status {
        case .installed: outcome = .installed
        case .supported, .unsupported, .checking: outcome = .notReady
        case .unavailable(let message): outcome = .failed(message)
        }
        feedback = .init(pair: job.pair, outcome: outcome)
    }

    func beginDownload(_ target: String) -> AppleTranslationAssetDownloadRequest? {
        guard active, downloadRequest == nil, let source, statuses[target] == .supported else { return nil }
        let request = AppleTranslationAssetDownloadRequest(id: UUID(), pair: .init(source: source, target: target))
        downloadRequest = request
        verifyingDownload = false
        feedback = nil
        return request
    }

    func owns(_ request: AppleTranslationAssetDownloadRequest) -> Bool {
        active && downloadRequest == request && source == request.pair.source
    }

    func prepared(_ request: AppleTranslationAssetDownloadRequest) {
        guard owns(request), !verifyingDownload else { return }
        verifyingDownload = true
        // prepareTranslation may return while macOS is still downloading.
        // Only a fresh directional .installed result can say Downloaded.
        checkSource(verifying: request)
    }

    func failed(_ request: AppleTranslationAssetDownloadRequest, error: Error) {
        guard owns(request) else { return }
        downloadRequest = nil
        verifyingDownload = false
        let cancelled = (error as? CocoaError)?.code == .userCancelled || error is CancellationError
        feedback = .init(
            pair: request.pair,
            outcome: cancelled ? .cancelled : .failed(Self.boundedMessage(error.localizedDescription)))
    }

    func cancelDownload() {
        guard let request = downloadRequest else { return }
        downloadRequest = nil
        verifyingDownload = false
        feedback = .init(pair: request.pair, outcome: .cancelled)
        checkSource()
    }

    private static func boundedMessage(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(512)))
    }
}
