import Foundation
import SQLite3

/// Folder stats from earlier walks, cached in SQLite as a tree: each row is one folder name under its parent's row,
/// which takes far less space than a full path per row. Row 0 is "/" and is its own parent.
/// It's only a cache, so a file with another schema version, or one that won't open, is deleted and started over.
public actor FolderStatsStore {
    public static var defaultURL: URL {
        URL.cachesDirectory.appending(path: "dev.bvdwalt.fennec/folder-stats.sqlite")
    }

    static let schemaVersion: Int32 = 1
    static let rootID: Int64 = 0

    enum SQL {
        static let schema = """
            CREATE TABLE folders (
              id          INTEGER PRIMARY KEY,
              parent      INTEGER NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
              name        TEXT    NOT NULL,
              bytes       INTEGER,
              allocated   INTEGER,
              files       INTEGER,
              subfolders  INTEGER,
              newest      INTEGER,
              calculated  INTEGER,
              duration_ms INTEGER,
              incomplete  INTEGER NOT NULL DEFAULT 0
            ) STRICT;
            INSERT INTO folders (id, parent, name) VALUES (0, 0, '');
            CREATE UNIQUE INDEX folders_parent_name ON folders(parent, name);
            CREATE INDEX folders_calculated ON folders(calculated) WHERE calculated IS NOT NULL;
            PRAGMA user_version = \(schemaVersion);
            """
        static let statsColumns = "bytes, allocated, files, subfolders, newest, calculated, duration_ms, incomplete"

        static func statsValues(_ stats: FolderStats) -> [Int64?] {
            [stats.bytes, stats.allocated, stats.files, stats.subfolders,
             stats.newest.map { Int64($0.timeIntervalSince1970) }, Int64(stats.calculated.timeIntervalSince1970),
             stats.durationMilliseconds, stats.incomplete ? 1 : 0]
        }

        static func stats(from row: Row, at offset: Int32) -> FolderStats {
            FolderStats(
                bytes: row.int64(offset), allocated: row.int64(offset + 1), files: row.int64(offset + 2),
                subfolders: row.int64(offset + 3),
                newest: row.isNull(offset + 4) ? nil : Date(timeIntervalSince1970: Double(row.int64(offset + 4))),
                calculated: Date(timeIntervalSince1970: Double(row.int64(offset + 5))),
                durationMilliseconds: row.int64(offset + 6), incomplete: row.int64(offset + 7) != 0)
        }

        static let child = "SELECT id FROM folders WHERE parent = ?1 AND name = ?2"
        static let insertName = "INSERT INTO folders (parent, name) VALUES (?1, ?2)"
        static let stats = "SELECT \(statsColumns) FROM folders WHERE id = ?1 AND calculated IS NOT NULL"
        static let childStats =
            "SELECT name, \(statsColumns) FROM folders WHERE parent = ?1 AND id != ?1 AND calculated IS NOT NULL"
        static let deleteChildren = "DELETE FROM folders WHERE parent = ?1 AND id != ?1"
        static let updateStats = """
            UPDATE folders SET bytes = ?2, allocated = ?3, files = ?4, subfolders = ?5, newest = ?6,
              calculated = ?7, duration_ms = ?8, incomplete = ?9 WHERE id = ?1
            """
        static let insertFolder =
            "INSERT INTO folders (parent, \(statsColumns), name) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)"
        static let stalest = "SELECT id FROM folders WHERE calculated IS NOT NULL ORDER BY calculated LIMIT ?1"
        static let parentAndName = "SELECT parent, name FROM folders WHERE id = ?1"

        static let queries = [child, insertName, stats, childStats, deleteChildren, updateStats, insertFolder,
                              stalest, parentAndName]
    }

    private let db: Database

    public init(url: URL = FolderStatsStore.defaultURL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            db = try Self.open(url)
        } catch {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
            db = try Self.open(url)
        }
    }

    private static func open(_ url: URL) throws -> Database {
        let db = try Database(path: url.path)
        try db.execute("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA foreign_keys = ON;")
        let version = try db.query("PRAGMA user_version") { $0.int64(0) }.first ?? 0
        if version == 0 {
            try db.transaction { try db.execute(SQL.schema) }
        } else if version != Int64(schemaVersion) {
            throw SQLiteError(code: SQLITE_SCHEMA, message: "folder stats schema \(version) is out of date")
        }
        return db
    }

    /// Names are stored precomposed: APFS treats both Unicode forms of a name as the same file, SQLite doesn't.
    public static func normalized(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
    }

    static func components(_ url: URL) -> [String] {
        url.standardizedFileURL.path.split(separator: "/").map { normalized(String($0)) }
    }

    public func stats(for folder: URL) throws -> FolderStats? {
        guard let id = try find(Self.components(folder)) else { return nil }
        return try db.query(SQL.stats, [id]) { SQL.stats(from: $0, at: 0) }.first
    }

    /// Stats for the folders directly inside `folder` that have any, keyed by `normalized(name)`.
    public func childStats(of folder: URL) throws -> [String: FolderStats] {
        guard let id = try find(Self.components(folder)) else { return [:] }
        let rows = try db.query(SQL.childStats, [id]) { ($0.text(0), SQL.stats(from: $0, at: 1)) }
        return Dictionary(rows, uniquingKeysWith: { first, _ in first })
    }

    /// Folders whose stats were calculated longest ago, oldest first.
    public func stalest(limit: Int) throws -> [URL] {
        let ids = try db.query(SQL.stalest, [Int64(limit)]) { $0.int64(0) }
        return try ids.map(path(of:))
    }

    /// Replaces everything stored under the walk's root with the walk's folders.
    public func save(_ walk: FolderWalk, at root: URL) throws {
        guard let first = walk.folders.first else { return }
        try db.transaction {
            let rootID = try ensure(Self.components(root))
            try db.run(SQL.deleteChildren, rootID)
            try db.run(SQL.updateStats, [rootID] + SQL.statsValues(first.stats))
            var ids = [rootID]
            ids.reserveCapacity(walk.folders.count)
            for folder in walk.folders.dropFirst() {
                let parent = ids[folder.parent]
                try db.run(
                    SQL.insertFolder, [parent] + SQL.statsValues(folder.stats), thenText: Self.normalized(folder.name))
                ids.append(db.lastInsertedID)
            }
        }
    }

    private func find(_ components: [String]) throws -> Int64? {
        var id = Self.rootID
        for name in components {
            guard let child = try db.query(SQL.child, [id], thenText: name, { $0.int64(0) }).first
            else { return nil }
            id = child
        }
        return id
    }

    private func ensure(_ components: [String]) throws -> Int64 {
        var id = Self.rootID
        for name in components {
            if let child = try db.query(SQL.child, [id], thenText: name, { $0.int64(0) }).first {
                id = child
            } else {
                try db.run(SQL.insertName, [id], thenText: name)
                id = db.lastInsertedID
            }
        }
        return id
    }

    private func path(of id: Int64) throws -> URL {
        var names: [String] = []
        var current = id
        while current != Self.rootID {
            guard let row = try db.query(SQL.parentAndName, [current], {
                (parent: $0.int64(0), name: $0.text(1))
            }).first else { break }
            names.append(row.name)
            current = row.parent
        }
        return URL(filePath: "/" + names.reversed().joined(separator: "/"), directoryHint: .isDirectory)
    }

    func queryPlans() throws -> [String: [String]] {
        var plans: [String: [String]] = [:]
        for sql in SQL.queries {
            plans[sql] = try db.query("EXPLAIN QUERY PLAN " + sql) { $0.text(3) }
        }
        return plans
    }
}

struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String
    var description: String { "SQLite error \(code): \(message)" }
}

final class Database {
    private let handle: OpaquePointer
    private var statements: [String: OpaquePointer] = [:]
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        var handle: OpaquePointer?
        let code = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard code == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open \(path)"
            sqlite3_close_v2(handle)
            throw SQLiteError(code: code, message: message)
        }
        self.handle = handle
        sqlite3_busy_timeout(handle, 2000)
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        sqlite3_exec(handle, "PRAGMA optimize", nil, nil, nil)
        sqlite3_close_v2(handle)
    }

    var lastInsertedID: Int64 { sqlite3_last_insert_rowid(handle) }

    func execute(_ sql: String) throws {
        try check(sqlite3_exec(handle, sql, nil, nil, nil))
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func run(_ sql: String, _ values: [Int64?], thenText text: String? = nil) throws {
        let statement = try prepared(sql, values, thenText: text)
        defer { sqlite3_reset(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw error(code) }
    }

    func run(_ sql: String, _ value: Int64) throws {
        try run(sql, [value])
    }

    func query<T>(
        _ sql: String, _ values: [Int64?] = [], thenText text: String? = nil, _ read: (Row) -> T
    ) throws -> [T] {
        let statement = try prepared(sql, values, thenText: text)
        defer { sqlite3_reset(statement) }
        var rows: [T] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return rows }
            guard code == SQLITE_ROW else { throw error(code) }
            rows.append(read(Row(statement: statement)))
        }
    }

    private func prepared(_ sql: String, _ values: [Int64?], thenText text: String?) throws -> OpaquePointer {
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
        } else {
            var created: OpaquePointer?
            try check(sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &created, nil))
            guard let created else { throw SQLiteError(code: SQLITE_MISUSE, message: "empty statement: \(sql)") }
            statements[sql] = created
            statement = created
        }
        sqlite3_clear_bindings(statement)
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            if let value { sqlite3_bind_int64(statement, position, value) } else { sqlite3_bind_null(statement, position) }
        }
        if let text { sqlite3_bind_text(statement, Int32(values.count + 1), text, -1, Self.transient) }
        return statement
    }

    private func check(_ code: Int32) throws {
        if code != SQLITE_OK { throw error(code) }
    }

    private func error(_ code: Int32) -> SQLiteError {
        SQLiteError(code: code, message: String(cString: sqlite3_errmsg(handle)))
    }
}

struct Row {
    let statement: OpaquePointer
    func int64(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
    func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
}
