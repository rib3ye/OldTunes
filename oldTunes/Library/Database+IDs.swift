import Foundation
import GRDB
import SQLite3

extension Database {
    /// The first column of every row as Int64, stepped with the C API.
    ///
    /// Every sort and every keystroke materializes the whole id list, so this is the hot path.
    /// Measured on 15,908 rows: SQLite itself walks ix_title in 0.5 ms, while `Int64.fetchAll`
    /// took 2.5 ms because GRDB's generic cursor runs unspecialized in a Debug build.
    func fetchIDs(sql: String, arguments: StatementArguments) throws -> [Int64] {
        var ids: [Int64] = []
        try forEachRow(sql: sql, arguments: arguments) { ids.append(sqlite3_column_int64($0, 0)) }
        return ids
    }

    /// Steps a cached statement with the C API, handing `body` the statement positioned on each row.
    func forEachRow(sql: String, arguments: StatementArguments, _ body: (OpaquePointer) throws -> Void) throws {
        let statement = try cachedStatement(sql: sql)
        try statement.setArguments(arguments)
        let handle = statement.sqliteStatement
        defer { sqlite3_reset(handle) }
        while true {
            let code = sqlite3_step(handle)
            if code == SQLITE_ROW {
                try body(handle)
            } else if code == SQLITE_DONE {
                return
            } else if (code == SQLITE_INTERRUPT || code == SQLITE_ABORT) && Task.isCancelled {
                // GRDB stops a cancelled task's read with sqlite3_interrupt, and on its own path
                // reports that as CancellationError ("the only error that a user sees when a Task
                // is cancelled"). Stepping here bypasses that path, so apply the same rule. The
                // check is on the task itself: GRDB 7 runs this block as a job of the calling task
                // (on the reader's queue), so its cancellation flag is visible here and is always
                // set before GRDB interrupts. An interrupt with no cancellation stays an error.
                throw CancellationError()
            } else {
                let message = String(cString: sqlite3_errmsg(sqliteConnection))
                throw DatabaseError(resultCode: ResultCode(rawValue: code), message: message, sql: sql)
            }
        }
    }
}
