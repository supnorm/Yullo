import Foundation
import Darwin

// This runner never invokes a shell. A separate process group owns every child,
// so cancellation also closes helpers that inherited the child's output pipes.
struct CLISubprocessResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
    var protocolCompleted = false
}

// Nonblocking producer side of a tracked child's stdin. The worker owns at most
// one additional frame while writing it. Admission never waits for pipe I/O.
final class CLISubprocessInput: @unchecked Sendable {
    private let lock = NSLock()
    private let byteLimit: Int
    private var frames: [Data] = []
    private var head = 0
    private var bytes = 0
    private var closed = false
    // A byte here wakes the worker's poll as soon as a frame or close arrives,
    // so a warm helper's request is written at once rather than at the next tick.
    private var wake: [Int32] = [-1, -1]
    init(byteLimit: Int = 131_072) {
        self.byteLimit = max(1, byteLimit)
        if pipe(&wake) == 0 {
            for fd in wake {
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            }
            _ = fcntl(wake[1], F_SETNOSIGPIPE, 1)
        } else {
            wake = [-1, -1]
        }
    }
    deinit { for fd in wake where fd >= 0 { Darwin.close(fd) } }
    @discardableResult func send(_ data: Data) -> Bool {
        lock.lock()
        guard !closed, !data.isEmpty, data.count <= byteLimit - bytes else {
            lock.unlock()
            return false
        }
        frames.append(data)
        bytes += data.count
        lock.unlock()
        signal()
        return true
    }
    func close() {
        lock.lock()
        closed = true
        lock.unlock()
        signal()
    }
    private func signal() {
        guard wake[1] >= 0 else { return }
        var byte: UInt8 = 1
        _ = write(wake[1], &byte, 1)
    }
    fileprivate var wakeDescriptor: Int32 { wake[0] }
    fileprivate func drainWake() {
        guard wake[0] >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 64)
        while read(wake[0], &buffer, buffer.count) > 0 {}
    }
    fileprivate var hasPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed || head < frames.count
    }
    fileprivate func next() -> (data: Data?, closed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard head < frames.count else { return (nil, closed) }
        let data = frames[head]
        frames[head] = Data()
        head += 1
        bytes -= data.count
        if head == frames.count {
            frames.removeAll(keepingCapacity: true)
            head = 0
        } else if head > 64 && head > frames.count / 2 {
            frames.removeFirst(head)
            head = 0
        }
        return (data, false)
    }
}

enum CLISubprocess {
    private static let registry = CLISubprocessRegistry()

    // Callers that own temporary request directories keep this scope until
    // their existing cleanup defer has run. Shutdown can then wait for context
    // cleanup as well as the child process, without blocking the main thread.
    static func beginRequest() throws -> CLISubprocessRequest {
        let id = try registry.begin()
        return CLISubprocessRequest { registry.finish(id) }
    }

    @discardableResult static func beginShutdown() -> Bool { registry.beginShutdown() }
    static func shutdownAndWait() async {
        await withCheckedContinuation { continuation in registry.waitForShutdown(continuation) }
    }

    static func run(
        executable: URL, arguments: [String], input: Data = Data(),
        directory: URL, environment: [String: String], timeout: TimeInterval,
        stdoutLimit: Int = 1_048_576, stderrLimit: Int = 65_536,
        completedOutput: (@Sendable (Data) throws -> Bool)? = nil
    ) async throws -> CLISubprocessResult {
        try Task.checkCancellation()
        let cancellation = CLICancellation()
        let request = try registry.begin(cancellation: cancellation)
        defer { registry.finish(request) }
        return try await withTaskCancellationHandler(
            operation: {
                try Task.checkCancellation()
                try cancellation.check()
                let result = try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(
                            with: Result {
                                try execute(
                                    executable: executable, arguments: arguments, input: input,
                                    directory: directory, environment: environment, timeout: timeout,
                                    stdoutLimit: stdoutLimit, stderrLimit: stderrLimit,
                                    completedOutput: completedOutput,
                                    cancellation: cancellation, request: request)
                            })
                    }
                }
                try Task.checkCancellation()
                try cancellation.check()
                return result
            }, onCancel: { cancellation.cancel() })
    }

    // stdout is delivered in small chunks and never accumulated. The consumer
    // must bound its own message framing; stderr retains the ordinary hard cap.
    static func runStreaming(
        executable: URL, arguments: [String], input: CLISubprocessInput,
        directory: URL, environment: [String: String], timeout: TimeInterval,
        stderrLimit: Int = 65_536,
        stdoutChunk: @escaping @Sendable (Data) throws -> Void
    ) async throws -> CLISubprocessResult {
        try Task.checkCancellation()
        let cancellation = CLICancellation()
        let request = try registry.begin(cancellation: cancellation)
        defer {
            input.close()
            registry.finish(request)
        }
        return try await withTaskCancellationHandler(
            operation: {
                try Task.checkCancellation()
                try cancellation.check()
                let result = try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(
                            with: Result {
                                try execute(
                                    executable: executable, arguments: arguments, input: Data(),
                                    directory: directory, environment: environment, timeout: timeout,
                                    stdoutLimit: 0, stderrLimit: stderrLimit, streamingInput: input,
                                    stdoutChunk: stdoutChunk, cancellation: cancellation, request: request)
                            })
                    }
                }
                try Task.checkCancellation()
                try cancellation.check()
                return result
            },
            onCancel: {
                input.close()
                cancellation.cancel()
            })
    }

    private static func execute(
        executable: URL, arguments: [String], input: Data,
        directory: URL, environment: [String: String], timeout: TimeInterval,
        stdoutLimit: Int, stderrLimit: Int,
        streamingInput: CLISubprocessInput? = nil,
        stdoutChunk: (@Sendable (Data) throws -> Void)? = nil,
        completedOutput: (@Sendable (Data) throws -> Bool)? = nil,
        cancellation: CLICancellation, request: UUID
    ) throws -> CLISubprocessResult {
        guard !cancellation.isCancelled else { throw CancellationError() }
        var inputPipe = [Int32](repeating: -1, count: 2)
        var outputPipe = [Int32](repeating: -1, count: 2)
        var errorPipe = [Int32](repeating: -1, count: 2)
        guard pipe(&inputPipe) == 0 else { throw CLIError.launchFailed }
        defer { closeDescriptors(inputPipe) }
        guard pipe(&outputPipe) == 0 else { throw CLIError.launchFailed }
        defer { closeDescriptors(outputPipe) }
        guard pipe(&errorPipe) == 0 else { throw CLIError.launchFailed }
        defer { closeDescriptors(errorPipe) }
        for fd in inputPipe + outputPipe + errorPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        // F_SETNOSIGPIPE is per descriptor: a CLI that closes stdin cannot crash
        // Yullo with SIGPIPE, and we do not change the app's signal handlers.
        _ = fcntl(inputPipe[1], F_SETNOSIGPIPE, 1)

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw CLIError.launchFailed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw CLIError.launchFailed }
        defer { posix_spawnattr_destroy(&attributes) }
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGTERM)
        guard posix_spawn_file_actions_adddup2(&actions, inputPipe[0], STDIN_FILENO) == 0,
            posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO) == 0,
            posix_spawn_file_actions_adddup2(&actions, errorPipe[1], STDERR_FILENO) == 0,
            posix_spawn_file_actions_addchdir(&actions, directory.path) == 0,
            posix_spawnattr_setpgroup(&attributes, 0) == 0,
            // The app's DispatchSource bridge ignores SIGTERM at the POSIX
            // layer. CLI/helper children retain normal signal semantics.
            posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0,
            posix_spawnattr_setflags(
                &attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF)) == 0
        else { throw CLIError.launchFailed }

        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in argv + envp { if let pointer { free(pointer) } } }
        guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil }) else {
            throw CLIError.launchFailed
        }
        let pid = try registry.spawn(request) {
            var pid: pid_t = 0
            let code = argv.withUnsafeBufferPointer { args in
                envp.withUnsafeBufferPointer { env in
                    posix_spawn(
                        &pid, executable.path, &actions, &attributes,
                        UnsafeMutablePointer(mutating: args.baseAddress!),
                        UnsafeMutablePointer(mutating: env.baseAddress!))
                }
            }
            guard code == 0, pid > 0 else { throw CLIError.launchFailed }
            return pid
        }
        close(inputPipe[0])
        inputPipe[0] = -1
        close(outputPipe[1])
        outputPipe[1] = -1
        close(errorPipe[1])
        errorPipe[1] = -1
        for fd in [inputPipe[1], outputPipe[0], errorPipe[0]] {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }

        var reaped = false
        var processStatus: Int32 = 0
        defer { registry.cleanupProcess(request, pid: pid) }
        var deadline = ProcessInfo.processInfo.systemUptime + max(0.05, timeout)
        var protocolCompleted = false
        var checkedOutputCount = 0
        var output = Data(), errors = Data(), inputOffset = 0
        var pendingInput = input
        var outputEOF = false, errorEOF = false
        var buffer = [UInt8](repeating: 0, count: 16_384)

        func readAvailable(
            _ fd: Int32, into data: inout Data, eof: inout Bool, limit: Int,
            chunk: (@Sendable (Data) throws -> Void)? = nil
        ) throws {
            var reads = 0
            while !eof && reads < 16 {
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    reads += 1
                    if let chunk {
                        try chunk(Data(buffer[0..<count]))
                    } else {
                        guard count <= limit - data.count else { throw CLIError.outputTooLarge }
                        data.append(contentsOf: buffer[0..<count])
                    }
                } else if count == 0 {
                    eof = true
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    break
                } else {
                    throw CLIError.launchFailed
                }
            }
        }

        while true {
            if cancellation.isCancelled { throw CancellationError() }
            if ProcessInfo.processInfo.systemUptime >= deadline { throw CLIError.timedOut }
            if inputPipe[1] >= 0 {
                if let streamingInput, inputOffset == pendingInput.count {
                    let next = streamingInput.next()
                    pendingInput = next.data ?? Data()
                    inputOffset = 0
                    if next.closed {
                        close(inputPipe[1])
                        inputPipe[1] = -1
                    }
                } else if streamingInput == nil && inputOffset == pendingInput.count {
                    close(inputPipe[1])
                    inputPipe[1] = -1
                }
                if inputPipe[1] >= 0 && inputOffset < pendingInput.count {
                    let count = pendingInput.withUnsafeBytes { bytes in
                        write(
                            inputPipe[1], bytes.baseAddress!.advanced(by: inputOffset), pendingInput.count - inputOffset
                        )
                    }
                    if count > 0 {
                        inputOffset += count
                    } else if count < 0 && errno == EPIPE {
                        close(inputPipe[1])
                        inputPipe[1] = -1
                    } else if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                        throw CLIError.launchFailed
                    }
                }
                if streamingInput == nil && inputOffset == pendingInput.count && inputPipe[1] >= 0 {
                    close(inputPipe[1])
                    inputPipe[1] = -1
                }
            }
            try readAvailable(outputPipe[0], into: &output, eof: &outputEOF, limit: stdoutLimit, chunk: stdoutChunk)
            try readAvailable(errorPipe[0], into: &errors, eof: &errorEOF, limit: stderrLimit)
            if !reaped {
                if let status = try registry.completedProcess(request, pid: pid) {
                    processStatus = status
                    reaped = true
                }
            }
            if reaped && outputEOF && errorEOF {
                // Drain and validate again: queued trailing bytes cannot be hidden
                // by an earlier protocol receipt. Cancellation still wins.
                try cancellation.check()
                if protocolCompleted {
                    guard try completedOutput?(output) == true else { throw CLIError.invalidResponse }
                    try cancellation.check()
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw CLIError.timedOut }
                }
                let status: Int32 = (processStatus & 0x7f) == 0 ? (processStatus >> 8) & 0xff : -1
                return CLISubprocessResult(
                    status: status, stdout: output, stderr: errors, protocolCompleted: protocolCompleted)
            }
            if !reaped, let completedOutput, output.count != checkedOutputCount {
                checkedOutputCount = output.count
                if try completedOutput(output) {
                    try cancellation.check()
                    guard ProcessInfo.processInfo.systemUptime < deadline else { throw CLIError.timedOut }
                    let completion = try registry.finishCompletedProtocol(request, pid: pid)
                    processStatus = completion.status
                    protocolCompleted = completion.interruptedAfterCompletion
                    reaped = true
                    // Owned descendants have been stopped. A detached process
                    // holding a pipe cannot keep completion waiting indefinitely.
                    deadline = min(deadline, ProcessInfo.processInfo.systemUptime + 0.5)
                    try cancellation.check()
                }
            }
            let inputReady = inputOffset < pendingInput.count || (streamingInput?.hasPending ?? false)
            var descriptors = [
                pollfd(fd: outputEOF ? -1 : outputPipe[0], events: Int16(POLLIN), revents: 0),
                pollfd(fd: errorEOF ? -1 : errorPipe[0], events: Int16(POLLIN), revents: 0),
                pollfd(fd: inputReady ? inputPipe[1] : -1, events: Int16(POLLOUT), revents: 0),
                pollfd(
                    fd: inputPipe[1] >= 0 ? streamingInput?.wakeDescriptor ?? -1 : -1, events: Int16(POLLIN),
                    revents: 0)
            ]
            _ = poll(&descriptors, nfds_t(descriptors.count), 20)
            streamingInput?.drainWake()
        }
    }

    private static func closeDescriptors(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 { close(descriptor) }
    }
}

// A `--serve` helper keeps one verified model loaded for a sequence of
// independent requests: one JSON line in, one JSON line out over private pipes.
// The owner serializes requests and reuses a helper only for the same identity.
// Stopping kills the process group; its private directory is removed after exit.
final class CLIServeHelper: @unchecked Sendable {
    let identity: String
    let directory: URL
    private let lock = NSLock()
    private let input: CLISubprocessInput
    private var task: Task<Void, Never>?
    private var buffer = Data()
    private var waiter: CheckedContinuation<Data, Error>?
    private var stopped = false

    init(identity: String, directory: URL, inputLimit: Int = 262_144) {
        self.identity = identity
        self.directory = directory
        input = CLISubprocessInput(byteLimit: inputLimit)
    }
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
    var isRunning: Bool { locked { !stopped } }

    // Path, size, modification date and file number of a verified model file.
    static func fileIdentity(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = (attributes[.size] as? NSNumber)?.int64Value,
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate,
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        else { return nil }
        return "\(url.path)\n\(size)\n\(modified)\n\(inode)"
    }

    // Creates the private working directory (mode 0700) and starts the helper.
    func launch(executable: URL, arguments: [String], environment: [String: String]) throws {
        let scope = try CLISubprocess.beginRequest()
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch {
            scope.finish()
            throw error
        }
        let worker = Task.detached(priority: .userInitiated) { [self] in
            _ = try? await CLISubprocess.runStreaming(
                executable: executable, arguments: arguments, input: input, directory: directory,
                environment: environment, timeout: 86_400, stderrLimit: 65_536,
                stdoutChunk: { [self] data in try receive(data) })
            try? FileManager.default.removeItem(at: directory)
            scope.finish()
            let pending = locked { () -> CheckedContinuation<Data, Error>? in
                stopped = true
                defer { waiter = nil }
                return waiter
            }
            pending?.resume(throwing: CLIError.executionFailed)
        }
        locked { task = worker }
    }

    // One response line at a time. The caller serializes requests.
    private func receive(_ data: Data) throws {
        var lines: [(CheckedContinuation<Data, Error>, Data)] = []
        let valid = locked { () -> Bool in
            buffer.append(data)
            while let end = buffer.firstIndex(of: 10) {
                guard let waiter else { return false }
                lines.append((waiter, Data(buffer[buffer.startIndex..<end])))
                self.waiter = nil
                buffer.removeSubrange(buffer.startIndex...end)
            }
            return buffer.count <= 1_048_576
        }
        for (waiter, line) in lines { waiter.resume(returning: line) }
        guard valid else { throw CLIError.invalidResponse }
    }

    func request(_ data: Data, timeout: TimeInterval) async throws -> Data {
        guard !data.contains(10), !data.contains(13) else { throw CLIError.invalidResponse }
        let watchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            self?.stop()
        }
        defer { watchdog.cancel() }
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let admitted = locked { () -> Bool in
                        guard !stopped, waiter == nil, input.send(data + Data([10])) else { return false }
                        waiter = continuation
                        return true
                    }
                    if !admitted { continuation.resume(throwing: CLIError.executionFailed) }
                }
            } onCancel: {
                stop()
            }
        } catch {
            // A replacement starts only after this process and its directory are gone.
            await stopAndWait()
            throw error
        }
    }

    func stop() {
        input.close()
        locked { task }?.cancel()
    }
    func stopAndWait() async {
        stop()
        await locked { task }?.value
    }
}

// Finishing is idempotent, including explicit finish followed by deinit.
final class CLISubprocessRequest: @unchecked Sendable {
    private let finishRequest: () -> Void
    fileprivate init(_ finishRequest: @escaping () -> Void) { self.finishRequest = finishRequest }
    func finish() { finishRequest() }
    deinit { finish() }
}

private final class CLISubprocessRegistry: @unchecked Sendable {
    private struct Request { let cancellation: CLICancellation? }
    private let lock = NSLock()
    private var stopping = false
    private var requests: [UUID: Request] = [:]
    private var groups: [UUID: pid_t] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func begin(cancellation: CLICancellation? = nil) throws -> UUID {
        lock.lock()
        defer { lock.unlock() }
        guard !stopping else { throw CancellationError() }
        let id = UUID()
        requests[id] = Request(cancellation: cancellation)
        return id
    }
    func finish(_ id: UUID) {
        lock.lock()
        requests.removeValue(forKey: id)
        let ready = stopping && requests.isEmpty ? waiters : []
        if !ready.isEmpty { waiters.removeAll() }
        lock.unlock()
        for waiter in ready { waiter.resume() }
    }
    @discardableResult func beginShutdown() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        stopWhileLocked()
        return !requests.isEmpty
    }
    func waitForShutdown(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        stopWhileLocked()
        if requests.isEmpty {
            lock.unlock()
            continuation.resume()
        } else {
            waiters.append(continuation)
            lock.unlock()
        }
    }
    private func stopWhileLocked() {
        guard !stopping else { return }
        stopping = true
        for request in requests.values { request.cancellation?.cancel() }
        // Every stored group belongs to our own unreaped child. Spawn and
        // reaping use this same lock, so a reused PID can never be signalled.
        for pid in groups.values { _ = kill(-pid, SIGKILL) }
    }
    func spawn(_ id: UUID, _ body: () throws -> pid_t) throws -> pid_t {
        lock.lock()
        defer { lock.unlock() }
        guard !stopping, requests[id] != nil else { throw CancellationError() }
        let pid = try body()
        groups[id] = pid
        return pid
    }
    func completedProcess(_ id: UUID, pid: pid_t) throws -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard groups[id] == pid else { throw CLIError.launchFailed }
        // WNOWAIT keeps the exited child reserved while its remaining group is
        // killed. Reaping first would open a PID-reuse race with shutdown.
        var info = siginfo_t()
        let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        if result == -1 {
            if errno == EINTR { return nil }
            groups.removeValue(forKey: id)
            throw CLIError.launchFailed
        }
        guard info.si_pid == pid else { return nil }
        _ = kill(-pid, SIGKILL)
        var status: Int32 = 0
        var waited: pid_t
        repeat { waited = waitpid(pid, &status, 0) } while waited == -1 && errno == EINTR
        groups.removeValue(forKey: id)
        guard waited == pid else { throw CLIError.launchFailed }
        return status
    }
    func finishCompletedProtocol(_ id: UUID, pid: pid_t) throws
        -> (status: Int32, interruptedAfterCompletion: Bool)
    {
        lock.lock()
        defer { lock.unlock() }
        guard !stopping, groups[id] == pid else { throw CancellationError() }
        // Keep the child reserved until its group is stopped. Recheck natural
        // exit under this lock so a nonzero exit is never called protocol success.
        var info = siginfo_t()
        var result: Int32
        repeat {
            result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        } while result == -1 && errno == EINTR
        guard result == 0 else { throw CLIError.launchFailed }
        let wasRunning = info.si_pid != pid
        let stopped = kill(-pid, SIGKILL) == 0
        var status: Int32 = 0
        var waited: pid_t
        repeat { waited = waitpid(pid, &status, 0) } while waited == -1 && errno == EINTR
        groups.removeValue(forKey: id)
        guard waited == pid else { throw CLIError.launchFailed }
        return (status, wasRunning && stopped && (status & 0x7f) == SIGKILL)
    }

    func cleanupProcess(_ id: UUID, pid: pid_t) {
        lock.lock()
        guard groups.removeValue(forKey: id) == pid else {
            lock.unlock()
            return
        }
        // The child has not been reaped, so its PID still identifies this group.
        _ = kill(-pid, SIGKILL)
        lock.unlock()
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    }
}

private final class CLICancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
    func check() throws { if isCancelled { throw CancellationError() } }
}
