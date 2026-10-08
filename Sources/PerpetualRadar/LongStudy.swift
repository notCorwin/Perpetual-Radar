import Foundation
import CSQLite

struct LongStudyCounters: Codable, Sendable { var evaluated = 0; var unknown = 0 }
struct LongStudyPosition: Codable, Sendable {
    var trade: ResearchLongTrade
    var favorable = 0.0
    var adverse = 0.0
    var missingHours = 0
    var funding = 0.0
    var fundingReason: String?
}
struct ResearchLongTrade: Codable, Sendable {
    var id: String
    var studyID: String
    var instrument: String
    var entryTime: Int64
    var entryPrice: Double?
    var exitTime: Int64?
    var exitPrice: Double?
    var status = "Open"
    var uncertain = false
    var unknownHours = 0
    var crossesSplit = false
    var entryEvent: ResearchEvent
    var exitEvent: ResearchEvent?
    var outcome = ResearchOutcome(hours: 0)
}
struct LongStudyReport: Codable, Sendable {
    var closed: Int
    var open: Int
    var incomplete: Int
    var uncertain: Int
    var grossProfit: Double?
    var netProfit: Double?
    var profitFactor: Double?
    var averageHours: Double?
}

enum LongStudyEngine {
    static let version = "long-filters-1"
    static func period(_ timestamp: Int64, manifest: DataManifest) -> Int {
        let span = manifest.through-manifest.from
        let a = manifest.from+Int64(Double(span)*0.6)/hourMS*hourMS, b = manifest.from+Int64(Double(span)*0.8)/hourMS*hourMS
        return timestamp < a ? 0 : timestamp < b ? 1 : 2
    }
    static func covered(_ ranges: [ResearchRange], from: Int64, through: Int64) -> Bool {
        var cursor = from
        for range in ranges.sorted(by: { $0.from < $1.from }) where range.through >= from {
            if range.from > cursor { break }
            cursor = max(cursor, range.through + hourMS)
            if cursor >= through { return true }
        }
        return cursor >= through
    }
    static func accrue(_ position: inout LongStudyPosition, hour: Int64, series: ResearchSeries) {
        guard hour >= position.trade.entryTime, let entry = position.trade.entryPrice else { return }
        if let bar = series.candles[hour], bar.confirmed, bar.open != nil {
            position.favorable = max(position.favorable, bar.high / entry - 1)
            position.adverse = min(position.adverse, bar.low / entry - 1)
        } else { position.missingHours += 1 }
        if series.missingFunding.contains(where: { $0 > hour && $0 <= hour + hourMS }) { position.fundingReason = "An actual funding settlement rate is missing." }
        for settlement in series.funding where settlement.timestamp > hour && settlement.timestamp <= hour + hourMS {
            if let mark = settlement.mark, mark.isFinite, mark > 0, settlement.rate.isFinite { position.funding += mark * settlement.rate }
            else { position.fundingReason = "A settlement mark price or actual funding rate is missing." }
        }
    }
    static func close(_ position: LongStudyPosition, at timestamp: Int64, exit: Double?, costs: ResearchCosts?, ranges: [ResearchRange]) -> ResearchOutcome {
        let hours = max(0, Int((timestamp-position.trade.entryTime)/hourMS))
        var outcome = ResearchOutcome(hours: hours)
        guard let entry = position.trade.entryPrice, let exit, entry > 0, exit > 0, hours > 0, position.missingHours == 0 else {
            outcome.reason = "An entry/exit open or a holding-period hour is missing."; return outcome
        }
        outcome.gross = exit / entry - 1; outcome.mfe = position.favorable; outcome.mae = position.adverse
        guard let costs else { outcome.netReason = "Enter both fees and slippage to calculate modeled net returns."; return outcome }
        guard covered(ranges, from: position.trade.entryTime, through: timestamp) else { outcome.netReason = "Actual funding-rate coverage is incomplete."; return outcome }
        guard position.fundingReason == nil else { outcome.netReason = position.fundingReason; return outcome }
        let pe = entry * (1 + costs.slippageBps/10_000), px = exit * (1 - costs.slippageBps/10_000), quantity = 1/pe
        outcome.net = quantity * (px-pe) - quantity * (pe*costs.entryFeeBps + px*costs.exitFeeBps)/10_000 - quantity*position.funding
        return outcome
    }
    static func run(store: ResearchStore, study: ResearchStudy, manifest: DataManifest, checkpoint: inout Checkpoint, progress: (Int, Int, String) -> Void) throws {
        let filters = try study.spec.rules.map { try FilterCompiler.compile(FilterConfigV2.decode($0.filtersJSON)) }
        let warmup = ResearchVersion.warmup(filters)
        for index in checkpoint.instrumentIndex..<manifest.instruments.count {
            let instrument = manifest.instruments[index]
            let first = max(manifest.from-hourMS, (instrument.listedAt ?? manifest.from)/hourMS*hourMS)
            let end = min(manifest.through, instrument.delistedAt ?? manifest.through)
            var hour = checkpoint.nextHour ?? first
            while hour < end {
                try ResearchPressure.shared.check()
                guard ProcessInfo.processInfo.thermalState != .critical else { throw FilterError("Research paused under critical thermal pressure. The checkpoint is retained.") }
                let last = min(end-hourMS, hour+63*hourMS), from = max(0, hour-Int64(warmup+1)*hourMS)
                let size = try store.count("SELECT COALESCE(SUM(length(json)),0) FROM research_pins p JOIN research_data d USING(revision) WHERE p.manifest=? AND d.inst=? AND d.ts>=? AND d.ts<=?", [manifest.id,instrument.id,from,last+hourMS])
                guard size < ResearchVersion.memoryBudget/4 else { throw FilterError("The lookback exceeds the 128 MiB research budget. Its checkpoint is retained.") }
                let series = ResearchEngine.reconstruct(try store.series(instrument.id, from: from, through: last+hourMS, manifest: manifest.id))
                try store.database.transaction {
                    for h in stride(from: hour, through: last, by: Int(hourMS)) {
                        try ResearchPressure.shared.check()
                        let timestamp = h+hourMS
                        var counters = checkpoint.longCounters ?? .init(); counters.evaluated += 1
                        var context = ResearchEngine.context(instrument: instrument, hour: h, series: series)
                        context.longEntryPrice = checkpoint.longPosition?.trade.entryPrice; context.longEnteredAt = checkpoint.longPosition?.trade.entryTime
                        let key = "indicator:"+researchHash(manifest.digest+manifest.engine+instrument.id+String(h))
                        let saved = try store.get(key, as: [String: ResearchCachedScalar].self)?.mapValues(\.scalar) ?? [:]
                        let entryEval = FilterEvaluator(market: context, filter: filters[0], sharedReadings: saved), entry = entryEval.evaluate()
                        let exitEval = FilterEvaluator(market: context, filter: filters[1], sharedReadings: entryEval.sharedReadings), exit = exitEval.evaluate()
                        try store.put(key, kind: "indicator", exitEval.sharedReadings.mapValues(ResearchCachedScalar.init))
                        try store.database.execute("INSERT OR IGNORE INTO research_indicator_pins VALUES (?,?)", [manifest.id,key])
                        if (checkpoint.longPosition == nil ? entry.result : exit.result) == .unknown { counters.unknown += 1 }
                        checkpoint.longCounters = counters
                        func event(rule: Int, trace: FilterTrace, role: String) throws -> ResearchEvent {
                            let opportunity = entryEval.opportunity(at: h)
                            return .init(id: researchHash("\(study.id)|long|\(instrument.id)|\(timestamp)|\(role)"), studyID: study.id, ruleIndex: rule, instrument: instrument.id, timestamp: timestamp, direction: "Long", entry: role,
                                score: opportunity.score, scoreComplete: ResearchEngine.scoreComplete(opportunity), status: opportunity.status, setup: opportunity.setup,
                                split: ResearchEngine.split(timestamp: timestamp, from: manifest.from, through: manifest.through), outcomes: [],
                                traceJSON: String(decoding: try JSONSerialization.data(withJSONObject: trace.snapshot, options: [.sortedKeys]), as: UTF8.self), opportunityJSON: String(decoding: try JSONSerialization.data(withJSONObject: opportunity.snapshot, options: [.sortedKeys]), as: UTF8.self),
                                sources: Array(Set(series.sources+[instrument.metadataSourceID].compactMap { $0 })).sorted())
                        }
                        if var position = checkpoint.longPosition {
                            accrue(&position, hour: h, series: series)
                            if exit.result == .unknown { position.trade.uncertain = true; position.trade.unknownHours += 1 }
                            if exit.result == .yes {
                                let price = series.candles[timestamp].flatMap { $0.confirmed ? $0.open : nil }
                                position.trade.exitTime = timestamp; position.trade.exitPrice = price
                                position.trade.crossesSplit = period(position.trade.entryTime, manifest: manifest) != period(timestamp, manifest: manifest)
                                position.trade.outcome = close(position, at: timestamp, exit: price, costs: study.spec.costs, ranges: series.fundingCoverage)
                                position.trade.status = position.trade.outcome.gross == nil ? "Incomplete" : position.trade.uncertain ? "Uncertain" : "Closed"
                                var exitEvent = try event(rule: 1, trace: exitEval.evaluate(explain: true), role: "Exit")
                                exitEvent.outcomes = [position.trade.outcome]; position.trade.exitEvent = exitEvent
                                position.trade.entryEvent.outcomes = [position.trade.outcome]
                                try store.saveLongTrade(position.trade); checkpoint.longPosition = nil
                            } else { checkpoint.longPosition = position }
                            // Exit has priority. There is no same-hour close/re-entry.
                        } else if timestamp < end, instrument.eligible(at: timestamp), entry.result == .yes {
                            let entryEvent = try event(rule: 0, trace: entryEval.evaluate(explain: true), role: "Entry")
                            let price = series.candles[timestamp].flatMap { $0.confirmed ? $0.open : nil }
                            var trade = ResearchLongTrade(id: entryEvent.id, studyID: study.id, instrument: instrument.id, entryTime: timestamp, entryPrice: price, entryEvent: entryEvent)
                            if price == nil { trade.status = "Incomplete"; trade.outcome.reason = "The next-hour entry open is missing." }
                            else { checkpoint.longPosition = .init(trade: trade) }
                            try store.saveLongTrade(trade)
                        }
                    }
                    if let position = checkpoint.longPosition { try store.saveLongTrade(position.trade) }
                    checkpoint.instrumentIndex = index; checkpoint.nextHour = last+hourMS; checkpoint.updatedAt = researchNow()
                    try store.put("checkpoint:\(study.id)", kind: "checkpoint", checkpoint)
                }
                hour = last+hourMS
                progress(index, manifest.instruments.count, "\(instrument.id) · Evaluating Long entries and exits · \(checkpoint.longCounters?.evaluated ?? 0) hourly decisions")
            }
            if var position = checkpoint.longPosition {
                position.trade.outcome.reason = instrument.delistedAt.map { $0 <= manifest.through } == true ? "The contract delisted before an executable exit. No liquidation price is invented." : "The exit filter did not close this Long within the selected range. No end-of-study sale is invented."
                try store.saveLongTrade(position.trade)
            }
            checkpoint.instrumentIndex = index+1; checkpoint.nextHour = nil; checkpoint.longPosition = nil
            try store.put("checkpoint:\(study.id)", kind: "checkpoint", checkpoint)
        }
    }
}

extension ResearchStore {
    func saveLongTrade(_ trade: ResearchLongTrade) throws {
        try database.execute("INSERT OR REPLACE INTO research_long_trades VALUES (?,?,?,?,?)", [trade.id,trade.studyID,trade.instrument,trade.entryTime,try researchJSON(trade)])
        for event in [trade.entryEvent,trade.exitEvent].compactMap({ $0 }) {
            try database.execute("INSERT OR REPLACE INTO research_events VALUES (?,?,?,?)", [event.id,trade.studyID,event.timestamp,try researchJSON(event)])
        }
    }
    func longTrades(_ study: String, offset: Int = 0, limit: Int = 50) throws -> [ResearchLongTrade] {
        var json: [String] = []
        try database.query("SELECT json FROM research_long_trades WHERE study=? ORDER BY ts,id LIMIT ? OFFSET ?", [study,Int64(min(100,max(1,limit))),Int64(max(0,offset))]) { json.append(Self.text($0,0)) }
        return try json.map { try JSONDecoder().decode(ResearchLongTrade.self, from: Data($0.utf8)) }
    }
    func longReport(_ study: ResearchStudy, manifest: DataManifest, counters: LongStudyCounters) throws -> StudyReport {
        let valid = "json_extract(json,'$.status')='Closed' AND json_extract(json,'$.entryEvent.split')!='Purged'"
        let gross = "json_extract(json,'$.outcome.gross')", net = "json_extract(json,'$.outcome.net')", duration = "json_extract(json,'$.outcome.hours')"
        let table = "research_long_trades WHERE study=?"
        var summaries: [ResearchSummary] = []
        for (group, extra) in [("Closed Long trades", valid),("Uncertain trades · Excluded", "json_extract(json,'$.status')='Uncertain'"),("Observation",valid+" AND json_extract(json,'$.crossesSplit')=0 AND json_extract(json,'$.entryEvent.split')='Observation'"),("Validation",valid+" AND json_extract(json,'$.crossesSplit')=0 AND json_extract(json,'$.entryEvent.split')='Validation'"),("Holdout",valid+" AND json_extract(json,'$.crossesSplit')=0 AND json_extract(json,'$.entryEvent.split')='Holdout'")] {
            var s = ResearchSummary(group: group,ruleIndex: 0,hours: 0,count: 0,excluded: 0,netCount: 0)
            try database.query("SELECT COUNT(\(gross)),COUNT(*)-COUNT(\(gross)),COUNT(\(net)),AVG(\(gross)),AVG(CASE WHEN \(gross) IS NOT NULL THEN \(gross)>0 END),AVG(\(net)),AVG(CASE WHEN \(net) IS NOT NULL THEN \(net)>0 END),AVG(json_extract(json,'$.outcome.mfe')),AVG(json_extract(json,'$.outcome.mae')) FROM \(table) AND \(extra)", [study.id]) {
                s.count = Int(sqlite3_column_int64($0,0)); s.excluded = Int(sqlite3_column_int64($0,1)); s.netCount = Int(sqlite3_column_int64($0,2)); s.mean = Self.number($0,3); s.winRate = Self.number($0,4); s.netMean = Self.number($0,5); s.netWinRate = Self.number($0,6); s.mfe = Self.number($0,7); s.mae = Self.number($0,8)
            }
            for modeled in [false,true] {
                let metric = modeled ? net : gross, count = modeled ? s.netCount : s.count
                if count > 0 {
                    var values: [Double] = []
                    try database.query("SELECT \(metric) FROM \(table) AND \(extra) AND \(metric) IS NOT NULL ORDER BY \(metric) LIMIT ? OFFSET ?", [study.id,Int64(count%2 == 0 ? 2 : 1),Int64((count-1)/2)]) { values.append(sqlite3_column_double($0,0)) }
                    let median = values.reduce(0,+)/Double(values.count)
                    if modeled { s.netMedian = median } else { s.median = median }
                }
                var blocks: [(Double,Int)] = []
                try database.query("SELECT SUM(\(metric)),COUNT(\(metric)) FROM \(table) AND \(extra) AND \(metric) IS NOT NULL GROUP BY (ts+?)/? ORDER BY (ts+?)/?", [study.id,3*24*hourMS,7*24*hourMS,3*24*hourMS,7*24*hourMS]) { blocks.append((sqlite3_column_double($0,0),Int(sqlite3_column_int64($0,1)))) }
                var bootstrap = ResearchBootstrap()
                if group != "Uncertain trades · Excluded", let interval = bootstrap.interval(blocks) {
                    if modeled { s.netIntervalLow = interval.0; s.netIntervalHigh = interval.1 } else { s.intervalLow = interval.0; s.intervalHigh = interval.1 }
                }
            }
            summaries.append(s)
        }
        func stateCount(_ status: String) throws -> Int { try count("SELECT COUNT(*) FROM \(table) AND json_extract(json,'$.status')=?", [study.id,status]) }
        var details = LongStudyReport(closed: try stateCount("Closed"),open: try stateCount("Open"),incomplete: try stateCount("Incomplete"),uncertain: try stateCount("Uncertain"))
        try database.query("SELECT SUM(\(gross)),SUM(\(net)),AVG(\(duration)),SUM(CASE WHEN \(gross)>0 THEN \(gross) ELSE 0 END),SUM(CASE WHEN \(gross)<0 THEN -\(gross) ELSE 0 END) FROM \(table) AND \(valid)", [study.id]) {
            details.grossProfit = Self.number($0,0); details.netProfit = Self.number($0,1); details.averageHours = Self.number($0,2)
            if let losses = Self.number($0,4), losses > 0 { details.profitFactor = (Self.number($0,3) ?? 0)/losses }
        }
        return StudyReport(studyID: study.id,manifestID: manifest.id,spec: study.spec,summaries: summaries,evaluated: counters.evaluated,unknown: counters.unknown,directionless: 0,uncertain: details.uncertain,baseline: 0,commonPool: counters.evaluated-counters.unknown,
            warnings: manifest.warnings+["Long only. Start flat; enter and exit at the next hourly open. Entry applies while flat, exit while holding; no same-hour re-entry. Open, uncertain, incomplete and purged trades are excluded from primary statistics. Trades crossing a time-split boundary are excluded from that split's statistics. Each trade starts with 1 USDT notional; totals are not portfolio or leveraged returns."],long: details)
    }
}
