import Foundation
import CSQLite

final class Store {
    private var db: OpaquePointer?

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw failure() }
        try execute("CREATE TABLE IF NOT EXISTS candles (inst_id TEXT, hour INTEGER, high REAL, low REAL, close REAL, volume REAL, base_volume REAL, open REAL, PRIMARY KEY(inst_id,hour))")
        try execute("CREATE TABLE IF NOT EXISTS oi_base (inst_id TEXT, hour INTEGER, value REAL, PRIMARY KEY(inst_id,hour))")
        try execute("CREATE TABLE IF NOT EXISTS ema200 (inst_id TEXT PRIMARY KEY, hour INTEGER, value REAL)")
        try execute("CREATE TABLE IF NOT EXISTS chart_stats (inst_id TEXT, hour INTEGER, oi REAL, sell REAL, buy REAL, PRIMARY KEY(inst_id,hour))")
        // Existing Python caches may predate base_volume.
        if !columns("candles").contains("base_volume") { try execute("ALTER TABLE candles ADD COLUMN base_volume REAL") }
        if !columns("candles").contains("open") { try execute("ALTER TABLE candles ADD COLUMN open REAL") }
        if !columns("chart_stats").contains("oi_contracts") { try execute("ALTER TABLE chart_stats ADD COLUMN oi_contracts REAL") }
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

    func load(hour: Int64, ids: Set<String>) throws -> (candles: [String: [Int64: Candle]], oi: [String: Double], oiHistory: [String: [Int64: Double]], ema: [String: (Int64, Double)]) {
        var candles: [String: [Int64: Candle]] = [:], oi: [String: Double] = [:], oiHistory: [String: [Int64: Double]] = [:], ema: [String: (Int64, Double)] = [:]
        let candleStmt = try statement("SELECT inst_id,hour,high,low,close,volume,base_volume,open FROM candles WHERE hour >= ? AND hour < ?")
        defer { sqlite3_finalize(candleStmt) }
        bind([hour - Int64(candleLookback) * hourMS, hour], to: candleStmt)
        while sqlite3_step(candleStmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(candleStmt, 0))
            guard ids.contains(id) else { continue }
            let ts = sqlite3_column_int64(candleStmt, 1)
            candles[id, default: [:]][ts] = Candle(hour: ts, high: sqlite3_column_double(candleStmt, 2), low: sqlite3_column_double(candleStmt, 3), close: sqlite3_column_double(candleStmt, 4), quoteVolume: sqlite3_column_double(candleStmt, 5), baseVolume: sqlite3_column_type(candleStmt, 6) == SQLITE_NULL ? nil : sqlite3_column_double(candleStmt, 6), open: sqlite3_column_type(candleStmt, 7) == SQLITE_NULL ? nil : sqlite3_column_double(candleStmt, 7))
        }
        let oiStmt = try statement("SELECT inst_id,value FROM oi_base WHERE hour = ?")
        defer { sqlite3_finalize(oiStmt) }
        bind([hour], to: oiStmt)
        while sqlite3_step(oiStmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(oiStmt, 0))
            if ids.contains(id) { oi[id] = sqlite3_column_double(oiStmt, 1) }
        }
        let historyStmt = try statement("SELECT inst_id,hour,oi_contracts FROM chart_stats WHERE hour>=? AND hour<? AND oi_contracts IS NOT NULL")
        defer { sqlite3_finalize(historyStmt) }
        bind([hour - Int64(chartHours - 1) * hourMS, hour], to: historyStmt)
        while sqlite3_step(historyStmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(historyStmt, 0))
            if ids.contains(id) { oiHistory[id, default: [:]][sqlite3_column_int64(historyStmt, 1)] = sqlite3_column_double(historyStmt, 2) }
        }
        let emaStmt = try statement("SELECT inst_id,hour,value FROM ema200")
        defer { sqlite3_finalize(emaStmt) }
        while sqlite3_step(emaStmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(emaStmt, 0))
            if ids.contains(id) { ema[id] = (sqlite3_column_int64(emaStmt, 1), sqlite3_column_double(emaStmt, 2)) }
        }
        return (candles, oi, oiHistory, ema)
    }

    func save(_ id: String, _ bar: Candle) throws {
        guard bar.confirmed else { return }
        try execute("INSERT INTO candles (inst_id,hour,high,low,close,volume,base_volume,open) VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(inst_id,hour) DO UPDATE SET base_volume=COALESCE(excluded.base_volume,candles.base_volume),open=COALESCE(excluded.open,candles.open)", [id, bar.hour, bar.high, bar.low, bar.close, bar.quoteVolume, bar.baseVolume, bar.open])
    }

    func saveCandles(_ id: String, _ bars: [Candle]) throws {
        guard !bars.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            for bar in bars { try save(id, bar) }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func saveChartStat(_ id: String, hour: Int64, oi: Double? = nil, sell: Double? = nil, buy: Double? = nil, oiContracts: Double? = nil) throws {
        try execute("INSERT INTO chart_stats (inst_id,hour,oi,sell,buy,oi_contracts) VALUES (?,?,?,?,?,?) ON CONFLICT(inst_id,hour) DO UPDATE SET oi=COALESCE(excluded.oi,chart_stats.oi),sell=COALESCE(excluded.sell,chart_stats.sell),buy=COALESCE(excluded.buy,chart_stats.buy),oi_contracts=COALESCE(excluded.oi_contracts,chart_stats.oi_contracts)", [id, hour, oi, sell, buy, oiContracts])
    }

    func saveOIHistory(_ id: String, _ points: [Int64: Double]) throws {
        guard !points.isEmpty else { return }
        try execute("BEGIN IMMEDIATE")
        do {
            for (hour, value) in points { try saveChartStat(id, hour: hour, oiContracts: value) }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func chartStats(_ id: String, since: Int64) throws -> [Int64: (oi: Double?, sell: Double?, buy: Double?)] {
        let stmt = try statement("SELECT hour,oi,sell,buy FROM chart_stats WHERE inst_id=? AND hour>=?")
        defer { sqlite3_finalize(stmt) }
        bind([id, since], to: stmt)
        var result: [Int64: (oi: Double?, sell: Double?, buy: Double?)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            result[sqlite3_column_int64(stmt, 0)] = (
                sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 1),
                sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 2),
                sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 3))
        }
        return result
    }

    func prune(hour: Int64, ids: Set<String>) throws {
        let cutoff = hour - Int64(candleLookback) * hourMS
        try execute("DELETE FROM candles WHERE hour < ?", [cutoff])
        try execute("DELETE FROM chart_stats WHERE hour < ?", [hour - Int64(chartHours - 1) * hourMS])
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
