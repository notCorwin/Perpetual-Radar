import Foundation

enum SuitePhase: String, CaseIterable, Codable, Sendable {
    case bullishSetup, bullishExhaustion, bearishReversal, bearishExhaustion
    var label: String {
        switch self {
        case .bullishSetup: "Bullish Setup"
        case .bullishExhaustion: "Bullish Exhaustion"
        case .bearishReversal: "Bearish Reversal"
        case .bearishExhaustion: "Bearish Exhaustion"
        }
    }
}

func strategyObservation(profile: StrategyProfile, readings: [SuiteReading]) throws -> FilterObservation {
    var results: [String: FilterTruth] = [:]
    for reading in readings {
        for phase in [SuitePhase.bullishSetup, .bearishReversal] {
            let truth = FilterTruth(rawValue: reading.phases[phase.rawValue]?.result ?? "unknown") ?? .unknown
            results[reading.instrument + "|" + phase.label] = truth == .no || reading.universe == "false" ? .no : truth == .yes && reading.universe == "true" ? .yes : .unknown
        }
        if let position = reading.position {
            results[reading.instrument + "|Exit " + position.direction + "|" + position.id] = reading.action.hasPrefix("Exit") ? .yes : reading.action == "Unknown" ? .unknown : .no
        }
    }
    return .init(configuration: try researchJSON(profile), universe: Set(results.keys), results: results)
}

struct SuiteExecution: Codable, Equatable, Sendable {
    var opposite = "exitThenWait"
    var entry = "newPhaseEntry"
    func validate() throws {
        guard ["exitThenWait", "reverse", "dedicatedOnly"].contains(opposite), ["newPhaseEntry", "matchWhileFlat"].contains(entry) else { throw FilterError("Choose a valid opposite-signal and re-entry policy.") }
    }
}

struct StrategyProfile: Codable, Sendable {
    var id = UUID().uuidString
    var mode = "radar"
    var name: String
    var universeJSON: String
    var phaseRules: [String: String]
    var revision = 0
    var updatedAt = researchNow()
    var execution = SuiteExecution()
    static let longMetrics: Set<String> = ["LongEntryPrice", "LongReturn", "LongHeldHours"]
    static let shortMetrics: Set<String> = ["ShortEntryPrice", "ShortReturn", "ShortHeldHours"]
    static func forbiddenMetrics(_ phase: SuitePhase?) -> Set<String> {
        phase == .bullishExhaustion ? shortMetrics : phase == .bearishExhaustion ? longMetrics : longMetrics.union(shortMetrics)
    }
    static func validateRule(_ rule: CompiledFilter, phase: SuitePhase?) throws {
        if phase != nil, ["all", "any"].contains(rule.config.root.kind), rule.config.root.children.isEmpty {
            throw FilterError("Add at least one condition to every phase. Empty phases cannot be activated.")
        }
        guard rule.metrics.isDisjoint(with: forbiddenMetrics(phase)) else {
            throw FilterError("Universe and entry phases cannot use position readings; exhaustion phases can only use their own direction's position.")
        }
    }
    var studyRules: [StudyRule] { [.init(name: name + " · Universe", filtersJSON: universeJSON)] + SuitePhase.allCases.map { .init(name: name + " · " + $0.label, filtersJSON: phaseRules[$0.rawValue] ?? "") } }
    func compiled() throws -> [CompiledFilter] {
        guard ["radar", "research"].contains(mode), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80 else { throw FilterError("Use a strategy name from 1 to 80 characters and a valid mode.") }
        try execution.validate()
        let rules = try studyRules.map { try FilterCompiler.compile(FilterConfigV2.decode($0.filtersJSON)) }
        for (index, rule) in rules.enumerated() {
            try Self.validateRule(rule, phase: index == 0 ? nil : SuitePhase.allCases[index-1])
        }
        return rules
    }
    func hydration() throws -> CompiledFilter {
        let all = try compiled(); var combined = all[0]
        combined.requiredHours = ResearchVersion.warmup(all) + 1
        for rule in all { combined.mergeRequirements(rule) }
        if combined.referencesBTC {
            let hours = max(combined.btcRequirements?.hours ?? 0,ResearchVersion.warmup(all)+1)
            combined.btcRequirements?.hours = hours
        }
        return combined
    }
}

struct SuitePosition: Codable, Sendable {
    var id = UUID().uuidString
    var strategyID: String
    var instrument: String
    var direction: String
    var enteredAt: Int64
    var entryPrice: Double
    var strategy: StrategyProfile
    var exitedAt: Int64?
    var exitPrice: Double?
    var exitStrategy: StrategyProfile?
    var priceReturn: String?
}

struct SuitePhaseReading: Codable, Sendable {
    var result: String
    var hour: Int64
    var traceJSON: String?
}
struct SuiteReading: Codable, Sendable {
    var strategyID = ""
    var revision = 0
    var instrument: String
    var hour: Int64
    var provisional: Bool
    var universe: String
    var universeTraceJSON: String?
    var phases: [String: SuitePhaseReading]
    var conflict: Bool
    var action: String
    var reason: String
    var price: Double?
    var position: SuitePosition?
    var positionReturn: String?
}

enum SuiteEvaluation {
    static func relativeReturn(price: Double?, entry: Double, direction: String) -> String? {
        guard let change = percentChange(price,entry) else { return nil }
        let value = (direction == "Long" ? 1 : -1)*change/100
        return value.isInfinite ? (value>0 ? "Infinity" : "-Infinity") : String(value)
    }
    static func positionContext(_ input: FilterMarketData, direction: String?, price: Double?, time: Int64?) -> FilterMarketData {
        var context = input
        context.longEntryPrice = direction == "Long" ? price : nil; context.longEnteredAt = direction == "Long" ? time : nil
        context.shortEntryPrice = direction == "Short" ? price : nil; context.shortEnteredAt = direction == "Short" ? time : nil
        return context
    }
    static func traces(_ context: FilterMarketData, filters: [CompiledFilter], explain: Bool = false) -> [FilterTrace] {
        var shared: [String: FilterScalar] = [:]
        return filters.map { filter in
            let evaluator = FilterEvaluator(market: context, filter: filter, sharedReadings: shared)
            let trace = evaluator.evaluate(explain: explain); shared = evaluator.sharedReadings; return trace
        }
    }
    static func truth(_ traces: [FilterTrace], _ phase: SuitePhase) -> FilterTruth { traces[1 + SuitePhase.allCases.firstIndex(of: phase)!].result }
    static func decision(_ traces: [FilterTrace], direction: String?, execution: SuiteExecution) -> (String, String) {
        let setup = truth(traces, .bullishSetup), reversal = truth(traces, .bearishReversal)
        let conflict = setup == .yes && reversal == .yes
        if let direction {
            let exhaustion = truth(traces, direction == "Long" ? .bullishExhaustion : .bearishExhaustion)
            let opposite = direction == "Long" ? reversal : setup
            let useOpposite = direction == "Short" || execution.opposite != "dedicatedOnly"
            if exhaustion == .yes || useOpposite && opposite == .yes {
                let suffix = traces[0].result == .yes && !conflict && opposite == .yes && execution.opposite == "reverse" ? "; then Enter \(direction == "Long" ? "Short" : "Long")" : ""
                return ("Exit \(direction)" + suffix, "A saved exit phase matches. Record actual fills to update your position.")
            }
            if exhaustion == .unknown || useOpposite && opposite == .unknown { return ("Unknown", "An exit reading is missing. The actual position is retained.") }
            return ("Hold \(direction)", "No exit phase matches.")
        }
        if conflict { return ("Conflict", "Both entry phases match. Inspect both rules before choosing a direction.") }
        guard traces[0].result == .yes else { return (traces[0].result == .unknown ? "Unknown" : "Wait", "Universe rules do not definitely match.") }
        if setup == .yes { return ("Enter Long", "Bullish Setup matches while flat.") }
        if reversal == .yes { return ("Enter Short", "Bearish Reversal matches while flat.") }
        return (setup == .unknown || reversal == .unknown ? "Unknown" : "Wait", "No definite entry phase matches.")
    }
}

actor SuiteEvaluationWorker {
    private let confirmationCooldowns = FilterCooldownMemory()
    func evaluate(_ markets: [FilterMarketData], profile: StrategyProfile, positions: [SuitePosition], forming: Bool, available: Bool, detail: String? = nil) throws -> [SuiteReading] {
        let filters = try profile.compiled()
        let held = Dictionary(uniqueKeysWithValues: positions.filter { $0.strategyID == profile.id && $0.exitedAt == nil }.map { ($0.instrument, $0) })
        var closedReferences: [ObjectIdentifier: FilterReferenceSnapshot] = [:]
        var readings = try markets.map { original in
            try Task.checkCancellation()
            let position = held[original.id]
            var context = SuiteEvaluation.positionContext(LongDecision.context(original, forming: forming), direction: position?.direction, price: position?.entryPrice, time: position?.enteredAt)
            context.cooldowns = confirmationCooldowns; context.recordCooldowns = !forming
            if !forming {
                context.evaluationTime = context.now
                if let reference = context.referenceBTC, !reference.market.historicalClose {
                    let key = ObjectIdentifier(reference)
                    if closedReferences[key] == nil { closedReferences[key] = FilterReferenceSnapshot(market: LongDecision.context(reference.market,forming:false), receivedAt:reference.receivedAt,connected:reference.connected) }
                    context.referenceBTC = closedReferences[key]
                }
            }
            let ready = available && context.candles[context.hour].map { forming || $0.confirmed } == true
            var traces = SuiteEvaluation.traces(context, filters: filters, explain: detail == original.id)
            if !ready {
                for index in traces.indices { traces[index].result = .unknown; traces[index].reason = "Monitoring is paused or this hourly candle is unavailable. Last definite membership is retained."; traces[index].children = [] }
            }
            var phases: [String: SuitePhaseReading] = [:]
            for (index, phase) in SuitePhase.allCases.enumerated() {
                let trace = traces[index + 1]
                phases[phase.rawValue] = .init(result: ready ? trace.result.rawValue : "unknown", hour: context.hour, traceJSON: detail == original.id ? String(decoding: try JSONSerialization.data(withJSONObject: trace.snapshot, options: [.sortedKeys]), as: UTF8.self) : nil)
            }
            let waiting = !forming && position.map { $0.enteredAt >= context.now } == true
            let decision = waiting ? ("Unknown", "Waiting for the first evaluated hourly close after the actual entry.") : ready ? SuiteEvaluation.decision(traces, direction: position?.direction, execution: profile.execution) : ("Unknown", "Monitoring is paused or this hourly candle is unavailable. Tracking is retained.")
            let priceReturn = ready && !waiting ? position.flatMap { p in SuiteEvaluation.relativeReturn(price: context.candles[context.hour]?.close,entry: p.entryPrice,direction: p.direction) } : nil
            return SuiteReading(strategyID: profile.id, revision: profile.revision, instrument: original.id, hour: context.hour, provisional: forming, universe: ready ? traces[0].result.rawValue : "unknown", universeTraceJSON: detail == original.id ? String(decoding: try JSONSerialization.data(withJSONObject: traces[0].snapshot, options: [.sortedKeys]), as: UTF8.self) : nil, phases: phases, conflict: ready && SuiteEvaluation.truth(traces, .bullishSetup) == .yes && SuiteEvaluation.truth(traces, .bearishReversal) == .yes, action: decision.0, reason: decision.1, price: context.candles[context.hour]?.close, position: position, positionReturn: priceReturn)
        }
        for position in held.values where !markets.contains(where: { $0.id == position.instrument }) {
            let hour = researchNow()/hourMS*hourMS-(forming ? 0 : hourMS)
            let phases = Dictionary(uniqueKeysWithValues: SuitePhase.allCases.map { ($0.rawValue,SuitePhaseReading(result: "unknown",hour: hour)) })
            readings.append(.init(strategyID: profile.id,revision: profile.revision,instrument: position.instrument, hour: hour, provisional: forming, universe: "unknown", phases: phases, conflict: false, action: "Unknown", reason: "The contract is unavailable. Record an actual exit manually; no fill is invented.", position: position))
        }
        return readings
    }
}

extension Store {
    // Modes are views over one library. Research experiments retain their own
    // immutable snapshots; only editable profiles live in the shared service.
    func initializeSharedSuiteLibrary(researchURL: URL? = nil) throws {
        guard try preference(forKey: "suiteProfiles") == nil else { return }
        func legacy(_ store: Store, _ mode: String) throws -> [StrategyProfile] {
            try store.preference(forKey: "suiteProfiles.\(mode)").map { try JSONDecoder().decode([StrategyProfile].self, from: Data($0.utf8)) } ?? []
        }
        var sources = try legacy(self, "radar") + legacy(self, "research")
        if let researchURL, FileManager.default.fileExists(atPath: researchURL.path) {
            sources += try legacy(Store(url: researchURL), "research")
        }
        var profiles: [StrategyProfile] = []
        for var profile in sources where !profiles.contains(where: { $0.id == profile.id }) {
            if profiles.contains(where: { $0.name.lowercased() == profile.name.lowercased() }) {
                let base = String(profile.name.prefix(60)); var suffix = 1
                repeat { profile.name = base + " · Research \(suffix)"; suffix += 1 }
                while profiles.contains(where: { $0.name.lowercased() == profile.name.lowercased() })
            }
            profile.mode = "radar"; profiles.append(profile)
        }
        try transaction {
            try setPreference(try researchJSON(profiles), forKey: "suiteProfiles")
            try setPreference(try preference(forKey: "suiteSelected.radar") ?? "", forKey: "suiteSelected")
        }
    }
    func importLongRecordsIntoSuite() throws {
        guard try preference(forKey: "suiteLongRecordsImported") == nil else { return }
        let disabled = try FilterCompiler.compile(source: "1 > 2").config.json
        func profile(_ old: LongStrategy) -> StrategyProfile {
            .init(id: old.id, name: old.name, universeJSON: FilterConfigV2().json,
                  phaseRules: ["bullishSetup": old.entryJSON,"bullishExhaustion": old.exitJSON,"bearishReversal": disabled,"bearishExhaustion": disabled],
                  revision: old.revision, updatedAt: old.updatedAt)
        }
        try transaction {
            var profiles = try suiteProfiles("radar"), positions = try suitePositions()
            for old in try longStrategies() where !profiles.contains(where: { $0.id == old.id }) {
                var p = profile(old); _ = try p.compiled()
                if profiles.contains(where: { $0.name.lowercased() == p.name.lowercased() }) { p.name = String(p.name.prefix(60))+" · Imported Long" }
                profiles.append(p)
            }
            for old in try longPositions() where !positions.contains(where: { $0.id == old.id }) {
                positions.append(.init(id: old.id,strategyID: old.strategyID,instrument: old.instrument,direction: "Long",enteredAt: old.enteredAt,entryPrice: old.entryPrice,strategy: profile(old.strategy),exitedAt: old.exitedAt,exitPrice: old.exitPrice,exitStrategy: old.exitStrategy.map(profile)))
            }
            try setPreference(try researchJSON(profiles), forKey: "suiteProfiles")
            try setPreference(try researchJSON(positions), forKey: "suitePositions")
            if try preference(forKey: "suiteSelected")?.isEmpty != false, let selected = try preference(forKey: "longSelectedStrategy"), profiles.contains(where: { $0.id == selected }) { try setPreference(selected, forKey: "suiteSelected") }
            try setPreference("true", forKey: "suiteLongRecordsImported")
        }
    }
    func suiteProfiles(_ mode: String) throws -> [StrategyProfile] { try preference(forKey: "suiteProfiles").map { try JSONDecoder().decode([StrategyProfile].self, from: Data($0.utf8)) } ?? [] }
    func suitePositions() throws -> [SuitePosition] {
        let records = try preference(forKey: "suitePositions").map { try JSONDecoder().decode([SuitePosition].self, from: Data($0.utf8)) } ?? []
        return records.map { input in var record = input; record.priceReturn = SuiteEvaluation.relativeReturn(price: record.exitPrice,entry: record.entryPrice,direction: record.direction); return record }
    }
    func selectedSuiteProfile(_ mode: String) throws -> StrategyProfile? {
        let selected = try preference(forKey: "suiteSelected")
        return try suiteProfiles(mode).first { $0.id == selected }
    }
    func saveSuiteProfile(_ input: StrategyProfile, copy: Bool = false) throws -> StrategyProfile {
        var result = input; let rules = try input.compiled()
        result.mode = "radar"
        result.universeJSON = rules[0].config.json
        for (index, phase) in SuitePhase.allCases.enumerated() { result.phaseRules[phase.rawValue] = rules[index+1].config.json }
        result.name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy || result.id.isEmpty { result.id = UUID().uuidString; result.revision = 0 }
        try transaction {
            var profiles = try suiteProfiles(result.mode)
            if copy {
                let base = String(result.name.prefix(65)); var suffix = 1
                while profiles.contains(where: { $0.name.lowercased() == result.name.lowercased() }) {
                    result.name = base + " copy" + (suffix == 1 ? "" : " \(suffix)"); suffix += 1
                }
            }
            guard !profiles.contains(where: { $0.id != result.id && $0.name.lowercased() == result.name.lowercased() }) else { throw FilterError("A strategy with this name already exists. Choose a new name.") }
            if let old = profiles.first(where: { $0.id == result.id }) { guard result.revision == old.revision else { throw FilterError("The strategy changed. Reload before saving.") } }
            else { guard result.revision == 0 else { throw FilterError("The strategy was deleted. Save a new copy.") } }
            result.revision += 1; result.updatedAt = researchNow()
            profiles.removeAll { $0.id == result.id }; profiles.insert(result, at: 0)
            try setPreference(try researchJSON(profiles), forKey: "suiteProfiles")
        }
        return result
    }
    func suiteInventory(_ mode: String, saved: StrategyProfile? = nil) throws -> [String: Any] {
        func object<T: Encodable>(_ value: T) throws -> Any { try JSONSerialization.jsonObject(with: Data(researchJSON(value).utf8)) }
        var response: [String: Any] = ["profiles": try object(suiteProfiles(mode)), "positions": try object(suitePositions()), "selectedID": try preference(forKey: "suiteSelected") ?? ""]
        if let draft = try preference(forKey: "suiteDraft.\(mode)"), !draft.isEmpty { response["draft"] = try JSONSerialization.jsonObject(with: Data(draft.utf8)) }
        if let saved { response["saved"] = try object(saved) }
        return response
    }
    func manageSuite(_ request: [String: Any], mode: String) throws -> [String: Any] {
        guard ["radar", "research"].contains(mode) else { throw FilterError("Invalid workspace.") }
        let action = request["action"] as? String ?? "inventory", id = request["profileID"] as? String ?? ""
        var saved: StrategyProfile?
        switch action {
        case "draft":
            // Drafts are opaque editor state. They never compile, activate or
            // change confirmation membership, and may contain incomplete text.
            guard let raw = request["draft"], JSONSerialization.isValidJSONObject(raw) else { throw FilterError("Provide valid editor state.") }
            let data = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
            guard data.count <= 1_048_576 else { throw FilterError("The editor draft exceeds 1 MiB.") }
            try setPreference(String(decoding: data, as: UTF8.self), forKey: "suiteDraft.\(mode)")
        case "save", "copy":
            guard let raw = request["profile"] else { throw FilterError("Provide a complete four-phase strategy.") }
            var profile = try JSONDecoder().decode(StrategyProfile.self, from: JSONSerialization.data(withJSONObject: raw)); profile.mode = mode
            saved = try saveSuiteProfile(profile, copy: action == "copy")
        case "select":
            guard try id.isEmpty || suiteProfiles(mode).contains(where: { $0.id == id }) else { throw FilterError("This strategy no longer exists.") }
            try setPreference(id, forKey: "suiteSelected")
        case "delete":
            guard !(try suitePositions()).contains(where: { $0.strategyID == id && $0.exitedAt == nil }) else { throw FilterError("Close or remove this strategy's actual open positions before deleting it.") }
            try setPreference(try researchJSON(try suiteProfiles(mode).filter { $0.id != id }), forKey: "suiteProfiles")
            if try preference(forKey: "suiteSelected") == id { try setPreference("", forKey: "suiteSelected") }
        case "open", "close":
            guard mode == "radar", let profile = try suiteProfiles(mode).first(where: { $0.id == id }), let instrument = request["instrument"] as? String,
                  instrument.hasSuffix("-USDT-SWAP"), let price = request["price"] as? Double, price.isFinite, price > 0,
                  let time = (request["timestamp"] as? NSNumber)?.int64Value, time > 0, time <= researchNow() else { throw FilterError("Choose a Radar strategy and a positive actual price with a valid UTC time.") }
            var records = try suitePositions(); let index = records.firstIndex { $0.strategyID == id && $0.instrument == instrument && $0.exitedAt == nil }
            if action == "open" {
                guard index == nil, let direction = request["direction"] as? String, ["Long", "Short"].contains(direction) else { throw FilterError("Choose Long or Short. One actual position per strategy and contract is allowed.") }
                records.append(.init(strategyID: id, instrument: instrument, direction: direction, enteredAt: time, entryPrice: price, strategy: profile))
            } else {
                guard let index, time >= records[index].enteredAt else { throw FilterError("The actual exit must follow an open entry.") }
                records[index].exitedAt = time; records[index].exitPrice = price; records[index].exitStrategy = profile
            }
            try setPreference(try researchJSON(records), forKey: "suitePositions")
        case "removeTracking":
            let record = request["positionID"] as? String ?? ""
            try setPreference(try researchJSON(try suitePositions().filter { $0.id != record }), forKey: "suitePositions")
        case "inventory", "evaluate", "preview": break
        default: throw FilterError("Unknown strategy action.")
        }
        return try suiteInventory(mode, saved: saved)
    }
}
