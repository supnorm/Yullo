import Foundation
import CryptoKit

// Session-only response reuse. Fingerprints retain neither credentials nor the
// source text; both the entry count and payload bytes have explicit limits.
final class ResponseCache<Value> {
    struct Generation {
        fileprivate let owner: UUID
        fileprivate let epoch: UInt64
    }
    struct Lookup {
        let value: Value?
        let generation: Generation
    }
    private struct Entry {
        let value: Value
        let cost: Int
        let expires: TimeInterval
        var lastAccess: UInt64
    }
    private let lock = NSLock()
    private let owner = UUID()
    private var epoch: UInt64 = 0
    private var entries: [Data: Entry] = [:]
    private var cost = 0
    private var sequence: UInt64 = 0
    private let capacity: Int
    private let maxCost: Int
    private let lifetime: TimeInterval
    private let clock: () -> TimeInterval
    init(
        capacity: Int, maxCost: Int, lifetime: TimeInterval = 300,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.capacity = capacity
        self.maxCost = maxCost
        self.lifetime = lifetime
        self.clock = clock
    }
    func lookup(for key: Data) -> Lookup {
        lock.lock()
        defer { lock.unlock() }
        let generation = Generation(owner: owner, epoch: epoch)
        guard var entry = entries[key] else { return Lookup(value: nil, generation: generation) }
        guard entry.expires > clock() else {
            remove(key)
            return Lookup(value: nil, generation: generation)
        }
        sequence &+= 1
        entry.lastAccess = sequence
        entries[key] = entry
        return Lookup(value: entry.value, generation: generation)
    }
    func value(for key: Data) -> Value? { lookup(for: key).value }
    func insert(_ value: Value, for key: Data, cost: Int, generation: Generation) {
        lock.lock()
        defer { lock.unlock() }
        // A cleared request may still finish for its caller, but cannot evict
        // or overwrite a newer entry while committing its old cache result.
        guard generation.owner == owner, generation.epoch == epoch else { return }
        remove(key)
        guard capacity > 0, cost >= 0, cost <= maxCost, lifetime > 0 else { return }
        let now = clock()
        for expired in entries.filter({ $0.value.expires <= now }).map(\.key) { remove(expired) }
        while entries.count >= capacity || self.cost + cost > maxCost {
            guard let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key else { return }
            remove(oldest)
        }
        sequence &+= 1
        entries[key] = Entry(value: value, cost: cost, expires: now + lifetime, lastAccess: sequence)
        self.cost += cost
    }
    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        epoch &+= 1
        entries.removeAll(keepingCapacity: false)
        cost = 0
        sequence = 0
    }
    private func remove(_ key: Data) {
        if let entry = entries.removeValue(forKey: key) { cost -= entry.cost }
    }
}

func responseFingerprint(_ request: URLRequest, credentialHeader: String) -> Data {
    var hash = SHA256()
    for part in [
        Data((request.httpMethod ?? "").utf8), Data((request.url?.absoluteString ?? "").utf8),
        Data((request.value(forHTTPHeaderField: credentialHeader) ?? "").utf8), request.httpBody ?? Data()
    ] {
        hash.update(data: Data("\(part.count):".utf8))
        hash.update(data: part)
    }
    return Data(hash.finalize())
}

final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}

// A total network budget, independent of URLSession's resettable idle timer.
// The one-shot owner rejects late responses and cancels its transport task.
enum APIRequestDeadline {
    static func run<Value: Sendable>(
        seconds: TimeInterval, operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        guard seconds.isFinite, seconds > 0, seconds <= 3600 else { throw URLError(.timedOut) }
        let owner = Owner<Value>(seconds: seconds)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { owner.start($0, operation: operation) }
        } onCancel: {
            owner.cancel()
        }
    }

    private final class Owner<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private let clock = ContinuousClock()
        private let deadline: ContinuousClock.Instant
        private var terminal: Result<Value, Error>?
        private var continuation: CheckedContinuation<Value, Error>?
        private var worker: Task<Void, Never>?
        private var timer: Task<Void, Never>?

        init(seconds: TimeInterval) { deadline = ContinuousClock.now.advanced(by: .seconds(seconds)) }
        func start(
            _ continuation: CheckedContinuation<Value, Error>,
            operation: @escaping @Sendable () async throws -> Value
        ) {
            lock.lock()
            if let terminal {
                lock.unlock()
                continuation.resume(with: terminal)
                return
            }
            self.continuation = continuation
            lock.unlock()
            let worker = Task.detached {
                do {
                    try Task.checkCancellation()
                    guard self.mayStart else { throw URLError(.timedOut) }
                    let value = try await operation()
                    self.complete(.success(value), fromWorker: true)
                } catch { self.complete(.failure(error), fromWorker: true) }
            }
            let timer = Task.detached {
                do { try await self.clock.sleep(until: self.deadline, tolerance: .zero) } catch { return }
                self.complete(.failure(URLError(.timedOut)), fromWorker: false)
            }
            lock.lock()
            if terminal == nil {
                self.worker = worker
                self.timer = timer
                lock.unlock()
            } else {
                lock.unlock()
                worker.cancel()
                timer.cancel()
            }
        }
        private var mayStart: Bool {
            lock.lock()
            defer { lock.unlock() }
            return terminal == nil && clock.now < deadline
        }
        func cancel() { complete(.failure(CancellationError()), fromWorker: false) }
        private func complete(_ incoming: Result<Value, Error>, fromWorker: Bool) {
            lock.lock()
            guard terminal == nil else {
                lock.unlock()
                return
            }
            let result: Result<Value, Error>
            if fromWorker, clock.now >= deadline {
                result = .failure(URLError(.timedOut))
            } else {
                result = incoming
            }
            terminal = result
            let continuation = self.continuation, worker = self.worker, timer = self.timer
            self.continuation = nil
            self.worker = nil
            self.timer = nil
            lock.unlock()
            timer?.cancel()
            if !fromWorker { worker?.cancel() }
            continuation?.resume(with: result)
        }
    }
}

struct APITextProgress: Sendable {
    let sequence: UInt64
    let text: String
}

// A brief synchronous observer; a consumer still owns its request/phase guard
// for any UI work it queues. No callback can begin after this lease closes.
private final class APIProgressOwner: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let callback: @Sendable (APITextProgress) -> Void
    private var open = true
    private var sequence: UInt64 = 0
    private var lastPublish: ContinuousClock.Instant?

    init(_ callback: @escaping @Sendable (APITextProgress) -> Void) { self.callback = callback }
    var hasPublished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sequence > 0
    }
    func publish(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard open, !Task.isCancelled, !text.isEmpty else { return }
        let now = ContinuousClock.now
        if let lastPublish, lastPublish.duration(to: now) < .milliseconds(100) { return }
        sequence += 1
        lastPublish = now
        // Recursive locking also permits an observer to cancel its own task.
        callback(.init(sequence: sequence, text: text))
    }
    func close() {
        lock.lock()
        open = false
        lock.unlock()
    }
}

// Told when a service accepted a request only after it was resent without
// streaming: the request's endpoint and model, never a key or any text.
typealias APIStreamingRejection = @Sendable (_ endpoint: URL, _ model: String) -> Void
enum APIStreamingFallback {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var observer: APIStreamingRejection?
    static func observe(_ observer: APIStreamingRejection?) {
        lock.lock()
        Self.observer = observer
        lock.unlock()
    }
    static func report(_ endpoint: URL, _ model: String) {
        lock.lock()
        let observer = Self.observer
        lock.unlock()
        observer?(endpoint, model)
    }
}

// Records, for one request, that the service accepted it only without streaming.
final class APIStreamingRejectionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var rejected = false
    func set() {
        lock.lock()
        rejected = true
        lock.unlock()
    }
    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return rejected
    }
}

struct APIClient {
    static let maximumResponseBytes = ChatCompletionsStreamDecoder.maximumResponseBytes
    let session: URLSession
    private let cache: ResponseCache<String>
    private let translationDeadline: @Sendable (Int) -> TimeInterval
    private let streamingRejected: APIStreamingRejection
    private static let sharedCache = ResponseCache<String>(capacity: 32, maxCost: 2 * 1024 * 1024)
    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 40
        config.timeoutIntervalForResource = 60
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()
    static func defaultTranslationDeadline(textBytes: Int) -> TimeInterval {
        min(60, 12 + Double(max(0, textBytes)) / 256)
    }
    init(
        session: URLSession? = nil,
        translationDeadline: @escaping @Sendable (Int) -> TimeInterval = { defaultTranslationDeadline(textBytes: $0) },
        streamingRejected: APIStreamingRejection? = nil
    ) {
        self.session = session ?? Self.sharedSession
        self.translationDeadline = translationDeadline
        self.streamingRejected = streamingRejected ?? { APIStreamingFallback.report($0, $1) }
        // Injected test/local sessions never consume responses from another session.
        self.cache = session == nil ? Self.sharedCache : ResponseCache<String>(capacity: 32, maxCost: 2 * 1024 * 1024)
    }
    static func clearCachedResponses() { sharedCache.removeAll() }
    static func endpoint(_ input: String) throws -> URL {
        do { return try ChatCompletionsProtocol.endpoint(input) } catch let error as CoreTranslationError {
            throw APIError(error)
        }
    }
    static func request(
        endpoint: String, model: String, key: String, text: String, source: String, target: String,
        terms: [CoreVocabularyTranslationTerm] = [], context: [String]? = nil, instructions: String? = nil
    )
        throws -> URLRequest
    {
        do {
            let request = try ChatCompletionsProtocol.request(
                endpoint: endpoint, model: model, key: key, text: text,
                source: source, target: target, languageAliases: TranslationPrompt.languages,
                instructions: instructions)
            return try VocabularyPromptData.apply(to: request, text: text, terms: terms, context: context)
        } catch let error as CoreTranslationError { throw APIError(error) }
    }
    func translate(
        endpoint: String, model: String, key: String, text: String, source: String, target: String,
        useCache: Bool = true, terms: [CoreVocabularyTranslationTerm] = [], context: [String]? = nil,
        instructions: String? = nil, progress: (@Sendable (APITextProgress) -> Void)? = nil
    ) async throws -> String {
        try Task.checkCancellation()
        let request = try Self.request(
            endpoint: endpoint, model: model, key: key, text: text, source: source, target: target, terms: terms,
            context: context, instructions: instructions)
        return try await perform(
            request, useCache: useCache, deadline: translationDeadline(text.utf8.count), progress: progress)
    }
    static func jsonBatchRequest(
        endpoint: String, model: String, key: String, batch: CoreJSONTranslationBatch.Batch,
        source: String, target: String
    ) throws -> URLRequest {
        var request = try Self.request(
            endpoint: endpoint, model: model, key: key, text: String(decoding: batch.input, as: UTF8.self),
            source: source, target: target)
        guard let data = request.httpBody,
            var body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            var messages = body["messages"] as? [[String: String]], messages.count == 2,
            let instruction = messages[0]["content"]
        else { throw APIError.invalidResponse }
        messages[0]["content"] = instruction + StructuredJSONPrompt.rules
        body["messages"] = messages
        let encoded = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        guard encoded.count <= 131_072 else { throw CoreJSONTranslationPlan.Issue.tooComplex }
        request.httpBody = encoded
        return request
    }
    func translateJSONBatch(
        endpoint: String, model: String, key: String, batch: CoreJSONTranslationBatch.Batch,
        source: String, target: String
    ) async throws -> String {
        let request = try Self.jsonBatchRequest(
            endpoint: endpoint, model: model, key: key, batch: batch, source: source, target: target)
        let result = try await perform(request, useCache: false, deadline: translationDeadline(batch.input.count))
        _ = try batch.decode(Data(result.utf8))
        return result
    }

    static func refinementRequest(
        endpoint: String, model: String, key: String, text: String, style: RewriteStyle,
        terms: [CoreVocabularyTranslationTerm] = [], requirements: CoreWritingRequirements = .standard,
        instructions: String? = nil
    )
        throws -> URLRequest
    {
        do {
            let request = try ChatCompletionsProtocol.refinementRequest(
                endpoint: endpoint, model: model, key: key, text: text, style: style, requirements: requirements,
                instructions: instructions)
            return try VocabularyPromptData.apply(to: request, text: text, terms: terms)
        } catch let error as CoreTranslationError { throw APIError(error) }
    }
    func refine(
        endpoint: String, model: String, key: String, text: String, style: RewriteStyle, useCache: Bool = true,
        terms: [CoreVocabularyTranslationTerm] = [], requirements: CoreWritingRequirements = .standard,
        instructions: String? = nil, progress: (@Sendable (APITextProgress) -> Void)? = nil
    )
        async throws -> String
    {
        try Task.checkCancellation()
        let request = try Self.refinementRequest(
            endpoint: endpoint, model: model, key: key, text: text, style: style, terms: terms,
            requirements: requirements, instructions: instructions)
        return try await perform(request, useCache: useCache, progress: progress)
    }
    // An explicit Describe request: the description is the only user message.
    func describePreset(
        endpoint: String, model: String, key: String, description: String, languageIDs: [String]
    ) async throws -> String {
        try Task.checkCancellation()
        let request: URLRequest
        do {
            request = try ChatCompletionsProtocol.presetDescriptionRequest(
                endpoint: endpoint, model: model, key: key, description: description, languageIDs: languageIDs)
        } catch let error as CoreTranslationError { throw APIError(error) }
        return try await perform(request, useCache: false)
    }
    static func voiceEditRequest(
        endpoint: String, model: String, key: String, source: String, instruction: String,
        terms: [CoreVocabularyTranslationTerm] = []
    ) throws -> URLRequest {
        try CoreVoiceEditPrompt.validateInputs(source: source, instruction: instruction)
        let language = Language.detected(in: source)
        let data = try CoreVoiceEditPrompt.userData(
            source: source, instruction: instruction, terms: terms,
            change: CoreVoiceEditPrompt.localLead(
                instruction, language: language?.name, languageID: language?.id))
        // Reuse connection/model/header validation, then replace exactly the
        // current task's two messages. No source or instruction enters rules.
        var request = try Self.refinementRequest(
            endpoint: endpoint, model: model, key: key, text: source, style: .professional)
        guard let body = request.httpBody,
            var root = try JSONSerialization.jsonObject(with: body) as? [String: Any],
            let messages = root["messages"] as? [[String: String]], messages.count == 2,
            messages[0]["role"] == "system", messages[1]["role"] == "user"
        else { throw APIError.invalidResponse }
        root["messages"] = [
            [
                "role": "system",
                "content": CoreVoiceEditPrompt.instruction
            ],
            ["role": "user", "content": String(decoding: data, as: UTF8.self)]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: root, options: .sortedKeys)
        return request
    }
    func voiceEdit(
        endpoint: String, model: String, key: String, source: String, instruction: String,
        terms: [CoreVocabularyTranslationTerm] = []
    ) async throws -> String {
        try Task.checkCancellation()
        let request = try Self.voiceEditRequest(
            endpoint: endpoint, model: model, key: key, source: source, instruction: instruction, terms: terms)
        // A spoken edit is a fresh explicit operation, never history reuse.
        let result = try await perform(request, useCache: false)
        try CoreVoiceEditPrompt.validateResult(source: source, instruction: instruction, result: result)
        return result
    }
    private func perform(
        _ request: URLRequest, useCache: Bool, deadline: TimeInterval? = nil,
        progress: (@Sendable (APITextProgress) -> Void)? = nil
    ) async throws -> String {
        try Task.checkCancellation()
        let owner = progress.map(APIProgressOwner.init)
        defer { owner?.close() }
        let fingerprint = responseFingerprint(request, credentialHeader: "Authorization")
        let lookup = useCache ? cache.lookup(for: fingerprint) : nil
        if let text = lookup?.value { return text }
        let output: String
        do {
            output = try await withTaskCancellationHandler {
                let outgoing = try Self.transportRequest(request, streaming: owner != nil)
                let session = session
                // A service that rejects streaming gets the same request once more
                // without it, as long as no streamed text has been shown.
                let exchange: @Sendable () async throws -> Exchange = {
                    do {
                        return .init(
                            response: try await Self.boundedResponse(for: outgoing, session: session, progress: owner))
                    } catch {
                        guard let owner, !owner.hasPublished, Self.rejectsStreaming(error) else { throw error }
                        try Task.checkCancellation()
                        owner.close()
                        return .init(
                            response: try await Self.boundedResponse(for: request, session: session), fellBack: true)
                    }
                }
                let result: Exchange
                if let deadline {
                    result = try await APIRequestDeadline.run(seconds: deadline, operation: exchange)
                } else {
                    result = try await exchange()
                }
                let response = result.response
                owner?.close()
                if result.fellBack, let url = request.url, let model = Self.model(of: request) {
                    streamingRejected(url, model)
                }
                switch response {
                case .json(let data, let status):
                    return try ChatCompletionsProtocol.parseResponse(data: data, statusCode: status)
                case .streamed(let value): return value
                }
            } onCancel: {
                owner?.close()
            }
        } catch let
            error as CoreTranslationError
        { throw APIError(error) }
        try Task.checkCancellation()
        if let lookup { cache.insert(output, for: fingerprint, cost: output.utf8.count, generation: lookup.generation) }
        return output
    }
    // Statuses a service uses for a request field it doesn't accept or a stream it can't
    // produce. Keys, limits and outages fail the same way without streaming. A service
    // that ignores the field and answers in JSON needs no retry: the decoder reads both.
    private static func rejectsStreaming(_ error: Error) -> Bool {
        switch error {
        case APIError.http(let status): return [400, 404, 405, 406, 415, 422, 501].contains(status)
        default: return false
        }
    }
    private static func model(of request: URLRequest) -> String? {
        guard let body = request.httpBody,
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return nil }
        return object["model"] as? String
    }
    private static func transportRequest(_ request: URLRequest, streaming: Bool) throws -> URLRequest {
        guard streaming else { return request }
        guard let body = request.httpBody,
            var object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { throw APIError.invalidResponse }
        object["stream"] = true
        var copy = request
        copy.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        copy.httpBody = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        return copy
    }
    private enum TransportResponse: Sendable {
        case json(Data, Int)
        case streamed(String)
    }
    private struct Exchange: Sendable {
        let response: TransportResponse
        var fellBack = false
    }
    private static func boundedResponse(
        for request: URLRequest, session: URLSession, progress: APIProgressOwner? = nil
    ) async throws -> TransportResponse {
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: NoRedirects())
            return try await withTaskCancellationHandler {
                defer { bytes.task.cancel() }
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse }
                // Status errors remain specific even if the error body is large.
                guard (200..<300).contains(response.statusCode) else { throw APIError.http(response.statusCode) }
                guard response.expectedContentLength <= Int64(Self.maximumResponseBytes) else {
                    throw APIError.invalidResponse
                }
                if let progress {
                    var decoder = ChatCompletionsStreamDecoder()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        let changed = try decoder.append(byte)
                        if decoder.isComplete {
                            progress.close()
                            return .streamed(try decoder.finish())
                        }
                        if changed { progress.publish(decoder.partialText) }
                    }
                    let output = try decoder.finish()
                    progress.close()
                    return .streamed(output)
                }
                var data = Data()
                if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < Self.maximumResponseBytes else { throw APIError.invalidResponse }
                    data.append(byte)
                }
                try Task.checkCancellation()
                return .json(data, response.statusCode)
            } onCancel: {
                progress?.close()
                bytes.task.cancel()
            }
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }
}

// Connection setup/testing uses the same canonical endpoint as credential lookup,
// independently of which translation engine is currently selected.
struct APIConnectionSettings: Equatable, Sendable {
    let endpoint: String
    let model: String
    init(endpoint: String, model: String) throws {
        self.endpoint = try APIClient.endpoint(endpoint.trimmingCharacters(in: .whitespacesAndNewlines)).absoluteString
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !self.model.isEmpty else { throw APIError.missingModel }
    }
}
