import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// This is a wire-format boundary, not a networking session. The app owns
// credential lookup/storage, transport, retry policy, cancellation, caching and diagnostics.
public enum ChatCompletionsProtocol {
    public static func endpoint(_ input: String) throws -> URL {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: value), let host = components.host, !host.isEmpty,
            components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
            components.scheme == "https"
                || (components.scheme == "http"
                    && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host.lowercased()))
        else { throw CoreTranslationError.invalidEndpoint }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/chat/completions") { path += "/chat/completions" }
        components.path = path
        guard let url = components.url else { throw CoreTranslationError.invalidEndpoint }
        return url
    }

    public static func request(
        endpoint: String, model: String, key: String, text: String,
        source: String, target: String, languageAliases: [String: String], instructions: String? = nil
    ) throws -> URLRequest {
        try request(endpoint: endpoint, model: model, key: key, text: text) {
            try CoreTranslationPrompt.instruction(
                source: source, target: target, languageAliases: languageAliases, instructions: instructions)
        }
    }

    public static func refinementRequest(
        endpoint: String, model: String, key: String, text: String,
        style: RewriteStyle, requirements: CoreWritingRequirements = .standard, instructions: String? = nil
    ) throws -> URLRequest {
        try request(endpoint: endpoint, model: model, key: key, text: text) {
            CoreWritingPrompt.instruction(style: style, requirements: requirements, instructions: instructions)
        }
    }

    // The description is the only user message; the fixed instruction owns the
    // reply format, and the app validates every field before showing it.
    public static func presetDescriptionRequest(
        endpoint: String, model: String, key: String, description: String, languageIDs: [String]
    ) throws -> URLRequest {
        try request(endpoint: endpoint, model: model, key: key, text: description) {
            CorePresetDescription.serviceInstruction(languageIDs: languageIDs)
        }
    }

    private static func request(
        endpoint: String, model: String, key: String, text: String,
        instruction: () throws -> String
    ) throws -> URLRequest {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CoreTranslationError.missingModel
        }
        var request = URLRequest(url: try Self.endpoint(endpoint))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let instruction = try instruction()
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "model": model, "stream": false,
                "messages": [["role": "system", "content": instruction], ["role": "user", "content": text]]
            ], options: .sortedKeys)
        return request
    }

    public static func parseResponse(data: Data, statusCode: Int) throws -> String {
        guard (200..<300).contains(statusCode) else { throw CoreTranslationError.http(statusCode) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]], let choice = choices.first
        else { throw CoreTranslationError.invalidResponse }
        // Partial or tool-directed output is not a completed text result, even
        // when the provider also includes plausible content. Never cache it.
        switch choice["finish_reason"] as? String {
        case "length": throw CoreTranslationError.truncated
        case "content_filter": throw CoreTranslationError.refused
        case "tool_calls", "function_call": throw CoreTranslationError.invalidResponse
        default: break  // Retain compatibility with providers omitting this field.
        }
        guard let message = choice["message"] as? [String: Any] else { throw CoreTranslationError.invalidResponse }
        // Compatible providers may omit the role, but an explicit role must
        // identify the completed assistant result rather than source/tool data.
        if let role = message["role"] {
            guard let role = role as? String, role == "assistant" else { throw CoreTranslationError.invalidResponse }
        }
        if let callID = message["tool_call_id"], !(callID is NSNull) { throw CoreTranslationError.invalidResponse }
        if let refusal = message["refusal"] as? String, !refusal.isEmpty { throw CoreTranslationError.refused }
        // Some compatible proxies omit or mislabel finish_reason. The trusted
        // message structure still cannot direct tools in this text-only task.
        if let calls = message["tool_calls"], !(calls is NSNull) {
            guard let calls = calls as? [Any], calls.isEmpty else { throw CoreTranslationError.invalidResponse }
        }
        if let call = message["function_call"], !(call is NSNull) { throw CoreTranslationError.invalidResponse }
        guard let content = message["content"] as? String else { throw CoreTranslationError.invalidResponse }
        let output = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { throw CoreTranslationError.empty }
        return output
    }
}
