import Foundation
import SQLite3

/// 对表格块跑一条只读的 SQL（设计 9.2 节 query；第 7 条：查询用系统的 SQLite3）。
/// 每次查询现建一个内存数据库，把表装进去，锁成只读，再跑那一条 SELECT。几千行装一遍是几毫秒的事。
public enum SQLQuery {
    public enum Value: Equatable, Sendable {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
    }

    public struct Table: Sendable, Equatable {
        public var name: String
        public var columns: [String]
        public var rows: [[Value]]

        public init(name: String, columns: [String], rows: [[Value]]) {
            self.name = name
            self.columns = columns
            self.rows = rows
        }
    }

    public struct Result: Sendable, Equatable {
        public var columns: [String]
        public var rows: [[Value]]
        /// 结果比上限多，后面的没回。
        public var truncated: Bool
    }

    /// 查不了的原因（SQLite 的原话，或者我们的规矩），写给 AI 看。
    public struct QueryError: Error, Equatable, Sendable {
        public var message: String
    }

    /// `limit`：最多回几行；`timeout`：最多跑几秒（三张表互相连接这种写错的查询会跑很久）。
    public static func run(_ sql: String, tables: [Table], limit: Int = 500,
                           timeout: TimeInterval = 3) throws(QueryError) -> Result {
        var handle: OpaquePointer?
        guard sqlite3_open(":memory:", &handle) == SQLITE_OK, let db = handle else {
            throw QueryError(message: "could not create the query database")
        }
        defer { sqlite3_close(db) }
        try load(tables, into: db)
        try execute("PRAGMA query_only = 1", db)

        let deadline = UnsafeMutablePointer<Double>.allocate(capacity: 1)
        deadline.pointee = Date().timeIntervalSinceReferenceDate + timeout
        defer { deadline.deallocate() }
        sqlite3_progress_handler(db, 10_000, { context in
            guard let context else { return 0 }
            return Date().timeIntervalSinceReferenceDate > context.assumingMemoryBound(to: Double.self).pointee ? 1 : 0
        }, deadline)

        var statement: OpaquePointer?
        var tail: UnsafePointer<CChar>?
        let prepared = sql.withCString { sqlite3_prepare_v2(db, $0, -1, &statement, &tail) }
        guard prepared == SQLITE_OK, let statement else { throw QueryError(message: message(db)) }
        defer { sqlite3_finalize(statement) }
        if let tail, !String(cString: tail).trimmingCharacters(in: CharacterSet(charactersIn: "; \t\r\n")).isEmpty {
            throw QueryError(message: "only one statement per query")
        }
        guard sqlite3_stmt_readonly(statement) != 0 else { throw QueryError(message: "only SELECT queries are allowed") }

        let columnCount = Int(sqlite3_column_count(statement))
        let columns = (0..<columnCount).map { String(cString: sqlite3_column_name(statement, Int32($0))) }
        var rows: [[Value]] = []
        var truncated = false
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw QueryError(message: step == SQLITE_INTERRUPT ? "the query took longer than \(Int(timeout)) seconds"
                                                                 : message(db))
            }
            guard rows.count < limit else {
                truncated = true
                break
            }
            rows.append((0..<columnCount).map { value(statement, Int32($0)) })
        }
        return Result(columns: columns, rows: rows, truncated: truncated)
    }

    // MARK: - 装表

    private static func load(_ tables: [Table], into db: OpaquePointer) throws(QueryError) {
        try execute("BEGIN", db)
        for table in tables {
            let columns = table.columns.map(quoted).joined(separator: ", ")
            try execute("CREATE TABLE \(quoted(table.name)) (\(columns))", db)
            let placeholders = Array(repeating: "?", count: table.columns.count).joined(separator: ", ")
            var insert: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO \(quoted(table.name)) VALUES (\(placeholders))", -1, &insert, nil)
                    == SQLITE_OK, let insert else { throw QueryError(message: message(db)) }
            defer { sqlite3_finalize(insert) }
            for row in table.rows {
                sqlite3_reset(insert)
                for (offset, value) in row.prefix(table.columns.count).enumerated() {
                    bind(value, to: insert, at: Int32(offset + 1))
                }
                guard sqlite3_step(insert) == SQLITE_DONE else { throw QueryError(message: message(db)) }
            }
        }
        try execute("COMMIT", db)
    }

    /// SQL 里的名字一律用双引号括起来，里面的双引号写两个：中文、空格、关键字都不怕。
    public static func quoted(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func bind(_ value: Value, to statement: OpaquePointer, at index: Int32) {
        switch value {
        case .null: sqlite3_bind_null(statement, index)
        case .integer(let number): sqlite3_bind_int64(statement, index, number)
        case .real(let number): sqlite3_bind_double(statement, index, number)
        case .text(let text):
            // SQLITE_TRANSIENT：让 SQLite 自己拷一份，Swift 的字符串离开这一行就不在了。
            sqlite3_bind_text(statement, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }

    private static func value(_ statement: OpaquePointer, _ column: Int32) -> Value {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, column))
        case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(statement, column)))
        case SQLITE_NULL: return .null
        default: return .text("(binary)")
        }
    }

    private static func execute(_ sql: String, _ db: OpaquePointer) throws(QueryError) {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw QueryError(message: message(db)) }
    }

    private static func message(_ db: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(db))
    }
}
