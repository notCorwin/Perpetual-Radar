import Foundation
import CSQLite

final class Store {
    private var db: OpaquePointer?

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw failure() }
        try execute("CREATE TABLE IF NOT EXISTS preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS market_filter_combinations (id TEXT PRIMARY KEY, name TEXT NOT NULL, name_key TEXT NOT NULL UNIQUE, filters_json TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS candles (inst_id TEXT, hour INTEGER, high REAL, low REAL, close REAL, volume REAL, base_volume REAL, open REAL, PRIMARY KEY(inst_id,hour))")
        try execute("CREATE TABLE IF NOT EXISTS ema200 (inst_id TEXT PRIMARY KEY, hour INTEGER, value REAL)")
        try execute("CREATE TABLE IF NOT EXISTS chart_stats (inst_id TEXT, hour INTEGER, oi REAL, sell REAL, buy REAL, PRIMARY KEY(inst_id,hour))")
        try execute("CREATE INDEX IF NOT EXISTS candles_hour ON candles(hour)")
        try execute("CREATE INDEX IF NOT EXISTS chart_stats_hour ON chart_stats(hour)")
        // Existing Python caches may predate base_volume.
        if !columns("candles").contains("base_volume") { try execute("ALTER TABLE candles ADD COLUMN base_volume REAL") }
        if !columns("candles").contains("open") { try execute("ALTER TABLE candles ADD COLUMN open REAL") }
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

    func preference(forKey key: String) throws -> String? {
        let stmt = try statement("SELECT value FROM preferences WHERE key=?")
        defer { sqlite3_finalize(stmt) }
        bind([key], to: stmt)
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return String(cString: sqlite3_column_text(stmt, 0))
        case SQLITE_DONE: return nil
        default: throw failure()
        }
    }

    func setPreference(_ value: String, forKey key: String) throws {
        try execute("INSERT INTO preferences (key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, value])
    }

    func transaction<T>(_ action: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try action()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func marketFilterCombinations() throws -> [MarketFilterCombination] {
        let stmt = try statement("SELECT id,name,filters_json FROM market_filter_combinations ORDER BY name COLLATE NOCASE")
        defer { sqlite3_finalize(stmt) }
        var result: [MarketFilterCombination] = []
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            result.append(MarketFilterCombination(id: String(cString: sqlite3_column_text(stmt, 0)),
                                                 name: String(cString: sqlite3_column_text(stmt, 1)),
                                                 filtersJSON: String(cString: sqlite3_column_text(stmt, 2))))
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return result
    }

    func saveMarketFilterCombination(name: String, filtersJSON: String) throws -> MarketFilterCombination {
        let stmt = try statement("INSERT INTO market_filter_combinations (id,name,name_key,filters_json) VALUES (?,?,?,?) ON CONFLICT(name_key) DO UPDATE SET name=excluded.name,filters_json=excluded.filters_json RETURNING id,name,filters_json")
        defer { sqlite3_finalize(stmt) }
        bind([UUID().uuidString, name, name.lowercased(), filtersJSON], to: stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure() }
        let result = MarketFilterCombination(id: String(cString: sqlite3_column_text(stmt, 0)),
                                             name: String(cString: sqlite3_column_text(stmt, 1)),
                                             filtersJSON: String(cString: sqlite3_column_text(stmt, 2)))
        // Finish the statement so the write commits before acknowledging the save.
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
        return result
    }

    func deleteMarketFilterCombination(_ id: String) throws -> Bool {
        try execute("DELETE FROM market_filter_combinations WHERE id=?", [id])
        return sqlite3_changes(db) > 0
    }

    func load(hour: Int64, ids: Set<String>) throws -> (candles: [String: [Int64: Candle]], ema: [String: (Int64, Double)]) {
        var candles: [String: [Int64: Candle]] = [:], ema: [String: (Int64, Double)] = [:]
        let candleStmt = try statement("SELECT inst_id,hour,high,low,close,volume,base_volume,open FROM candles WHERE hour >= ? AND hour < ?")
        defer { sqlite3_finalize(candleStmt) }
        bind([hour - Int64(candleLookback) * hourMS, hour], to: candleStmt)
        while sqlite3_step(candleStmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(candleStmt, 0))
            guard ids.contains(id) else { continue }
            let ts = sqlite3_column_int64(candleStmt, 1)
            candles[id, default: [:]][ts] = Candle(hour: ts, high: sqlite3_column_double(candleStmt, 2), low: sqlite3_column_double(candleStmt, 3), close: sqlite3_column_double(candleStmt, 4), quoteVolume: sqlite3_column_double(candleStmt, 5), baseVolume: sqlite3_column_type(candleStmt, 6) == SQLITE_NULL ? nil : sqlite3_column_double(candleStmt, 6), open: sqlite3_column_type(candleStmt, 7) == SQLITE_NULL ? nil : sqlite3_column_double(candleStmt, 7))
        }
        let emaStmt = try statement("SELECT inst_id,hour,value FROM ema200")
        defer { sqlite3_finalize(emaStmt) }
        while sqlite3_step(emaStmt) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(emaStmt, 0))
            if ids.contains(id) { ema[id] = (sqlite3_column_int64(emaStmt, 1), sqlite3_column_double(emaStmt, 2)) }
        }
        return (candles, ema)
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

    func candles(_ id: String, since: Int64, through: Int64) throws -> [Int64: Candle] {
        let stmt = try statement("SELECT hour,high,low,close,volume,base_volume,open FROM candles WHERE inst_id=? AND hour>=? AND hour<=? ORDER BY hour")
        defer { sqlite3_finalize(stmt) }
        bind([id, since, through], to: stmt)
        var result: [Int64: Candle] = [:]
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            let ts = sqlite3_column_int64(stmt, 0)
            result[ts] = Candle(hour: ts, high: sqlite3_column_double(stmt, 1), low: sqlite3_column_double(stmt, 2), close: sqlite3_column_double(stmt, 3), quoteVolume: sqlite3_column_double(stmt, 4), baseVolume: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 5), open: sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 6))
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return result
    }

    func oldestCandleHour(_ id: String) throws -> Int64? {
        let stmt = try statement("SELECT MIN(hour) FROM candles WHERE inst_id=? AND open IS NOT NULL")
        defer { sqlite3_finalize(stmt) }
        bind([id], to: stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure() }
        return sqlite3_column_type(stmt, 0) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 0)
    }

    func saveChartStat(_ id: String, hour: Int64, oi: Double? = nil, sell: Double? = nil, buy: Double? = nil) throws {
        try execute("INSERT INTO chart_stats (inst_id,hour,oi,sell,buy) VALUES (?,?,?,?,?) ON CONFLICT(inst_id,hour) DO UPDATE SET oi=COALESCE(excluded.oi,chart_stats.oi),sell=COALESCE(excluded.sell,chart_stats.sell),buy=COALESCE(excluded.buy,chart_stats.buy)", [id, hour, oi, sell, buy])
    }

    func openInterest(hour: Int64) throws -> [String: Double] {
        let stmt = try statement("SELECT inst_id,oi FROM chart_stats WHERE hour=? AND oi IS NOT NULL")
        defer { sqlite3_finalize(stmt) }
        bind([hour], to: stmt)
        var result: [String: Double] = [:]
        var status = sqlite3_step(stmt)
        while status == SQLITE_ROW {
            result[String(cString: sqlite3_column_text(stmt, 0))] = sqlite3_column_double(stmt, 1)
            status = sqlite3_step(stmt)
        }
        guard status == SQLITE_DONE else { throw failure() }
        return result
    }

    func chartStats(_ id: String, since: Int64, through: Int64 = .max) throws -> [Int64: (oi: Double?, sell: Double?, buy: Double?)] {
        let stmt = try statement("SELECT hour,oi,sell,buy FROM chart_stats WHERE inst_id=? AND hour>=? AND hour<=?")
        defer { sqlite3_finalize(stmt) }
        bind([id, since, through], to: stmt)
        var result: [Int64: (oi: Double?, sell: Double?, buy: Double?)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            result[sqlite3_column_int64(stmt, 0)] = (
                sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 1),
                sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 2),
                sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 3))
        }
        return result
    }
}
