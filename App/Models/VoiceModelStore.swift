import Foundation
import Combine

enum LocalModelDownloadOwner { case library, quickSetup }

struct LocalModelDownloadHandle {
    let modelID: String
    fileprivate let generation: UUID
    fileprivate let ownsDownload: Bool
}

@MainActor final class VoiceModelStore: ObservableObject {
    static let shared = VoiceModelStore()
    @Published private(set) var installed: [InstalledLocalModel] = []
    @Published private(set) var downloads: [String: ModelDownloadProgress] = [:]
    @Published private(set) var errors: [String: String] = [:]
    private var errorIDs: [String: UUID] = [:]
    @Published private(set) var message = ""
    @Published private(set) var importing = false
    private enum MessageOwner: Equatable { case inventory, modelImport }
    private var messageOwner: MessageOwner?
    private var jobIDs: [String: UUID] = [:]
    private var jobOwners: [String: LocalModelDownloadOwner] = [:]
    private var jobs: [String: Task<Void, Never>] = [:]
    private var revision = 0
    private let library: ModelLibrary
    init(library: ModelLibrary = VoiceResources.library) { self.library = library }
    // Callers keep their own read even when a newer refresh owns UI publication.
    @discardableResult func refresh() async -> [InstalledLocalModel] {
        revision += 1
        let expected = revision
        do {
            let values = try await library.installedModels()
            if expected == revision {
                installed = values
                if messageOwner == .inventory {
                    messageOwner = nil
                    message = ""
                }
            }
            return values
        } catch {
            if expected == revision {
                messageOwner = .inventory
                message = error.localizedDescription
            }
            return installed
        }
    }
    func download(_ id: String) { _ = startOrJoinDownload(id) }
    @discardableResult func startOrJoinDownload(_ id: String, owner: LocalModelDownloadOwner = .library)
        -> LocalModelDownloadHandle
    {
        if let generation = jobIDs[id] {
            return LocalModelDownloadHandle(modelID: id, generation: generation, ownsDownload: false)
        }
        setError(nil, for: id)
        let expected = UUID()
        jobIDs[id] = expected
        jobOwners[id] = owner
        downloads[id] = ModelDownloadProgress(
            modelID: id, phase: .downloading, fraction: 0, downloadedBytes: 0, totalBytes: nil)
        jobs[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.library.download(id: id) { [weak self] progress in
                    Task { @MainActor in
                        guard self?.jobIDs[id] == expected else { return }
                        self?.downloads[id] = progress
                    }
                }
                guard self.jobIDs[id] == expected else { return }
                self.jobs[id] = nil
                self.jobIDs[id] = nil
                self.jobOwners[id] = nil
                self.downloads[id] = nil
                await self.refresh()
            } catch {
                guard self.jobIDs[id] == expected else { return }
                self.jobs[id] = nil
                self.jobIDs[id] = nil
                self.jobOwners[id] = nil
                self.downloads[id] = nil
                if !(error is CancellationError) { self.setError(error.localizedDescription, for: id) }
            }
        }
        return LocalModelDownloadHandle(modelID: id, generation: expected, ownsDownload: true)
    }
    func cancel(_ id: String) { jobs[id]?.cancel() }
    func cancel(_ handle: LocalModelDownloadHandle) {
        guard canCancel(handle) else { return }
        jobs[handle.modelID]?.cancel()
    }
    // Waits for the job behind a handle, then reports whether its verified model
    // is installed now. A cancelled or failed job reports false.
    func waitForDownload(_ handle: LocalModelDownloadHandle) async -> Bool {
        if jobIDs[handle.modelID] == handle.generation, let job = jobs[handle.modelID] { await job.value }
        return await refresh().contains { $0.id == handle.modelID }
    }
    func canCancel(_ handle: LocalModelDownloadHandle) -> Bool {
        handle.ownsDownload && jobIDs[handle.modelID] == handle.generation
    }
    func activeDownloadHandles(ownedBy owner: LocalModelDownloadOwner) -> [LocalModelDownloadHandle] {
        jobIDs.compactMap { id, generation in
            guard jobOwners[id] == owner else { return nil }
            return LocalModelDownloadHandle(modelID: id, generation: generation, ownsDownload: true)
        }
    }
    func verifyModel(_ id: String) async throws { _ = try await library.modelURL(id: id) }
    func importModel(_ url: URL, task: ModelDiscoveryTask? = nil) {
        guard jobs["import"] == nil else { return }
        let priorErrors = errorIDs
        messageOwner = nil
        message = ""
        importing = true
        jobs["import"] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let imported = try await self.library.importModel(from: url, expectedTask: task)
                // Clear only the failure this import replaced, never a newer
                // operation whose error happens to have the same wording.
                if let prior = priorErrors[imported.id], self.errorIDs[imported.id] == prior {
                    self.setError(nil, for: imported.id)
                }
                await self.refresh()
            } catch {
                self.messageOwner = .modelImport
                self.message = error.localizedDescription
            }
            self.jobs["import"] = nil
            self.importing = false
        }
    }
    // An import failure answers that import; leaving the library clears it,
    // so a later visit doesn't show an old file's error.
    func dismissImportMessage() {
        guard messageOwner == .modelImport, !importing else { return }
        messageOwner = nil
        message = ""
    }
    func remove(_ id: String) {
        setError(nil, for: id)
        Task { @MainActor in
            do {
                try await library.remove(id: id)
                await refresh()
            } catch { setError(error.localizedDescription, for: id) }
        }
    }
    private func setError(_ value: String?, for id: String) {
        errorIDs[id] = value.map { _ in UUID() }
        errors[id] = value
    }
}
