import Foundation

private let api = "https://www.okx.com/api/v5"
private let publicWS = "wss://ws.okx.com:8443/ws/v5/public"
private let businessWS = "wss://ws.okx.com:8443/ws/v5/business"
private let turnoverThresholdKey = "minimum24hTurnoverUSDT"

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

private func millis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

private struct Market {
    let id: String
    var turnover24hUSDT: Double?
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
    private var rows: [String: Market] = [:]
    private var candles: [String: [Int64: Candle]] = [:]
    private var emaStates: [String: (Int64, Double)] = [:]
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
                candles = cached.candles; emaStates = cached.ema
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
        var turnover: [String: Double] = [:]
        for case let ticker as [String: Any] in tickers {
            guard let id = ticker["instId"] as? String, rows[id] != nil,
                  let value = usdtTurnover24h(ticker) else { continue }
            turnover[id] = value
        }
        guard !turnover.isEmpty else {
            throw NSError(domain: "OKX", code: 4, userInfo: [NSLocalizedDescriptionKey: "No USDT swap ticker data found"])
        }
        for id in rows.keys { rows[id]?.turnover24hUSDT = turnover[id] }
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
        guard !history || old == nil || (!old!.confirmed && bar.confirmed) || old!.baseVolume == nil else { return }
        let settled: Candle
        if history, let old, old.confirmed, old.baseVolume == nil {
            settled = Candle(hour: old.hour, high: old.high, low: old.low, close: old.close, quoteVolume: old.quoteVolume, baseVolume: bar.baseVolume)
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
        return (1...candleLookback).allSatisfy { series[hour - Int64($0) * hourMS]?.confirmed == true } &&
            (1..<14).allSatisfy { series[hour - Int64($0) * hourMS]?.baseVolume != nil }
    }

    private func scan(_ path: String, delay: UInt64, repeatScan: Bool = false) async {
        var ids = rows.keys.sorted()
        if path.contains("open-interest-history") { ids = ids.filter { rows[$0]?.oiBase == nil } }
        while !Task.isCancelled {
            var failed = Set<String>()
            for id in ids {
                if Task.isCancelled { return }
                do {
                    let parameters = path == "/market/candles"
                        ? ["instId": id, "bar": "1H", "limit": historyReady(id) ? "1" : "201"]
                        : ["instId": id, "period": "1H"]
                    let result = try await get(path, parameters)
                    switch path {
                    case "/market/candles":
                        for case let bar as [String] in result { updateCandle(id, bar, history: true) }
                    case "/rubik/stat/contracts/open-interest-history":
                        if let item = result.compactMap({ $0 as? [String] }).first(where: { Int64($0.first ?? "") == hour - hourMS }),
                           item.count >= 2, let base = Double(item[1]), base.isFinite, base > 0 {
                            rows[id]?.oiBase = base
                            try store.execute("INSERT OR IGNORE INTO oi_base VALUES (?,?,?)", [id, hour, base])
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
            do { try store.prune(hour: hour, ids: Set(rows.keys)) } catch { startupError = error.localizedDescription }
            for id in rows.keys {
                rows[id]?.oiBase = nil; rows[id]?.buy = nil; rows[id]?.sell = nil; rows[id]?.takerRatio = nil
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

    func snapshot(rocPeriod: Int, marocPeriod: Int) -> [String: Any] {
        guard (1...100).contains(rocPeriod), (1...100).contains(marocPeriod) else {
            return ["rows": [], "updatedAt": NSNull(), "error": "Periods must be from 1 to 100.",
                    "minimum24hTurnoverUSDT": minimum24hTurnoverUSDT]
        }
        let null = NSNull()
        var output: [[String: Any]] = []
        for id in rows.keys.sorted() {
            guard let row = rows[id], let turnover = row.turnover24hUSDT,
                  turnover >= Double(minimum24hTurnoverUSDT) else { continue }
            let bars = candles[id] ?? [:]
            let (high, low) = extremes(bars, hour)
            let (upper, middle, lower) = boll(bars, hour)
            let (roc, maroc) = rocMaroc(bars, hour, rocPeriod, marocPeriod)
            let current = bars[hour], previous = bars[hour - hourMS]
            let (oldRoc, oldMaroc) = previous?.confirmed == true ? rocMaroc(bars, hour - hourMS, rocPeriod, marocPeriod) : (nil, nil)
            let price = current?.close
            let previousEMA = ema200(id, bars)
            let ema = previousEMA.flatMap { old in price.map { old + ($0 - old) * 2 / 201 } }
            output.append([
                "instId": id, "price": price as Any? ?? null,
                "priceChange": percentChange(price, previous?.confirmed == true ? previous?.close : nil) as Any? ?? null,
                "vwap14": vwap14(bars, hour) as Any? ?? null,
                "ema200": ema as Any? ?? null, "ema200Slope": (ema.flatMap { value in previousEMA.map { value - $0 } }) as Any? ?? null,
                "oi": row.oi as Any? ?? null, "oiBase": row.oiBase as Any? ?? null,
                "oiLog": logChange(row.oi, row.oiBase) as Any? ?? null, "oiUsd": row.oiUsd as Any? ?? null,
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
                "minimum24hTurnoverUSDT": minimum24hTurnoverUSDT]
    }
}
