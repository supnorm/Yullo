import Foundation

struct VoiceRecognitionSettings: Equatable, Sendable {
    static let appleModelID = "apple-speech"
    static let cohereLanguageIDs = ["en", "fr", "de", "es", "pt", "it", "nl", "pl", "el", "ar", "ja", "ko", "zh", "vi"]
    static func requiresLanguageHint(modelID: String, architecture: String? = nil) -> Bool {
        modelID == "cohere-transcribe-q4" || architecture == "cohere_asr"
    }
    let modelID: String
    let useAppleFallback: Bool
    let appleLocale: String
    let languageHint: String?
    let personalVocabulary: CoreVocabularyConfiguration
    init(
        modelID: String, useAppleFallback: Bool, appleLocale: String, languageHint: String? = nil,
        personalVocabulary: CoreVocabularyConfiguration = .init()
    ) {
        self.modelID = modelID.isEmpty ? ModelLibrary.defaultModelID : modelID
        self.useAppleFallback = useAppleFallback
        self.appleLocale = appleLocale
        self.languageHint = languageHint == "auto" || languageHint == "" ? nil : languageHint
        self.personalVocabulary = personalVocabulary
    }
    init(_ preferences: Preferences, systemLocale: String = Locale.current.identifier) {
        self.init(
            modelID: preferences.voiceModelID, useAppleFallback: preferences.voiceAppleFallback,
            appleLocale: preferences.voiceAppleLocale == "system" ? systemLocale : preferences.voiceAppleLocale,
            languageHint: preferences.voiceRecognitionLanguage, personalVocabulary: preferences.personalVocabulary)
    }
    var isApplePrimary: Bool { modelID == Self.appleModelID }
}

struct VoiceRecognitionBackend: Sendable {
    var localInstalled: @Sendable (String) async throws -> Bool
    var localTranscribe: @Sendable (URL, String, String?) async throws -> LocalTranscriptionResult
    var appleReady: @Sendable (String) async throws -> Void
    var apple: @Sendable (URL, String) async throws -> LocalTranscriptionResult
    var localRequiresLanguage: @Sendable (String) async throws -> Bool = {
        VoiceRecognitionSettings.requiresLanguageHint(modelID: $0)
    }
    var localTranscribeWithHints: (@Sendable (URL, String, String?, String) async throws -> LocalTranscriptionResult)? =
        nil
    var localWarm: @Sendable (String) async -> Void = { _ in }
    // Model, language hint and recognition hints; nil when the runtime cannot start early.
    var localReserve: @Sendable (String, String?, String) async -> (any VoiceRecognitionReserving)? = { _, _, _ in
        nil
    }
    // A recognizer that stays loaded between recordings; tried before `localReserve`.
    var sharedReserve: @Sendable (String, String?, String) async -> (any VoiceRecognitionReserving)? = { _, _, _ in
        nil
    }
}

// A recognizer started while recording. `finish` recognizes the complete WAV once;
// `cancel` stops it. Either ends the reservation.
protocol VoiceRecognitionReserving: AnyObject, Sendable {
    func finish(audioURL: URL) async throws -> LocalTranscriptionResult
    func cancel() async
}
extension LocalRecognitionReservation: VoiceRecognitionReserving {}

// Validates a reserved result like `transcribe`. A failed early helper falls
// back to the ordinary route (a fresh local helper, then permitted Apple fallback).
private final class VoiceRecognitionReservation: VoiceRecognitionReserving {
    private let reserved: any VoiceRecognitionReserving
    private let service: VoiceRecognitionService
    private let settings: VoiceRecognitionSettings
    init(
        _ reserved: any VoiceRecognitionReserving, service: VoiceRecognitionService, settings: VoiceRecognitionSettings
    ) {
        self.reserved = reserved
        self.service = service
        self.settings = settings
    }
    func finish(audioURL: URL) async throws -> LocalTranscriptionResult {
        do {
            let result = try await reserved.finish(audioURL: audioURL)
            try Task.checkCancellation()
            return try VoiceRecognitionService.validated(result)
        } catch {
            try Task.checkCancellation()
            guard VoiceRecognitionService.allowsFallback(after: error) else { throw error }
            return try await service.transcribe(audioURL: audioURL, settings: settings)
        }
    }
    func cancel() async { await reserved.cancel() }
}

actor VoiceRecognitionService {
    private let backend: VoiceRecognitionBackend
    init(backend: VoiceRecognitionBackend) { self.backend = backend }
    init(
        library: ModelLibrary, local: LocalTranscriber, apple: AppleSpeechTranscriber,
        sharedReserve: @escaping @Sendable (String, String?, String) async -> (any VoiceRecognitionReserving)? = {
            _, _, _ in nil
        }
    ) {
        backend = VoiceRecognitionBackend(
            localInstalled: { id in
                try await library.installedModels(matchingID: id).contains { $0.id == id && $0.task == .dictation }
            },
            localTranscribe: { try await local.transcribe(audioURL: $0, modelID: $1, languageHint: $2) },
            appleReady: { _ = try await apple.requireAvailable(localeID: $0) },
            apple: { try await apple.transcribe(audioURL: $0, localeID: $1) },
            localRequiresLanguage: { id in
                if VoiceRecognitionSettings.requiresLanguageHint(modelID: id) { return true }
                return try await library.installedModels(matchingID: id).contains {
                    $0.id == id
                        && VoiceRecognitionSettings.requiresLanguageHint(modelID: id, architecture: $0.architecture)
                }
            },
            localTranscribeWithHints: { audio, model, language, hints in
                try await local.transcribe(
                    audioURL: audio, modelID: model, languageHint: language, vocabularyHints: hints)
            }, localWarm: { await local.warmModel(id: $0) },
            localReserve: {
                await local.reserve(modelID: $0, languageHint: $1, vocabularyHints: $2)
            }, sharedReserve: sharedReserve)
    }
    func prepare(_ settings: VoiceRecognitionSettings) async throws {
        try Task.checkCancellation()
        if settings.isApplePrimary {
            try await backend.appleReady(settings.appleLocale)
            try Task.checkCancellation()
            return
        }
        do {
            if try await backend.localInstalled(settings.modelID) {
                _ = try await languageHint(settings)
                try Task.checkCancellation()
                return
            }
        } catch {
            try Task.checkCancellation()
            guard settings.useAppleFallback, Self.allowsFallback(after: error) else { throw error }
        }
        guard settings.useAppleFallback else { throw ModelLibraryError.unavailable }
        try Task.checkCancellation()
        try await backend.appleReady(settings.appleLocale)
        try Task.checkCancellation()
    }
    // Best effort while recording: errors stay with transcribe's existing route.
    func warm(_ settings: VoiceRecognitionSettings) async {
        guard !settings.isApplePrimary, !Task.isCancelled else { return }
        await backend.localWarm(settings.modelID)
    }
    // Starts the local recognizer during recording when its runtime can wait for
    // the finished audio. Uses the same model, language and hints as `transcribe`.
    func reserve(_ settings: VoiceRecognitionSettings) async -> (any VoiceRecognitionReserving)? {
        guard !settings.isApplePrimary, !Task.isCancelled,
            let hints = try? CoreVocabularyProcessor.shared.snapshot(for: settings.personalVocabulary)
                .recognitionHintText,
            (try? await backend.localInstalled(settings.modelID)) == true
        else { return nil }
        // A nil hint means automatic language; an error leaves it to `transcribe`.
        let hint: String?
        do { hint = try await languageHint(settings) } catch { return nil }
        if let reserved = await backend.sharedReserve(settings.modelID, hint, hints) {
            return VoiceRecognitionReservation(reserved, service: self, settings: settings)
        }
        guard let reserved = await backend.localReserve(settings.modelID, hint, hints) else { return nil }
        return VoiceRecognitionReservation(reserved, service: self, settings: settings)
    }
    func transcribe(audioURL: URL, settings: VoiceRecognitionSettings) async throws -> LocalTranscriptionResult {
        try Task.checkCancellation()
        let hints = try CoreVocabularyProcessor.shared.snapshot(for: settings.personalVocabulary).recognitionHintText
        try Task.checkCancellation()
        if settings.isApplePrimary {
            let result = try await backend.apple(audioURL, settings.appleLocale)
            try Task.checkCancellation()
            return try Self.validated(result, hintsUnavailable: !hints.isEmpty)
        }
        do {
            let hint = try await languageHint(settings)
            let result: LocalTranscriptionResult
            if !hints.isEmpty, let transcribe = backend.localTranscribeWithHints {
                result = try await transcribe(audioURL, settings.modelID, hint, hints)
            } else {
                result = try await backend.localTranscribe(audioURL, settings.modelID, hint)
            }
            try Task.checkCancellation()
            return try Self.validated(
                result, hintsUnavailable: !hints.isEmpty && backend.localTranscribeWithHints == nil)
        } catch {
            try Task.checkCancellation()
            guard settings.useAppleFallback, Self.allowsFallback(after: error) else { throw error }
            let result = try await backend.apple(audioURL, settings.appleLocale)
            try Task.checkCancellation()
            return try Self.validated(result, hintsUnavailable: !hints.isEmpty)
        }
    }
    static func allowsFallback(after error: Error) -> Bool {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return false }
        if let error = error as? LocalTranscriptionError {
            switch error {
            case .failed, .runtimeMissing: return true
            case .noSpeech, .invalidAudio, .invalidOutput, .busy, .languageRequired, .tooLong, .senseVoiceTooLong:
                return false
            }
        }
        if let error = error as? ModelLibraryError {
            switch error {
            case .unavailable, .unknownModel, .invalidFormat, .invalidSize, .invalidHash, .taskMismatch: return true
            case .busy, .inUse, .downloadFailed, .storageFull, .storageUnavailable: return false
            }
        }
        return false
    }
    private func languageHint(_ settings: VoiceRecognitionSettings) async throws -> String? {
        guard try await backend.localRequiresLanguage(settings.modelID) else { return nil }
        guard let hint = settings.languageHint, VoiceRecognitionSettings.cohereLanguageIDs.contains(hint) else {
            throw LocalTranscriptionError.languageRequired
        }
        return hint
    }
    static func validated(
        _ result: LocalTranscriptionResult, hintsUnavailable: Bool = false
    ) throws -> LocalTranscriptionResult {
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalTranscriptionError.noSpeech
        }
        guard result.text.utf8.count <= 262_144 else { throw LocalTranscriptionError.invalidOutput }
        return LocalTranscriptionResult(
            text: result.text, detectedLanguage: result.detectedLanguage,
            vocabularyHintsUnavailable: result.vocabularyHintsUnavailable || hintsUnavailable)
    }
}
