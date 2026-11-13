import Foundation
import Darwin

// Model paths own individual files. Never recursively remove an unexpected
// directory, and publish atomically without replacing directory contents.
enum ModelFileIO {
    static func checkDestination(_ url: URL) throws {
        var directory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue {
            throw ModelLibraryError.storageUnavailable
        }
    }
    static func remove(_ url: URL) throws {
        guard unlink(url.path) != 0 else { return }
        let code = POSIXErrorCode(rawValue: errno) ?? .EIO
        guard code != .ENOENT else { return }
        throw failure(code)
    }
    static func publish(_ source: URL, to destination: URL) throws {
        guard rename(source.path, destination.path) != 0 else { return }
        throw failure(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    private static func failure(_ code: POSIXErrorCode) -> Error {
        if code == .ENOSPC { return ModelLibraryError.storageFull }
        if [.EISDIR, .ENOTDIR, .EACCES, .EPERM, .EROFS, .ENOENT].contains(code) {
            return ModelLibraryError.storageUnavailable
        }
        return POSIXError(code)
    }
}

// Owned partial bytes are tied to a pinned artifact by ModelLibrary. Every retry
// starts at the immutable origin URL, never a persisted expiring CDN redirect.
final class LocalModelDownload {
    typealias AvailableCapacity = @Sendable (URL) -> Int64?
    private let availableCapacity: AvailableCapacity
    init(
        availableCapacity: @escaping AvailableCapacity = { destination in
            let values = try? destination.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey
            ])
            return values?.volumeAvailableCapacityForImportantUsage
                ?? values?.volumeAvailableCapacity.map { Int64($0) }
        }
    ) {
        self.availableCapacity = availableCapacity
    }
    func fetch(
        url: URL, destination: URL, expected: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL {
        for attempt in 0...1 {
            try Task.checkCancellation()
            do {
                return try await ModelTransfer(availableCapacity: availableCapacity).fetch(
                    url: url, destination: destination, expected: expected, progress: progress)
            } catch ModelTransferIssue.restart {
                try ModelFileIO.remove(destination)
                if attempt == 1 { throw ModelLibraryError.downloadFailed }
            }
        }
        throw ModelLibraryError.downloadFailed
    }
}
private enum ModelTransferIssue: Error { case restart }
private final class ModelTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let availableCapacity: LocalModelDownload.AvailableCapacity
    init(availableCapacity: @escaping LocalModelDownload.AvailableCapacity) {
        self.availableCapacity = availableCapacity
        super.init()
    }
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var file: FileHandle?
    private var destination: URL?
    private var expected: Int64 = 0
    private var written: Int64 = 0
    private var responseBytes: Int64?
    private var received: Int64 = 0
    private var onProgress: (@Sendable (Int64) -> Void)?
    private var cancelled = false, completed = false, acceptedResponse = false
    private var lastProgress: TimeInterval = 0

    func fetch(
        url: URL, destination: URL, expected: Int64,
        progress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL {
        try Task.checkCancellation()
        guard expected > 0 else { throw ModelLibraryError.invalidSize }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path) {
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                let size = (attributes[.size] as? NSNumber)?.int64Value, size >= 0, size <= expected
            else {
                throw ModelTransferIssue.restart
            }
        }
        let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            if [.EISDIR, .ENOTDIR, .EACCES, .EPERM, .EROFS].contains(code) {
                throw ModelLibraryError.storageUnavailable
            }
            throw POSIXError(code)
        }
        var identity = stat()
        guard fstat(descriptor, &identity) == 0,
            identity.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), identity.st_nlink == 1
        else {
            close(descriptor)
            throw ModelTransferIssue.restart
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let offset: UInt64
        do { offset = try handle.seekToEnd() } catch {
            try? handle.close()
            throw error
        }
        guard offset <= UInt64(expected) else {
            try? handle.close()
            throw ModelTransferIssue.restart
        }
        // Check the owned file's actual volume, counting only new bytes. An
        // unknown capacity keeps the normal write/ENOSPC path; no reserve or
        // guessed headroom blocks a download that can fit.
        let remaining = expected - Int64(offset)
        if remaining > 0, let available = availableCapacity(destination.resolvingSymlinksInPath()),
            available >= 0, available < remaining
        {
            try? handle.close()
            try Task.checkCancellation()
            throw ModelLibraryError.storageFull
        }
        if offset == UInt64(expected) {
            try handle.synchronize()
            try handle.close()
            progress(expected)
            return destination
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !cancelled else {
                    lock.unlock()
                    try? handle.close()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                self.destination = destination
                self.expected = expected
                self.file = handle
                self.written = Int64(offset)
                self.onProgress = progress
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 45
                config.timeoutIntervalForResource = 3600
                config.httpCookieStorage = nil
                config.urlCredentialStorage = nil
                config.urlCache = nil
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session
                var request = URLRequest(url: url)
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                progress(Int64(offset))
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }
    private func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
        finish(.failure(CancellationError()))
    }
    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard !completed, let continuation else {
            lock.unlock()
            return
        }
        completed = true
        self.continuation = nil
        let session = self.session, file = self.file
        self.session = nil
        self.task = nil
        self.file = nil
        self.onProgress = nil
        var outcome = result
        if case .success = result {
            do {
                try file?.synchronize()
                try file?.close()
            } catch {
                outcome = .failure(error)
                try? file?.close()
            }
        } else {
            try? file?.close()
        }
        lock.unlock()
        session?.invalidateAndCancel()
        continuation.resume(with: outcome)
    }
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard request.url?.scheme == "https", request.url?.user == nil, request.url?.password == nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        guard !completed, !cancelled, let http = response as? HTTPURLResponse else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        let status = http.statusCode
        var error: Error?
        if status == 200 {
            do {
                try file?.truncate(atOffset: 0)
                try file?.seek(toOffset: 0)
                written = 0
            } catch let failure { error = failure }
            if response.expectedContentLength >= 0, response.expectedContentLength != expected {
                error = ModelLibraryError.invalidSize
            }
            responseBytes = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
        } else if status == 206 {
            let raw = http.value(forHTTPHeaderField: "Content-Range") ?? ""
            let values = raw.dropFirst(6).split(whereSeparator: { $0 == "-" || $0 == "/" }).compactMap { Int64($0) }
            if raw.range(of: "^bytes [0-9]+-[0-9]+/[0-9]+$", options: .regularExpression) == nil || values.count != 3 {
                error = ModelTransferIssue.restart
            } else if values[0] != written || values[2] != expected || values[1] < values[0] || values[1] >= expected {
                error = ModelTransferIssue.restart
            } else {
                responseBytes = values[1] - values[0] + 1
                if response.expectedContentLength >= 0, response.expectedContentLength != responseBytes {
                    error = ModelTransferIssue.restart
                }
            }
        } else if status == 416 {
            error = ModelTransferIssue.restart
        } else {
            error = ModelLibraryError.downloadFailed
        }
        acceptedResponse = error == nil
        lock.unlock()
        if let error {
            completionHandler(.cancel)
            finish(.failure(error))
        } else {
            completionHandler(.allow)
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !completed, !cancelled, acceptedResponse else {
            lock.unlock()
            return
        }
        guard data.count <= expected - written, responseBytes.map({ Int64(data.count) <= $0 - received }) ?? true else {
            lock.unlock()
            finish(.failure(ModelLibraryError.invalidSize))
            return
        }
        do { try file?.write(contentsOf: data) } catch {
            lock.unlock()
            finish(.failure(error))
            return
        }
        written += Int64(data.count)
        received += Int64(data.count)
        let value = written, callback = onProgress
        let now = ProcessInfo.processInfo.systemUptime
        let emit = now - lastProgress >= 0.1 || written == expected
        if emit { lastProgress = now }
        lock.unlock()
        if emit { callback?(value) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let destination = self.destination, valid = acceptedResponse && written == expected
        lock.unlock()
        if let error {
            finish(.failure(error))
        } else if valid, let destination {
            finish(.success(destination))
        } else {
            finish(.failure(URLError(.networkConnectionLost)))
        }
    }
}
