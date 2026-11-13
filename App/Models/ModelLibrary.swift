import Foundation
import CryptoKit

enum ModelTask: String, CaseIterable, Codable, Sendable { case dictation, translation, readAloud }
typealias ModelDiscoveryTask = ModelTask

enum LocalModelRuntime: String, Codable, Sendable {
    case whisper, transcribe, llama, audioSpeech
    var task: ModelTask {
        switch self {
        case .whisper, .transcribe: return .dictation
        case .llama: return .translation
        case .audioSpeech: return .readAloud
        }
    }
}
typealias LocalASRRuntime = LocalModelRuntime

// Native helpers inside the app. ggml loads precompiled Metal kernels named
// default.metallib from the executable's bundle. Each pinned ggml revision needs
// its own kernels, so the recognition and translation helpers live in nested
// bundles with their own Resources; the speech helper uses the app's Resources.
enum RuntimeHelper: String, CaseIterable, Sendable {
    case whisper = "yullo-whisper", transcribe = "yullo-transcribe", liveTranscribe = "yullo-live-transcribe",
        llama = "yullo-llama", speech = "yullo-speech"
    var relativePath: String {
        switch self {
        case .whisper, .transcribe, .liveTranscribe:
            return "Contents/Helpers/LocalRecognition.bundle/Contents/MacOS/" + rawValue
        case .llama: return "Contents/Helpers/LocalTranslation.bundle/Contents/MacOS/" + rawValue
        case .speech: return "Contents/Helpers/" + rawValue
        }
    }
    static func url(_ helper: Self, in bundle: URL = Bundle.main.bundleURL) -> URL {
        bundle.appendingPathComponent(helper.relativePath)
    }
}

struct LocalModelDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let fileName: String
    let sizeBytes: Int64
    let sha256: String
    let downloadURL: URL
    let supportsCantonese: Bool
    let runtime: LocalASRRuntime
    let task: ModelTask
    init(
        id: String, name: String, fileName: String, sizeBytes: Int64, sha256: String, downloadURL: URL,
        supportsCantonese: Bool, runtime: LocalASRRuntime = .whisper, task: ModelTask? = nil
    ) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.downloadURL = downloadURL
        self.supportsCantonese = supportsCantonese
        self.runtime = runtime
        self.task = task ?? runtime.task
    }
}

struct InstalledLocalModel: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let url: URL
    let sizeBytes: Int64
    let imported: Bool
    let runtime: LocalASRRuntime
    let task: ModelTask
    let architecture: String?
    init(
        id: String, name: String, url: URL, sizeBytes: Int64, imported: Bool, runtime: LocalASRRuntime = .whisper,
        task: ModelTask? = nil, architecture: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.sizeBytes = sizeBytes
        self.imported = imported
        self.runtime = runtime
        self.task = task ?? runtime.task
        self.architecture = architecture
    }
}

struct LocalModelImportInfo: Equatable, Sendable {
    var task: ModelTask { runtime.task }
    let name: String
    let sizeBytes: Int64
    let supportsCantonese: Bool
    let runtime: LocalASRRuntime
    init(name: String, sizeBytes: Int64, supportsCantonese: Bool, runtime: LocalASRRuntime = .whisper) {
        self.name = name
        self.sizeBytes = sizeBytes
        self.supportsCantonese = supportsCantonese
        self.runtime = runtime
    }
}

struct ModelDownloadProgress: Sendable {
    enum Phase: String, Sendable { case downloading, verifying, ready }
    let modelID: String
    let phase: Phase
    let fraction: Double?
    let downloadedBytes: Int64
    let totalBytes: Int64?
}

enum ModelLibraryError: Error, LocalizedError, Equatable {
    case unknownModel, unavailable, invalidFormat, invalidSize, invalidHash, busy, inUse, downloadFailed, storageFull,
        storageUnavailable, taskMismatch
    var errorDescription: String? { L10n.tr(messageKey) }
    var messageKey: String {
        switch self {
        case .unknownModel: return "Choose a model from the local model library."
        case .unavailable: return "Download or import this model before using it."
        case .invalidFormat: return "This file isn’t a supported local model."
        case .invalidSize: return "The model download is incomplete or has an unexpected size."
        case .invalidHash: return "The downloaded model couldn’t be verified. Download it again."
        case .busy: return "This model is already downloading."
        case .inUse: return "This model is in use. Try again when it finishes."
        case .downloadFailed: return "Couldn’t download the model. Check your internet connection and try again."
        case .storageFull:
            return "Not enough free space to download this model. Free up space on this Mac and try again."
        case .storageUnavailable:
            return "A local file or folder is blocking this action. Check Yullo’s model folder and its permissions."
        case .taskMismatch: return "Choose a model for the selected task."
        }
    }
    // Preserve an actionable local write failure instead of blaming the network.
    // Inspect only the captured error chain, never mutable ambient errno or text.
    static func downloadFailure(_ error: Error) -> Self {
        if let issue = error as? Self, issue == .invalidSize || issue == .storageFull || issue == .storageUnavailable {
            return issue
        }
        var cause = error as NSError
        var visited = Set<ObjectIdentifier>()
        for _ in 0..<8 {
            guard visited.insert(ObjectIdentifier(cause)).inserted else { break }
            if (cause.domain == NSCocoaErrorDomain && cause.code == CocoaError.Code.fileWriteOutOfSpace.rawValue)
                || (cause.domain == NSPOSIXErrorDomain && cause.code == Int(POSIXErrorCode.ENOSPC.rawValue))
            {
                return .storageFull
            }
            if cause.domain == NSCocoaErrorDomain && cause.code == CocoaError.Code.fileWriteNoPermission.rawValue {
                return .storageUnavailable
            }
            guard let underlying = cause.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            cause = underlying
        }
        return .downloadFailed
    }
}

// File ownership and verification are independent of views and microphone state.
// Model weights are never placed in the application bundle or sent to a provider.
actor ModelLibrary {
    static let shared = ModelLibrary()
    typealias Fetcher = @Sendable (URL, URL, Int64, @escaping @Sendable (Int64) -> Void) async throws -> URL
    nonisolated static let repositoryRevision = "5359861c739e955e79d9a303bcbc70fb988958b1"
    nonisolated static let defaultModelID = "whisper-turbo-q5"
    nonisolated static let catalog: [LocalModelDescriptor] =
        {
            func descriptor(_ id: String, _ name: String, _ file: String, _ size: Int64, _ sha: String, _ yue: Bool)
                -> LocalModelDescriptor
            {
                LocalModelDescriptor(
                    id: id, name: name, fileName: file, sizeBytes: size, sha256: sha,
                    downloadURL: URL(
                        string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(repositoryRevision)/\(file)")!,
                    supportsCantonese: yue)
            }
            return [
                descriptor(
                    "whisper-base-q5", "Whisper Base · Q5", "ggml-base-q5_1.bin", 59_707_625,
                    "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898", false),
                descriptor(
                    "whisper-small-q5", "Whisper Small · Q5", "ggml-small-q5_1.bin", 190_085_487,
                    "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb", false),
                descriptor(
                    defaultModelID, "Whisper Large v3 Turbo · Q5", "ggml-large-v3-turbo-q5_0.bin", 574_041_195,
                    "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2", true),
                descriptor(
                    "whisper-turbo-q8", "Whisper Large v3 Turbo · Q8", "ggml-large-v3-turbo-q8_0.bin", 874_188_075,
                    "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1", true),
                descriptor(
                    "whisper-large-v3-q5", "Whisper Large v3 · Q5", "ggml-large-v3-q5_0.bin", 1_081_140_203,
                    "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1", true)
            ]
        }() + [
            LocalModelDescriptor(
                id: "qwen3-asr-06b-q4", name: "Qwen3 ASR 0.6B · Q4", fileName: "Qwen3-ASR-0.6B-Q4_K_M.gguf",
                sizeBytes: 589_560_480, sha256: "5b58f32a58ffa2c8783e0b0963485623e286e6272d953dfc9e28bc3447dee0c0",
                downloadURL: URL(
                    string:
                        "https://huggingface.co/handy-computer/Qwen3-ASR-0.6B-gguf/resolve/7e7c69a577fa2725dfedbe34b5e999336e30a19b/Qwen3-ASR-0.6B-Q4_K_M.gguf"
                )!,
                supportsCantonese: true, runtime: .transcribe),
            LocalModelDescriptor(
                id: "nemotron-35-q4", name: "Nemotron 3.5 ASR 0.6B · Q4",
                fileName: "nemotron-3.5-asr-streaming-0.6b-Q4_K_M.gguf",
                sizeBytes: 495_831_520, sha256: "41c99fa5fb6f3d35f68e79adc3e755eca2232a8d921178bd647b71194792b8fd",
                downloadURL: URL(
                    string:
                        "https://huggingface.co/handy-computer/nemotron-3.5-asr-streaming-0.6b-gguf/resolve/53ce288f69326b415aeef030cfcb02a08a8096dd/nemotron-3.5-asr-streaming-0.6b-Q4_K_M.gguf"
                )!,
                supportsCantonese: false, runtime: .transcribe),
            LocalModelDescriptor(
                id: "parakeet-v3-q4", name: "Parakeet TDT 0.6B v3 · Q4", fileName: "parakeet-tdt-0.6b-v3-Q4_K_M.gguf",
                sizeBytes: 485_425_504, sha256: "b68557be1e3c40207fd7c4bd9d63f1d3316b963f15325bfb0cc16a8bb0ffd181",
                downloadURL: URL(
                    string:
                        "https://huggingface.co/handy-computer/parakeet-tdt-0.6b-v3-gguf/resolve/d8d8c32cb2017c57e5307767343e97870f8a7f53/parakeet-tdt-0.6b-v3-Q4_K_M.gguf"
                )!,
                supportsCantonese: false, runtime: .transcribe)
        ] + LocalModelCatalog.additional

    private struct ImportRecord: Codable {
        let id: String
        let name: String
        let sizeBytes: Int64
        let sha256: String
        let runtime: LocalASRRuntime?
    }
    private struct Fingerprint: Equatable {
        let size: Int64
        let modified: Date
        let inode: UInt64
    }
    private let directory: URL
    private let descriptors: [LocalModelDescriptor]
    private let fetcher: Fetcher?
    private var downloads = Set<String>()
    private var leases: [String: Int] = [:]
    private var verified: [String: Fingerprint] = [:]

    init(
        directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Yullo/Models", isDirectory: true),
        descriptors: [LocalModelDescriptor] = ModelLibrary.catalog, fetcher: Fetcher? = nil
    ) {
        self.directory = directory.standardizedFileURL
        self.descriptors = descriptors
        self.fetcher = fetcher
    }

    nonisolated static func preflightImport(_ source: URL, expectedTask: ModelTask? = nil) throws
        -> LocalModelImportInfo
    {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension.lowercased()
        guard ["bin", "gguf"].contains(ext) else { throw ModelLibraryError.invalidFormat }
        let size = try fingerprint(source).size
        guard size >= 1_048_576, size <= 400_000_000_000 else { throw ModelLibraryError.invalidSize }
        let runtime: LocalASRRuntime
        if ext == "bin" {
            runtime = .whisper
        } else {
            switch try ggufArchitecture(source) {
            case "qwen3_asr", "parakeet", "sensevoice", "cohere_asr": runtime = .transcribe
            case "qwen3", "gemma3", "hunyuan-dense": runtime = .llama
            case "audiocpp": runtime = .audioSpeech
            default: throw ModelLibraryError.invalidFormat
            }
        }
        if let expectedTask, runtime.task != expectedTask { throw ModelLibraryError.taskMismatch }
        try validateHeader(source, runtime: runtime)
        let cantonese: Bool
        if runtime == .transcribe {
            cantonese = ["qwen3_asr", "sensevoice"].contains(try ggufArchitecture(source))
        } else if runtime == .whisper {
            let file = try FileHandle(forReadingFrom: source)
            defer { try? file.close() }
            let data = try file.read(upToCount: 48) ?? Data()
            guard data.count == 48 else { throw ModelLibraryError.invalidFormat }
            let melBins = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[40 + $1]) << (8 * $1) }
            let vocabulary = (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[4 + $1]) << (8 * $1) }
            cantonese = melBins == 128 && vocabulary >= 51866
        } else {
            cantonese = false
        }
        return LocalModelImportInfo(
            name: source.deletingPathExtension().lastPathComponent, sizeBytes: size,
            supportsCantonese: cantonese, runtime: runtime)
    }

    func runtime(id: String) throws -> LocalASRRuntime {
        if let descriptor = descriptors.first(where: { $0.id == id }) { return descriptor.runtime }
        return try readRecord(id: id).runtime ?? .whisper
    }

    func task(id: String) throws -> ModelTask {
        if let descriptor = descriptors.first(where: { $0.id == id }) { return descriptor.task }
        return try runtime(id: id).task
    }

    func installedModels(matchingID: String? = nil) throws -> [InstalledLocalModel] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        var result = descriptors.compactMap { descriptor -> InstalledLocalModel? in
            guard matchingID == nil || descriptor.id == matchingID else { return nil }
            let url = directory.appendingPathComponent(descriptor.fileName)
            guard let stamp = try? Self.fingerprint(url), stamp.size == descriptor.sizeBytes,
                (try? Self.validateHeader(url, runtime: descriptor.runtime)) != nil
            else { return nil }
            return InstalledLocalModel(
                id: descriptor.id, name: descriptor.name, url: url, sizeBytes: stamp.size, imported: false,
                runtime: descriptor.runtime,
                architecture: descriptor.runtime == .whisper ? nil : try? Self.ggufArchitecture(url))
        }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where url.pathExtension == "json"
            && (matchingID == nil || url.deletingPathExtension().lastPathComponent == matchingID)
        {
            guard let record = try? readRecord(id: url.deletingPathExtension().lastPathComponent),
                let stamp = try? Self.fingerprint(importURL(record.id, runtime: record.runtime ?? .whisper)),
                stamp.size == record.sizeBytes,
                (try? Self.validateHeader(
                    importURL(record.id, runtime: record.runtime ?? .whisper), runtime: record.runtime ?? .whisper))
                    != nil
            else { continue }
            result.append(
                InstalledLocalModel(
                    id: record.id, name: record.name, url: importURL(record.id, runtime: record.runtime ?? .whisper),
                    sizeBytes: stamp.size, imported: true, runtime: record.runtime ?? .whisper,
                    architecture: (record.runtime ?? .whisper) == .whisper
                        ? nil : try? Self.ggufArchitecture(importURL(record.id, runtime: record.runtime ?? .whisper))))
        }
        return result
    }

    func modelURL(id: String) throws -> URL {
        let url: URL, expectedSize: Int64, expectedHash: String
        if let descriptor = descriptors.first(where: { $0.id == id }) {
            url = directory.appendingPathComponent(descriptor.fileName)
            expectedSize = descriptor.sizeBytes
            expectedHash = descriptor.sha256
        } else {
            let record = try readRecord(id: id)
            url = importURL(id, runtime: record.runtime ?? .whisper)
            expectedSize = record.sizeBytes
            expectedHash = record.sha256
        }
        let stamp = try Self.fingerprint(url)
        guard stamp.size == expectedSize else { throw ModelLibraryError.invalidSize }
        if verified[id] != stamp {
            try Self.validateHeader(url, runtime: runtime(id: id))
            guard try Self.digest(url) == expectedHash else { throw ModelLibraryError.invalidHash }
            verified[id] = stamp
        }
        return url
    }

    func acquireModel(id: String) throws -> URL {
        let url = try modelURL(id: id)
        leases[id, default: 0] += 1
        return url
    }
    func releaseModel(id: String) { leases[id] = max(0, (leases[id] ?? 0) - 1) }

    func download(id: String, progress: @escaping @Sendable (ModelDownloadProgress) -> Void = { _ in }) async throws
        -> InstalledLocalModel
    {
        guard let model = descriptors.first(where: { $0.id == id }) else { throw ModelLibraryError.unknownModel }
        guard !downloads.contains(id) else { throw ModelLibraryError.busy }
        downloads.insert(id)
        defer { downloads.remove(id) }
        try Task.checkCancellation()
        if let existing = try? modelURL(id: id) {
            progress(
                ModelDownloadProgress(
                    modelID: id, phase: .ready, fraction: 1, downloadedBytes: model.sizeBytes,
                    totalBytes: model.sizeBytes))
            return InstalledLocalModel(
                id: id, name: model.name, url: existing, sizeBytes: model.sizeBytes, imported: false,
                runtime: model.runtime)
        }
        guard (leases[id] ?? 0) == 0 else { throw ModelLibraryError.inUse }
        try prepareDirectory()
        try ModelFileIO.checkDestination(directory.appendingPathComponent(model.fileName))
        let staging = directory.appendingPathComponent(
            fetcher == nil ? ".partial-" + model.sha256 : ".download-\(UUID().uuidString)")
        var keepPartial = fetcher == nil
        defer { if !keepPartial || Task.isCancelled { try? ModelFileIO.remove(staging) } }
        let downloader = LocalModelDownload()
        do {
            let report: @Sendable (Int64) -> Void = { bytes in
                progress(
                    ModelDownloadProgress(
                        modelID: id, phase: .downloading,
                        fraction: min(1, Double(bytes) / Double(model.sizeBytes)), downloadedBytes: bytes,
                        totalBytes: model.sizeBytes))
            }
            if let fetcher {
                _ = try await fetcher(model.downloadURL, staging, model.sizeBytes, report)
            } else {
                _ = try await downloader.fetch(
                    url: model.downloadURL, destination: staging, expected: model.sizeBytes, progress: report)
            }
        } catch is CancellationError { throw CancellationError() } catch {
            if Task.isCancelled { throw CancellationError() }
            if (error as? ModelLibraryError) == .invalidSize { keepPartial = false }
            throw ModelLibraryError.downloadFailure(error)
        }
        try Task.checkCancellation()
        keepPartial = false
        progress(
            ModelDownloadProgress(
                modelID: id, phase: .verifying, fraction: nil, downloadedBytes: model.sizeBytes,
                totalBytes: model.sizeBytes))
        let stamp = try Self.fingerprint(staging)
        guard stamp.size == model.sizeBytes else { throw ModelLibraryError.invalidSize }
        try Self.validateHeader(staging, runtime: model.runtime)
        guard try Self.digest(staging) == model.sha256 else { throw ModelLibraryError.invalidHash }
        try Task.checkCancellation()
        let target = directory.appendingPathComponent(model.fileName)
        // A concurrent import may have installed/acquired this same model while
        // the network request was suspended. Reuse a valid file without mutation.
        if let existing = try? modelURL(id: id) {
            progress(
                ModelDownloadProgress(
                    modelID: id, phase: .ready, fraction: 1, downloadedBytes: model.sizeBytes,
                    totalBytes: model.sizeBytes))
            return InstalledLocalModel(
                id: id, name: model.name, url: existing, sizeBytes: model.sizeBytes, imported: false,
                runtime: model.runtime)
        }
        guard (leases[id] ?? 0) == 0 else { throw ModelLibraryError.inUse }
        try ModelFileIO.publish(staging, to: target)
        if Task.isCancelled {
            try? ModelFileIO.remove(target)
            throw CancellationError()
        }
        verified[id] = try Self.fingerprint(target)
        progress(
            ModelDownloadProgress(
                modelID: id, phase: .ready, fraction: 1, downloadedBytes: model.sizeBytes, totalBytes: model.sizeBytes))
        return InstalledLocalModel(
            id: id, name: model.name, url: target, sizeBytes: model.sizeBytes, imported: false, runtime: model.runtime)
    }

    func importModel(from source: URL, expectedTask: ModelTask? = nil) async throws -> InstalledLocalModel {
        try Task.checkCancellation()
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let info = try Self.preflightImport(source, expectedTask: expectedTask)
        let stamp = try Self.fingerprint(source)
        let hash = try Self.digest(source)
        try Task.checkCancellation()
        try prepareDirectory()
        if let model = descriptors.first(where: {
            $0.sha256 == hash && $0.sizeBytes == stamp.size && $0.runtime == info.runtime
        }) {
            let target = directory.appendingPathComponent(model.fileName)
            try copyVerified(
                source: source, target: target, expectedHash: hash, expectedSize: stamp.size, runtime: info.runtime,
                modelID: model.id)
            verified[model.id] = try Self.fingerprint(target)
            return InstalledLocalModel(
                id: model.id, name: model.name, url: target, sizeBytes: stamp.size, imported: false,
                runtime: model.runtime)
        }
        // Audio GGUFs embed companion files. Only verified catalog artifacts
        // reach the unpacking runtime; arbitrary imported embedded paths do not.
        guard info.runtime != .audioSpeech else { throw ModelLibraryError.invalidFormat }
        let id = "import-" + hash.prefix(24)
        let target = importURL(id, runtime: info.runtime)
        let hadOwnedFile = FileManager.default.fileExists(atPath: target.path)
        try copyVerified(
            source: source, target: target, expectedHash: hash, expectedSize: stamp.size, runtime: info.runtime,
            modelID: id)
        let rawName = source.deletingPathExtension().lastPathComponent
        let name = String(rawName.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(100))
        let record = ImportRecord(
            id: id, name: name.isEmpty ? L10n.tr("Imported local model") : name, sizeBytes: stamp.size, sha256: hash,
            runtime: info.runtime)
        do {
            try JSONEncoder().encode(record).write(to: directory.appendingPathComponent(id + ".json"), options: .atomic)
            verified[id] = try Self.fingerprint(target)
        } catch {
            // A metadata failure must not delete a model that existed before
            // this import, especially when its identical bytes are leased.
            if !hadOwnedFile { try? ModelFileIO.remove(target) }
            throw error
        }
        return InstalledLocalModel(
            id: id, name: record.name, url: target, sizeBytes: stamp.size, imported: true, runtime: info.runtime)
    }

    func remove(id: String) throws {
        guard (leases[id] ?? 0) == 0 else { throw ModelLibraryError.inUse }
        guard !downloads.contains(id) else { throw ModelLibraryError.busy }
        let url: URL
        if let model = descriptors.first(where: { $0.id == id }) {
            url = directory.appendingPathComponent(model.fileName)
        } else {
            let record = try readRecord(id: id)
            url = importURL(id, runtime: record.runtime ?? .whisper)
        }
        try ModelFileIO.remove(url)
        if id.hasPrefix("import-") { try? ModelFileIO.remove(directory.appendingPathComponent(id + ".json")) }
        verified.removeValue(forKey: id)
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    private func importURL(_ id: String, runtime: LocalASRRuntime) -> URL {
        let canonical = directory.appendingPathComponent(id + (runtime == .whisper ? ".bin" : ".gguf"))
        // Early local-text imports used the legacy Whisper extension. Continue
        // reading their existing owned files in place, including while leased.
        if runtime == .llama, !FileManager.default.fileExists(atPath: canonical.path) {
            let legacy = directory.appendingPathComponent(id + ".bin")
            if FileManager.default.fileExists(atPath: legacy.path) { return legacy }
        }
        return canonical
    }
    private func readRecord(id: String) throws -> ImportRecord {
        guard id.range(of: "^import-[a-f0-9]{24}$", options: .regularExpression) != nil else {
            throw ModelLibraryError.unknownModel
        }
        let url = directory.appendingPathComponent(id + ".json")
        guard let size = try? Self.fingerprint(url).size, size < 4096,
            let record = try? JSONDecoder().decode(ImportRecord.self, from: Data(contentsOf: url)),
            record.id == id, record.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
            id == "import-" + record.sha256.prefix(24)
        else { throw ModelLibraryError.unavailable }
        return record
    }
    private func copyVerified(
        source: URL, target: URL, expectedHash: String, expectedSize: Int64, runtime: LocalASRRuntime, modelID: String
    ) throws {
        try ModelFileIO.checkDestination(target)
        if source.standardizedFileURL == target.standardizedFileURL {
            guard try Self.fingerprint(target).size == expectedSize else { throw ModelLibraryError.invalidSize }
            try Self.validateHeader(target, runtime: runtime)
            guard try Self.digest(target) == expectedHash else { throw ModelLibraryError.invalidHash }
            return
        }
        if (try? Self.fingerprint(target).size) == expectedSize,
            (try? Self.validateHeader(target, runtime: runtime)) != nil,
            (try? Self.digest(target)) == expectedHash
        {
            return
        }
        try Task.checkCancellation()
        guard (leases[modelID] ?? 0) == 0 else { throw ModelLibraryError.inUse }
        let temporary = directory.appendingPathComponent(".import-\(UUID().uuidString)")
        defer { try? ModelFileIO.remove(temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        try Task.checkCancellation()
        guard try Self.fingerprint(temporary).size == expectedSize else { throw ModelLibraryError.invalidSize }
        try Self.validateHeader(temporary, runtime: runtime)
        guard try Self.digest(temporary) == expectedHash else { throw ModelLibraryError.invalidHash }
        try ModelFileIO.publish(temporary, to: target)
    }
    private static func fingerprint(_ url: URL) throws -> Fingerprint {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let size = (attributes[.size] as? NSNumber)?.int64Value,
            let modified = attributes[.modificationDate] as? Date
        else { throw ModelLibraryError.unavailable }
        return Fingerprint(
            size: size, modified: modified, inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)
    }
    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func validateHeader(_ url: URL, runtime: LocalASRRuntime = .whisper) throws {
        _ = try fingerprint(url)
        if runtime != .whisper {
            let allowed: [String]
            switch runtime {
            case .transcribe: allowed = ["qwen3_asr", "parakeet", "sensevoice", "cohere_asr"]
            case .llama: allowed = ["qwen3", "gemma3", "hunyuan-dense"]
            case .audioSpeech: allowed = ["audiocpp"]
            case .whisper: allowed = []
            }
            let architecture = try ggufArchitecture(url)
            guard allowed.contains(architecture) else { throw ModelLibraryError.invalidFormat }
            if runtime == .llama && architecture == "gemma3" {
                // Some runtime-specific GGUFs use this family name but omit
                // required text-model metadata. Reject them before copying or
                // presenting an import as ready; do not invent model defaults.
                let epsilon = "gemma3.attention.layer_norm_rms_epsilon"
                let dimensions = [
                    "gemma3.block_count", "gemma3.context_length", "gemma3.embedding_length",
                    "gemma3.attention.head_count", "gemma3.attention.head_count_kv"
                ]
                let metadata = try ggufMetadata(url, keys: Set(dimensions + [epsilon]))
                guard case .scalar(type: 6, bits: let bits) = metadata[epsilon],
                    Float(bitPattern: UInt32(bits)).isFinite, Float(bitPattern: UInt32(bits)) > 0
                else {
                    throw ModelLibraryError.invalidFormat
                }
                for key in dimensions {
                    guard case .scalar(type: 4, bits: let size) = metadata[key], size > 0 else {
                        throw ModelLibraryError.invalidFormat
                    }
                }
            }
            return
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard let data = try file.read(upToCount: 48), data.count == 48 else { throw ModelLibraryError.invalidFormat }
        func int(_ offset: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << (8 * $1) } }
        guard int(0) == 0x67676d6c, (50_000...52_000).contains(int(4)), int(8) == 1500,
            [384, 512, 768, 1024, 1280].contains(int(12)), int(16) > 0, int(16) <= 32,
            [4, 6, 12, 24, 32].contains(int(20)), int(24) == 448, int(28) == int(12),
            int(32) > 0, int(32) <= 32, [4, 6, 12, 24, 32].contains(int(36)),
            [80, 128].contains(int(40))
        else { throw ModelLibraryError.invalidFormat }
    }
    static func ggufArchitecture(_ url: URL) throws -> String {
        guard
            case .text(let architecture) = try ggufMetadata(url, keys: ["general.architecture"])["general.architecture"]
        else {
            throw ModelLibraryError.invalidFormat
        }
        return architecture
    }
    private enum GGUFMetadataValue { case text(String), scalar(type: UInt64, bits: UInt64) }
    private static func ggufMetadata(_ url: URL, keys: Set<String>) throws -> [String: GGUFMetadataValue] {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard let data = try file.read(upToCount: 1_048_576), data.count >= 24 else {
            throw ModelLibraryError.invalidFormat
        }
        var cursor = 0
        func number(_ bytes: Int) throws -> UInt64 {
            guard cursor <= data.count - bytes else { throw ModelLibraryError.invalidFormat }
            defer { cursor += bytes }
            return (0..<bytes).reduce(UInt64(0)) { $0 | UInt64(data[cursor + $1]) << (8 * $1) }
        }
        func string() throws -> String {
            let length = try number(8)
            guard length <= 65_536, length <= UInt64(data.count - cursor),
                let value = String(data: data[cursor..<(cursor + Int(length))], encoding: .utf8)
            else { throw ModelLibraryError.invalidFormat }
            cursor += Int(length)
            return value
        }
        func skip(_ type: UInt64, depth: Int = 0) throws {
            guard depth < 4 else { throw ModelLibraryError.invalidFormat }
            if type == 8 {
                _ = try string()
                return
            }
            if type == 9 {
                let itemType = try number(4), count = try number(8)
                guard count <= 100_000 else { throw ModelLibraryError.invalidFormat }
                for _ in 0..<Int(count) { try skip(itemType, depth: depth + 1) }
                return
            }
            let sizes: [UInt64: Int] = [0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8]
            guard let size = sizes[type] else { throw ModelLibraryError.invalidFormat }
            _ = try number(size)
        }
        guard try number(4) == 0x46554747, try number(4) == 3 else { throw ModelLibraryError.invalidFormat }
        let tensors = try number(8), metadata = try number(8)
        guard tensors > 0, tensors <= 1_000_000, metadata > 0, metadata <= 10_000 else {
            throw ModelLibraryError.invalidFormat
        }
        var values: [String: GGUFMetadataValue] = [:]
        for _ in 0..<Int(metadata) {
            let key = try string(), type = try number(4)
            if keys.contains(key) {
                guard values[key] == nil else { throw ModelLibraryError.invalidFormat }
                if type == 8 {
                    values[key] = .text(try string())
                } else {
                    let sizes: [UInt64: Int] = [0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8]
                    guard let size = sizes[type] else { throw ModelLibraryError.invalidFormat }
                    values[key] = .scalar(type: type, bits: try number(size))
                }
                if values.count == keys.count { return values }
            } else {
                try skip(type)
            }
        }
        throw ModelLibraryError.invalidFormat
    }

}
