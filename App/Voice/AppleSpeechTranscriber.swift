import Foundation
import Speech
import AVFoundation

struct AppleSpeechLocale: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}
struct AppleSpeechAvailability: Equatable, Sendable {
    enum State: Equatable, Sendable { case ready, needsDownload, downloading, unsupportedLocale, unavailableDevice }
    let localeID: String?
    let localeName: String
    let state: State
}
enum AppleSpeechError: Error, LocalizedError, Equatable {
    case unavailable, unsupportedLocale, assetsMissing, downloading, busy, failed
    var errorDescription: String? { L10n.tr(messageKey) }
    var messageKey: String {
        switch self {
        case .unavailable: return "Apple Speech isn’t available on this Mac. Choose a local model."
        case .unsupportedLocale:
            return "Apple Speech doesn’t support this language. Choose another language or a local model."
        case .assetsMissing: return "Download the Apple Speech language in Dictation settings first."
        case .downloading: return "The Apple Speech language is still downloading. Try again when it finishes."
        case .busy: return "The previous Apple Speech request is still stopping. Try again in a moment."
        case .failed: return "Apple Speech couldn’t transcribe this recording. Try again or choose a local model."
        }
    }
}

struct AppleSpeechAssetBackend: Sendable {
    let reserve: @Sendable (Locale) async throws -> Bool
    let release: @Sendable (Locale) async -> Bool
    // This app's reservations and how many macOS allows at once.
    var reserved: @Sendable () async -> [Locale] = { [] }
    var capacity = Int.max
    static let system = Self(
        reserve: { try await AssetInventory.reserve(locale: $0) },
        release: { await AssetInventory.release(reservedLocale: $0) },
        reserved: { await AssetInventory.reservedLocales },
        capacity: AssetInventory.maximumReservedLocales)
}

// Reservations are app-wide, and a false reserve receipt is not a new lease.
// Keep operation-owned reservations until the entire overlapping cohort ends;
// locale variants can share assets without exposing that mapping to the app.
actor AppleSpeechAssetReservations {
    static let shared = AppleSpeechAssetReservations()
    struct Ticket: Hashable, Sendable {
        fileprivate let owner: UUID
        fileprivate let id: UUID
    }
    private struct Drain {
        let id: UUID
        let task: Task<Void, Never>
    }
    private let identity = UUID()
    private let backend: AppleSpeechAssetBackend
    private var users = Set<UUID>()
    private var owned: [Locale] = []
    private var drain: Drain?

    init(backend: AppleSpeechAssetBackend = .system) { self.backend = backend }

    func acquire(locale: Locale) async throws -> Ticket {
        try Task.checkCancellation()
        while let pending = drain {
            await finishDrain(pending)
            try Task.checkCancellation()
        }
        let ticket = Ticket(owner: identity, id: UUID())
        users.insert(ticket.id)
        do {
            // Register before suspension. A cancelled reservation call must
            // settle before its ticket can leave the cohort.
            if try await backend.reserve(locale) { owned.append(locale) }
            try Task.checkCancellation()
            return ticket
        } catch {
            await release(ticket)
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw error
        }
    }
    func release(_ ticket: Ticket) async {
        guard ticket.owner == identity else { return }
        guard users.remove(ticket.id) != nil else {
            if let pending = drain { await finishDrain(pending) }
            return
        }
        guard users.isEmpty, !owned.isEmpty else { return }
        let locales = owned, backend = backend
        owned = []
        let pending = Drain(
            id: UUID(),
            task: Task { for locale in locales { _ = await backend.release(locale) } })
        drain = pending
        await finishDrain(pending)
    }
    // macOS removes a language's assets soon after its last reservation ends, so a
    // language the person downloaded keeps its reservation after the cohort drains.
    func keep(locale: Locale) {
        owned.removeAll { $0.identifier == locale.identifier }
    }
    // At the limit, a new download replaces languages kept by earlier downloads;
    // reservations held by work in progress stay.
    func makeRoom(for locale: Locale) async {
        var reserved = await backend.reserved()
        guard !reserved.contains(where: { $0.identifier == locale.identifier }) else { return }
        for kept in reserved where reserved.count >= backend.capacity {
            guard !owned.contains(where: { $0.identifier == kept.identifier }) else { continue }
            if await backend.release(kept) { reserved.removeAll { $0.identifier == kept.identifier } }
        }
    }
    private func finishDrain(_ pending: Drain) async {
        await pending.task.value
        if drain?.id == pending.id { drain = nil }
    }
}

// SpeechAnalyzer/SpeechTranscriber are on-device APIs. Recognition never calls
// assetInstallationRequest: only the explicit Settings download action may do so.
private final class AppleSpeechRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var timedOut = false
    func markTimedOut() {
        lock.lock()
        timedOut = true
        lock.unlock()
    }
    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }
}

actor AppleSpeechTranscriber {
    private var running = false
    private var downloadingAssets = false
    private let reservations: AppleSpeechAssetReservations
    #if YULLO_TESTING
        private let afterStart: (@Sendable () async -> Void)?
        private let timeoutOverride: Double?
        init(
            afterStart: (@Sendable () async -> Void)? = nil, timeout: Double? = nil,
            reservations: AppleSpeechAssetReservations = .shared
        ) {
            self.afterStart = afterStart
            self.timeoutOverride = timeout
            self.reservations = reservations
        }
    #else
        init(reservations: AppleSpeechAssetReservations = .shared) { self.reservations = reservations }
    #endif

    func supportedLocales() async -> [AppleSpeechLocale] {
        guard SpeechTranscriber.isAvailable else { return [] }
        return await SpeechTranscriber.supportedLocales.map { locale in
            AppleSpeechLocale(
                id: locale.identifier,
                name: L10n.locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func inspect(localeID: String) async -> AppleSpeechAvailability {
        guard SpeechTranscriber.isAvailable else {
            return .init(localeID: nil, localeName: localeID, state: .unavailableDevice)
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else {
            return .init(localeID: nil, localeName: localeID, state: .unsupportedLocale)
        }
        let module = Self.module(locale)
        let status = await AssetInventory.status(forModules: [module])
        let installed = await SpeechTranscriber.installedLocales
        let hasInstalledLocale = installed.contains {
            Self.localeKey($0.identifier) == Self.localeKey(locale.identifier)
        }
        let state: AppleSpeechAvailability.State
        switch status {
        case .installed: state = .ready
        case .downloading: state = .downloading
        // Installed assets may report "supported" before the application has
        // reserved the locale. Reserving existing assets does not download them.
        case .supported: state = hasInstalledLocale ? .ready : .needsDownload
        case .unsupported: state = .unsupportedLocale
        @unknown default: state = .unavailableDevice
        }
        return .init(
            localeID: locale.identifier,
            localeName: L10n.locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier, state: state
        )
    }
    // Recording preflight checks metadata only: merely selecting a language or
    // cancelling before ASR must not accumulate OS asset reservations.
    func requireAvailable(localeID: String) async throws -> String {
        try await availableLocale(localeID: localeID).identifier
    }
    private func availableLocale(localeID: String) async throws -> Locale {
        try Task.checkCancellation()
        let value = await inspect(localeID: localeID)
        try Task.checkCancellation()
        switch value.state {
        case .ready:
            guard let resolved = value.localeID,
                let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: resolved))
            else {
                throw AppleSpeechError.unsupportedLocale
            }
            try Task.checkCancellation()
            return locale
        case .needsDownload: throw AppleSpeechError.assetsMissing
        case .downloading: throw AppleSpeechError.downloading
        case .unsupportedLocale: throw AppleSpeechError.unsupportedLocale
        case .unavailableDevice: throw AppleSpeechError.unavailable
        }
    }
    func downloadAssets(localeID: String) async throws {
        try Task.checkCancellation()
        guard !downloadingAssets else { throw AppleSpeechError.downloading }
        downloadingAssets = true
        defer { downloadingAssets = false }
        guard SpeechTranscriber.isAvailable else { throw AppleSpeechError.unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else {
            throw AppleSpeechError.unsupportedLocale
        }
        // A language that was already installed goes back as it was; a new one stays.
        let wasReady = await inspect(localeID: locale.identifier).state == .ready
        if !wasReady { await reservations.makeRoom(for: locale) }
        let ticket = try await reservations.acquire(locale: locale)
        do {
            try Task.checkCancellation()
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [Self.module(locale)]) {
                try await request.downloadAndInstall()
            }
            _ = try await availableLocale(localeID: locale.identifier)
            if !wasReady { await reservations.keep(locale: locale) }
        } catch {
            await reservations.release(ticket)
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw error
        }
        await reservations.release(ticket)
        try Task.checkCancellation()
    }
    func transcribe(audioURL: URL, localeID: String) async throws -> LocalTranscriptionResult {
        try Task.checkCancellation()
        guard !running else { throw AppleSpeechError.busy }
        running = true
        defer { running = false }
        let duration = try LocalTranscriber.validateAudio(audioURL)
        let locale = try await availableLocale(localeID: localeID)
        let ticket = try await reservations.acquire(locale: locale)
        let text: String
        do {
            try Task.checkCancellation()
            text = try await analyze(audioURL: audioURL, locale: locale, duration: duration)
        } catch {
            await reservations.release(ticket)
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let error = error as? LocalTranscriptionError { throw error }
            if let error = error as? AppleSpeechError { throw error }
            throw AppleSpeechError.failed
        }
        await reservations.release(ticket)
        try Task.checkCancellation()
        return LocalTranscriptionResult(text: text, detectedLanguage: locale.language.languageCode?.identifier)
    }
    private func analyze(audioURL: URL, locale: Locale, duration: Double) async throws -> String {
        try await analyze(audioURL: audioURL, module: Self.module(locale), duration: duration)
    }
    private func analyze(audioURL: URL, module: SpeechTranscriber, duration: Double) async throws -> String {
        let analyzer = SpeechAnalyzer(modules: [module]), state = AppleSpeechRunState()
        let collector = Task { () throws -> String in
            var text = ""
            for try await result in module.results {
                try Task.checkCancellation()
                guard result.isFinal else { continue }
                text += String(result.text.characters)
                guard text.utf8.count <= 262_144 else { throw LocalTranscriptionError.invalidOutput }
            }
            return text
        }
        #if YULLO_TESTING
            let timeout = timeoutOverride ?? Self.processingTimeout(duration: duration)
        #else
            let timeout = Self.processingTimeout(duration: duration)
        #endif
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            state.markTimedOut()
            collector.cancel()
            await analyzer.cancelAndFinishNow()
        }
        do {
            let text = try await withTaskCancellationHandler(
                operation: {
                    let file = try AVAudioFile(forReading: audioURL)
                    try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
                    #if YULLO_TESTING
                        await afterStart?()
                    #endif
                    try Task.checkCancellation()
                    let text = try await collector.value
                    try Task.checkCancellation()
                    guard !state.didTimeOut else { throw AppleSpeechError.failed }
                    return text
                },
                onCancel: {
                    collector.cancel()
                    Task { await analyzer.cancelAndFinishNow() }
                })
            watchdog.cancel()
            await watchdog.value
            await analyzer.cancelAndFinishNow()
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw LocalTranscriptionError.noSpeech
            }
            return text
        } catch {
            watchdog.cancel()
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            _ = try? await collector.value
            await watchdog.value
            if Task.isCancelled { throw CancellationError() }
            if state.didTimeOut { throw AppleSpeechError.failed }
            if error is CancellationError { throw CancellationError() }
            throw error
        }
    }
    nonisolated static func processingTimeout(duration: Double) -> Double { max(45, min(600, duration * 3 + 45)) }
    private nonisolated static func module(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    }
    private nonisolated static func localeKey(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}
