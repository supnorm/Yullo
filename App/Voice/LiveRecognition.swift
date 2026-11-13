import Foundation

// Live text is provisional. A recovery snapshot can be explicitly copied as
// a draft after terminal recognition failure. Only finish returns a result
// eligible for the normal transformation and delivery pipeline.
protocol VoiceLiveRecognizing: Sendable {
    /// Nonblocking admission of already sanitized 16 kHz mono PCM.
    /// False stops optional preview; it must never stop the recording writer.
    func accept(_ samples: [Float]) -> Bool
    func finish(audioURL: URL) async throws -> LocalTranscriptionResult
    func cancel() async
    func recoverySnapshot() async -> VoiceRecognitionRecoverySnapshot?
}
extension VoiceLiveRecognizing {
    func recoverySnapshot() async -> VoiceRecognitionRecoverySnapshot? { nil }
}

// Close admission on the producer thread before notifying the UI. A busy
// MainActor must not turn successive audio buffers into unbounded failure tasks.
final class LiveAudioForwarder: @unchecked Sendable {
    private let lock = NSLock()
    private var recognizer: (any VoiceLiveRecognizing)?
    private let onOverload: @Sendable () -> Void
    init(_ recognizer: any VoiceLiveRecognizing, onOverload: @escaping @Sendable () -> Void) {
        self.recognizer = recognizer
        self.onOverload = onOverload
    }
    func accept(_ samples: [Float]) {
        let failed = lock.withLock {
            guard let recognizer else { return false }
            guard !recognizer.accept(samples) else { return false }
            self.recognizer = nil
            return true
        }
        if failed { onOverload() }
    }
}

enum LiveRecognitionIssue: Error, LocalizedError, Equatable, Sendable {
    case unsupported, unavailable, overloaded, invalidOutput, failed
    var errorDescription: String? {
        switch self {
        case .unsupported: return L10n.tr("This recognition model doesn’t support live preview.")
        case .unavailable: return L10n.tr("Live preview is unavailable. Recording will finish normally.")
        case .overloaded: return L10n.tr("Live preview paused to keep recording smoothly.")
        case .invalidOutput, .failed: return L10n.tr("Live preview stopped. Recording will finish normally.")
        }
    }
}

enum LiveRecognitionSupport {
    enum Mode: Equatable { case apple, nativeStream, recentWindow }
    static func mode(modelID: String, architecture: String? = nil) -> Mode? {
        if modelID == VoiceRecognitionSettings.appleModelID { return .apple }
        if modelID == "nemotron-35-q4" { return .nativeStream }
        if [
            "qwen3-asr-06b-q4", "qwen3-asr-17b-q8", "parakeet-v3-q4", "parakeet-ultra-q4", "sensevoice-small-q8",
            "cohere-transcribe-q4"
        ].contains(modelID)
            || ["qwen3_asr", "parakeet", "sensevoice", "cohere_asr"].contains(architecture ?? "")
        {
            return .recentWindow
        }
        return nil
    }
}
