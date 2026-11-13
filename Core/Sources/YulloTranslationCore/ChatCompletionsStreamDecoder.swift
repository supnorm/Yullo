import Foundation

// One response only. Provisional text is never a completed result until a
// selected-choice stop or DONE event passes the ordinary text-result checks.
public struct ChatCompletionsStreamDecoder: Sendable {
    public static let maximumResponseBytes = 4 * 1024 * 1024
    private enum Mode: Equatable, Sendable { case undecided, json, events }
    private var mode = Mode.undecided
    private var receivedBytes = 0
    private var prefix = Data()
    private var possibleBOM = false
    private var json = Data()
    private var line = Data()
    private var event = Data()
    private var hasDataLine = false
    private var skipLF = false
    private var firstLine = true
    private var selectedIndex: Int?
    private var finishReason: String?
    private var text = ""
    private var completedText: String?

    public init() {}
    public var partialText: String { text }
    public var isComplete: Bool { completedText != nil }

    @discardableResult public mutating func append(_ byte: UInt8) throws -> Bool {
        if receivedBytes & 1023 == 0 { try Task.checkCancellation() }
        guard receivedBytes < Self.maximumResponseBytes else { throw CoreTranslationError.invalidResponse }
        receivedBytes += 1
        guard !isComplete else { return false }
        switch mode {
        case .json:
            json.append(byte)
            return false
        case .events:
            return try appendEventByte(byte)
        case .undecided:
            prefix.append(byte)
            if prefix.count == 1 && byte == 0xEF {
                possibleBOM = true
                return false
            }
            if possibleBOM {
                if prefix.count < 3 { return false }
                possibleBOM = false
                if prefix.elementsEqual([0xEF, 0xBB, 0xBF]) { return false }
            }
            if [UInt8(9), 10, 13, 32].contains(byte) { return false }
            // Preserve the ordinary JSON boundary's Unicode/BOM support.
            // These leading bytes cannot begin a UTF-8 SSE field.
            if byte == 123 || byte == 91 || byte == 0 || byte == 0xFF || byte == 0xFE {
                mode = .json
                json = prefix
                prefix = Data()
                return false
            }
            mode = .events
            let initial = prefix
            prefix = Data()
            var changed = false
            for value in initial { changed = try appendEventByte(value) || changed }
            return changed
        }
    }

    @discardableResult public mutating func append(contentsOf data: Data) throws -> Bool {
        var changed = false
        for byte in data { changed = try append(byte) || changed }
        return changed
    }

    public mutating func finish() throws -> String {
        try Task.checkCancellation()
        if let completedText { return completedText }
        switch mode {
        case .json, .undecided:
            let value = try ChatCompletionsProtocol.parseResponse(
                data: mode == .json ? json : prefix, statusCode: 200)
            try Task.checkCancellation()
            completedText = value
            return value
        case .events:
            if !line.isEmpty { _ = try consumeLine() }
            if !isComplete && hasDataLine { _ = try consumeEvent() }
            guard let completedText else { throw CoreTranslationError.invalidResponse }
            try Task.checkCancellation()
            return completedText
        }
    }

    private mutating func appendEventByte(_ byte: UInt8) throws -> Bool {
        guard !isComplete else { return false }
        if skipLF {
            skipLF = false
            if byte == 10 { return false }
        }
        if byte == 13 {
            skipLF = true
            return try consumeLine()
        }
        if byte == 10 { return try consumeLine() }
        line.append(byte)
        return false
    }

    private mutating func consumeLine() throws -> Bool {
        defer { line.removeAll(keepingCapacity: true) }
        var bytes = line
        if firstLine {
            firstLine = false
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        }
        guard let value = String(data: bytes, encoding: .utf8) else { throw CoreTranslationError.invalidResponse }
        if value.isEmpty { return try consumeEvent() }
        if value.hasPrefix(":") { return false }
        let colon = value.firstIndex(of: ":")
        let field = colon.map { String(value[..<$0]) } ?? value
        guard field == "data" else { return false }
        var payload = colon.map { value[value.index(after: $0)...] } ?? ""[...]
        if payload.first == " " { payload = payload.dropFirst() }
        if hasDataLine { event.append(10) }
        event.append(contentsOf: payload.utf8)
        hasDataLine = true
        return false
    }

    private mutating func consumeEvent() throws -> Bool {
        guard hasDataLine else { return false }
        defer {
            hasDataLine = false
            event.removeAll(keepingCapacity: true)
        }
        try Task.checkCancellation()
        guard let payload = String(data: event, encoding: .utf8) else { throw CoreTranslationError.invalidResponse }
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if trimmed == "[DONE]" {
            try complete()
            return false
        }
        guard let root = try? JSONSerialization.jsonObject(with: event) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]]
        else { throw CoreTranslationError.invalidResponse }
        // Compatible services may emit usage-only chunks or omit choice indices.
        guard let first = choices.first else { return false }
        if selectedIndex == nil { selectedIndex = first["index"] as? Int ?? 0 }
        guard let choice = choices.first(where: { ($0["index"] as? Int ?? selectedIndex) == selectedIndex }) else {
            return false
        }
        let reason = choice["finish_reason"] as? String
        switch reason {
        case "length": throw CoreTranslationError.truncated
        case "content_filter": throw CoreTranslationError.refused
        case "tool_calls", "function_call": throw CoreTranslationError.invalidResponse
        default: break
        }
        let delta: [String: Any]
        if let value = choice["delta"] as? [String: Any] {
            delta = value
        } else if reason != nil && choice["delta"] == nil {
            delta = [:]
        } else {
            throw CoreTranslationError.invalidResponse
        }
        if let role = delta["role"] {
            guard let role = role as? String, role == "assistant" else { throw CoreTranslationError.invalidResponse }
        }
        if let callID = delta["tool_call_id"], !(callID is NSNull) { throw CoreTranslationError.invalidResponse }
        if let refusal = delta["refusal"] as? String, !refusal.isEmpty { throw CoreTranslationError.refused }
        if let calls = delta["tool_calls"], !(calls is NSNull) {
            guard let calls = calls as? [Any], calls.isEmpty else { throw CoreTranslationError.invalidResponse }
        }
        if let call = delta["function_call"], !(call is NSNull) { throw CoreTranslationError.invalidResponse }
        var changed = false
        if let content = delta["content"], !(content is NSNull) {
            guard let content = content as? String else { throw CoreTranslationError.invalidResponse }
            if !content.isEmpty {
                text += content
                changed = true
            }
        }
        if let reason { finishReason = reason }
        if reason == "stop" { try complete() }
        try Task.checkCancellation()
        return changed
    }

    private mutating func complete() throws {
        var choice: [String: Any] = ["message": ["role": "assistant", "content": text]]
        if let finishReason { choice["finish_reason"] = finishReason }
        let data = try JSONSerialization.data(withJSONObject: ["choices": [choice]])
        let value = try ChatCompletionsProtocol.parseResponse(data: data, statusCode: 200)
        try Task.checkCancellation()
        completedText = value
    }
}
