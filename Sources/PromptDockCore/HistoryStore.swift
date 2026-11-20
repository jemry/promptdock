import Foundation
import SQLite3

/// 一次成功完成的模型调用（spec 10 调用历史）。
public struct HistoryEntry: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var createdAt: Date
    public var title: String
    public var target: String
    public var input: String
    public var output: String

    public init(id: Int64, createdAt: Date, title: String, target: String, input: String, output: String) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.target = target
        self.input = input
        self.output = output
    }
}

/// 调用历史存储（SQLite，表 `history`）。隐私默认关闭：settings.keep_history 开启才写入。
/// 记录输入与输出全文，容量上限 200 条，超出删最旧。非线程安全，由调用方保证在同一线程使用。
public final class HistoryStore {
    public static let capacity = 200
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var db: OpaquePointer?

    /// - Parameter path: 数据库文件路径；传 ":memory:" 使用内存库。父目录不存在时自动创建。
    public init(path: String) throws {
        if path != ":memory:" {
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "-"
            sqlite3_close_v2(handle)
            throw UsageStoreError.open(path: path, message: message)
        }
        db = handle
        let sql = """
            CREATE TABLE IF NOT EXISTS history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at INTEGER NOT NULL,
                title TEXT NOT NULL,
                target TEXT NOT NULL,
                input TEXT NOT NULL,
                output TEXT NOT NULL
            );
            """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw UsageStoreError.sqlite(message: String(cString: sqlite3_errmsg(db)))
        }
    }

    deinit { sqlite3_close_v2(db) }

    /// 追加一条并裁剪到容量上限（保留最新）。
    public func add(title: String, target: String, input: String, output: String, at date: Date = Date()) {
        let sql = "INSERT INTO history (created_at, title, target, input, output) VALUES (?, ?, ?, ?, ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(date.timeIntervalSince1970.rounded(.down)))
        sqlite3_bind_text(stmt, 2, title, -1, Self.transient)
        sqlite3_bind_text(stmt, 3, target, -1, Self.transient)
        sqlite3_bind_text(stmt, 4, input, -1, Self.transient)
        sqlite3_bind_text(stmt, 5, output, -1, Self.transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return }
        trim()
    }

    /// 最近的使用记录（新的在前）。
    public func recent(limit: Int = HistoryStore.capacity) -> [HistoryEntry] {
        let sql = "SELECT id, created_at, title, target, input, output FROM history ORDER BY id DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var entries: [HistoryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            entries.append(HistoryEntry(
                id: sqlite3_column_int64(stmt, 0),
                createdAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 1))),
                title: String(cString: sqlite3_column_text(stmt, 2)),
                target: String(cString: sqlite3_column_text(stmt, 3)),
                input: String(cString: sqlite3_column_text(stmt, 4)),
                output: String(cString: sqlite3_column_text(stmt, 5))))
        }
        return entries
    }

    /// 清空全部历史。
    public func clear() {
        sqlite3_exec(db, "DELETE FROM history;", nil, nil, nil)
    }

    /// 超出容量上限时删最旧。
    private func trim() {
        let sql = "DELETE FROM history WHERE id NOT IN (SELECT id FROM history ORDER BY id DESC LIMIT ?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(Self.capacity))
        sqlite3_step(stmt)
    }
}
