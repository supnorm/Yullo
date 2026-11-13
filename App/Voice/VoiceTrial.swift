import Foundation

// A trial changes only this recording's output and destination. Recognition,
// fallback, live preview, finish methods and processing policy stay authoritative.
enum VoiceTrial {
    static func canStart(isBusy: Bool, result: String) -> Bool {
        !isBusy && result.isEmpty
    }

    static func preferences(from saved: Preferences) -> Preferences {
        var trial = saved
        trial.voiceTranslateEnabled = false
        trial.voiceOutputMode = "original"
        trial.voicePreviewFirst = true
        return trial
    }
}

// Terminal feedback for a guide-owned recording. Its text belongs to the
// guide's current visit, not an editor, destination, history or recent result.
enum VoiceTrialOutcome: Equatable {
    case recognized(String), failed(String), cancelled
}

@MainActor final class VoiceTrialCompletion {
    let id: UUID
    private var receive: ((VoiceTrialOutcome) -> Void)?
    init(id: UUID = UUID(), receive: @escaping (VoiceTrialOutcome) -> Void) {
        self.id = id
        self.receive = receive
    }
    func complete(_ outcome: VoiceTrialOutcome) {
        let handler = receive
        receive = nil
        handler?(outcome)
    }
}
