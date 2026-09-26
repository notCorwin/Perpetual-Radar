import Foundation
import CSQLite

final class Store {
    private var db: OpaquePointer?

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw failure() }
        try execute("CREATE TABLE IF NOT EXISTS candles (inst_id TEXT, hour INTEGER, high REAL, low REAL, close REAL, volume REAL, base_volume REAL, PRIMARY KEY(inst_id,hour))")
        try execute("CREATE TABLE IF NOT EXISTS oi_base (inst_id TEXT, hour INTEGER, value REAL, PRIMARY KEY(inst_id,hour))")
        try execute("CREATE TABLE IF NOT EXISTS ema200 (inst_id TEXT PRIMARY KEY, hour INTEGER, value REAL)")
        // Existing Python caches may predate base_volume.
        if !columns("candles").contains("base_volume") { try execute("ALTER TABLE candles ADD COLUMN base_volume REAL") }
    }

    deinit { sqlite3_close(db) }

    private func failure() -> NSError {
        NSError(domain: "SQLite", code: Int(sqlite3_errcode(db)), userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(db))])
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }
        return stmt
    }

    private func bind(_ values: [Any?], to stmt: OpaquePointer) {
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let text as String: sqlite3_bind_text(stmt, position, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case let integer as Int64: sqlite3_bind_int64(stmt, position, integer)
            case let double as Double: sqlite3_bind_double(stmt, position, double)
            default: sqlite3_bind_null(stmt, position)
            }
        }
    }

    func execute(_ sql: String, _ values: [Any?] = []) throws {
        let stmt = try statement(sql)
        defer { sqlite3_finalize(stmt) }
        bind(values, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }

    private func columns(_ table: String) -> Set<String> {
        guard let stmt = try? statement("PRAGMA table_info(\(table))") else { return [] }
        defer { sqlite3_finalize(stmt) }
        var names = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW { names.insert(String(cString: sqlite3_column_text(stmt, 1))) }
        return names
    }

    func load(hour: Int64, ids: Set<String>) throws -> (candles: [String: [Int64: Candle]], oi: [String: Double], ema: [String: (Int64, Double)]) {
        var candles: [String: [Int64: Candle]] = [:], oi: [String: Double] = [:], ema: [String: (Int64, Double)] = [:]
        let candleStmt = try statement("SELECT inst_id,hour,high,low,close,volume,base_volume FROM candles WHERE hour >= ? AND hour < ?")
        defer { sqlite3_finalize(candleStmt) }
        bind([hour - Int64(candleLookback) * hourMS, hour], to: candleStmt)
        while sqlite3_step(candleStmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(candleStmt, 0))
            guard ids.contains(id) else { continue }
            let ts = sqlite3_column_int64(candleStmt, 1)
            candles[id, default: [:]][ts] = Candle(hour: ts, high: sqlite3_column_double(candleStmt, 2), low: sqlite3_column_double(candleStmt, 3), close: sqlite3_column_double(candleStmt, 4), quoteVolume: sqlite3_column_double(candleStmt, 5), baseVolume: sqlite3_column_type(candleStmt, 6) == SQLITE_NULL ? nil : sqlite3_column_double(candleStmt, 6))
        }
        let oiStmt = try statement("SELECT inst_id,value FROM oi_base WHERE hour = ?")
        defer { sqlite3_finalize(oiStmt) }
        bind([hour], to: oiStmt)
        while sqlite3_step(oiStmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(oiStmt, 0))
            if ids.contains(id) { oi[id] = sqlite3_column_double(oiStmt, 1) }
        }
        let emaStmt = try statement("SELECT inst_id,hour,value FROM ema200")
        defer { sqlite3_finalize(emaStmt) }
        while sqlite3_step(emaStmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(emaStmt, 0))
            if ids.contains(id) { ema[id] = (sqlite3_column_int64(emaStmt, 1), sqlite3_column_double(emaStmt, 2)) }
        }
        return (candles, oi, ema)
    }

    func save(_ id: String, _ bar: Candle) throws {
        guard bar.confirmed else { return }
        try execute("INSERT INTO candles VALUES (?,?,?,?,?,?,?) ON CONFLICT(inst_id,hour) DO UPDATE SET base_volume=COALESCE(candles.base_volume,excluded.base_volume)", [id, bar.hour, bar.high, bar.low, bar.close, bar.quoteVolume, bar.baseVolume])
    }

    func prune(hour: Int64, ids: Set<String>) throws {
        let cutoff = hour - Int64(candleLookback) * hourMS
        try execute("DELETE FROM candles WHERE hour < ?", [cutoff])
        try execute("DELETE FROM oi_base WHERE hour != ?", [hour])
        try execute("DELETE FROM ema200 WHERE hour < ? OR hour >= ?", [cutoff - hourMS, hour])
        let stmt = try statement("SELECT inst_id FROM ema200")
        defer { sqlite3_finalize(stmt) }
        var stale: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(stmt, 0))
            if !ids.isEmpty && !ids.contains(id) { stale.append(id) }
        }
        for id in stale { try execute("DELETE FROM ema200 WHERE inst_id=?", [id]) }
    }
}
