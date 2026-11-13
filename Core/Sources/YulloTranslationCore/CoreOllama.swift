import Foundation

// Ollama's local API, as plain data: requests Yullo sends and replies it reads.
// Only the current task's text and fixed instructions are sent; no key exists.
public enum CoreOllama {
    public static let defaultHost = "http://127.0.0.1:11434"
    public static let keepAlive = "10m"

    public struct Model: Equatable, Sendable {
        public let name: String
        public let sizeBytes: Int64
        public let parameterSize: String?
        // A model Ollama runs on another computer, not this Mac.
        public let online: Bool
    }

    public struct PullProgress: Equatable, Sendable {
        public let status: String
        public let completed: Int64?
        public let total: Int64?
        public let done: Bool
        public var fraction: Double? {
            guard let completed, let total, total > 0 else { return nil }
            return min(1, Double(completed) / Double(total))
        }
    }

    public enum Issue: Error, Equatable, Sendable { case malformed, failed(String) }

    // Writing and translation models only; embedding models can't write.
    public static func models(fromTags data: Data) throws -> [Model] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let list = object["models"] as? [[String: Any]]
        else { throw Issue.malformed }
        return list.compactMap { entry -> Model? in
            guard let name = (entry["name"] as? String) ?? (entry["model"] as? String), !name.isEmpty else {
                return nil
            }
            let details = entry["details"] as? [String: Any] ?? [:]
            let families = (details["families"] as? [String] ?? []) + [details["family"] as? String].compactMap { $0 }
            let lowered = name.lowercased()
            if lowered.contains("embed") || families.contains(where: { $0.lowercased().contains("bert") }) {
                return nil
            }
            let online = entry["remote_host"] != nil || lowered.hasSuffix("-cloud") || lowered.hasSuffix(":cloud")
            let size = (entry["size"] as? NSNumber)?.int64Value ?? 0
            return Model(
                name: name, sizeBytes: size, parameterSize: details["parameter_size"] as? String, online: online)
        }
    }

    public static func pullProgress(fromLine data: Data) throws -> PullProgress {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Issue.malformed
        }
        if let error = object["error"] as? String { throw Issue.failed(error) }
        let status = object["status"] as? String ?? ""
        return PullProgress(
            status: status, completed: (object["completed"] as? NSNumber)?.int64Value,
            total: (object["total"] as? NSNumber)?.int64Value, done: status == "success")
    }

    // One non-streaming chat turn: fixed system instruction, the text as the user message.
    public static func chatBody(model: String, instruction: String, text: String) throws -> Data {
        var options: [String: Any] = ["temperature": 0.2]
        if let context = contextTokens(instruction: instruction, text: text) { options["num_ctx"] = context }
        return try JSONSerialization.data(
            withJSONObject: [
                "model": model, "stream": false, "think": false, "keep_alive": keepAlive,
                "options": options,
                "messages": [["role": "system", "content": instruction], ["role": "user", "content": text]]
            ] as [String: Any])
    }

    // Ollama's own window can be as small as 2,048 tokens, and it silently
    // drops the start of a longer prompt. A longer request asks for a window
    // that holds the instruction, the text and an answer as long as the text;
    // a short one keeps the loaded model's window, so no reload is needed.
    public static func contextTokens(instruction: String, text: String) -> Int? {
        let needed =
            CoreAppleWriterPlan.estimatedTokens(instruction) + 2 * CoreAppleWriterPlan.estimatedTokens(text) + 512
        guard needed > 2_048 else { return nil }
        return max(4_096, (needed + 1_023) / 1_024 * 1_024)
    }

    // The whole answer arrives at once: time to load a cold model, then to
    // write an answer as long as the text at a slow local pace.
    public static func answerSeconds(for text: String) -> Double {
        max(180, 60 + Double(CoreAppleWriterPlan.estimatedTokens(text)) / 5)
    }

    // An empty generate request loads the model while the person is still speaking.
    public static func warmUpBody(model: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": keepAlive])
    }

    public static func pullBody(model: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model": model, "stream": true] as [String: Any])
    }

    public static func chatText(from data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Issue.malformed
        }
        if let error = object["error"] as? String { throw Issue.failed(error) }
        guard let message = object["message"] as? [String: Any], let content = message["content"] as? String else {
            throw Issue.malformed
        }
        return withoutThinking(content).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Some models still emit their reasoning; it never reaches the text.
    static func withoutThinking(_ text: String) -> String {
        text.replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression)
    }

    // Loopback only counts as this Mac; anything else is an online service. An
    // empty address means the default one, as it does for every request.
    public static func isOnThisMac(host: String) -> Bool {
        guard let url = URL(string: host.isEmpty ? defaultHost : host), let name = url.host?.lowercased() else {
            return false
        }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(name)
    }
}
