import Foundation

private let api = "https://www.okx.com/api/v5"
private let publicWS = "wss://ws.okx.com:8443/ws/v5/public"
private let businessWS = "wss://ws.okx.com:8443/ws/v5/business"
private let turnoverThresholdKey = "minimum24hTurnoverUSDT"
private let spreadFilterEnabledKey = "spreadFilterEnabled"
private let maximumSpreadPercentKey = "maximumSpreadPercent"

func supportedTurnoverThreshold(_ value: Int) -> Bool {
    value == 10_000_000 || value == 30_000_000 || value == 100_000_000
}

private func numeric(_ value: Any?) -> Double? {
    let result = (value as? String).flatMap(Double.init) ?? (value as? NSNumber)?.doubleValue
    return result?.isFinite == true ? result : nil
}

func usdtTurnover24h(_ ticker: [String: Any]) -> Double? {
    guard let baseVolume = numeric(ticker["volCcy24h"]), baseVolume >= 0,
          let lastPrice = numeric(ticker["last"]), lastPrice > 0 else { return nil }
    let turnover = baseVolume * lastPrice
    return turnover.isFinite ? turnover : nil
}

func spreadPercent(_ ticker: [String: Any]) -> Double? {
    guard let bid = numeric(ticker["bidPx"]), let ask = numeric(ticker["askPx"]),
          bid > 0, ask >= bid else { return nil }
    let spread = (ask - bid) / (bid + (ask - bid) / 2) * 100
    return spread.isFinite ? spread : nil
}

func passesSpreadFilter(_ spread: Double?, enabled: Bool, maximum: Double) -> Bool {
    // Keep values at the configured boundary despite binary rounding in the bid/ask calculation.
    !enabled || (spread.map { $0 <= maximum + 1e-10 } ?? false)
}

private func millis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

private struct Market {
    let id: String
    var turnover24hUSDT: Double?
    var spreadPercent: Double?
    var oi: Double?
    var oiTimestamp = 0.0
    var oiBase: Double?
    var oiUsd: Double?
    var buy: Double?
    var sell: Double?
    var takerRatio: Double?
}

@MainActor
final class Radar {
    private let store: Store
    private(set) var minimum24hTurnoverUSDT: Int
    private(set) var spreadFilterEnabled: Bool
    private(set) var maximumSpreadPercent: Double
    private var rows: [String: Market] = [:]
    private var candles: [String: [Int64: Candle]] = [:]
    private var oiHistory: [String: [Int64: Double]] = [:]
    private var emaStates: [String: (Int64, Double)] = [:]
    private var chartLiveStats: [String: (oi: Double?, sell: Double?, buy: Double?)] = [:]
    private var hour = millis() / hourMS * hourMS
    private var updatedAt: Int64?
    private var failedPaths = Set<String>()
    private var disconnectedChannels = Set<String>()
    private var tasks: [Task<Void, Never>] = []
    private var sockets: [URLSessionWebSocketTask] = []
    private var startupError = ""

    init() throws {
        let savedThreshold = UserDefaults.standard.integer(forKey: turnoverThresholdKey)
        minimum24hTurnoverUSDT = supportedTurnoverThreshold(savedThreshold) ? savedThreshold : 10_000_000
        spreadFilterEnabled = UserDefaults.standard.object(forKey: spreadFilterEnabledKey) as? Bool ?? true
        let savedSpread = UserDefaults.standard.object(forKey: maximumSpreadPercentKey) as? Double ?? 0.15
        maximumSpreadPercent = savedSpread.isFinite && (0...100).contains(savedSpread) ? savedSpread : 0.15
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("PerpetualRadar", isDirectory: true)
        store = try Store(url: support.appendingPathComponent("radar.sqlite3"))
        try store.prune(hour: hour, ids: [])
    }

    deinit {
        tasks.forEach { $0.cancel() }
        sockets.forEach { $0.cancel(with: .goingAway, reason: nil) }
    }

    private func touch() { updatedAt = millis() }

    func setMinimum24hTurnoverUSDT(_ value: Int) -> Bool {
        guard supportedTurnoverThreshold(value) else { return false }
        minimum24hTurnoverUSDT = value
        UserDefaults.standard.set(value, forKey: turnoverThresholdKey)
        touch()
        return true
    }

    func setSpreadFilterEnabled(_ value: Bool) {
        spreadFilterEnabled = value
        UserDefaults.standard.set(value, forKey: spreadFilterEnabledKey)
        touch()
    }

    func setMaximumSpreadPercent(_ value: Double) -> Bool {
        guard value.isFinite, (0...100).contains(value) else { return false }
        maximumSpreadPercent = value
        UserDefaults.standard.set(value, forKey: maximumSpreadPercentKey)
        touch()
        return true
    }

    private func get(_ path: String, _ parameters: [String: String]) async throws -> [Any] {
        var parts = URLComponents(string: api + path)!
        parts.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: parts.url!)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              body["code"] as? String == "0", let rows = body["data"] as? [Any] else {
            throw NSError(domain: "OKX", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid OKX response for \(path)"])
        }
        return rows
    }

    func start() {
        tasks.append(Task { [weak self] in await self?.bootstrap() })
    }

    private func bootstrap() async {
        while !Task.isCancelled {
            do {
                let items = try await get("/public/instruments", ["instType": "SWAP"])
                let oi = try await get("/public/open-interest", ["instType": "SWAP"])
                let tickers = try await get("/market/tickers", ["instType": "SWAP"])
                for case let item as [String: Any] in items {
                    guard item["state"] as? String == "live", item["instCategory"] as? String == "1",
                          item["settleCcy"] as? String == "USDT", let id = item["instId"] as? String,
                          id.hasSuffix("-USDT-SWAP"), id != "USDC-USDT-SWAP" else { continue }
                    rows[id] = Market(id: id)
                }
                guard !rows.isEmpty else { throw NSError(domain: "OKX", code: 2, userInfo: [NSLocalizedDescriptionKey: "No live USDT perpetual swaps found"]) }
                try updateTickers(tickers)
                for case let item as [String: Any] in oi { updateOI(item) }
                try store.prune(hour: hour, ids: Set(rows.keys))
                let cached = try store.load(hour: hour, ids: Set(rows.keys))
                candles = cached.candles; oiHistory = cached.oiHistory; emaStates = cached.ema
                for (id, value) in cached.oi { rows[id]?.oiBase = value }
                startupError = ""; touch()
                tasks.append(Task { [weak self] in await self?.scan("/market/candles", delay: 120_000_000) })
                tasks.append(Task { [weak self] in await self?.scan("/rubik/stat/contracts/open-interest-history", delay: 250_000_000) })
                tasks.append(Task { [weak self] in await self?.scan("/rubik/stat/taker-volume-contract", delay: 250_000_000, repeatScan: true) })
                tasks.append(Task { [weak self] in await self?.websocket(publicWS, channel: "open-interest") })
                tasks.append(Task { [weak self] in await self?.websocket(businessWS, channel: "candle1H") })
                tasks.append(Task { [weak self] in await self?.pollTickers() })
                tasks.append(Task { [weak self] in await self?.clock() })
                return
            } catch {
                startupError = "OKX unavailable: \(error.localizedDescription). Retrying."
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    private func updateTickers(_ tickers: [Any]) throws {
        var quotes: [String: (turnover: Double, spread: Double?)] = [:]
        for case let ticker as [String: Any] in tickers {
            guard let id = ticker["instId"] as? String, rows[id] != nil,
                  let value = usdtTurnover24h(ticker) else { continue }
            quotes[id] = (value, spreadPercent(ticker))
        }
        guard !quotes.isEmpty else {
            throw NSError(domain: "OKX", code: 4, userInfo: [NSLocalizedDescriptionKey: "No USDT swap ticker data found"])
        }
        for id in rows.keys {
            rows[id]?.turnover24hUSDT = quotes[id]?.turnover
            rows[id]?.spreadPercent = quotes[id]?.spread
        }
        touch()
    }

    private func pollTickers() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            if Task.isCancelled { return }
            do {
                try updateTickers(await get("/market/tickers", ["instType": "SWAP"]))
                failedPaths.remove("/market/tickers")
            } catch {
                failedPaths.insert("/market/tickers")
                NSLog("/market/tickers: %@", error.localizedDescription)
            }
        }
    }

    private func updateOI(_ item: [String: Any]) {
        guard let id = item["instId"] as? String, var row = rows[id],
              let current = numeric(item["oi"]), current >= 0,
              let stamp = numeric(item["ts"]), stamp >= row.oiTimestamp else { return }
        row.oi = current; row.oiTimestamp = stamp; row.oiUsd = numeric(item["oiUsd"])
        rows[id] = row; touch()
    }

    private func updateCandle(_ id: String, _ values: [String], history: Bool = false) {
        guard rows[id] != nil, let bar = Candle(values), bar.hour >= hour - Int64(candleLookback) * hourMS else { return }
        let old = candles[id]?[bar.hour]
        guard !history || old == nil || (!old!.confirmed && bar.confirmed) || old!.baseVolume == nil || old!.open == nil else { return }
        let settled: Candle
        if history, let old, old.confirmed, old.baseVolume == nil {
            settled = Candle(hour: old.hour, high: old.high, low: old.low, close: old.close, quoteVolume: old.quoteVolume, baseVolume: bar.baseVolume, open: bar.open)
        } else { settled = bar }
        candles[id, default: [:]][bar.hour] = settled
        if settled.confirmed {
            do { try store.save(id, settled) }
            catch { startupError = "Cache error: \(error.localizedDescription)" }
        }
        touch()
    }

    private func historyReady(_ id: String) -> Bool {
        let series = candles[id] ?? [:]
        return (1...candleLookback).allSatisfy { series[hour - Int64($0) * hourMS]?.confirmed == true && series[hour - Int64($0) * hourMS]?.open != nil } &&
            (1..<14).allSatisfy { series[hour - Int64($0) * hourMS]?.baseVolume != nil }
    }

    private func scan(_ path: String, delay: UInt64, repeatScan: Bool = false) async {
        var ids = rows.keys.sorted()
        while !Task.isCancelled {
            var failed = Set<String>()
            for id in ids {
                if Task.isCancelled { return }
                do {
                    let parameters = path == "/market/candles"
                        ? ["instId": id, "bar": "1H", "limit": historyReady(id) ? "1" : "251"]
                        : ["instId": id, "period": "1H"]
                    let result = try await get(path, parameters)
                    switch path {
                    case "/market/candles":
                        for case let bar as [String] in result { updateCandle(id, bar, history: true) }
                    case "/rubik/stat/contracts/open-interest-history":
                        var fixed: [Int64: Double] = [:]
                        for case let item as [String] in result {
                            guard item.count >= 2, let ts = Int64(item[0]), ts % hourMS == 0,
                                  ts >= hour - Int64(chartHours - 1) * hourMS, ts < hour,
                                  let value = Double(item[1]), value.isFinite, value > 0 else { continue }
                            fixed[ts] = value
                        }
                        if let base = fixed[hour - hourMS] {
                            try store.saveOIHistory(id, fixed.filter { $0.key == hour - hourMS || oiHistory[id]?[$0.key] != $0.value })
                            oiHistory[id, default: [:]].merge(fixed) { _, latest in latest }
                            rows[id]?.oiBase = base
                            try store.execute("INSERT OR REPLACE INTO oi_base VALUES (?,?,?)", [id, hour, base])
                            touch()
                        } else { failed.insert(id) }
                    default:
                        if let item = result.compactMap({ $0 as? [String] }).first(where: { Int64($0.first ?? "") == hour }),
                           item.count >= 3, let sell = Double(item[1]), let buy = Double(item[2]),
                           buy.isFinite, sell.isFinite, buy >= 0, sell >= 0 {
                            rows[id]?.buy = buy; rows[id]?.sell = sell
                            rows[id]?.takerRatio = buy + sell > 0 ? (buy - sell) / (buy + sell) * 100 : nil
                            touch()
                        }
                    }
                } catch {
                    failed.insert(id)
                    NSLog("%@ %@: %@", path, id, error.localizedDescription)
                }
                try? await Task.sleep(nanoseconds: delay)
            }
            if failed.isEmpty { failedPaths.remove(path) } else { failedPaths.insert(path) }
            if !repeatScan && failed.isEmpty { return }
            ids = repeatScan ? rows.keys.sorted() : failed.sorted()
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
    }

    private func websocket(_ address: String, channel: String) async {
        var backoff: UInt64 = 1_000_000_000
        while !Task.isCancelled {
            let socket = URLSession.shared.webSocketTask(with: URL(string: address)!)
            sockets.append(socket); socket.resume()
            let ping = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    try? await socket.send(.string("ping"))
                }
            }
            do {
                let args = rows.keys.sorted().map { ["channel": channel, "instId": $0] }
                for start in stride(from: 0, to: args.count, by: 50) {
                    let message = ["op": "subscribe", "args": Array(args[start..<min(start + 50, args.count)])] as [String: Any]
                    let data = try JSONSerialization.data(withJSONObject: message)
                    try await socket.send(.string(String(decoding: data, as: UTF8.self)))
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                disconnectedChannels.remove(channel); backoff = 1_000_000_000
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard case let .string(text) = message, text != "pong",
                          let data = text.data(using: .utf8),
                          let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                    if payload["event"] as? String == "error" {
                        throw NSError(domain: "OKX", code: 3, userInfo: [NSLocalizedDescriptionKey: payload["msg"] as? String ?? "Subscription failed"])
                    }
                    guard let arg = payload["arg"] as? [String: String], arg["channel"] == channel,
                          let items = payload["data"] as? [Any] else { continue }
                    for item in items {
                        if channel == "open-interest", let value = item as? [String: Any] { updateOI(value) }
                        if channel == "candle1H", let id = arg["instId"], let value = item as? [String] { updateCandle(id, value) }
                    }
                }
            } catch {
                if !Task.isCancelled { NSLog("%@ WebSocket: %@", channel, error.localizedDescription) }
            }
            ping.cancel(); socket.cancel(with: .goingAway, reason: nil)
            sockets.removeAll { $0 === socket }
            disconnectedChannels.insert(channel)
            try? await Task.sleep(nanoseconds: backoff)
            backoff = min(backoff * 2, 30_000_000_000)
        }
    }

    private func clock() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let current = millis() / hourMS * hourMS
            guard current != hour else { continue }
            hour = current
            chartLiveStats.removeAll()
            do { try store.prune(hour: hour, ids: Set(rows.keys)) } catch { startupError = error.localizedDescription }
            for id in rows.keys {
                if let row = rows[id], row.oiTimestamp >= Double(hour - hourMS),
                   row.oiTimestamp < Double(hour), let oi = row.oi, oi > 0 {
                    oiHistory[id, default: [:]][hour - hourMS] = oi
                }
                rows[id]?.oiBase = nil; rows[id]?.buy = nil; rows[id]?.sell = nil; rows[id]?.takerRatio = nil
                oiHistory[id] = oiHistory[id]?.filter { $0.key >= hour - Int64(chartHours - 1) * hourMS }
                candles[id] = candles[id]?.filter { $0.key >= hour - Int64(candleLookback) * hourMS }
            }
            emaStates = emaStates.filter { $0.value.0 >= hour - Int64(candleLookback + 1) * hourMS && $0.value.0 < hour }
            touch()
            tasks.append(Task { [weak self] in await self?.scan("/market/candles", delay: 120_000_000) })
            tasks.append(Task { [weak self] in await self?.scan("/rubik/stat/contracts/open-interest-history", delay: 250_000_000) })
            tasks.removeAll { $0.isCancelled }
        }
    }

    private func ema200(_ id: String, _ bars: [Int64: Candle]) -> Double? {
        let target = hour - hourMS
        var state = emaStates[id]
        if let prior = state, prior.0 < target {
            for ts in stride(from: prior.0 + hourMS, through: target, by: Int(hourMS)) {
                guard let bar = bars[ts], bar.confirmed else { state = nil; break }
                state = (ts, state!.1 + (bar.close - state!.1) * 2 / 201)
            }
        }
        if state?.0 != target {
            let closes = (0..<200).compactMap { age -> Double? in
                guard let bar = bars[target - Int64(age) * hourMS], bar.confirmed else { return nil }
                return bar.close
            }
            guard closes.count == 200 else { return nil }
            state = (target, closes.reduce(0, +) / 200)
        }
        if emaStates[id]?.0 != state?.0 || emaStates[id]?.1 != state?.1 {
            emaStates[id] = state
            do { try store.execute("INSERT OR REPLACE INTO ema200 VALUES (?,?,?)", [id, state!.0, state!.1]) }
            catch { startupError = "Cache error: \(error.localizedDescription)" }
        }
        return state?.1
    }

    func loadChart(_ id: String) async -> [String: Any] {
        guard rows[id] != nil else { return ["bars": [], "error": "Unknown contract"] }
        var failures: [String] = []
        do {
            for case let values as [String] in try await get("/market/candles", ["instId": id, "bar": "1H", "limit": "251"]) {
                updateCandle(id, values, history: true)
            }
        } catch { failures.append("candles") }
        for (path, label) in [
            ("/rubik/stat/contracts/open-interest-history", "OI"),
            ("/rubik/stat/taker-volume-contract", "taker volume"),
        ] {
            do {
                for case let values as [String] in try await get(path, ["instId": id, "period": "1H"]) {
                    guard let first = values.first, let ts = Int64(first),
                          ts >= hour - Int64(chartHours - 1) * hourMS, ts <= hour else { continue }
                    if label == "OI", values.count >= 4, let value = Double(values[3]), value.isFinite, value >= 0 {
                        if ts == hour {
                            var live = chartLiveStats[id] ?? (oi: nil, sell: nil, buy: nil)
                            live.oi = value; chartLiveStats[id] = live
                        } else { try store.saveChartStat(id, hour: ts, oi: value) }
                    } else if label == "taker volume", values.count >= 3,
                              let sell = Double(values[1]), let buy = Double(values[2]),
                              sell.isFinite, buy.isFinite, sell >= 0, buy >= 0 {
                        if ts == hour {
                            var live = chartLiveStats[id] ?? (oi: nil, sell: nil, buy: nil)
                            live.sell = sell; live.buy = buy; chartLiveStats[id] = live
                        } else { try store.saveChartStat(id, hour: ts, sell: sell, buy: buy) }
                    }
                }
            } catch { failures.append(label) }
        }
        var result = chartSnapshot(id)
        if !failures.isEmpty { result["error"] = "Some chart data is unavailable: \(failures.joined(separator: ", "))." }
        return result
    }

    func chartSnapshot(_ id: String) -> [String: Any] {
        guard rows[id] != nil else { return ["bars": [], "error": "Unknown contract"] }
        let null = NSNull()
        let series = candles[id] ?? [:]
        let stats: [Int64: (oi: Double?, sell: Double?, buy: Double?)]
        do { stats = try store.chartStats(id, since: hour - Int64(chartHours - 1) * hourMS) }
        catch { return ["bars": [], "error": "Cannot read chart cache: \(error.localizedDescription)"] }
        let first = hour - Int64(chartHours - 1) * hourMS
        let seed = (1...200).compactMap { series[first - Int64($0) * hourMS]?.confirmed == true ? series[first - Int64($0) * hourMS]?.close : nil }
        var ema: Double? = seed.count == 200 ? seed.reduce(0, +) / 200 : nil
        var chartEMA: [Int64: Double] = [:]
        if let previous = ema200(id, series) {
            let alpha = 2.0 / 201.0
            let last = series[hour] == nil ? hour - hourMS : hour
            var value = series[hour].map { previous + ($0.close - previous) * alpha } ?? previous
            for ts in stride(from: last, through: first, by: -Int(hourMS)) {
                guard let bar = series[ts] else { break }
                chartEMA[ts] = value
                value = (value - bar.close * alpha) / (1 - alpha)
            }
        }
        var output: [[String: Any]] = []
        for ts in stride(from: first, through: hour, by: Int(hourMS)) {
            guard let bar = series[ts] else { ema = nil; continue }
            ema = chartEMA[ts] ?? ema.map { $0 + (bar.close - $0) * 2 / 201 }
            guard let open = bar.open else { continue }
            let (roc, maroc) = rocMaroc(series, ts, 9, 9)
            let (upper, middle, lower) = boll(series, ts)
            let stat = stats[ts]
            let live = chartLiveStats[id]
            let oi = ts == hour ? rows[id]?.oiUsd ?? live?.oi : stat?.oi
            let sell = ts == hour ? rows[id]?.sell ?? live?.sell : stat?.sell
            let buy = ts == hour ? rows[id]?.buy ?? live?.buy : stat?.buy
            output.append([
                "hour": ts, "open": open, "high": bar.high, "low": bar.low, "close": bar.close,
                "volume": bar.quoteVolume, "confirmed": bar.confirmed,
                "vwap": vwap14(series, ts) as Any? ?? null, "ema": ema as Any? ?? null,
                "bollUpper": upper as Any? ?? null, "bollMiddle": middle as Any? ?? null, "bollLower": lower as Any? ?? null,
                "roc": roc as Any? ?? null, "maroc": maroc as Any? ?? null,
                "rsi6": rsi(series, ts, 6) as Any? ?? null,
                "rsi12": rsi(series, ts, 12) as Any? ?? null,
                "rsi24": rsi(series, ts, 24) as Any? ?? null,
                "oi": oi as Any? ?? null, "sell": sell as Any? ?? null, "buy": buy as Any? ?? null,
            ])
        }
        return ["bars": output, "error": ""]
    }

    func snapshot(rocPeriod: Int, marocPeriod: Int) -> [String: Any] {
        guard (1...100).contains(rocPeriod), (1...100).contains(marocPeriod) else {
            return ["rows": [], "updatedAt": NSNull(), "error": "Periods must be from 1 to 100.",
                    "minimum24hTurnoverUSDT": minimum24hTurnoverUSDT,
                    "spreadFilterEnabled": spreadFilterEnabled, "maximumSpreadPercent": maximumSpreadPercent]
        }
        let null = NSNull()
        var output: [[String: Any]] = []
        for id in rows.keys.sorted() {
            guard let row = rows[id], let turnover = row.turnover24hUSDT,
                  turnover >= Double(minimum24hTurnoverUSDT),
                  passesSpreadFilter(row.spreadPercent, enabled: spreadFilterEnabled, maximum: maximumSpreadPercent) else { continue }
            let bars = candles[id] ?? [:]
            let (high, low) = extremes(bars, hour)
            let (upper, middle, lower) = boll(bars, hour)
            let (roc, maroc) = rocMaroc(bars, hour, rocPeriod, marocPeriod)
            let current = bars[hour], previous = bars[hour - hourMS]
            let (oldRoc, oldMaroc) = previous?.confirmed == true ? rocMaroc(bars, hour - hourMS, rocPeriod, marocPeriod) : (nil, nil)
            let price = current?.close
            let previousEMA = ema200(id, bars)
            let ema = previousEMA.flatMap { old in price.map { old + ($0 - old) * 2 / 201 } }
            // Recover the last closed hour's EMA slope from its close and EMA value.
            let priorEMASlope = previous.flatMap { bar in bar.confirmed ? previousEMA.map { (bar.close - $0) * 2 / 199 } : nil }
            var oiPoints = (oiHistory[id] ?? [:]).map { (hour: $0.key, oi: $0.value) }.sorted { $0.hour < $1.hour }
            let hasLiveOI = row.oiTimestamp >= Double(hour) && (row.oi ?? 0) > 0
            if hasLiveOI, let oi = row.oi { oiPoints.append((hour: hour, oi: oi)) }
            output.append([
                "instId": id, "price": price as Any? ?? null,
                "priceChange": percentChange(price, previous?.confirmed == true ? previous?.close : nil) as Any? ?? null,
                "vwap14": vwap14(bars, hour) as Any? ?? null,
                "ema200": ema as Any? ?? null, "ema200Slope": priorEMASlope as Any? ?? null,
                "oi": row.oi as Any? ?? null, "oiBase": row.oiBase as Any? ?? null,
                "oiLog": logChange(row.oi, row.oiBase) as Any? ?? null, "oiUsd": row.oiUsd as Any? ?? null,
                "oiSignal": (hasLiveOI ? oiSignal(oiPoints)?.rawValue : nil) as Any? ?? null,
                "buy": row.buy as Any? ?? null, "sell": row.sell as Any? ?? null,
                "takerRatio": row.takerRatio as Any? ?? null,
                "volumeLog": logChange(current?.quoteVolume, previous?.confirmed == true ? previous?.quoteVolume : nil) as Any? ?? null,
                "high48": high as Any? ?? null, "high48Diff": percentChange(price, high) as Any? ?? null,
                "low48": low as Any? ?? null, "low48Diff": percentChange(price, low) as Any? ?? null,
                "roc": roc as Any? ?? null, "maroc": maroc as Any? ?? null,
                "rocChange": percentChange(roc, oldRoc) as Any? ?? null,
                "marocChange": percentChange(maroc, oldMaroc) as Any? ?? null,
                "rsi6": rsi(bars, hour, 6) as Any? ?? null,
                "rsi12": rsi(bars, hour, 12) as Any? ?? null,
                "rsi24": rsi(bars, hour, 24) as Any? ?? null,
                "bollUpper": upper as Any? ?? null, "bollMiddle": middle as Any? ?? null, "bollLower": lower as Any? ?? null,
            ])
        }
        let error = !startupError.isEmpty ? startupError : !failedPaths.isEmpty ? "Some OKX data is unavailable; retrying." :
            !disconnectedChannels.isEmpty ? "OKX \(disconnectedChannels.sorted()[0]) disconnected; reconnecting." : ""
        return ["rows": output, "updatedAt": updatedAt as Any? ?? null, "error": error,
                "minimum24hTurnoverUSDT": minimum24hTurnoverUSDT,
                "spreadFilterEnabled": spreadFilterEnabled, "maximumSpreadPercent": maximumSpreadPercent]
    }
}
