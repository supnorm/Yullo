import AppKit
import Foundation

enum OllamaIssue: Error, LocalizedError, Equatable, Sendable {
    case notInstalled, notRunning, noModel, modelMissing(String), outOfMemory, timedOut, failed
    var errorDescription: String? {
        switch self {
        case .notInstalled: return L10n.tr("Ollama isn’t installed.")
        case .notRunning: return L10n.tr("Ollama isn’t running.")
        case .noModel: return L10n.tr("Choose a model in Ollama.")
        case .modelMissing(let name): return L10n.format("%@ isn’t in Ollama anymore.", name)
        case .outOfMemory: return L10n.tr("Ollama ran out of memory. Try a smaller model.")
        case .timedOut: return L10n.tr("Ollama took too long to respond.")
        case .failed: return L10n.tr("Ollama couldn’t finish this request.")
        }
    }
}

// Talks to Ollama on this Mac (or the address the person set). Probes are short
// and run only when a screen or a request needs them, never in the background.
actor OllamaClient {
    static let shared = OllamaClient()
    static let bundleID = "com.electron.ollama"

    enum Status: Equatable, Sendable {
        case notInstalled, notRunning, running([CoreOllama.Model])
    }

    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    nonisolated static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    func status(host: String) async -> Status {
        do { return .running(try await models(host: host)) } catch {
            return Self.isInstalled ? .notRunning : .notInstalled
        }
    }

    func models(host: String) async throws -> [CoreOllama.Model] {
        let (data, _) = try await send(host: host, path: "/api/tags", body: nil, timeout: 1.5)
        return try CoreOllama.models(fromTags: data)
    }

    // Progress reports a fraction while layers download; the model is ready when this returns.
    func pull(model: String, host: String, progress: @escaping @Sendable (Double?) -> Void) async throws {
        var request = try Self.request(host: host, path: "/api/pull", body: CoreOllama.pullBody(model: model))
        request.timeoutInterval = 60 * 60
        let (bytes, response) = try await session.bytes(for: request)
        try Self.check(response)
        for try await line in bytes.lines {
            try Task.checkCancellation()
            let value = try CoreOllama.pullProgress(fromLine: Data(line.utf8))
            progress(value.fraction)
            if value.done { return }
        }
        throw OllamaIssue.failed
    }

    // The selected model and address only; no other setting reaches Ollama.
    struct Target: Sendable {
        let host: String
        let model: String
    }

    func write(
        text: String, style: RewriteStyle, requirements: CoreWritingRequirements, instructions: String?, target: Target
    ) async throws -> String {
        let instruction = CoreWritingPrompt.instruction(
            style: style, requirements: requirements, instructions: instructions)
        return try await chat(instruction: instruction, text: text, target: target)
    }

    // Edit with voice: the same two messages as an API connection, the
    // spoken instruction and the selection, and nothing else.
    func voiceEdit(
        source: String, instruction: String, terms: [CoreVocabularyTranslationTerm], target: Target
    ) async throws -> String {
        try CoreVoiceEditPrompt.validateInputs(source: source, instruction: instruction)
        let language = Language.detected(in: source)
        let data = try CoreVoiceEditPrompt.userData(
            source: source, instruction: instruction, terms: terms,
            change: CoreVoiceEditPrompt.localLead(
                instruction, language: language?.name, languageID: language?.id))
        return try await chat(
            instruction: CoreVoiceEditPrompt.instruction,
            text: String(decoding: data, as: UTF8.self), target: target)
    }

    func translate(text: String, from: String, to: String, instructions: String?, target: Target) async throws -> String
    {
        let aliases = [from.lowercased(): from, to.lowercased(): to]
        let instruction = try CoreTranslationPrompt.instruction(
            source: from, target: to, languageAliases: aliases, instructions: instructions)
        return try await chat(instruction: instruction, text: text, target: target)
    }

    // Loads the model while the person is still speaking; no text is sent.
    func warmUp(host: String, model: String) async {
        guard !model.isEmpty, let body = try? CoreOllama.warmUpBody(model: model) else { return }
        _ = try? await send(host: host, path: "/api/generate", body: body, timeout: 120)
    }

    private func chat(instruction: String, text: String, target: Target) async throws -> String {
        guard !target.model.isEmpty else { throw OllamaIssue.noModel }
        let body = try CoreOllama.chatBody(model: target.model, instruction: instruction, text: text)
        // A cold model can take a while to load before the first word.
        let (data, _) = try await send(
            host: target.host, path: "/api/chat", body: body, timeout: CoreOllama.answerSeconds(for: text),
            model: target.model)
        do {
            let output = try CoreOllama.chatText(from: data)
            guard !output.isEmpty else { throw OllamaIssue.failed }
            return output
        } catch CoreOllama.Issue.failed(let message) {
            throw Self.issue(message, model: target.model)
        }
    }

    // The model names a missing model in an HTTP error reply.
    private func send(host: String, path: String, body: Data?, timeout: TimeInterval, model: String = "") async throws
        -> (Data, URLResponse)
    {
        var request = try Self.request(host: host, path: path, body: body)
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400,
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            {
                throw Self.issue(message, model: model)
            }
            try Self.check(response)
            return (data, response)
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw OllamaIssue.timedOut
            case .cancelled: throw CancellationError()
            default: throw Self.isInstalled ? OllamaIssue.notRunning : OllamaIssue.notInstalled
            }
        }
    }

    private static func request(host: String, path: String, body: Data?) throws -> URLRequest {
        guard let base = URL(string: host.isEmpty ? CoreOllama.defaultHost : host),
            base.scheme?.hasPrefix("http") == true,
            let url = URL(string: path, relativeTo: base)
        else { throw OllamaIssue.notRunning }
        var request = URLRequest(url: url)
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OllamaIssue.failed
        }
    }

    private static func issue(_ message: String, model: String) -> OllamaIssue {
        let lowered = message.lowercased()
        if lowered.contains("not found") { return .modelMissing(model) }
        if lowered.contains("memory") { return .outOfMemory }
        return .failed
    }
}
