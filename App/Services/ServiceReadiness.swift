import CryptoKit
import Foundation

// Task pages offer a connected service only after it has worked with its
// current settings: a passed test, a loaded voice list or a completed request.
// The record keeps a hash of non-secret settings per service, never a key or
// any text. Changing those settings, or saving a new key, removes it.
enum ConnectedService: String, CaseIterable, Sendable {
    case api = "api"
    case cli = "cli"
    case azureSpeech = "speech.azure"
    case googleSpeech = "speech.google"
    case elevenLabsSpeech = "speech.elevenlabs"
    case speechAPI = "speech.api"

    static func speech(_ provider: SpeechProvider) -> ConnectedService? {
        switch provider {
        case .azure: return .azureSpeech
        case .google: return .googleSpeech
        case .elevenlabs: return .elevenLabsSpeech
        case .speechAPI: return .speechAPI
        case .macOS, .local: return nil
        }
    }
    // Translation and writing share one API connection and one CLI setup.
    static func text(_ engine: String) -> ConnectedService? {
        engine == "api" ? .api : engine == "cli" ? .cli : nil
    }

    func fingerprint(_ preferences: Preferences) -> String {
        let parts: [String]
        switch self {
        case .api: parts = [preferences.endpoint, preferences.model]
        case .cli: parts = [preferences.cli.provider.rawValue, preferences.cli.executablePath, preferences.cli.model]
        case .azureSpeech: parts = [preferences.azureRegion]
        case .googleSpeech: parts = [preferences.googleSpeech.endpoint]
        case .elevenLabsSpeech: parts = [preferences.elevenLabsSpeech.endpoint, preferences.elevenLabsSpeech.model]
        case .speechAPI: parts = [preferences.speechAPI.endpoint, preferences.speechAPI.model]
        }
        let digest = SHA256.hash(data: Data(([rawValue] + parts).joined(separator: "\u{1F}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension Preferences {
    func isWorking(_ service: ConnectedService) -> Bool {
        workingServices[service.rawValue] == service.fingerprint(self)
    }
    mutating func recordWorking(_ service: ConnectedService) {
        workingServices[service.rawValue] = service.fingerprint(self)
    }
    mutating func forgetWorking(_ service: ConnectedService) {
        workingServices.removeValue(forKey: service.rawValue)
    }
    // A request's endpoint and model, as the API client reports them, against the saved ones.
    func isAPIConnection(endpoint: URL, model: String) -> Bool {
        (try? ChatCompletionsProtocol.endpoint(self.endpoint).absoluteString) == endpoint.absoluteString
            && self.model.trimmingCharacters(in: .whitespacesAndNewlines)
                == model.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// Which choices a task's service picker lists. The current choice always stays,
// so a picker never hides what is selected.
enum ServiceChoices {
    // Configured services are offered, not only ones that have worked: the row under
    // each engine menu says why one cannot run yet and offers its fix.
    static func configured(_ engine: String, _ preferences: Preferences) -> Bool {
        switch engine {
        // The saved fields only; whether the address and key work is the status line's job.
        case "api":
            return !preferences.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !preferences.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // The suggested path is filled in for everyone, so a command-line app counts once it has
        // worked, has a model, or points somewhere the person chose.
        case "cli":
            let cli = preferences.cli
            return preferences.isWorking(.cli) || !cli.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || cli.executablePath != cli.provider.suggestedExecutablePath
        default: return false
        }
    }
    static func translation(_ preferences: Preferences, hasLocalModel: Bool) -> [String] {
        let ready =
            ["apple"] + (hasLocalModel ? ["local"] : [])
            + ["api", "cli"].filter { configured($0, preferences) }
        let ollama = preferences.ollamaModel.isEmpty ? [] : ["ollama"]
        return including(preferences.engine, in: ready + ollama, order: ["apple", "local", "ollama", "api", "cli"])
    }
    static func writing(_ preferences: Preferences) -> [String] {
        // Apple · on device is always listed; when it can't run, Write with says why.
        let ready = ["apple"] + ["api", "cli"].filter { configured($0, preferences) }
        let ollama = preferences.ollamaModel.isEmpty ? [] : ["ollama"]
        return including(
            preferences.voiceRefinementEngine, in: ready + ollama, order: ["apple", "ollama", "api", "cli"])
    }
    static func speech(_ preferences: Preferences, hasLocalModel: Bool) -> [SpeechProvider] {
        SpeechProvider.allCases.filter { provider in
            if provider.rawValue == preferences.speechEngine { return true }
            switch provider {
            case .macOS: return true
            case .local: return hasLocalModel
            default: return ConnectedService.speech(provider).map(preferences.isWorking) ?? false
            }
        }
    }
    // Whether the picker leaves something out, so "Set up another service…" helps.
    static func omitsSpeech(_ shown: [SpeechProvider]) -> Bool { shown.count < SpeechProvider.allCases.count }
    private static func including(_ current: String, in ready: [String], order: [String]) -> [String] {
        order.filter { ready.contains($0) || $0 == current }
    }
}
