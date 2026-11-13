import Foundation

enum ModelResourcePriority: Equatable, Sendable { case balanced, compact, quality }

struct ModelTaskNeeds: Sendable {
    let task: ModelTask
    var languageIDs: [String] = []
    var livePreview = false
    var priority = ModelResourcePriority.balanced
    var allowsRequiredLanguageHint = false
}

struct ModelHardwareProfile: Equatable, Sendable {
    enum Architecture: Equatable, Sendable { case appleSilicon, intel, unknown }
    let physicalMemoryBytes: UInt64?
    let availableDiskBytes: UInt64?
    let architecture: Architecture
    let availableRuntimes: [LocalModelRuntime]
    var liveRecognitionAvailable = true
    var unavailableModelIDs: [String] = []

    // File-system and volume-capacity queries take several milliseconds; Settings
    // pages read the profile off the main thread.
    static func load() async -> Self { await Task.detached(priority: .userInitiated) { current() }.value }
    static func current(bundleURL: URL = Bundle.main.bundleURL, storageURL: URL? = nil) -> Self {
        let manager = FileManager.default
        let paths: [(LocalModelRuntime, RuntimeHelper)] = [
            (.whisper, .whisper), (.transcribe, .transcribe), (.llama, .llama), (.audioSpeech, .speech)
        ]
        let runtimes = paths.compactMap { runtime, helper in
            manager.isExecutableFile(atPath: RuntimeHelper.url(helper, in: bundleURL).path) ? runtime : nil
        }
        var directory =
            storageURL
            ?? manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? manager.homeDirectoryForCurrentUser
        while !manager.fileExists(atPath: directory.path), directory.path != "/" {
            directory.deleteLastPathComponent()
        }
        let values = try? directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey
        ])
        let available =
            values?.volumeAvailableCapacityForImportantUsage
            ?? values?.volumeAvailableCapacity.map { Int64($0) }
        let disk = available.flatMap { $0 >= 0 ? UInt64($0) : nil }
        let resources = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        var unavailable: [String] = []
        if !manager.isReadableFile(atPath: resources.appendingPathComponent("LocalSpeech/espeak-ng-data.bin").path) {
            unavailable.append("kokoro-82m-q8")
        }
        if !manager.isReadableFile(atPath: resources.appendingPathComponent("Audio/YulloSampleVoice.wav").path) {
            unavailable.append("cosyvoice3-q8")
        }
        #if arch(arm64)
            let architecture = Architecture.appleSilicon
        #elseif arch(x86_64)
            let architecture = Architecture.intel
        #else
            let architecture = Architecture.unknown
        #endif
        return .init(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            availableDiskBytes: disk, architecture: architecture, availableRuntimes: runtimes,
            liveRecognitionAvailable: manager.isExecutableFile(
                atPath: RuntimeHelper.url(.liveTranscribe, in: bundleURL).path),
            unavailableModelIDs: unavailable)
    }
}

struct ModelHardwareCandidate: Sendable {
    let id: String
    let task: ModelTask
    let runtime: LocalModelRuntime
    let downloadBytes: Int64
    // Broad planning envelope, not a measured peak or an installation limit.
    let estimatedWorkingMemoryBytes: UInt64
    let languageIDs: [String]
    let supportsLivePreview: Bool
    var requiresLanguageHint = false
    let balancedRank: Int
    let qualityRank: Int
}

struct ModelHardwareRecommendation: Equatable, Sendable {
    enum Reason: Equatable, Sendable { case balanced, compact, quality, livePreview, languageCoverage }
    let modelID: String
    let reason: Reason
}

// A small deterministic suggestion over the existing reviewed catalog. This
// owner cannot install, select, read content or change a processing permission.
enum HardwareModelRecommendation {
    static let gib: UInt64 = 1_073_741_824

    static func recommend(
        needs: ModelTaskNeeds, profile: ModelHardwareProfile, candidates: [ModelHardwareCandidate],
        installedIDs: Set<String> = []
    ) -> ModelHardwareRecommendation? {
        let memory = profile.physicalMemoryBytes.flatMap { $0 > 0 ? $0 : nil }
        let budget = memory.map { $0 / 2 }
        let languages = Set(needs.languageIDs.compactMap { coverageID($0, task: needs.task) })
        let matching = candidates.filter { candidate in
            guard candidate.task == needs.task, candidate.runtime.task == needs.task,
                profile.availableRuntimes.contains(candidate.runtime), candidate.downloadBytes > 0,
                candidate.estimatedWorkingMemoryBytes > 0, !profile.unavailableModelIDs.contains(candidate.id)
            else { return false }
            if candidate.requiresLanguageHint && !needs.allowsRequiredLanguageHint { return false }
            if let budget, candidate.estimatedWorkingMemoryBytes > budget { return false }
            let supported = Set(candidate.languageIDs.compactMap { coverageID($0, task: needs.task) })
            guard languages.isSubset(of: supported) else { return false }
            if !installedIDs.contains(candidate.id), let disk = profile.availableDiskBytes {
                let (staging, overflow) = UInt64(candidate.downloadBytes).multipliedReportingOverflow(by: 2)
                let (required, overheadOverflow) = staging.addingReportingOverflow(256 * 1_024 * 1_024)
                if overflow || overheadOverflow || required > disk { return false }
            }
            return true
        }
        guard !matching.isEmpty else { return nil }
        let liveMatches = matching.filter {
            $0.supportsLivePreview && profile.liveRecognitionAvailable
        }
        let values = needs.livePreview && !liveMatches.isEmpty ? liveMatches : matching
        let compact = needs.priority == .compact || memory == nil
        let sorted = values.sorted { left, right in
            if compact {
                if left.estimatedWorkingMemoryBytes != right.estimatedWorkingMemoryBytes {
                    return left.estimatedWorkingMemoryBytes < right.estimatedWorkingMemoryBytes
                }
                if left.downloadBytes != right.downloadBytes { return left.downloadBytes < right.downloadBytes }
            }
            let lhs = needs.priority == .quality ? left.qualityRank : left.balancedRank
            let rhs = needs.priority == .quality ? right.qualityRank : right.balancedRank
            if lhs != rhs { return lhs > rhs }
            if left.downloadBytes != right.downloadBytes { return left.downloadBytes < right.downloadBytes }
            return left.id < right.id
        }
        guard let selected = sorted.first else { return nil }
        let reason: ModelHardwareRecommendation.Reason =
            needs.livePreview && !liveMatches.isEmpty
            ? .livePreview
            : compact
                ? .compact
                : needs.priority == .quality
                    ? .quality
                    : languages.isEmpty ? .balanced : .languageCoverage
        return .init(modelID: selected.id, reason: reason)
    }

    private static func coverageID(_ value: String, task: ModelTask) -> String? {
        let code = value.replacingOccurrences(of: "_", with: "-").lowercased()
        guard code != "auto", !code.isEmpty else { return nil }
        if code == "zh-hant" || code.hasPrefix("zh-tw") || code.hasPrefix("zh-hk") {
            return task == .translation ? "zh-Hant" : "zh"
        }
        if code == "zh" || code.hasPrefix("zh-hans") || code.hasPrefix("zh-cn") { return "zh" }
        return code.split(separator: "-").first.map(String.init)
    }
}

extension ModelDiscoveryCatalog {
    static let hardwareCatalog = hardwareCandidates(descriptors: ModelLibrary.catalog)
    // Whisper's published memory table establishes that download bytes are
    // not peak RAM. Other envelopes allow model state/activation overhead for
    // these fixed packages; they are approximate selection guidance only.
    // Ranks come from the cited ratings: balanced favors speed plus accuracy,
    // quality favors accuracy, and a task's maintainer pick leads balanced use.
    static func hardwareCandidates(descriptors: [LocalModelDescriptor] = ModelLibrary.catalog)
        -> [ModelHardwareCandidate]
    {
        let gib = HardwareModelRecommendation.gib
        let memory: [String: UInt64] = [
            "whisper-base-q5": gib, "whisper-small-q5": 2 * gib, "whisper-turbo-q5": 3 * gib,
            "whisper-turbo-q8": 4 * gib, "whisper-large-v3-q5": 5 * gib, "qwen3-asr-06b-q4": 3 * gib,
            "nemotron-35-q4": 3 * gib, "parakeet-v3-q4": 3 * gib, "sensevoice-small-q8": 2 * gib,
            "cohere-transcribe-q4": 6 * gib, "qwen3-asr-17b-q8": 5 * gib, "parakeet-ultra-q4": 3 * gib,
            "hy-mt2-18b-q4": 3 * gib,
            "qwen3-4b-instruct-q4": 6 * gib,
            "translategemma-4b-q4": 6 * gib, "kokoro-82m-q8": 2 * gib, "qwen3-tts-customvoice-q8": 7 * gib,
            "cosyvoice3-q8": 6 * gib
        ]
        return descriptors.compactMap { descriptor in
            guard let envelope = memory[descriptor.id], let rating = rating(for: descriptor.id),
                let entry = entries.first(where: {
                    $0.task == descriptor.task && $0.managedModelIDs.contains(descriptor.id)
                })
            else { return nil }
            return .init(
                id: descriptor.id, task: descriptor.task, runtime: descriptor.runtime,
                downloadBytes: descriptor.sizeBytes, estimatedWorkingMemoryBytes: envelope,
                languageIDs: entry.languageIDs,
                supportsLivePreview: [
                    "qwen3-asr-06b-q4", "nemotron-35-q4", "parakeet-v3-q4", "sensevoice-small-q8",
                    "cohere-transcribe-q4", "qwen3-asr-17b-q8", "parakeet-ultra-q4"
                ]
                .contains(descriptor.id), requiresLanguageHint: descriptor.id == "cohere-transcribe-q4",
                balancedRank: preferredModelIDs[descriptor.task] == descriptor.id
                    ? 1_000 : (rating.speed + rating.accuracy) * 10 + rating.accuracy,
                qualityRank: rating.accuracy * 10 + rating.speed)
        }
    }
}
