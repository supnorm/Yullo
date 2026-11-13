import Foundation
import AVFoundation

enum SpeechAPIError: Error, LocalizedError, Equatable {
    case endpoint, model, voice, format, input, audio, tooLarge, provider, http(Int)
    var errorDescription: String? {
        switch self {
        case .endpoint:
            return L10n.tr(
                "Use an HTTPS speech URL, or HTTP for localhost. Leave out credentials and query parameters.")
        case .model: return L10n.tr("Enter the speech model ID from your service.")
        case .voice: return L10n.tr("Choose a voice or enter its voice ID.")
        case .format: return L10n.tr("Choose MP3 or WAV as the audio format.")
        case .input: return L10n.tr("Enter some text to read aloud.")
        case .audio: return L10n.tr("The speech service returned no playable audio.")
        case .tooLarge: return L10n.tr("The speech response is too large. Try a shorter passage.")
        case .provider: return L10n.tr("No voice service is chosen.")
        case .http(401), .http(403): return L10n.tr("Check the speech API key and account access.")
        case .http(429): return L10n.tr("The speech service limit was reached. Try again later.")
        case .http(let code): return L10n.format("The speech service returned an error (HTTP %ld).", code)
        }
    }
}

struct SpeechAPIClient {
    private static let maximumAudioBytes = 32 * 1_024 * 1_024
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 90
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()
    static func baseURL(_ input: String) throws -> URL {
        guard var parts = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
            let host = parts.host?.lowercased(), !host.isEmpty, parts.user == nil, parts.password == nil,
            parts.query == nil, parts.fragment == nil,
            parts.scheme?.lowercased() == "https"
                || (parts.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host))
        else { throw SpeechAPIError.endpoint }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = host
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard let value = parts.url else { throw SpeechAPIError.endpoint }
        return value
    }
    static func endpoint(_ input: String) throws -> URL {
        let base = try baseURL(input)
        if base.path.hasSuffix("/audio/speech") { return base }
        return base.appendingPathComponent("audio/speech")
    }
    static func request(
        configuration: SpeechAPIConfiguration, key: String, text: String, language: String, rate: Double
    ) throws -> URLRequest {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SpeechAPIError.input }
        guard text.utf8.count <= 262_144 else { throw CloudSpeechError.inputTooLarge }
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let voice = configuration.voice(for: language).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.utf8.count <= 512,
            !model.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw SpeechAPIError.model }
        guard !voice.isEmpty, voice.utf8.count <= 512,
            !voice.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw SpeechAPIError.voice }
        let format = configuration.responseFormat.lowercased()
        guard ["mp3", "wav"].contains(format) else { throw SpeechAPIError.format }
        var request = URLRequest(url: try endpoint(configuration.endpoint))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg, audio/wav", forHTTPHeaderField: "Accept")
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.utf8.count <= 8_192, !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw CloudSpeechError.key }
        if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "model": model, "input": text, "voice": voice,
                "speed": rate.isFinite ? min(4, max(0.25, rate)) : 1, "response_format": format
            ], options: [.sortedKeys])
        return request
    }
    static func synthesize(
        configuration: SpeechAPIConfiguration, key: String, text: String, language: String, rate: Double,
        session: URLSession? = nil
    ) async throws -> Data {
        try Task.checkCancellation()
        let request = try request(configuration: configuration, key: key, text: text, language: language, rate: rate)
        let (bytes, response) = try await (session ?? self.session).bytes(for: request, delegate: NoRedirects())
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw SpeechAPIError.audio }
        guard response.statusCode == 200 else { throw SpeechAPIError.http(response.statusCode) }
        let mime = response.mimeType?.lowercased() ?? ""
        guard !mime.contains("json"), !mime.hasPrefix("text/") else { throw SpeechAPIError.audio }
        guard response.expectedContentLength <= Int64(maximumAudioBytes) else { throw SpeechAPIError.tooLarge }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumAudioBytes else { throw SpeechAPIError.tooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        guard isSupportedAudio(data) else { throw SpeechAPIError.audio }
        return data
    }
    static func isSupportedAudio(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        if data.starts(with: [0x52, 0x49, 0x46, 0x46]), data.dropFirst(8).starts(with: [0x57, 0x41, 0x56, 0x45]) {
            return true
        }
        if data.starts(with: [0x49, 0x44, 0x33]) { return true }
        return data[data.startIndex] == 0xff && data[data.startIndex + 1] & 0xe0 == 0xe0
            && data[data.startIndex + 1] & 0x06 != 0
    }
}

// Current text + explicit speech settings only. Credentials are supplied by the
// caller, never fetched while inspecting an unused provider or browsing models.
enum SpeechService {
    private static let cache = ResponseCache<Data>(capacity: 12, maxCost: 8 * 1_024 * 1_024)
    // Settings samples repeat one fixed sentence per language. A local result
    // is kept for this app session per model, voice, language, speed and
    // reference file, so playing it again needs no helper run.
    private static let localSamples = ResponseCache<Data>(
        capacity: 32, maxCost: 48 * 1_024 * 1_024, lifetime: 24 * 3_600)
    static func clearCachedAudio() {
        cache.removeAll()
        localSamples.removeAll()
        CloudSpeechProviders.clearCachedCatalogs()
    }
    static func localSampleKey(modelID: String, voiceID: String, language: String, rate: Double, reference: URL?)
        -> Data
    {
        var identity: [String: Any] = [
            "model": modelID, "voice": voiceID, "language": language,
            "rate": rate.isFinite ? (rate * 100).rounded() / 100 : 1
        ]
        if var reference {
            // A replaced or edited file at the same path is a different voice.
            reference.removeAllCachedResourceValues()
            let values = try? reference.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            identity["reference"] = reference.standardizedFileURL.path
            identity["size"] = values?.fileSize ?? -1
            identity["modified"] = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        }
        return (try? JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys])) ?? Data()
    }
    static func localSample(key: Data, synthesize: () async throws -> Data) async throws -> Data {
        let lookup = localSamples.lookup(for: key)
        if let audio = lookup.value { return audio }
        let audio = try await synthesize()
        try Task.checkCancellation()
        localSamples.insert(audio, for: key, cost: audio.count, generation: lookup.generation)
        return audio
    }
    static func keyAccount(provider: SpeechProvider, configuration: SpeechAPIConfiguration, region: String = "") throws
        -> String
    {
        if provider == .azure { return AzureSpeech.keyAccount(try AzureSpeech.region(region)) }
        guard provider != .macOS, provider != .local else { throw SpeechAPIError.provider }
        let endpoint =
            try provider == .speechAPI
            ? SpeechAPIClient.endpoint(configuration.endpoint) : SpeechAPIClient.baseURL(configuration.endpoint)
        return "yullo.speech." + provider.rawValue + "/" + endpoint.absoluteString
    }
    static func fingerprint(
        provider: SpeechProvider, configuration: SpeechAPIConfiguration, region: String, key: String, text: String,
        language: String, rate: Double
    ) throws -> Data {
        var request = URLRequest(url: URL(string: "https://yullo.invalid/speech-cache")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "X-Yullo-Credential")
        // Speed applied only during playback leaves the provider request, and
        // its audio, unchanged; Slow then reuses the same entry.
        let sentRate =
            providerReceivesRate(provider: provider, configuration: configuration, region: region, language: language)
            ? rate : 1
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "provider": provider.rawValue,
                "endpoint": configuration.endpoint, "region": region, "model": configuration.model,
                "voice": configuration.voice(for: language), "format": configuration.responseFormat,
                "text": text, "language": language, "rate": sentRate.isFinite ? sentRate : 1
            ], options: [.sortedKeys])
        return responseFingerprint(request, credentialHeader: "X-Yullo-Credential")
    }
    // Automatic voices are sent rate 1, and named voices without speed support
    // omit it. Both get the speed during playback instead.
    private static func providerReceivesRate(
        provider: SpeechProvider, configuration: SpeechAPIConfiguration, region: String, language: String
    ) -> Bool {
        guard [.azure, .google, .elevenlabs].contains(provider) else { return true }
        let voice = configuration.voice(for: language)
        guard !voice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return CloudSpeechProviders.supportsRate(
            CloudSpeechConfiguration(
                provider: provider, endpoint: configuration.endpoint, region: region,
                modelID: configuration.model, voiceID: voice))
    }
    static func synthesize(
        provider: SpeechProvider, configuration: SpeechAPIConfiguration, region: String = "", key: String,
        text: String, language: String, rate: Double, session: URLSession? = nil, useCache: Bool = true,
        authorization: ProcessingAuthorization? = nil
    ) async throws -> Data {
        try Task.checkCancellation()
        if provider == .local {
            // Local generation owns no persistent audio cache. A reference
            // sample or installed model can change without a cloud cache key.
            return try await LocalSpeechSynthesizer.shared.synthesize(
                text: text, language: language,
                modelID: configuration.model, voiceID: configuration.voice(for: language), rate: rate)
        }
        let permission = authorization ?? ProcessingPolicyController.shared.authorization(for: .standard)
        return try await ProcessingPolicyController.shared.performExternal(authorization: permission) {
            try await synthesizeExternal(
                provider: provider, configuration: configuration, region: region, key: key,
                text: text, language: language, rate: rate, session: session, useCache: useCache)
        }
    }
    private static func synthesizeExternal(
        provider: SpeechProvider, configuration: SpeechAPIConfiguration, region: String, key: String,
        text: String, language: String, rate: Double, session: URLSession?, useCache: Bool
    ) async throws -> Data {
        let identity = try fingerprint(
            provider: provider, configuration: configuration, region: region, key: key, text: text, language: language,
            rate: rate)
        let mayCache = useCache && session == nil
        let lookup = mayCache ? cache.lookup(for: identity) : nil
        if let audio = lookup?.value { return audio }
        let audio: Data
        switch provider {
        case .macOS, .local: throw SpeechAPIError.provider
        case .speechAPI:
            audio = try await SpeechAPIClient.synthesize(
                configuration: configuration, key: key, text: text, language: language, rate: rate, session: session)
        case .azure, .google, .elevenlabs:
            let automatic = configuration.voice(for: language).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let selected = try await CloudSpeechProviders.automaticConfiguration(
                CloudSpeechConfiguration(
                    provider: provider, endpoint: configuration.endpoint, region: region,
                    modelID: configuration.model, voiceID: configuration.voice(for: language)),
                language: language, key: key, session: session, useCache: useCache)
            try Task.checkCancellation()
            // Apply speed locally for automatic voices, whose rate support is
            // unknown until this catalog resolves. Never apply it twice.
            audio = try await CloudSpeechProviders.synthesize(
                text: text, language: language, rate: automatic ? 1 : rate,
                configuration: selected, key: key, session: session)
        }
        try Task.checkCancellation()
        guard SpeechAPIClient.isSupportedAudio(audio) else { throw SpeechAPIError.audio }
        if let lookup { cache.insert(audio, for: identity, cost: audio.count, generation: lookup.generation) }
        return audio
    }
    static func playbackRate(
        provider: SpeechProvider, configuration: SpeechAPIConfiguration, region: String = "", language: String,
        rate: Double
    ) -> Float {
        if provider == .local { return LocalSpeechSynthesizer.playbackRate(modelID: configuration.model, rate: rate) }
        guard [.azure, .google, .elevenlabs].contains(provider),
            !providerReceivesRate(provider: provider, configuration: configuration, region: region, language: language)
        else { return 1 }
        return Float(rate.isFinite ? min(2, max(0.5, rate)) : 1)
    }
    // nil selects the caller's installed macOS voice. A cancelled request never
    // changes backend or begins speech after the user pressed stop.
    static func shouldUseService(provider: SpeechProvider, configuration: SpeechAPIConfiguration? = nil, offline: Bool)
        -> Bool
    {
        if provider == .local { return true }
        guard provider != .macOS else { return false }
        let endpoint = configuration.flatMap { try? SpeechAPIClient.endpoint($0.endpoint) }
        if provider == .speechAPI, configuration != nil, endpoint == nil { return false }
        if !offline { return true }
        guard provider == .speechAPI, let host = endpoint?.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }
    static func route(
        provider: SpeechProvider, offline: Bool, configuration: SpeechAPIConfiguration? = nil,
        remote: () async throws -> Data
    ) async throws -> Data? {
        try Task.checkCancellation()
        guard shouldUseService(provider: provider, configuration: configuration, offline: offline) else { return nil }
        do {
            let data = try await remote()
            try Task.checkCancellation()
            return data
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
            if error is ProcessingPolicyIssue || (error as? CoreFallbackError)?.allowsAutomaticFallback == false {
                throw error
            }
            return nil
        }
    }
}

// Creating and preparing the first AVAudioPlayer in a process took 146-268 ms
// on the main actor, and 7-9 ms once warm. Read aloud prepares one silent,
// never-played player while synthesis runs, after its policy and credential
// gates, so the first real player starts warm. It holds no user audio and runs
// once per process.
enum AudioOutputWarmup {
    private static let lock = NSLock()
    private static var started = false
    @discardableResult static func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return false }
        started = true
        Task.detached(priority: .userInitiated) { _ = silentPlayer() }
        return true
    }
    // 50 ms of 24 kHz 16-bit mono zeros at volume 0; play() is never called.
    static func silentPlayer() -> AVAudioPlayer? {
        let bytes = 2_400
        var wave = Data("RIFF".utf8)
        func word(_ value: Int, _ width: Int) {
            for offset in 0..<width { wave.append(UInt8(truncatingIfNeeded: value >> (8 * offset))) }
        }
        word(36 + bytes, 4)
        wave.append(Data("WAVEfmt ".utf8))
        for (value, width) in [(16, 4), (1, 2), (1, 2), (24_000, 4), (48_000, 4), (2, 2), (16, 2)] {
            word(value, width)
        }
        wave.append(Data("data".utf8))
        word(bytes, 4)
        wave.append(Data(count: bytes))
        guard let player = try? AVAudioPlayer(data: wave) else { return nil }
        player.volume = 0
        return player.prepareToPlay() ? player : nil
    }
}
