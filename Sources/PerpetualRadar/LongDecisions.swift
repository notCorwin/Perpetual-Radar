import Foundation

struct LongStrategy: Codable, Sendable {
    var id = UUID().uuidString
    var name: String
    var entryJSON: String
    var exitJSON: String
    var revision = 0
    var updatedAt = researchNow()
    func compiled() throws -> (CompiledFilter, CompiledFilter) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80 else { throw FilterError("Use a strategy name from 1 to 80 characters.") }
        let entry = try FilterCompiler.compile(FilterConfigV2.decode(entryJSON)), exit = try FilterCompiler.compile(FilterConfigV2.decode(exitJSON))
        guard entry.metrics.isDisjoint(with: StrategyProfile.longMetrics.union(StrategyProfile.shortMetrics)) else { throw FilterError("Long position readings belong in the exit filter; no position exists before entry.") }
        for (label, rule) in [("entry", entry), ("exit", exit)] {
            guard !(["all", "any"].contains(rule.config.root.kind) && rule.config.root.children.isEmpty) else { throw FilterError("Add at least one \(label) condition. An empty market filter matches every contract.") }
        }
        return (entry, exit)
    }
}

// These are explicit user records, not an inferred exchange account or an order.
struct LongTrackedPosition: Codable, Sendable {
    var id = UUID().uuidString
    var strategyID: String
    var instrument: String
    var enteredAt: Int64
    var entryPrice: Double
    var strategy: LongStrategy
    var exitedAt: Int64?
    var exitPrice: Double?
    var exitStrategy: LongStrategy?
}

struct LongDecisionRow: Codable, Sendable {
    var instrument: String
    var hour: Int64
    var entry: String
    var exit: String
    var action: String
    var reason: String
    var price: Double?
    var position: LongTrackedPosition?
    var entryTraceJSON: String?
    var exitTraceJSON: String?
    var btcExit = false
}

enum LongDecision {
    static func action(entry: FilterTruth, exit: FilterTruth, holding: Bool, available: Bool = true) -> (String, String) {
        guard available else { return ("Unknown", "Monitoring is paused or the completed hourly price is unavailable. Tracking is retained.") }
        if holding {
            if exit == .yes { return ("Exit Long", "The exit filter matches. Record your actual exit when you close the position.") }
            if exit == .unknown { return ("Unknown", "The exit filter has missing inputs. The tracked Long remains open.") }
            return ("Hold Long", "The exit filter does not match. Repeated entry matches do not open another position.")
        }
        if entry == .unknown { return ("Unknown", "An entry input is missing. Unknown does not create a position.") }
        return entry == .yes ? ("Enter Long", "The entry filter matches while flat. Exit rules become active after entry. Record your actual entry after trading.") : ("Wait", "The entry filter does not match.")
    }
    static func context(_ input: FilterMarketData, forming: Bool) -> FilterMarketData {
        if forming { return input }
        var market = input
        market.evaluationTime = input.evaluationTime ?? input.now
        market.hour -= hourMS; market.now = market.hour + hourMS
        market.current = [:]; market.previousEMA = nil; market.historicalClose = true
        let series = ResearchEngine.reconstruct(ResearchSeries(candles: market.candles, stats: market.stats, quotes: market.quotes))
        market.quotes = series.quotes
        return market
    }
}

actor LongDecisionWorker {
    func evaluate(_ markets: [FilterMarketData], strategy: LongStrategy, positions: [LongTrackedPosition], forming: Bool, available: Bool, detailID: String? = nil, reference: FilterReferenceSnapshot? = nil) throws -> [LongDecisionRow] {
        let (entry, exit) = try strategy.compiled()
        let held = Dictionary(uniqueKeysWithValues: positions.filter { $0.strategyID == strategy.id && $0.exitedAt == nil }.map { ($0.instrument, $0) })
        let present = Set(markets.map(\.id))
        let btc = reference ?? markets.first?.referenceBTC
        let unavailable = held.values.filter { !present.contains($0.instrument) }.map { position in
            FilterMarketData(id: position.instrument, hour: btc?.market.hour ?? researchNow()/hourMS*hourMS, now: btc?.market.now ?? researchNow(), listedAt: nil, candles: [:], stats: [:], quotes: [:], referenceBTC: btc, evaluationTime: btc?.market.now, cooldowns: markets.first?.cooldowns)
        }
        return try (markets + unavailable).map { original in
            try Task.checkCancellation()
            var market = LongDecision.context(original, forming: forming)
            if forming { market.recordCooldowns = false }
            market.longEntryPrice = held[market.id]?.entryPrice; market.longEnteredAt = held[market.id]?.enteredAt
            let explain = original.id == detailID
            let e = FilterEvaluator(market: market, filter: entry), a = e.evaluate(explain: explain)
            var b = FilterEvaluator(market: market, filter: exit, sharedReadings: e.sharedReadings).evaluate(explain: explain)
            let readingTime = forming ? market.now : market.hour+hourMS
            let waitingForEntryClose = held[market.id].map { $0.enteredAt >= readingTime } == true
            let ready = available && !waitingForEntryClose && market.candles[market.hour].map { forming ? !$0.confirmed : $0.confirmed } == true
            var decision = LongDecision.action(entry: a.result, exit: b.result, holding: held[market.id] != nil, available: ready)
            if waitingForEntryClose { decision = ("Unknown", "Waiting for the first evaluated close after your actual entry. The tracked Long remains open.") }
            var btcExit = false
            if available, held[market.id] != nil, exit.referencesBTC {
                var confirmed = LongDecision.context(original, forming: false)
                confirmed.longEntryPrice = market.longEntryPrice; confirmed.longEnteredAt = market.longEnteredAt
                let referenceEvaluator = FilterEvaluator(market: confirmed, filter: exit, referenceOnly: true)
                let independent = referenceEvaluator.evaluate(explain: explain)
                if independent.result == .yes, independent.referenceDriven {
                    btcExit = true; b = explain ? independent : referenceEvaluator.evaluate(explain: true)
                    func causes(_ trace: FilterTrace) -> [String] {
                        guard trace.result == .yes else { return [] }
                        if !trace.readingSources.isEmpty { return [trace.label] }
                        if trace.reason.hasPrefix("Cooldown remains active") { return [trace.reason] }
                        return trace.children.flatMap(causes)
                    }
                    let reason = Array(Set(causes(b))).sorted().joined(separator: "; ")
                    decision = ("Exit Long", "Confirmed BTC risk: \(reason.isEmpty ? "the BTC exit rule matches" : reason). Independent of the contract close and forming-hour preview.")
                }
            }
            func json(_ trace: FilterTrace) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: trace.snapshot, options: [.sortedKeys]), as: UTF8.self) }
            return LongDecisionRow(instrument: market.id, hour: market.hour, entry: a.result.rawValue, exit: b.result.rawValue, action: decision.0, reason: decision.1,
                price: market.candles[market.hour]?.close, position: held[market.id],
                entryTraceJSON: explain ? try json(a) : nil, exitTraceJSON: explain ? try json(b) : nil, btcExit: btcExit)
        }
    }
}

extension Store {
    func longStrategies() throws -> [LongStrategy] {
        try preference(forKey: "longStrategies").map { try JSONDecoder().decode([LongStrategy].self, from: Data($0.utf8)) } ?? []
    }
    func longPositions() throws -> [LongTrackedPosition] {
        try preference(forKey: "longPositions").map { try JSONDecoder().decode([LongTrackedPosition].self, from: Data($0.utf8)) } ?? []
    }
    func saveLongStrategy(_ input: LongStrategy) throws -> LongStrategy {
        var result = input; let (entry, exit) = try input.compiled()
        result.name = input.name.trimmingCharacters(in: .whitespacesAndNewlines); result.entryJSON = entry.config.json; result.exitJSON = exit.config.json
        if result.id.isEmpty { result.id = UUID().uuidString }
        try transaction {
            var list = try longStrategies()
            guard !list.contains(where: { $0.id != result.id && $0.name.lowercased() == result.name.lowercased() }) else { throw FilterError("A strategy with this name already exists.") }
            if let previous = list.first(where: { $0.id == result.id }) {
                guard previous.revision == result.revision else { throw FilterError("This strategy changed. Reload it before saving.") }
            } else { guard result.revision == 0 else { throw FilterError("The strategy no longer exists. Save a new copy.") } }
            result.revision += 1; result.updatedAt = researchNow()
            list.removeAll { $0.id == result.id }; list.insert(result, at: 0)
            try setPreference(try researchJSON(list), forKey: "longStrategies")
        }
        return result
    }
    func deleteLongStrategy(_ id: String) throws {
        try transaction {
            guard !(try longPositions()).contains(where: { $0.strategyID == id && $0.exitedAt == nil }) else { throw FilterError("Close or remove this strategy's tracked positions before deleting it.") }
            try setPreference(try researchJSON(try longStrategies().filter { $0.id != id }), forKey: "longStrategies")
        }
    }
    func trackLong(strategyID: String, instrument: String, price: Double, timestamp: Int64, close: Bool) throws {
        guard price.isFinite, price > 0, timestamp > 0, timestamp <= researchNow(), instrument.hasSuffix("-USDT-SWAP") else { throw FilterError("Enter a positive actual price and a valid entry/exit time.") }
        try transaction {
            guard let strategy = try longStrategies().first(where: { $0.id == strategyID }) else { throw FilterError("Save and select a strategy first.") }
            var records = try longPositions()
            let index = records.firstIndex { $0.strategyID == strategyID && $0.instrument == instrument && $0.exitedAt == nil }
            if close {
                guard let index, timestamp >= records[index].enteredAt else { throw FilterError("The exit must follow an existing tracked entry.") }
                records[index].exitedAt = timestamp; records[index].exitPrice = price; records[index].exitStrategy = strategy
            } else {
                guard index == nil else { throw FilterError("This contract already has a tracked Long in this strategy.") }
                records.append(.init(strategyID: strategyID, instrument: instrument, enteredAt: timestamp, entryPrice: price, strategy: strategy))
            }
            try setPreference(try researchJSON(records), forKey: "longPositions")
        }
    }
    func removeLongTracking(_ id: String) throws {
        try setPreference(try researchJSON(try longPositions().filter { $0.id != id }), forKey: "longPositions")
    }
}
