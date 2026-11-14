import Foundation

struct SpeechVoice: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let languageCodes: [String]
    var gender: String? = nil
    var accent: String? = nil
    var previewURL: URL? = nil
    var displayLabel: String { name == id ? id : "\(name) · \(id)" }
    func supports(language: String) -> Bool {
        languageCodes.isEmpty
            || languageCodes.contains {
                CloudSpeechProviders.languageFamily($0) == CloudSpeechProviders.languageFamily(language)
            }
    }
}
struct SpeechModel: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let languageCodes: [String]
    var maxCharacters: Int? = nil
    func supports(language: String) -> Bool {
        // A multilingual model's generic Mandarin capability can read either
        // script; individual regional voices still match their precise locale.
        func spokenFamily(_ value: String) -> String {
            let code = CloudSpeechProviders.languageFamily(value)
            return code == "zh-Hant" ? "zh" : code
        }
        return languageCodes.isEmpty || languageCodes.contains { spokenFamily($0) == spokenFamily(language) }
    }
}
struct CloudSpeechConfiguration: Equatable, Sendable {
    let provider: SpeechProvider
    var endpoint: String = ""
    var region: String = ""
    var modelID: String = ""
    var voiceID: String = ""
}
enum CloudSpeechError: Error, LocalizedError, Equatable {
    case configuration, key, voice, inputTooLarge, invalidResponse, audio, catalogTooLarge, http(Int)
    var errorDescription: String? {
        switch self {
        case .configuration: return L10n.tr("Check the speech service URL and region.")
        case .key: return L10n.tr("Enter your speech API key.")
        case .voice: return L10n.tr("Choose a voice or enter its voice ID.")
        case .inputTooLarge: return L10n.tr("This text is too long to read in one request.")
        case .invalidResponse: return L10n.tr("The speech service returned an invalid response.")
        case .audio: return L10n.tr("The speech service returned no playable audio.")
        case .catalogTooLarge: return L10n.tr("The voice list is too large. Enter a voice ID manually.")
        case .http(401), .http(403): return L10n.tr("Check the speech API key and account access.")
        case .http(429): return L10n.tr("The speech service limit was reached. Try again later.")
        case .http(let status): return L10n.format("The speech service returned an error (HTTP %ld).", status)
        }
    }
}

// Fixed speech tasks only. No conversation, previous/next utterance, prompt,
// request stitching, provider response text or preview URL enters synthesis.
enum CloudSpeechProviders {
    private static let maximumAudioBytes = 16 * 1_024 * 1_024
    private static let maximumCatalogBytes = 8 * 1_024 * 1_024
    private static let maximumVoices = 8_192
    // Voice lists change rarely, so Settings and automatic voice choice share
    // one per-account copy for six hours; an explicit refresh replaces it.
    private static let voiceCatalogs = ResponseCache<[SpeechVoice]>(
        capacity: 6, maxCost: 4 * 1_024 * 1_024, lifetime: 6 * 3_600)
    private static let modelCatalogs = ResponseCache<[SpeechModel]>(capacity: 6, maxCost: 256 * 1_024, lifetime: 3_600)
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 45
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    static func clearCachedCatalogs() {
        voiceCatalogs.removeAll()
        modelCatalogs.removeAll()
    }

    // Automatic means the current passage's language, not a language stored in
    // Settings. Catalogs contain metadata only and are isolated by account.
    static func automaticConfiguration(
        _ configuration: CloudSpeechConfiguration, language: String,
        key: String, session: URLSession? = nil, useCache: Bool = true
    ) async throws -> CloudSpeechConfiguration {
        try Task.checkCancellation()
        guard configuration.voiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return configuration
        }
        guard [.azure, .google, .elevenlabs].contains(configuration.provider) else {
            throw CloudSpeechError.configuration
        }
        let mayCache = useCache && session == nil
        var resolved = configuration
        if configuration.provider == .elevenlabs {
            if resolved.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                resolved.modelID = "eleven_multilingual_v2"
            }
            let identity = try catalogFingerprint(configuration: resolved, key: key, models: true)
            let models = try await cachedCatalog(
                modelCatalogs, identity: identity, mayCache: mayCache,
                cost: {
                    $0.reduce(0) {
                        $0 + $1.id.utf8.count + $1.name.utf8.count + $1.languageCodes.reduce(0) { $0 + $1.utf8.count }
                    }
                }
            ) {
                try await listModels(configuration: resolved, key: key, session: session)
            }
            guard let model = models.first(where: { $0.id == resolved.modelID }), !model.languageCodes.isEmpty,
                model.supports(language: language)
            else { throw CloudSpeechError.voice }
        }
        let identity = try catalogFingerprint(configuration: configuration, key: key)
        let voices = try await cachedCatalog(
            voiceCatalogs, identity: identity, mayCache: mayCache, cost: voiceCatalogCost
        ) {
            try await listVoices(configuration: configuration, key: key, session: session)
        }
        try Task.checkCancellation()
        guard let voice = automaticVoice(voices, provider: configuration.provider, language: language) else {
            throw CloudSpeechError.voice
        }
        resolved.voiceID = voice.id
        return resolved
    }

    static func automaticVoice(_ voices: [SpeechVoice], provider: SpeechProvider, language: String) -> SpeechVoice? {
        let family = languageFamily(language)
        let normalized = language.replacingOccurrences(of: "_", with: "-").lowercased()
        let locale =
            normalized.contains("-") && normalized != "zh-hant"
            ? normalized
            : Language.catalog.first(where: { $0.id == family })?.locale.lowercased() ?? normalized
        let candidates = voices.filter {
            provider == .elevenlabs || (!$0.languageCodes.isEmpty && $0.supports(language: language))
        }
        if provider == .azure, let preferred = AzureSpeech.voices[family],
            let voice = candidates.first(where: { $0.id == preferred })
        {
            return voice
        }
        func rank(_ voice: SpeechVoice) -> Int {
            let id = voice.id.lowercased()
            var score = voice.languageCodes.contains(where: { $0.lowercased() == locale }) ? 0 : 100
            if !voice.languageCodes.isEmpty && voice.supports(language: language) { score -= 200 }
            if id.hasPrefix(locale + "-") { score -= 20 }
            if provider == .azure && id.hasSuffix("neural") { score -= 10 }
            if provider == .google {
                if id.contains("-neural2-") {
                    score -= 10
                } else if id.contains("-wavenet-") {
                    score -= 8
                } else if id.contains("-standard-") {
                    score -= 6
                }
            }
            return score
        }
        return candidates.min { lhs, rhs in
            let left = rank(lhs), right = rank(rhs)
            return left == right ? lhs.id < rhs.id : left < right
        }
    }

    static func voiceCatalogCost(_ voices: [SpeechVoice]) -> Int {
        voices.reduce(0) {
            $0 + $1.id.utf8.count + $1.name.utf8.count + $1.languageCodes.reduce(0) { $0 + $1.utf8.count } + 128
        }
    }

    // The voice list Settings shows. Without a refresh it reuses the shared
    // per-account copy; a refresh fetches again and replaces that copy.
    static func voiceCatalog(configuration: CloudSpeechConfiguration, key: String, refresh: Bool) async throws
        -> [SpeechVoice]
    {
        let identity = try catalogFingerprint(configuration: configuration, key: key)
        let lookup = voiceCatalogs.lookup(for: identity)
        if !refresh, let voices = lookup.value { return voices }
        let voices = try await listVoices(configuration: configuration, key: key)
        try Task.checkCancellation()
        voiceCatalogs.insert(voices, for: identity, cost: voiceCatalogCost(voices), generation: lookup.generation)
        return voices
    }

    static func catalogFingerprint(configuration: CloudSpeechConfiguration, key: String, models: Bool = false) throws
        -> Data
    {
        var identity =
            try models
            ? request(configuration, path: "v1/models", key: key)
            : voiceListRequest(configuration: configuration, key: key)
        let region = configuration.provider == .azure ? try AzureSpeech.region(configuration.region) : ""
        identity.httpBody = try JSONSerialization.data(
            withJSONObject: ["provider": configuration.provider.rawValue, "region": region], options: [.sortedKeys])
        let header =
            configuration.provider == .google
            ? "X-Goog-Api-Key" : configuration.provider == .elevenlabs ? "xi-api-key" : "Ocp-Apim-Subscription-Key"
        return responseFingerprint(identity, credentialHeader: header)
    }

    static func cachedCatalog<Value>(
        _ cache: ResponseCache<Value>, identity: Data, mayCache: Bool,
        cost: (Value) -> Int, load: () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let lookup = mayCache ? cache.lookup(for: identity) : nil
        if let value = lookup?.value { return value }
        let value = try await load()
        try Task.checkCancellation()
        if let lookup { cache.insert(value, for: identity, cost: cost(value), generation: lookup.generation) }
        return value
    }

    static func synthesisRequest(
        text: String, language: String, rate: Double, configuration: CloudSpeechConfiguration, key: String
    ) throws -> URLRequest {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CloudSpeechError.audio }
        guard text.utf8.count <= 32_768 else { throw CloudSpeechError.inputTooLarge }
        guard rate.isFinite else { throw CloudSpeechError.configuration }
        let voice = try identifier(configuration.voiceID, issue: .voice, azureVoice: configuration.provider == .azure)
        var request: URLRequest
        switch configuration.provider {
        case .google:
            let locale = try Self.locale(language, provider: configuration.provider, voice: voice)
            guard text.utf8.count <= 5_000 else { throw CloudSpeechError.inputTooLarge }
            request = try Self.request(configuration, path: "v1/text:synthesize", key: key)
            var audio: [String: Any] = ["audioEncoding": "MP3"]
            if supportsRate(configuration) { audio["speakingRate"] = min(2, max(0.25, rate)) }
            request.httpBody = try JSONSerialization.data(
                withJSONObject: [
                    "input": ["text": text],
                    "voice": ["name": voice, "languageCode": locale], "audioConfig": audio
                ], options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        case .elevenlabs:
            request = try Self.request(
                configuration, path: "v1/text-to-speech/\(voice)", key: key,
                query: [URLQueryItem(name: "output_format", value: "mp3_44100_128")])
            var body: [String: Any] = ["text": text]
            let model = configuration.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !model.isEmpty { body["model_id"] = try identifier(model, issue: .configuration) }
            if supportsRate(configuration) { body["voice_settings"] = ["speed": min(1.2, max(0.7, rate))] }
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        case .azure:
            let locale = try Self.locale(language, provider: configuration.provider, voice: voice)
            request = try Self.request(configuration, path: "cognitiveservices/v1", key: key)
            let literal = AzureSpeech.escape(text)
            let percent = Int((min(2, max(0.5, rate)) - 1) * 100)
            let content =
                supportsRate(configuration)
                ? "<prosody rate='\(percent >= 0 ? "+" : "")\(percent)%'>\(literal)</prosody>" : literal
            let ssml =
                "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='\(locale)'><voice name='\(AzureSpeech.escape(voice))'>\(content)</voice></speak>"
            guard ssml.utf8.count <= 65_536 else { throw CloudSpeechError.inputTooLarge }
            request.httpBody = Data(ssml.utf8)
            request.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
            request.setValue("audio-24khz-48kbitrate-mono-mp3", forHTTPHeaderField: "X-Microsoft-OutputFormat")
        default: throw CloudSpeechError.configuration
        }
        request.httpMethod = "POST"
        request.setValue("audio/mpeg, application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func synthesize(
        text: String, language: String, rate: Double, configuration: CloudSpeechConfiguration,
        key: String, session: URLSession? = nil
    ) async throws -> Data {
        try Task.checkCancellation()
        let request = try synthesisRequest(
            text: text, language: language, rate: rate, configuration: configuration, key: key)
        let (data, response) = try await fetch(
            request, limit: configuration.provider == .google ? 24 * 1_024 * 1_024 : maximumAudioBytes,
            overflow: .audio, session: session)
        let audio: Data
        if configuration.provider == .google {
            struct Payload: Decodable { let audioContent: String }
            guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
                let decoded = Data(base64Encoded: payload.audioContent)
            else { throw CloudSpeechError.invalidResponse }
            audio = decoded
        } else {
            let mime = response.mimeType?.lowercased() ?? ""
            guard !mime.contains("json"), !mime.hasPrefix("text/") else { throw CloudSpeechError.audio }
            audio = data
        }
        guard audio.count <= maximumAudioBytes, isMP3(audio) else { throw CloudSpeechError.audio }
        try Task.checkCancellation()
        return audio
    }

    static func listVoices(configuration: CloudSpeechConfiguration, key: String, session: URLSession? = nil)
        async throws -> [SpeechVoice]
    {
        var voices: [SpeechVoice] = [], identifiers = Set<String>(), seenTokens = Set<String>()
        var token: String?, totalBytes = 0
        for _ in 0..<20 {
            try Task.checkCancellation()
            let request = try voiceListRequest(configuration: configuration, key: key, nextPageToken: token)
            let (data, _) = try await fetch(request, limit: 2 * 1_024 * 1_024, session: session)
            totalBytes += data.count
            guard totalBytes <= maximumCatalogBytes else { throw CloudSpeechError.catalogTooLarge }
            let page = try voicePage(data, provider: configuration.provider)
            for voice in page.voices where identifiers.insert(voice.id).inserted { voices.append(voice) }
            guard voices.count <= maximumVoices else { throw CloudSpeechError.catalogTooLarge }
            try Task.checkCancellation()
            if !page.hasMore {
                return voices.sorted {
                    $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            }
            guard let next = page.nextToken, !next.isEmpty, next.utf8.count <= 2_048,
                seenTokens.insert(next).inserted
            else { throw CloudSpeechError.invalidResponse }
            token = next
        }
        throw CloudSpeechError.catalogTooLarge
    }

    static func listModels(configuration: CloudSpeechConfiguration, key: String, session: URLSession? = nil)
        async throws -> [SpeechModel]
    {
        try Task.checkCancellation()
        // Google and Azure select model families through voice names, and do
        // not provide this model-list endpoint. Empty is not an auth check.
        guard configuration.provider == .elevenlabs else { return [] }
        let request = try Self.request(configuration, path: "v1/models", key: key)
        let (data, _) = try await fetch(request, limit: 1_024 * 1_024, overflow: .invalidResponse, session: session)
        struct LanguageEntry: Decodable { let language_id: String }
        struct Entry: Decodable {
            let model_id: String
            let name: String?
            let can_do_text_to_speech: Bool?
            let languages: [LanguageEntry]?
            let maximum_text_length_per_request: Int?
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data), entries.count <= 256 else {
            throw CloudSpeechError.invalidResponse
        }
        var seen = Set<String>(), models: [SpeechModel] = []
        for entry in entries where entry.can_do_text_to_speech == true {
            let id = try identifier(entry.model_id, issue: .invalidResponse)
            guard seen.insert(id).inserted else { continue }
            let limit = entry.maximum_text_length_per_request.flatMap { $0 > 0 && $0 <= 1_000_000 ? $0 : nil }
            models.append(
                SpeechModel(
                    id: id, name: label(entry.name) ?? id,
                    languageCodes: languages(entry.languages?.map(\.language_id) ?? []), maxCharacters: limit))
        }
        try Task.checkCancellation()
        return models
    }

    static func voiceListRequest(configuration: CloudSpeechConfiguration, key: String, nextPageToken: String? = nil)
        throws -> URLRequest
    {
        switch configuration.provider {
        case .google: return try request(configuration, path: "v1/voices", key: key)
        case .azure: return try request(configuration, path: "cognitiveservices/voices/list", key: key)
        case .elevenlabs:
            var query = [
                URLQueryItem(name: "page_size", value: "100"), URLQueryItem(name: "sort", value: "name"),
                URLQueryItem(name: "include_total_count", value: "false")
            ]
            if let nextPageToken { query.append(URLQueryItem(name: "next_page_token", value: nextPageToken)) }
            return try request(configuration, path: "v2/voices", key: key, query: query)
        default: throw CloudSpeechError.configuration
        }
    }
    static func supportsRate(_ configuration: CloudSpeechConfiguration) -> Bool {
        switch configuration.provider {
        case .azure: return configuration.voiceID.hasSuffix("Neural") && !configuration.voiceID.contains(":")
        case .google:
            let voice = configuration.voiceID.lowercased()
            return ["-standard-", "-wavenet-", "-neural2-", "-chirp3-hd-"].contains { voice.contains($0) }
        case .elevenlabs:
            return [
                "", "eleven_multilingual_v2", "eleven_turbo_v2", "eleven_turbo_v2_5", "eleven_flash_v2",
                "eleven_flash_v2_5"
            ].contains(configuration.modelID)
        default: return false
        }
    }
    static func languageFamily(_ value: String) -> String {
        Language.speechCode(value)
    }

    private static func request(
        _ configuration: CloudSpeechConfiguration, path: String, key: String, query: [URLQueryItem] = []
    ) throws -> URLRequest {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 8_192,
            !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw CloudSpeechError.key }
        let base: String
        if configuration.provider == .azure {
            guard let region = try? AzureSpeech.region(configuration.region) else {
                throw CloudSpeechError.configuration
            }
            base =
                configuration.endpoint.isEmpty ? "https://\(region).tts.speech.microsoft.com" : configuration.endpoint
        } else if configuration.provider == .google {
            base = configuration.endpoint.isEmpty ? "https://texttospeech.googleapis.com" : configuration.endpoint
        } else if configuration.provider == .elevenlabs {
            base = configuration.endpoint.isEmpty ? "https://api.elevenlabs.io" : configuration.endpoint
        } else {
            throw CloudSpeechError.configuration
        }
        guard var components = URLComponents(string: base.trimmingCharacters(in: .whitespacesAndNewlines)),
            let host = components.host?.lowercased(), !host.isEmpty, components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil,
            components.scheme?.lowercased() == "https"
                || (components.scheme?.lowercased() == "http"
                    && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host))
        else { throw CloudSpeechError.configuration }
        components.scheme = components.scheme?.lowercased()
        components.host = host
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([components.path, path].filter { !$0.isEmpty }.joined(separator: "/"))
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw CloudSpeechError.configuration }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Yullo", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            key,
            forHTTPHeaderField: configuration.provider == .google
                ? "X-Goog-Api-Key" : configuration.provider == .elevenlabs ? "xi-api-key" : "Ocp-Apim-Subscription-Key")
        return request
    }
    private static func fetch(
        _ request: URLRequest, limit: Int, overflow: CloudSpeechError = .catalogTooLarge, session: URLSession?
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            try Task.checkCancellation()
            // Per-task delegate also protects injected sessions from redirecting
            // credentials to a different origin. No provider URLs are followed.
            let (bytes, response) = try await (session ?? self.session).bytes(for: request, delegate: NoRedirects())
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw CloudSpeechError.invalidResponse }
            guard response.statusCode == 200 else { throw CloudSpeechError.http(response.statusCode) }
            if response.expectedContentLength > Int64(limit) { throw overflow }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < limit else { throw overflow }
                data.append(byte)
            }
            try Task.checkCancellation()
            return (data, response)
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }
    private struct VoicePage {
        let voices: [SpeechVoice]
        var hasMore = false
        var nextToken: String? = nil
    }
    private static func voicePage(_ data: Data, provider: SpeechProvider) throws -> VoicePage {
        do {
            switch provider {
            case .google:
                struct Entry: Decodable {
                    let name: String
                    let languageCodes: [String]
                    let ssmlGender: String?
                }
                struct Page: Decodable { let voices: [Entry] }
                let page = try JSONDecoder().decode(Page.self, from: data)
                guard page.voices.count <= maximumVoices else { throw CloudSpeechError.catalogTooLarge }
                return VoicePage(
                    voices: try page.voices.map { entry in
                        let id = try identifier(entry.name, issue: .invalidResponse)
                        return SpeechVoice(
                            id: id, name: id, languageCodes: languages(entry.languageCodes),
                            gender: label(entry.ssmlGender))
                    })
            case .azure:
                struct Entry: Decodable {
                    let ShortName: String
                    let DisplayName: String?
                    let Locale: String
                    let SecondaryLocaleList: [String]?
                    let Gender: String?
                }
                let entries = try JSONDecoder().decode([Entry].self, from: data)
                guard entries.count <= maximumVoices else { throw CloudSpeechError.catalogTooLarge }
                return VoicePage(
                    voices: try entries.map { entry in
                        let id = try identifier(entry.ShortName, issue: .invalidResponse, azureVoice: true)
                        return SpeechVoice(
                            id: id, name: label(entry.DisplayName) ?? id,
                            languageCodes: languages([entry.Locale] + (entry.SecondaryLocaleList ?? [])),
                            gender: label(entry.Gender))
                    })
            case .elevenlabs:
                struct Verified: Decodable {
                    let language: String?
                    let locale: String?
                }
                struct Entry: Decodable {
                    let voice_id: String
                    let name: String
                    let labels: [String: String]?
                    let verified_languages: [Verified]?
                    let preview_url: String?
                }
                struct Page: Decodable {
                    let voices: [Entry]
                    let has_more: Bool
                    let next_page_token: String?
                }
                let page = try JSONDecoder().decode(Page.self, from: data)
                guard page.voices.count <= maximumVoices else { throw CloudSpeechError.catalogTooLarge }
                let voices = try page.voices.map { entry in
                    let id = try identifier(entry.voice_id, issue: .invalidResponse)
                    let codes =
                        (entry.verified_languages ?? []).flatMap { [$0.locale, $0.language].compactMap { $0 } }
                        + [entry.labels?["language"]].compactMap { $0 }
                    let preview = entry.preview_url.flatMap(URL.init(string:)).flatMap {
                        $0.scheme == "https" && $0.user == nil && $0.password == nil ? $0 : nil
                    }
                    return SpeechVoice(
                        id: id, name: label(entry.name) ?? id, languageCodes: languages(codes),
                        gender: label(entry.labels?["gender"]), accent: label(entry.labels?["accent"]),
                        previewURL: preview)
                }
                return VoicePage(voices: voices, hasMore: page.has_more, nextToken: page.next_page_token)
            default: throw CloudSpeechError.configuration
            }
        } catch let error as CloudSpeechError { throw error } catch { throw CloudSpeechError.invalidResponse }
    }
    private static func identifier(_ value: String, issue: CloudSpeechError, azureVoice: Bool = false) throws -> String
    {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // Azure's catalog includes names with accented letters. Its voice ID is
        // an escaped SSML attribute, not a URL path. Other providers retain the
        // ASCII path/model identifier policy; controls and markup stay invalid.
        let pattern =
            azureVoice ? "^[A-Za-z0-9][\\p{L}\\p{M}\\p{N}._:-]{0,255}$" : "^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$"
        guard value.utf8.count <= 1_024, value.range(of: pattern, options: .regularExpression) != nil else {
            throw issue
        }
        return value
    }
    private static func languages(_ values: [String]) -> [String] {
        Array(
            Set(
                values.prefix(128).filter {
                    $0.range(of: "^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,3}$", options: .regularExpression) != nil
                })
        ).sorted()
    }
    private static func label(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
            value.count <= 200, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        return value
    }
    private static func locale(_ language: String, provider: SpeechProvider, voice: String) throws -> String {
        let family = languageFamily(language)
        let parts = voice.split(separator: "-")
        if parts.count >= 3 {
            let voiceLocale = parts.prefix(2).joined(separator: "-")
            let voiceFamily = languageFamily(voiceLocale)
            if voiceFamily == family || (["zh", "zh-Hant"].contains(voiceFamily) && ["zh", "zh-Hant"].contains(family))
            {
                return voiceLocale
            }
        }
        let normalized = language.replacingOccurrences(of: "_", with: "-")
        if provider == .google {
            if family == "zh" { return "cmn-CN" }
            if family == "yue" { return "yue-HK" }
            if family == "zh-Hant" { return "cmn-TW" }
        }
        if family == "zh-Hant" { return "zh-TW" }
        if normalized.contains("-"),
            normalized.range(of: "^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8}){1,3}$", options: .regularExpression) != nil
        {
            return normalized
        }
        if let selected = Language.catalog.first(where: { $0.id == family }) { return selected.locale }
        if family.range(of: "^[a-z]{2,3}$", options: .regularExpression) != nil { return family }
        throw CloudSpeechError.voice
    }
    private static func isMP3(_ data: Data) -> Bool {
        data.count >= 3
            && (data.starts(with: [0x49, 0x44, 0x33])
                || (data[data.startIndex] == 0xff && data[data.startIndex + 1] & 0xe0 == 0xe0))
    }
}

// A missing or refused key is told, with its fix, instead of read by a Mac voice
// without a word; an unreachable service still falls back.
extension CloudSpeechError: CoreFallbackError {
    var isKeyProblem: Bool { self == .key || self == .http(401) || self == .http(403) }
    var allowsAutomaticFallback: Bool { !isKeyProblem }
}
