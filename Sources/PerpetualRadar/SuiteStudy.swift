import Foundation
import CSQLite

struct SuiteCapitalSettings: Codable, Sendable {
    var initial = 10_000.0
    var allocation = 1.0
    var leverage = 1.0
    var maintenanceRate: Double?
    var liquidationFeeBps: Double?
    func validate(costs: ResearchCosts?) throws {
        guard initial.isFinite, initial > 0, allocation.isFinite, allocation > 0, allocation <= 1, leverage.isFinite, leverage >= 1,
              let maintenanceRate, maintenanceRate.isFinite, maintenanceRate >= 0, maintenanceRate < 1,
              let liquidationFeeBps, liquidationFeeBps.isFinite, liquidationFeeBps >= 0, liquidationFeeBps < 10_000,
              leverage * (maintenanceRate + (liquidationFeeBps + (costs?.entryFeeBps ?? 0))/10_000) < 1 else {
            throw FilterError("Enter positive capital, allocation above 0 through 100%, leverage ≥ 1, and explicit maintenance/ liquidation fee values. The initial position must exceed maintenance and liquidation reserves.")
        }
    }
}
struct SuiteCapital: Codable, Sendable {
    var defaults = SuiteCapitalSettings()
    var overrides: [String: SuiteCapitalSettings] = [:]
    func settings(_ instrument: String) -> SuiteCapitalSettings { overrides[instrument] ?? defaults }
    func validate(costs: ResearchCosts?) throws { try defaults.validate(costs: costs); for settings in overrides.values { try settings.validate(costs: costs) } }
}

struct SuiteIntent: Sendable {
    var exit = false
    var enter: String?
    var phase: SuitePhase?
    var uncertain = false
    var reason = ""
}
struct SuiteSignals: Codable, Sendable {
    var episodes: [String: ResearchEpisode] = [:]
    var pending: String?
    mutating func step(_ traces: [FilterTrace], holding: String?, execution: SuiteExecution, baseline: Bool = false, eligible: Bool = true) -> SuiteIntent {
        var events: [String: String] = [:]
        for phase in [SuitePhase.bullishSetup, .bearishReversal] {
            var episode = episodes[phase.rawValue] ?? .init()
            events[phase.rawValue] = episode.observe(SuiteEvaluation.truth(traces, phase), baseline: baseline)
            episodes[phase.rawValue] = episode
        }
        let setup = SuiteEvaluation.truth(traces, .bullishSetup), reversal = SuiteEvaluation.truth(traces, .bearishReversal)
        let conflict = setup == .yes && reversal == .yes
        let entryPhase: SuitePhase? = !conflict && setup == .yes ? .bullishSetup : !conflict && reversal == .yes ? .bearishReversal : nil
        let entryDirection = entryPhase.map { $0 == .bullishSetup ? "Long" : "Short" }
        let canEnter = !baseline && eligible && traces[0].result == .yes && entryPhase != nil
        if let holding {
            pending = nil
            let exhaustion: SuitePhase = holding == "Long" ? .bullishExhaustion : .bearishExhaustion
            let opposite: SuitePhase = holding == "Long" ? .bearishReversal : .bullishSetup
            let oppositeMatch = SuiteEvaluation.truth(traces, opposite) == .yes
            let useOpposite = holding == "Short" || execution.opposite != "dedicatedOnly"
            let exit = SuiteEvaluation.truth(traces, exhaustion) == .yes || useOpposite && oppositeMatch
            guard exit else { return .init(reason: "Hold") }
            let phase = SuiteEvaluation.truth(traces, exhaustion) == .yes ? exhaustion : opposite
            if oppositeMatch && canEnter && entryDirection != holding {
                if execution.opposite == "reverse" { return .init(exit: true, enter: entryDirection, phase: phase, reason: "Reverse at next open") }
                if execution.opposite == "exitThenWait" { pending = entryDirection }
            }
            return .init(exit: true, phase: phase, reason: phase.label)
        }
        if let waiting = pending {
            pending = nil
            if canEnter && entryDirection == waiting { return .init(enter: waiting, phase: entryPhase, reason: "Opposite signal reconfirmed after exit") }
            return .init(reason: "Pending direction cancelled")
        }
        guard canEnter, let phase = entryPhase else { return .init(reason: conflict ? "Conflict" : "Wait") }
        let event = events[phase.rawValue]
        guard execution.entry == "matchWhileFlat" || event != nil else { return .init(reason: "Existing phase episode") }
        return .init(enter: entryDirection, phase: phase, uncertain: event == "uncertain", reason: phase.label)
    }
}

struct SuiteTrade: Codable, Sendable {
    var id: String
    var studyID: String
    var profileID: String
    var profileName: String
    var model: String
    var instrument: String
    var direction: String
    var entryTime: Int64
    var entryPrice: Double
    var margin: Double
    var quantity: Double
    var exitTime: Int64?
    var exitPrice: Double?
    var liquidationFrom: Int64?
    var liquidationThrough: Int64?
    var status = "Open"
    var reason = ""
    var uncertain = false
    var crossesSplit = false
    var profit: Double?
    var returnValue: Double?
    var priceReturn: Double?
    var mfe = 0.0
    var mae = 0.0
    var mfeIncomplete = false
    var maeIncomplete = false
    var holdingHoursLow: Double?
    var holdingHoursHigh: Double?
    var fees = 0.0
    var funding = 0.0
    var entryEvent: ResearchEvent
    var exitEvent: ResearchEvent?
}
struct SuiteStudyPosition: Codable, Sendable {
    var trade: SuiteTrade
    var collateral: Double
    var sign: Double { trade.direction == "Long" ? 1 : -1 }
    func equity(_ price: Double) -> Double { collateral + sign * trade.quantity * (price-trade.entryPrice) }
    func liquidationPrice(rate: Double) -> Double? {
        let p = (collateral-sign*trade.quantity*trade.entryPrice)/(trade.quantity*(rate-sign))
        return p.isFinite && p > 0 ? p : nil
    }
}
struct SuiteWallet: Codable, Sendable {
    var model: String
    var cash: Double
    var position: SuiteStudyPosition?
    var signals = SuiteSignals()
    var peak: Double
    var lastEquity: Double
    var maxDrawdown = 0.0
    var incompleteReason: String?
    var uncertain = false
    var evaluated = 0
    var unknown = 0
    var common = 0
    var baseline = 0
    init(model: String, initial: Double) { self.model = model; cash = initial; peak = initial; lastEquity = initial }
}
struct SuiteCheckpoint: Codable, Sendable {
    var strategyIndex = 0
    var wallets: [String: SuiteWallet] = [:]
}
struct SuiteCurvePoint: Codable, Sendable {
    var timestamp: Int64
    var equity: Double
    var drawdown: Double
    var direction: String?
    var uncertain: Bool
}
struct SuiteAccount: Codable, Sendable {
    var profileID: String
    var profileName: String
    var instrument: String
    var model: String
    var initial: Double
    var endingEquity: Double
    var returnValue: Double
    var maxDrawdown: Double?
    var observedDrawdown: Double
    var status: String
    var reason: String?
    var openDirection: String?
    var evaluated = 0
    var unknown = 0
    var common = 0
    var baseline = 0
}
struct SuiteSummary: Codable, Sendable {
    var profileID: String
    var profileName: String
    var model: String
    var instrument: String?
    var direction: String?
    var split: String?
    var count: Int
    var excluded: Int
    var open: Int
    var liquidations: Int
    var winRate: Double?
    var mean: Double?
    var payoffRatio: Double?
    var payoffInfinite = false
    var profitFactor: Double?
    var profitFactorInfinite = false
    var profit: Double?
    var averageHours: Double?
    var averageHoursLow: Double?
    var mfe: Double?
    var mae: Double?
    var intervalLow: Double?
    var intervalHigh: Double?
    var incomplete = 0
    var uncertain = 0
    var crossSplit = 0
    var purged = 0
}
struct SuiteStudyReport: Codable, Sendable {
    var summaries: [SuiteSummary]
    var accounts: [SuiteAccount]
}

enum SuiteStudyEngine {
    static let version = "suite-cycle-1"
    static func event(study: ResearchStudy, profile: StrategyProfile, profileIndex: Int, instrument: ResearchInstrument, hour: Int64, phase: SuitePhase, traces: [FilterTrace], model: String, role: String, series: ResearchSeries, manifest: DataManifest, referenceSources: [String] = []) throws -> ResearchEvent {
        let object: [String: Any] = ["id": profile.id, "label": profile.name + " · " + role, "result": "true", "hour": hour, "readings": [:] as [String: String], "reason": phase.label, "children": traces.map(\.snapshot), "eventHours": [hour]]
        return .init(id: researchHash("\(study.id)|\(profile.id)|\(instrument.id)|\(hour)|\(model)|\(role)"), studyID: study.id, ruleIndex: profileIndex*5+1+SuitePhase.allCases.firstIndex(of: phase)!, instrument: instrument.id, timestamp: hour+hourMS, direction: phase == .bullishSetup || phase == .bullishExhaustion ? "Long" : "Short", entry: role, score: nil, scoreComplete: false, status: phase.label, setup: nil, split: ResearchEngine.split(timestamp: hour+hourMS, from: manifest.from, through: manifest.through), outcomes: [], traceJSON: String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self), opportunityJSON: "{}", sources: Array(Set(series.sources+[instrument.metadataSourceID].compactMap { $0 }+referenceSources)).sorted())
    }
    static func close(_ wallet: inout SuiteWallet, at time: Int64, price: Double, feeBps: Double, event: ResearchEvent, reason: String, manifest: DataManifest, liquidationHour: Int64? = nil, exactTime: Bool = true) -> SuiteTrade? {
        guard var position = wallet.position else { return nil }
        let fee = position.trade.quantity*price*feeBps/10_000
        let payout = max(0, position.equity(price)-fee)
        wallet.cash += payout
        position.trade.exitTime = time; position.trade.exitPrice = price; position.trade.fees += fee
        position.trade.profit = payout-position.trade.margin; position.trade.returnValue = (payout-position.trade.margin)/position.trade.margin
        position.trade.priceReturn = position.sign*(price-position.trade.entryPrice)/abs(position.trade.entryPrice)
        position.trade.mfe = max(position.trade.mfe,position.trade.priceReturn!)
        position.trade.mae = min(position.trade.mae,position.trade.priceReturn!)
        position.trade.holdingHoursHigh = Double(time-position.trade.entryTime)/Double(hourMS)
        position.trade.holdingHoursLow = exactTime ? position.trade.holdingHoursHigh : Double(max(0,(liquidationHour ?? time)-position.trade.entryTime))/Double(hourMS)
        position.trade.exitEvent = event; position.trade.reason = reason
        position.trade.crossesSplit = LongStudyEngine.period(position.trade.entryTime, manifest: manifest) != LongStudyEngine.period(time, manifest: manifest)
        position.trade.status = position.trade.uncertain ? "Uncertain" : "Closed"
        if let h = liquidationHour { position.trade.liquidationFrom = h; position.trade.liquidationThrough = h+hourMS }
        wallet.position = nil
        return position.trade
    }
    static func run(store: ResearchStore, study: ResearchStudy, manifest: DataManifest, checkpoint: inout Checkpoint, progress: (Int, Int, String) -> Void) throws {
        let profiles = study.spec.strategySnapshots!, capital = study.spec.capital!, execution = study.spec.execution!
        let compiled = try profiles.map { try $0.compiled() }, warmup = ResearchVersion.warmup(compiled.flatMap { $0 })
        let referencesBTC = compiled.flatMap { $0 }.contains(where: \.referencesBTC)
        var saved = checkpoint.suite ?? .init()
        for profileIndex in saved.strategyIndex..<profiles.count {
            let profile = profiles[profileIndex]
            for index in checkpoint.instrumentIndex..<manifest.instruments.count {
                let instrument = manifest.instruments[index], settings = capital.settings(instrument.id)
                let first = max(manifest.from-hourMS, (instrument.listedAt ?? manifest.from)/hourMS*hourMS)
                let end = min(manifest.through, instrument.delistedAt ?? manifest.through)
                var hour = checkpoint.nextHour ?? first
                if saved.wallets.isEmpty {
                    saved.wallets["Gross"] = .init(model: "Gross", initial: settings.initial)
                    if study.spec.costs != nil { saved.wallets["Net"] = .init(model: "Net", initial: settings.initial) }
                }
                while hour < end {
                    try ResearchPressure.shared.check()
                    guard ProcessInfo.processInfo.thermalState != .critical else { throw FilterError("Research paused under critical thermal pressure. Resume from its saved checkpoint.") }
                    let last = min(end-hourMS, hour+63*hourMS), from = max(0, hour-Int64(warmup+1)*hourMS)
                    let size = try store.count("SELECT COALESCE(SUM(length(json)),0) FROM research_pins p JOIN research_data d USING(revision) WHERE p.manifest=? AND d.inst IN (?,?) AND d.ts>=? AND d.ts<=?", [manifest.id,instrument.id,referencesBTC ? btcReferenceID : instrument.id,from,last+hourMS])
                    guard size < ResearchVersion.memoryBudget/4 else { throw FilterError("The lookback exceeds the research working budget. Its checkpoint is retained.") }
                    let series = ResearchEngine.reconstruct(try store.series(instrument.id, from: from, through: last+hourMS, manifest: manifest.id))
                    let reference = try ResearchEngine.btcSeries(store:store,manifest:manifest,from:from,through:last,required:referencesBTC)
                    try store.database.transaction {
                        for h in stride(from: hour, through: last, by: Int(hourMS)) {
                            try ResearchPressure.shared.check()
                            let time = h+hourMS, base = ResearchEngine.context(instrument: instrument, hour: h, series: series,reference:reference)
                            // All compared versions use the same available entry-input pool.
                            let common = compiled.allSatisfy { rules in
                                [0,1,3].allSatisfy { FilterEvaluator(market: base, filter: rules[$0]).evaluate().result != .unknown }
                            }
                            for model in saved.wallets.keys.sorted() {
                                var wallet = saved.wallets[model]!
                                guard wallet.incompleteReason == nil else { continue }
                                let costs = model == "Net" ? study.spec.costs : nil, liquidationFee = costs == nil ? 0 : settings.liquidationFeeBps!
                                let rate = settings.maintenanceRate!+liquidationFee/10_000
                                if h >= manifest.from { wallet.evaluated += 1; wallet.common += common ? 1 : 0 }
                                var liquidated = false
                                if var position = wallet.position {
                                    guard let bar = series.candles[h], bar.confirmed, let open = bar.open else {
                                        wallet.incompleteReason = "A holding-period OHLC hour is missing. Capital simulation stops without filling the gap."
                                        position.trade.status = "Incomplete"; position.trade.reason = wallet.incompleteReason!; wallet.position = position
                                        try store.saveSuiteTrade(position.trade); saved.wallets[model] = wallet; continue
                                    }
                                    let openingGap = position.equity(open) <= position.trade.quantity*open*rate
                                    // A position closed at the open cannot owe later settlements.
                                    if costs != nil && !openingGap && (!LongStudyEngine.covered(series.fundingCoverage, from: h, through: time) || series.missingFunding.contains(where: { $0 > h && $0 <= time }) || !series.funding.filter({ $0.timestamp > h && $0.timestamp <= time }).allSatisfy({ $0.mark.map { $0.isFinite && $0 > 0 } == true && $0.rate.isFinite })) {
                                        wallet.incompleteReason = "Actual funding coverage, a rate or a settlement mark is missing. Net capital simulation stops here."
                                        position.trade.status = "Incomplete"; position.trade.reason = wallet.incompleteReason!; wallet.position = position
                                        try store.saveSuiteTrade(position.trade); saved.wallets[model] = wallet; continue
                                    }
                                    let adverse = position.sign > 0 ? bar.low : bar.high, favorable = position.sign > 0 ? bar.high : bar.low
                                    wallet.position = position
                                    if openingGap || position.liquidationPrice(rate: rate).map({ position.sign > 0 ? bar.low <= $0 : bar.high >= $0 }) == true {
                                        let fill = openingGap ? open : position.liquidationPrice(rate: rate)!
                                        wallet.position?.trade.mfe = max(position.trade.mfe,position.sign*(open-position.trade.entryPrice)/position.trade.entryPrice)
                                        wallet.position?.trade.mae = min(position.trade.mae,position.sign*(fill-position.trade.entryPrice)/position.trade.entryPrice)
                                        // The favorable extreme might occur after an intrahour liquidation.
                                        // Never attribute that later price to a position already closed.
                                        wallet.position?.trade.mfeIncomplete = fill != open
                                        let context = SuiteEvaluation.positionContext(base, direction: position.trade.direction, price: position.trade.entryPrice, time: position.trade.entryTime)
                                        let traces = SuiteEvaluation.traces(context, filters: compiled[profileIndex], explain: true)
                                        let e = try event(study: study, profile: profile, profileIndex: profileIndex, instrument: instrument, hour: h, phase: position.sign > 0 ? .bullishExhaustion : .bearishExhaustion, traces: traces, model: model, role: "Liquidation", series: series, manifest: manifest,referenceSources:reference?.sources ?? [])
                                        if let trade = close(&wallet, at: fill == open ? h : time, price: fill, feeBps: liquidationFee, event: e, reason: "Simplified isolated liquidation · OHLC hour", manifest: manifest, liquidationHour: h, exactTime: fill == open) { try store.saveSuiteTrade(trade) }
                                        wallet.signals.pending = nil; liquidated = true
                                    } else {
                                        wallet.position?.trade.mfe = max(position.trade.mfe, position.sign*(favorable-position.trade.entryPrice)/position.trade.entryPrice)
                                        wallet.position?.trade.mae = min(position.trade.mae, position.sign*(adverse-position.trade.entryPrice)/position.trade.entryPrice)
                                    }
                                    if !liquidated && costs != nil {
                                        for settlement in series.funding where settlement.timestamp > max(h,position.trade.entryTime) && settlement.timestamp <= time {
                                            let debit = position.sign*position.trade.quantity*settlement.mark!*settlement.rate
                                            wallet.position?.collateral -= debit; wallet.position?.trade.funding += debit
                                            if let held = wallet.position, held.equity(settlement.mark!) <= held.trade.quantity*settlement.mark!*rate {
                                                if settlement.timestamp < time { wallet.position?.trade.mfeIncomplete = true; wallet.position?.trade.maeIncomplete = true }
                                                let context = SuiteEvaluation.positionContext(base, direction: held.trade.direction, price: held.trade.entryPrice, time: held.trade.entryTime)
                                                let traces = SuiteEvaluation.traces(context, filters: compiled[profileIndex], explain: true)
                                                let e = try event(study: study, profile: profile, profileIndex: profileIndex, instrument: instrument, hour: h, phase: held.sign > 0 ? .bullishExhaustion : .bearishExhaustion, traces: traces, model: model, role: "Liquidation", series: series, manifest: manifest,referenceSources:reference?.sources ?? [])
                                                if let trade = close(&wallet, at: settlement.timestamp, price: settlement.mark!, feeBps: liquidationFee, event: e, reason: "Simplified isolated liquidation · funding settlement", manifest: manifest, liquidationHour: h) { try store.saveSuiteTrade(trade) }
                                                wallet.signals.pending = nil; liquidated = true; break
                                            }
                                        }
                                    }
                                }
                                let position = wallet.position
                                let context = SuiteEvaluation.positionContext(base, direction: position?.trade.direction, price: position?.trade.entryPrice, time: position?.trade.entryTime)
                                let traces = SuiteEvaluation.traces(context, filters: compiled[profileIndex], explain: true)
                                let relevant = position == nil ? [0,1,3] : position?.trade.direction == "Long" ? (execution.opposite == "dedicatedOnly" ? [2] : [2,3]) : [4,1]
                                if relevant.contains(where: { traces[$0].result == .unknown }) {
                                    if h >= manifest.from { wallet.unknown += 1 }
                                    if let position, SuiteEvaluation.decision(traces, direction: position.trade.direction, execution: execution).0 == "Unknown" { wallet.position?.trade.uncertain = true; wallet.uncertain = true }
                                }
                                if h < manifest.from { wallet.baseline += [1,3].filter { traces[$0].result == .yes }.count }
                                // Value the completed hour before executing any following-open orders.
                                // A missing price never falls back to the entry price or a previous close.
                                if let p = wallet.position, series.candles[h]?.close == nil {
                                    wallet.incompleteReason = "The hourly closing valuation is missing. Capital simulation stops here."
                                    wallet.position?.trade.status = "Incomplete"; wallet.position?.trade.reason = wallet.incompleteReason!
                                    try store.saveSuiteTrade(p.trade); saved.wallets[model] = wallet; continue
                                }
                                let equity = wallet.cash + (wallet.position.map { max(0,$0.equity(series.candles[h]!.close)) } ?? 0)
                                wallet.lastEquity = equity; wallet.peak = max(wallet.peak,equity)
                                let dd = wallet.peak > 0 ? (wallet.peak-equity)/wallet.peak : 0; wallet.maxDrawdown = max(wallet.maxDrawdown,dd)
                                if h >= manifest.from { try store.saveSuitePoint(study: study.id, profile: profile.id, instrument: instrument.id, model: model, point: .init(timestamp: time, equity: equity, drawdown: dd, direction: wallet.position?.trade.direction, uncertain: wallet.uncertain)) }
                                let intent = wallet.signals.step(traces, holding: position?.trade.direction, execution: execution, baseline: h < manifest.from, eligible: time < end && instrument.eligible(at: time) && (profiles.count == 1 || common))
                                let raw = series.candles[time].flatMap { $0.confirmed ? $0.open : nil }
                                if intent.exit && !liquidated && time < end, let position {
                                    if let raw {
                                        let fill = raw*(1-position.sign*(costs?.slippageBps ?? 0)/10_000)
                                        let phase = intent.phase ?? (position.sign > 0 ? .bullishExhaustion : .bearishExhaustion)
                                        let e = try event(study: study, profile: profile, profileIndex: profileIndex, instrument: instrument, hour: h, phase: phase, traces: traces, model: model, role: "Exit", series: series, manifest: manifest,referenceSources:reference?.sources ?? [])
                                        // A gap at the executable open liquidates before the pending signal.
                                        let gapLiquidation = position.equity(raw) <= position.trade.quantity*raw*rate
                                        if let trade = close(&wallet, at: time, price: gapLiquidation ? raw : fill, feeBps: gapLiquidation ? liquidationFee : costs?.exitFeeBps ?? 0, event: e, reason: gapLiquidation ? "Simplified isolated liquidation · opening gap" : intent.reason, manifest: manifest, liquidationHour: gapLiquidation ? time : nil) { try store.saveSuiteTrade(trade) }
                                        if gapLiquidation { liquidated = true; wallet.signals.pending = nil }
                                    } else { wallet.incompleteReason = "The next-hour exit open is missing. No closing fill is invented."; wallet.position?.trade.status = "Incomplete"; wallet.position?.trade.reason = wallet.incompleteReason! }
                                }
                                if let direction = intent.enter, !liquidated, wallet.position == nil, wallet.cash > 0, wallet.incompleteReason == nil {
                                    if let raw {
                                        let sign = direction == "Long" ? 1.0 : -1.0, fill = raw*(1+sign*(costs?.slippageBps ?? 0)/10_000)
                                        let margin = wallet.cash*settings.allocation, quantity = margin*settings.leverage/fill
                                        let fee = quantity*fill*(costs?.entryFeeBps ?? 0)/10_000
                                        guard quantity.isFinite, margin.isFinite else { throw FilterError("The configured exposure exceeds the numeric range.") }
                                        let phase: SuitePhase = direction == "Long" ? .bullishSetup : .bearishReversal
                                        let e = try event(study: study, profile: profile, profileIndex: profileIndex, instrument: instrument, hour: h, phase: phase, traces: traces, model: model, role: "Entry", series: series, manifest: manifest,referenceSources:reference?.sources ?? [])
                                        let uncertain = intent.uncertain || [0,1,3].contains(where: { traces[$0].result == .unknown })
                                        let trade = SuiteTrade(id: e.id, studyID: study.id, profileID: profile.id, profileName: profile.name, model: model, instrument: instrument.id, direction: direction, entryTime: time, entryPrice: fill, margin: margin, quantity: quantity, uncertain: uncertain, fees: fee, entryEvent: e)
                                        wallet.cash -= margin; wallet.position = .init(trade: trade, collateral: margin-fee); wallet.uncertain = wallet.uncertain || uncertain
                                        try store.saveSuiteTrade(trade)
                                    } else { wallet.incompleteReason = "The next-hour entry open is missing. No entry fill or continued compounding is invented." }
                                }
                                if let position = wallet.position { try store.saveSuiteTrade(position.trade) }
                                saved.wallets[model] = wallet
                            }
                        }
                        checkpoint.instrumentIndex = index; checkpoint.nextHour = last+hourMS; saved.strategyIndex = profileIndex; checkpoint.suite = saved; checkpoint.updatedAt = researchNow()
                        try store.put("checkpoint:\(study.id)", kind: "checkpoint", checkpoint)
                    }
                    hour = last+hourMS
                    progress(profileIndex*manifest.instruments.count+index, profiles.count*manifest.instruments.count, "\(profile.name) · \(instrument.id) · Multi-direction capital simulation")
                }
                for wallet in saved.wallets.values {
                    if var trade = wallet.position?.trade { trade.reason = wallet.incompleteReason ?? "The position remains open at the end of available history. No closing sale is invented."; try store.saveSuiteTrade(trade) }
                    let account = SuiteAccount(profileID: profile.id, profileName: profile.name, instrument: instrument.id, model: wallet.model, initial: settings.initial, endingEquity: wallet.lastEquity, returnValue: (wallet.lastEquity-settings.initial)/settings.initial, maxDrawdown: wallet.incompleteReason == nil && !wallet.uncertain ? wallet.maxDrawdown : nil, observedDrawdown: wallet.maxDrawdown, status: wallet.incompleteReason != nil ? "Incomplete" : wallet.uncertain ? "Uncertain" : "Complete", reason: wallet.incompleteReason, openDirection: wallet.position?.trade.direction, evaluated: wallet.evaluated, unknown: wallet.unknown, common: wallet.common, baseline: wallet.baseline)
                    try store.put("suite-account:\(study.id):\(profile.id):\(instrument.id):\(wallet.model)", kind: "suite-account-\(study.id)", account)
                }
                saved.wallets = [:]; checkpoint.nextHour = nil; checkpoint.instrumentIndex = index+1; checkpoint.suite = saved
                try store.put("checkpoint:\(study.id)", kind: "checkpoint", checkpoint)
            }
            saved.strategyIndex = profileIndex+1; checkpoint.instrumentIndex = 0; checkpoint.suite = saved
            try store.put("checkpoint:\(study.id)", kind: "checkpoint", checkpoint)
        }
    }
}

extension ResearchStore {
    func saveSuiteTrade(_ trade: SuiteTrade) throws {
        try database.execute("INSERT OR REPLACE INTO research_suite_trades VALUES (?,?,?,?,?,?,?)", [trade.id,trade.studyID,trade.profileID,trade.instrument,trade.model,trade.entryTime,try researchJSON(trade)])
        for event in [trade.entryEvent, trade.exitEvent].compactMap({ $0 }) { try database.execute("INSERT OR REPLACE INTO research_events VALUES (?,?,?,?)", [event.id,trade.studyID,event.timestamp,try researchJSON(event)]) }
    }
    func saveSuitePoint(study: String, profile: String, instrument: String, model: String, point: SuiteCurvePoint) throws {
        try database.execute("INSERT OR REPLACE INTO research_suite_equity VALUES (?,?,?,?,?,?)", [study,profile,instrument,model,point.timestamp,try researchJSON(point)])
    }
    func suiteTrades(_ study: String, offset: Int = 0, limit: Int = 50) throws -> [SuiteTrade] {
        var json: [String] = []; try database.query("SELECT json FROM research_suite_trades WHERE study=? ORDER BY ts,id LIMIT ? OFFSET ?", [study,Int64(min(100,max(1,limit))),Int64(max(0,offset))]) { json.append(Self.text($0,0)) }
        return try json.map { try JSONDecoder().decode(SuiteTrade.self, from: Data($0.utf8)) }
    }
    func suiteCurve(_ study: String, profile: String, instrument: String, model: String, offset: Int = 0, limit: Int = 1000) throws -> [SuiteCurvePoint] {
        var json: [String] = []; try database.query("SELECT json FROM research_suite_equity WHERE study=? AND profile=? AND inst=? AND model=? ORDER BY ts LIMIT ? OFFSET ?", [study,profile,instrument,model,Int64(min(2000,max(1,limit))),Int64(max(0,offset))]) { json.append(Self.text($0,0)) }
        return try json.map { try JSONDecoder().decode(SuiteCurvePoint.self, from: Data($0.utf8)) }
    }
    func suiteReport(_ study: ResearchStudy, manifest: DataManifest) throws -> StudyReport {
        var summaries: [SuiteSummary] = []
        let valid = "json_extract(json,'$.status')='Closed' AND json_extract(json,'$.crossesSplit')=0 AND json_extract(json,'$.entryEvent.split')!='Purged'"
        for profile in study.spec.strategySnapshots! {
            for model in study.spec.costs == nil ? ["Gross"] : ["Gross", "Net"] {
                var groups: [(String?,String?,String?)] = [(nil,nil,nil), (nil,"Long",nil), (nil,"Short",nil)]
                groups += manifest.instruments.map { ($0.id,nil,nil) }
                groups += ["Observation", "Validation", "Holdout"].map { (nil,nil,$0) }
                for (instrument,direction,split) in groups {
                    var whereSQL = "study=? AND profile=? AND model=?", args: [Any?] = [study.id,profile.id,model]
                    if let instrument { whereSQL += " AND inst=?"; args.append(instrument) }
                    if let direction { whereSQL += " AND json_extract(json,'$.direction')=?"; args.append(direction) }
                    if let split { whereSQL += " AND json_extract(json,'$.entryEvent.split')=?"; args.append(split) }
                    let r = "json_extract(json,'$.returnValue')", p = "json_extract(json,'$.profit')"
                    let total = try count("SELECT COUNT(*) FROM research_suite_trades WHERE \(whereSQL)", args)
                    let open = try count("SELECT COUNT(*) FROM research_suite_trades WHERE \(whereSQL) AND json_extract(json,'$.status')='Open'", args)
                    let liquidations = try count("SELECT COUNT(*) FROM research_suite_trades WHERE \(whereSQL) AND json_extract(json,'$.liquidationFrom') IS NOT NULL", args)
                    var s = SuiteSummary(profileID: profile.id, profileName: profile.name, model: model, instrument: instrument, direction: direction, split: split, count: 0, excluded: total-open, open: open, liquidations: liquidations)
                    s.incomplete = try count("SELECT COUNT(*) FROM research_suite_trades WHERE \(whereSQL) AND json_extract(json,'$.status')='Incomplete'", args)
                    s.uncertain = try count("SELECT COUNT(*) FROM research_suite_trades WHERE \(whereSQL) AND json_extract(json,'$.uncertain')=1", args)
                    s.crossSplit = try count("SELECT COUNT(*) FROM research_suite_trades WHERE \(whereSQL) AND json_extract(json,'$.crossesSplit')=1", args)
                    s.purged = try count("SELECT COUNT(*) FROM research_suite_trades WHERE \(whereSQL) AND json_extract(json,'$.entryEvent.split')='Purged'", args)
                    try database.query("SELECT COUNT(*),AVG(\(r)),AVG(\(p)>0),SUM(\(p)),AVG((json_extract(json,'$.exitTime')-json_extract(json,'$.entryTime'))/?),AVG(CASE WHEN COALESCE(json_extract(json,'$.mfeIncomplete'),0)=0 THEN json_extract(json,'$.mfe') END),AVG(CASE WHEN COALESCE(json_extract(json,'$.maeIncomplete'),0)=0 THEN json_extract(json,'$.mae') END),AVG(CASE WHEN \(r)>0 THEN \(r) END),AVG(CASE WHEN \(r)<0 THEN -\(r) END),SUM(CASE WHEN \(p)>0 THEN \(p) ELSE 0 END),SUM(CASE WHEN \(p)<0 THEN -\(p) ELSE 0 END),AVG(json_extract(json,'$.holdingHoursLow')) FROM research_suite_trades WHERE \(whereSQL) AND \(valid)", [hourMS]+args) {
                        s.count = Int(sqlite3_column_int64($0,0)); s.excluded = total-open-s.count
                        s.mean = Self.number($0,1); s.winRate = Self.number($0,2); s.profit = Self.number($0,3); s.averageHours = Self.number($0,4); s.mfe = Self.number($0,5); s.mae = Self.number($0,6); s.averageHoursLow = Self.number($0,11)
                        let win = Self.number($0,7), loss = Self.number($0,8), gains = Self.number($0,9), losses = Self.number($0,10)
                        if let win, let loss, loss > 0 { s.payoffRatio = win/loss } else { s.payoffInfinite = (win ?? 0) > 0 }
                        if let gains, let losses, losses > 0 { s.profitFactor = gains/losses } else { s.profitFactorInfinite = (gains ?? 0) > 0 }
                    }
                    var blocks: [(Double,Int)] = []
                    try database.query("SELECT SUM(\(r)),COUNT(*) FROM research_suite_trades WHERE \(whereSQL) AND \(valid) GROUP BY (ts+?)/? ORDER BY (ts+?)/?", args+[3*24*hourMS,7*24*hourMS,3*24*hourMS,7*24*hourMS]) { blocks.append((sqlite3_column_double($0,0),Int(sqlite3_column_int64($0,1)))) }
                    var bootstrap = ResearchBootstrap(); if let interval = bootstrap.interval(blocks) { s.intervalLow = interval.0; s.intervalHigh = interval.1 }
                    summaries.append(s)
                }
            }
        }
        let accounts = try objects("suite-account-\(study.id)", as: SuiteAccount.self)
        var warnings = ["Independent per-contract accounts. Simplified isolated liquidation uses traded hourly OHLC, not the OKX historical margin engine.", "Open, uncertain, incomplete, purged and cross-split trades are excluded from primary statistics. Curves include hourly unrealized equity; incomplete Net curves stop without fabricated funding."]
        if try study.spec.allRules.contains(where: { try FilterCompiler.compile(FilterConfigV2.decode($0.filtersJSON)).hasLiveBTC }) {
            warnings.append("Hourly approximation of live BTC rules: confirmation uses completed BTC hours; signals execute at the next hourly open. Intrahour triggers and cooldown observations are not reconstructed.")
        }
        return .init(studyID: study.id, manifestID: manifest.id, spec: study.spec, summaries: [], evaluated: accounts.reduce(0) { $0+$1.evaluated }, unknown: accounts.reduce(0) { $0+$1.unknown }, directionless: 0, uncertain: summaries.filter { $0.instrument == nil && $0.direction == nil && $0.split == nil }.reduce(0) { $0+$1.uncertain }, baseline: accounts.reduce(0) { $0+$1.baseline }, commonPool: accounts.reduce(0) { $0+$1.common }, warnings: warnings, suite: .init(summaries: summaries, accounts: accounts))
    }
}

/// Exports keep decimal ratios (the UI formats percentages) and original provenance.
enum SuiteCSV {
    static func export(store: ResearchStore, report: StudyReport, manifest: DataManifest, kind: String, write: ([String]) throws -> Void) throws {
        guard let result = report.suite else { return }
        let columns = ["study_id","manifest_id","data_digest","engine","source_revision","spec_json","sources_json"]
        let metadata = [report.studyID,manifest.id,manifest.digest,manifest.engine,manifest.sourceRevision,try researchJSON(report.spec),try researchJSON(manifest.sources)]
        func n(_ x: Double?) -> String { x.map { String($0) } ?? "" }
        if kind == "summary" {
            try write(columns+["profile_id","profile_name","model","instrument","direction","split","n","excluded","open","liquidations","win_rate","mean_margin_return","average_payoff_ratio","profit_factor","profit_usdt","mean_holding_hours","mfe","mae","ci_low","ci_high","incomplete","uncertain","cross_split","purged","mean_holding_hours_min","accounts_json"])
            for s in result.summaries {
                try Task.checkCancellation()
                let accounts = result.accounts.filter { $0.profileID == s.profileID && $0.model == s.model && (s.instrument == nil || $0.instrument == s.instrument) }
                try write(metadata+[s.profileID,s.profileName,s.model,s.instrument ?? "",s.direction ?? "",s.split ?? "",String(s.count),String(s.excluded),String(s.open),String(s.liquidations),n(s.winRate),n(s.mean),s.payoffInfinite ? "Infinity" : n(s.payoffRatio),s.profitFactorInfinite ? "Infinity" : n(s.profitFactor),n(s.profit),n(s.averageHours),n(s.mfe),n(s.mae),n(s.intervalLow),n(s.intervalHigh),String(s.incomplete),String(s.uncertain),String(s.crossSplit),String(s.purged),n(s.averageHoursLow),try researchJSON(accounts)])
            }
        } else if kind == "equity" {
            try write(columns+["profile_id","profile_name","instrument","model","timestamp_utc_ms","closing_equity_usdt","drawdown","direction","uncertain","account_status","account_reason"])
            for account in result.accounts {
                var offset = 0
                while true {
                    try Task.checkCancellation()
                    let points = try store.suiteCurve(report.studyID, profile: account.profileID, instrument: account.instrument, model: account.model, offset: offset, limit: 2000)
                    if points.isEmpty { break }
                    for p in points { try write(metadata+[account.profileID,account.profileName,account.instrument,account.model,String(p.timestamp),String(p.equity),String(p.drawdown),p.direction ?? "Flat",String(p.uncertain),account.status,account.reason ?? ""]) }
                    offset += points.count
                }
            }
        } else {
            try write(columns+["trade_id","profile_id","profile_name","instrument","model","direction","entry_utc_ms","entry_price","allocated_margin_usdt","quantity","exit_utc_ms","exit_price","holding_hours","status","reason","uncertain","crosses_split","entry_split","exit_split","profit_usdt","margin_return","directional_signed_relative_change","mfe","mae","fees_usdt","funding_debit_usdt","liquidation_hour_from_utc_ms","liquidation_hour_through_utc_ms","mfe_incomplete","mae_incomplete","holding_hours_min","holding_hours_max","entry_trace_json","exit_trace_json"])
            var offset = 0
            while true {
                try Task.checkCancellation()
                let trades = try store.suiteTrades(report.studyID, offset: offset, limit: 100); if trades.isEmpty { break }
                for t in trades {
                    var row = metadata + [t.id,t.profileID,t.profileName,t.instrument,t.model,t.direction,String(t.entryTime),String(t.entryPrice),String(t.margin),String(t.quantity)]
                    row += [t.exitTime.map { String($0) } ?? "",n(t.exitPrice),t.exitTime.map { String(Double($0-t.entryTime)/Double(hourMS)) } ?? "",t.status,t.reason,String(t.uncertain),String(t.crossesSplit),t.entryEvent.split,t.exitEvent?.split ?? ""]
                    row += [n(t.profit),n(t.returnValue),n(t.priceReturn),t.mfeIncomplete ? "" : String(t.mfe),t.maeIncomplete ? "" : String(t.mae),String(t.fees),String(t.funding)]
                    row += [t.liquidationFrom.map { String($0) } ?? "",t.liquidationThrough.map { String($0) } ?? "",String(t.mfeIncomplete),String(t.maeIncomplete),n(t.holdingHoursLow),n(t.holdingHoursHigh),t.entryEvent.traceJSON,t.exitEvent?.traceJSON ?? ""]
                    try write(row)
                }
                offset += trades.count
            }
        }
    }
}
