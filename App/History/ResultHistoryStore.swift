import Foundation
import SQLite3

typealias ResultHistoryRetention = CoreHistoryRetention

typealias ResultHistoryTask = CoreHistoryTask
typealias ResultHistoryFilter = CoreHistoryFilter
enum ResultHistoryDelivery: String, Sendable { case inserted, notInserted, uncertain }

struct ResultHistoryAcceptedResult: Sendable {
    let id: UUID
    let task: ResultHistoryTask
    let source: String
    let result: String
    let sourceLanguage: String?
    let targetLanguage: String?
    let delivery: ResultHistoryDelivery

    init(
        id: UUID = UUID(), task: ResultHistoryTask, source: String, result: String,
        sourceLanguage: String? = nil, targetLanguage: String? = nil,
        delivery: ResultHistoryDelivery = .notInserted
    ) {
        self.id = id
        self.task = task
        self.source = source
        self.result = result
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.delivery = delivery
    }
}

struct ResultHistorySummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let task: ResultHistoryTask
    let preview: String
    let sourceLanguage: String?
    let targetLanguage: String?
    let delivery: ResultHistoryDelivery
}

struct ResultHistoryEntry: Identifiable, Sendable {
    let summary: ResultHistorySummary
    let source: String
    let result: String
    var id: UUID { summary.id }
}

struct ResultHistoryCursor: Equatable, Sendable {
    let created: TimeInterval
    let id: UUID
    init(_ summary: ResultHistorySummary) {
        created = summary.createdAt.timeIntervalSince1970
        id = summary.id
    }
}

struct ResultHistoryPage: Sendable {
    let entries: [ResultHistorySummary]
    let hasOlder: Bool
    let hasSavedEntries: Bool
}

enum ResultHistoryError: Error, Equatable {
    case invalidRecord, invalidRevocation, unavailable, storageFull, unsupportedDatabase, closed
}

fileprivate final class ResultHistoryRevocation: @unchecked Sendable {
    private let owner: UUID
    private let lock = NSLock()
    private var consumed = false
    init(owner: UUID) { self.owner = owner }
    func consume(owner: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.owner == owner, !consumed else { return false }
        consumed = true
        return true
    }
}

private final class ResultHistoryWriteAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private let owner = UUID()
    private var desired: ResultHistoryStore.Configuration
    private var epoch = UUID()
    private var closed = false

    init(enabled: Bool, retention: ResultHistoryRetention) {
        desired = .init(owner: owner, id: UUID(), enabled: enabled, retention: retention)
    }
    func prepare(enabled: Bool, retention: ResultHistoryRetention) -> ResultHistoryStore.Configuration {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return desired }
        if desired.enabled != enabled || desired.retention != retention {
            epoch = UUID()
            desired = .init(owner: owner, id: UUID(), enabled: enabled, retention: retention)
        }
        return desired
    }
    func isCurrent(_ configuration: ResultHistoryStore.Configuration) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !closed && configuration.owner == owner && configuration.id == desired.id
    }
    func ticket() -> ResultHistoryStore.WriteTicket? {
        lock.lock()
        defer { lock.unlock() }
        return !closed && desired.enabled ? .init(owner: owner, epoch: epoch) : nil
    }
    func configuration(for ticket: ResultHistoryStore.WriteTicket) -> ResultHistoryStore.Configuration? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, desired.enabled, ticket.owner == owner, ticket.epoch == epoch else { return nil }
        return desired
    }
    func revoke() -> ResultHistoryStore.WriteRevocation {
        lock.lock()
        epoch = UUID()
        lock.unlock()
        return .init(state: ResultHistoryRevocation(owner: owner))
    }
    func consume(_ receipt: ResultHistoryStore.WriteRevocation) -> Bool { receipt.state.consume(owner: owner) }
    func close() {
        lock.lock()
        closed = true
        epoch = UUID()
        lock.unlock()
    }
}

#if YULLO_TESTING
    // Accessed only by the store actor and its synchronous SQLite callback.
    private final class ResultHistorySearchTestHook {
        var visit: (@Sendable () -> Void)?
    }
#endif

// The caller captures a ticket when starting a task and supplies only an accepted
// final result. A delayed completion cannot restore text after clear or disable.
actor ResultHistoryStore {
    struct Configuration: Sendable {
        fileprivate let owner: UUID
        fileprivate let id: UUID
        fileprivate let enabled: Bool
        fileprivate let retention: ResultHistoryRetention
    }
    struct WriteTicket: Sendable {
        fileprivate let owner: UUID
        fileprivate let epoch: UUID
    }
    struct WriteRevocation: Sendable { fileprivate let state: ResultHistoryRevocation }
    typealias CancelScheduled = @Sendable () -> Void
    typealias Schedule = @Sendable (Date, @escaping @Sendable () -> Void) -> CancelScheduled
    static let pageSize = 50
    static let maximumTextBytes = 262_144
    private static let applicationID: Int32 = 1_498_764_364
    private static let legacyTableSQL =
        "CREATE TABLE results(id TEXT PRIMARY KEY,created REAL NOT NULL,task TEXT NOT NULL CHECK(task IN ('translation','writing')),source TEXT NOT NULL CHECK(length(CAST(source AS BLOB)) BETWEEN 1 AND 262144),result TEXT NOT NULL CHECK(length(CAST(result AS BLOB)) BETWEEN 1 AND 262144),source_language TEXT,target_language TEXT,delivery TEXT NOT NULL CHECK(delivery IN ('inserted','notInserted','uncertain')),bytes INTEGER NOT NULL CHECK(bytes BETWEEN 2 AND 524288)) STRICT"
    private static let tableSQL =
        String(legacyTableSQL.dropLast(") STRICT".count))
        + ", is_dictation INTEGER NOT NULL DEFAULT 0) STRICT"
    private static let indexSQL = "CREATE INDEX results_created ON results(created,id)"
    private static let typeIndexSQL =
        "CREATE INDEX IF NOT EXISTS results_task_created ON results(task,is_dictation,created,id)"
    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Yullo/History", isDirectory: true).appendingPathComponent("results.sqlite3")
    }

    private let admission: ResultHistoryWriteAdmission
    private let url: URL
    private let now: @Sendable () -> Date
    private let schedule: Schedule
    private var database: OpaquePointer?
    private var enabled = false
    private var retention = ResultHistoryRetention.week
    private var appliedConfiguration: UUID?
    private var expirationGeneration = UUID()
    private var cancelExpiration: CancelScheduled?
    private var closed = false
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    #if YULLO_TESTING
        private let searchTestHook = ResultHistorySearchTestHook()
    #endif

    init(
        url: URL = ResultHistoryStore.defaultURL, enabled: Bool = false,
        retention: ResultHistoryRetention = .week, now: @escaping @Sendable () -> Date = { Date() },
        schedule: @escaping Schedule = { deadline, action in
            let task = Task {
                let delay = max(0, deadline.timeIntervalSinceNow)
                do { try await Task.sleep(nanoseconds: UInt64(min(delay, 31_536_000) * 1_000_000_000)) } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                action()
            }
            return { task.cancel() }
        }
    ) {
        self.url = url
        self.now = now
        self.schedule = schedule
        self.enabled = enabled
        self.retention = retention
        // Admission may be captured before asynchronous startup opens SQLite.
        // A matching configure keeps this epoch; changed settings revoke it.
        admission = ResultHistoryWriteAdmission(enabled: enabled, retention: retention)
    }
    deinit {
        cancelExpiration?()
        if let database { sqlite3_close(database) }
    }

    func configure(enabled requested: Bool, retention requestedRetention: ResultHistoryRetention = .week) throws {
        try checkOpen()
        try configure(prepareConfiguration(enabled: requested, retention: requestedRetention))
    }
    nonisolated func prepareConfiguration(enabled: Bool, retention: ResultHistoryRetention = .week) -> Configuration {
        admission.prepare(enabled: enabled, retention: retention)
    }
    func configure(_ configuration: Configuration) throws {
        try checkOpen()
        guard admission.isCurrent(configuration), appliedConfiguration != configuration.id else { return }
        let changed = enabled != configuration.enabled || retention != configuration.retention
        enabled = configuration.enabled
        retention = configuration.retention
        if try open(create: enabled) { try pruneAndSchedule() }
        appliedConfiguration = configuration.id
        if changed { notify() }
    }
    func changes() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            observers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id) }
            }
        }
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func notify() { observers.values.forEach { $0.yield(()) } }
    // Synchronous admission keeps microphone startup independent of disk work.
    // The lock contains only this opt-in flag and epoch, never text or SQLite.
    nonisolated func captureWriteTicket() -> WriteTicket? { admission.ticket() }
    func writeTicket() -> WriteTicket? { captureWriteTicket() }
    nonisolated func revokePendingWrites() -> WriteRevocation { admission.revoke() }

    @discardableResult
    func save(_ final: ResultHistoryAcceptedResult, using ticket: WriteTicket) throws -> Bool {
        try checkOpen()
        guard let configuration = admission.configuration(for: ticket) else { return false }
        try configure(configuration)
        guard admission.configuration(for: ticket) != nil else { return false }
        guard Self.valid(final) else { throw ResultHistoryError.invalidRecord }
        let date = now()
        guard date.timeIntervalSince1970.isFinite else { throw ResultHistoryError.invalidRecord }
        _ = try open(create: true)
        var inserted = false
        try transaction {
            // This final epoch check linearizes admission before SQLite work.
            // A later user intent does not hold this metadata lock through IO.
            guard admission.configuration(for: ticket) != nil else { return }
            try prune()
            if try contains(final.id) { return }
            let bytes = final.source.utf8.count + final.result.utf8.count
            try statement(
                "INSERT INTO results(id,created,task,source,result,source_language,target_language,delivery,bytes,is_dictation) VALUES(?,?,?,?,?,?,?,?,?,?)"
            ) { statement in
                try bind(final.id.uuidString, to: 1, in: statement)
                try require(sqlite3_bind_double(statement, 2, date.timeIntervalSince1970))
                try bind(final.task == .dictation ? "writing" : final.task.rawValue, to: 3, in: statement)
                try bind(final.source, to: 4, in: statement)
                try bind(final.result, to: 5, in: statement)
                try bind(final.sourceLanguage, to: 6, in: statement)
                try bind(final.targetLanguage, to: 7, in: statement)
                try bind(final.delivery.rawValue, to: 8, in: statement)
                try require(sqlite3_bind_int64(statement, 9, Int64(bytes)))
                try require(sqlite3_bind_int64(statement, 10, final.task == .dictation ? 1 : 0))
                try done(statement)
            }
            inserted = true
        }
        try armExpiration()
        if inserted { notify() }
        return inserted
    }

    func summaries() throws -> [ResultHistorySummary] {
        try page().entries
    }

    func page(
        before cursor: ResultHistoryCursor? = nil, search: String = "", filter: ResultHistoryFilter = .init()
    ) throws -> ResultHistoryPage {
        try checkOpen()
        guard try open(create: false) else { return .init(entries: [], hasOlder: false, hasSavedEntries: false) }
        try pruneAndSchedule()
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var predicates: [String] = []
        if cursor != nil { predicates.append("(created,id)<(?,?)") }
        if filter.task != nil { predicates.append("task=? AND is_dictation=?") }
        if filter.dateRange != nil { predicates.append("created>=? AND created<?") }
        if !query.isEmpty { predicates.append("(yullo_contains(source,?) OR yullo_contains(result,?))") }
        let clause = predicates.isEmpty ? "" : " WHERE " + predicates.joined(separator: " AND ")
        // A rare/no-match search scans older text one row at a time. Interrupt
        // that scan when its task is cancelled instead of blocking a new query.
        sqlite3_progress_handler(database, 1000, { _ in Task.isCancelled ? 1 : 0 }, nil)
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        // Build the small metadata index only when a type filter is used.
        // Default History opening and its metadata-only upgrade stay bounded.
        if filter.task != nil { try execute(Self.typeIndexSQL) }
        return try statement(
            "SELECT id,created,task,substr(result,1,160),source_language,target_language,delivery,is_dictation FROM results"
                + clause
                + " ORDER BY created DESC,id DESC LIMIT 51"
        ) { statement in
            var index: Int32 = 1
            if let cursor {
                try require(sqlite3_bind_double(statement, index, cursor.created))
                try bind(cursor.id.uuidString, to: index + 1, in: statement)
                index += 2
            }
            if let task = filter.task {
                try bind(task == .dictation ? "writing" : task.rawValue, to: index, in: statement)
                try require(sqlite3_bind_int64(statement, index + 1, task == .dictation ? 1 : 0))
                index += 2
            }
            if let range = filter.dateRange {
                try require(sqlite3_bind_double(statement, index, range.start.timeIntervalSince1970))
                try require(sqlite3_bind_double(statement, index + 1, range.end.timeIntervalSince1970))
                index += 2
            }
            if !query.isEmpty {
                try bind(query, to: index, in: statement)
                try bind(query, to: index + 1, in: statement)
            }
            var rows: [ResultHistorySummary] = []
            while try next(statement) {
                try Task.checkCancellation()
                rows.append(try summary(statement))
            }
            let hasSavedEntries: Bool
            if rows.isEmpty {
                hasSavedEntries = try self.statement("SELECT 1 FROM results LIMIT 1") { try next($0) }
            } else {
                hasSavedEntries = true
            }
            return .init(
                entries: Array(rows.prefix(Self.pageSize)), hasOlder: rows.count > Self.pageSize,
                hasSavedEntries: hasSavedEntries)
        }
    }

    func entry(id: UUID) throws -> ResultHistoryEntry? {
        try checkOpen()
        guard try open(create: false) else { return nil }
        try pruneAndSchedule()
        return try statement(
            "SELECT id,created,task,substr(result,1,160),source_language,target_language,delivery,is_dictation,source,result FROM results WHERE id=?"
        ) { statement in
            try bind(id.uuidString, to: 1, in: statement)
            guard try next(statement) else { return nil }
            let metadata = try summary(statement)
            let source = try text(statement, 8, limit: Self.maximumTextBytes)
            let result = try text(statement, 9, limit: Self.maximumTextBytes)
            return ResultHistoryEntry(summary: metadata, source: source, result: result)
        }
    }

    @discardableResult
    func updateDelivery(_ outcome: ResultHistoryDelivery, for id: UUID) throws -> Bool {
        try checkOpen()
        guard try open(create: false) else { return false }
        try pruneAndSchedule()
        let updated = try transaction {
            try statement("UPDATE results SET delivery=? WHERE id=?") { statement in
                try bind(outcome.rawValue, to: 1, in: statement)
                try bind(id.uuidString, to: 2, in: statement)
                try done(statement)
                return sqlite3_changes(database) == 1
            }
        }
        if updated { notify() }
        return updated
    }

    func delete(id: UUID) throws {
        try delete(id: id, after: revokePendingWrites())
    }
    func delete(id: UUID, after receipt: WriteRevocation) throws {
        try checkOpen()
        guard admission.consume(receipt) else { throw ResultHistoryError.invalidRevocation }
        guard try open(create: false) else { return }
        try transaction {
            try statement("DELETE FROM results WHERE id=?") { statement in
                try bind(id.uuidString, to: 1, in: statement)
                try done(statement)
            }
        }
        try armExpiration()
        notify()
    }
    func clear() throws {
        try clear(after: revokePendingWrites())
    }
    func clear(after receipt: WriteRevocation) throws {
        try checkOpen()
        guard admission.consume(receipt) else { throw ResultHistoryError.invalidRevocation }
        guard try open(create: false) else { return }
        try transaction { try execute("DELETE FROM results") }
        try armExpiration()
        notify()
    }
    func pruneExpired() throws {
        try checkOpen()
        guard try open(create: false) else { return }
        try pruneAndSchedule()
    }
    func close() {
        admission.close()
        expirationGeneration = UUID()
        cancelExpiration?()
        cancelExpiration = nil
        if let database { sqlite3_close(database) }
        database = nil
        closed = true
        observers.values.forEach { $0.finish() }
        observers.removeAll()
    }

    private func checkOpen() throws {
        try Task.checkCancellation()
        guard !closed else { throw ResultHistoryError.closed }
    }
    private func open(create: Bool) throws -> Bool {
        if database != nil { return true }
        guard url.isFileURL else { throw ResultHistoryError.unavailable }
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !exists && !create { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch { throw ResultHistoryError.unavailable }
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0) | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &opened, flags, nil) == SQLITE_OK, let opened else {
            if let opened { sqlite3_close(opened) }
            throw ResultHistoryError.unavailable
        }
        database = opened
        do {
            sqlite3_busy_timeout(opened, 250)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let appID = try integer("PRAGMA application_id")
            let version = try integer("PRAGMA user_version")
            if exists && (appID != Int64(Self.applicationID) || ![1, 2].contains(version)) {
                throw ResultHistoryError.unsupportedDatabase
            }
            try execute("PRAGMA page_size=4096")
            guard try integer("PRAGMA page_size") == 4096
            else { throw ResultHistoryError.unavailable }
            try execute("PRAGMA journal_mode=DELETE")
            try execute("PRAGMA secure_delete=ON")
            try execute("PRAGMA temp_store=MEMORY")
            try execute("PRAGMA trusted_schema=OFF")
            let searchUserData: UnsafeMutableRawPointer?
            #if YULLO_TESTING
                searchUserData = Unmanaged.passUnretained(searchTestHook).toOpaque()
            #else
                searchUserData = nil
            #endif
            guard
                sqlite3_create_function_v2(
                    opened, "yullo_contains", 2, SQLITE_UTF8 | SQLITE_DETERMINISTIC, searchUserData,
                    { context, _, values in
                        guard !Task.isCancelled else {
                            sqlite3_result_error_code(context, SQLITE_INTERRUPT)
                            return
                        }
                        #if YULLO_TESTING
                            if let pointer = sqlite3_user_data(context) {
                                Unmanaged<ResultHistorySearchTestHook>.fromOpaque(pointer).takeUnretainedValue()
                                    .visit?()
                            }
                        #endif
                        guard let values, let text = sqlite3_value_text(values[0]),
                            let query = sqlite3_value_text(values[1])
                        else {
                            sqlite3_result_int(context, 0)
                            return
                        }
                        guard
                            let sourceText = String(
                                bytes: UnsafeBufferPointer(start: text, count: Int(sqlite3_value_bytes(values[0]))),
                                encoding: .utf8),
                            let queryText = String(
                                bytes: UnsafeBufferPointer(start: query, count: Int(sqlite3_value_bytes(values[1]))),
                                encoding: .utf8)
                        else {
                            sqlite3_result_error(context, "Invalid UTF-8 in history search.", -1)
                            return
                        }
                        let matches =
                            sourceText.range(
                                of: queryText, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                        sqlite3_result_int(context, matches ? 1 : 0)
                    }, nil, nil, nil) == SQLITE_OK
            else { throw ResultHistoryError.unavailable }
            if !exists {
                try transaction {
                    try execute(Self.legacyTableSQL)
                    try execute(Self.indexSQL)
                    try execute("ALTER TABLE results ADD COLUMN is_dictation INTEGER NOT NULL DEFAULT 0")
                    try execute("PRAGMA application_id=\(Self.applicationID)")
                    try execute("PRAGMA user_version=2")
                }
            } else if version == 1 {
                try validateSchema(tableSQL: Self.legacyTableSQL)
                // Adding a constant-default column leaves existing text in
                // place. Older writing records retain their known category.
                try transaction {
                    try execute("ALTER TABLE results ADD COLUMN is_dictation INTEGER NOT NULL DEFAULT 0")
                    try execute("PRAGMA user_version=2")
                }
            }
            // Validate the fixed schema without scanning every stored text.
            // Corrupt/foreign files remain in place and fail at this boundary.
            try validateSchema(tableSQL: Self.tableSQL)
            return true
        } catch {
            sqlite3_close(opened)
            database = nil
            if let error = error as? ResultHistoryError { throw error }
            if error is CancellationError { throw error }
            throw ResultHistoryError.unavailable
        }
    }
    private func pruneAndSchedule() throws {
        let removed = try transaction { try prune() }
        try armExpiration()
        if removed { notify() }
    }
    @discardableResult private func prune() throws -> Bool {
        guard let seconds = retention.seconds else { return false }
        let cutoff = now().timeIntervalSince1970 - seconds
        guard cutoff.isFinite else { throw ResultHistoryError.unavailable }
        try statement("DELETE FROM results WHERE created<=?") { statement in
            try require(sqlite3_bind_double(statement, 1, cutoff))
            try done(statement)
        }
        return sqlite3_changes(database) > 0
    }
    private func validateSchema(tableSQL: String) throws {
        for (type, name, sql) in [("table", "results", tableSQL), ("index", "results_created", Self.indexSQL)] {
            let valid = try statement(
                "SELECT sql FROM sqlite_schema WHERE type=? AND name=? AND tbl_name='results' LIMIT 1"
            ) { statement in
                try bind(type, to: 1, in: statement)
                try bind(name, to: 2, in: statement)
                return try next(statement) && text(statement, 0, limit: 4096) == sql
            }
            guard valid else { throw ResultHistoryError.unsupportedDatabase }
        }
    }
    #if YULLO_TESTING
        func testObserveSearchVisits(_ visit: @escaping @Sendable () -> Void) {
            searchTestHook.visit = visit
        }
        func testLimitDatabasePages() throws {
            guard try open(create: true) else { return }
            let pages = try integer("PRAGMA page_count")
            _ = try integer("PRAGMA max_page_count=\(pages)")
        }
    #endif
    private func armExpiration() throws {
        expirationGeneration = UUID()
        cancelExpiration?()
        cancelExpiration = nil
        guard let seconds = retention.seconds else { return }
        let timestamp = try statement("SELECT min(created) FROM results") { statement -> Double? in
            guard try next(statement), sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
            return sqlite3_column_double(statement, 0)
        }
        guard let timestamp else { return }
        let ticket = expirationGeneration
        cancelExpiration = schedule(Date(timeIntervalSince1970: timestamp + seconds)) { [weak self] in
            Task { await self?.expirationFired(ticket) }
        }
    }
    private func expirationFired(_ ticket: UUID) {
        guard ticket == expirationGeneration, !closed else { return }
        do { try pruneAndSchedule() } catch {
            // Retry only on a later explicit store operation after an I/O error.
            cancelExpiration?()
            cancelExpiration = nil
            notify()
        }
    }
    private func contains(_ id: UUID) throws -> Bool {
        try statement("SELECT 1 FROM results WHERE id=?") { statement in
            try bind(id.uuidString, to: 1, in: statement)
            return try next(statement)
        }
    }
    private func summary(_ statement: OpaquePointer) throws -> ResultHistorySummary {
        guard let id = UUID(uuidString: try text(statement, 0, limit: 36)),
            let delivery = ResultHistoryDelivery(rawValue: try text(statement, 6, limit: 16)),
            sqlite3_column_type(statement, 7) == SQLITE_INTEGER
        else { throw ResultHistoryError.unavailable }
        let task: ResultHistoryTask
        switch (try text(statement, 2, limit: 16), sqlite3_column_int64(statement, 7)) {
        case ("translation", 0): task = .translation
        case ("writing", 0): task = .writing
        case ("writing", 1): task = .dictation
        default: throw ResultHistoryError.unavailable
        }
        let timestamp = sqlite3_column_double(statement, 1)
        guard timestamp.isFinite else { throw ResultHistoryError.unavailable }
        return ResultHistorySummary(
            id: id, createdAt: Date(timeIntervalSince1970: timestamp), task: task,
            preview: try text(statement, 3, limit: 640),
            sourceLanguage: try optionalText(statement, 4), targetLanguage: try optionalText(statement, 5),
            delivery: delivery)
    }
    private static func valid(_ value: ResultHistoryAcceptedResult) -> Bool {
        func language(_ value: String?) -> Bool {
            guard let value else { return true }
            return !value.isEmpty && value.utf8.count <= 64
                && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
        }
        return !value.source.isEmpty && !value.result.isEmpty
            && value.source.utf8.count <= maximumTextBytes && value.result.utf8.count <= maximumTextBytes
            && !value.source.utf8.contains(0) && !value.result.utf8.contains(0)
            && language(value.sourceLanguage) && language(value.targetLanguage)
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try Task.checkCancellation()
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try Task.checkCancellation()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            try Task.checkCancellation()
            throw sqliteFailure()
        }
    }
    private func statement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
            throw sqliteFailure()
        }
        defer { sqlite3_finalize(prepared) }
        return try body(prepared)
    }
    private func bind(_ value: String?, to index: Int32, in statement: OpaquePointer) throws {
        guard let value else {
            try require(sqlite3_bind_null(statement, index))
            return
        }
        guard let byteCount = Int32(exactly: value.utf8.count) else { throw ResultHistoryError.invalidRecord }
        try value.withCString {
            try require(
                sqlite3_bind_text(statement, index, $0, byteCount, unsafeBitCast(-1, to: sqlite3_destructor_type.self)))
        }
    }
    private func require(_ code: Int32) throws {
        guard code == SQLITE_OK else { throw sqliteFailure() }
    }
    private func sqliteFailure() -> ResultHistoryError {
        sqlite3_errcode(database) == SQLITE_FULL ? .storageFull : .unavailable
    }
    private func next(_ statement: OpaquePointer) throws -> Bool {
        let status = sqlite3_step(statement)
        try Task.checkCancellation()
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw sqliteFailure() }
        return status == SQLITE_ROW
    }
    private func done(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteFailure() }
    }
    private func integer(_ sql: String) throws -> Int64 {
        try statement(sql) { statement in
            guard try next(statement) else { throw ResultHistoryError.unavailable }
            return sqlite3_column_int64(statement, 0)
        }
    }
    private func text(_ statement: OpaquePointer, _ column: Int32, limit: Int) throws -> String {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT, count <= limit,
            let bytes = sqlite3_column_text(statement, column),
            let value = String(bytes: UnsafeBufferPointer(start: bytes, count: count), encoding: .utf8)
        else { throw ResultHistoryError.unavailable }
        return value
    }
    private func optionalText(_ statement: OpaquePointer, _ column: Int32) throws -> String? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : try text(statement, column, limit: 64)
    }
}
