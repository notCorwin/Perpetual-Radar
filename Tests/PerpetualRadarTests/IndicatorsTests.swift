import XCTest
@testable import PerpetualRadar

final class IndicatorsTests: XCTestCase {
    func testSwap24hTurnoverUsesBaseVolumeAndLastUSDTPrice() {
        XCTAssertEqual(usdtTurnover24h(["volCcy24h": "1000000", "last": "10"]), 10_000_000)
        XCTAssertEqual(usdtTurnover24h(["volCcy24h": "999999", "last": "10"]), 9_999_990)
        XCTAssertNil(usdtTurnover24h(["volCcy24h": "NaN", "last": "10"]))
        XCTAssertNil(usdtTurnover24h(["volCcy24h": "1000000", "last": "0"]))
    }

    func testSupported24hTurnoverThresholds() {
        XCTAssertTrue(supportedTurnoverThreshold(10_000_000))
        XCTAssertTrue(supportedTurnoverThreshold(30_000_000))
        XCTAssertTrue(supportedTurnoverThreshold(100_000_000))
        XCTAssertFalse(supportedTurnoverThreshold(0))
        XCTAssertFalse(supportedTurnoverThreshold(29_999_999))
    }

    func testSpreadFilter() {
        let tight = spreadPercent(["bidPx": "99.925", "askPx": "100.075"])
        let wide = spreadPercent(["bidPx": "99.9", "askPx": "100.1"])
        XCTAssertEqual(tight!, 0.15, accuracy: 0.000001)
        XCTAssertTrue(passesSpreadFilter(tight, enabled: true, maximum: 0.15))
        XCTAssertFalse(passesSpreadFilter(wide, enabled: true, maximum: 0.15))
        XCTAssertFalse(passesSpreadFilter(nil, enabled: true, maximum: 0.15))
        XCTAssertTrue(passesSpreadFilter(nil, enabled: false, maximum: 0.15))
        XCTAssertNil(spreadPercent(["bidPx": "0", "askPx": "100"]))
        XCTAssertNil(spreadPercent(["bidPx": "101", "askPx": "100"]))
    }

    func testOISignalUsesPriorStableWindowAndFindsNewCycles() {
        func signal(_ values: [Double]) -> OISignal? {
            oiSignal(values.enumerated().map { (hour: Int64($0.offset) * hourMS, oi: $0.element) })
        }
        let stable = Array(repeating: 100.0, count: 8)
        XCTAssertNil(signal(stable))
        XCTAssertEqual(signal(stable + [100]), .stable)
        XCTAssertEqual(signal(stable + [104]), .building)
        XCTAssertEqual(signal(stable + [104, 110, 109.5]), .peaking)
        XCTAssertEqual(signal(stable + [104, 110, 109.5, 103]), .unwinding)
        XCTAssertEqual(signal(stable + [104, 110, 109.5, 103, 102, 101, 108]), .building)
        let ended = stable + [104, 110, 109.5, 103, 102, 101, 100, 100, 100, 100]
        XCTAssertEqual(signal(ended), .stable)
        XCTAssertEqual(signal(ended + [104]), .building)
        XCTAssertEqual(signal(stable + [80, 80, 80, 84]), .building)
        XCTAssertNil(oiSignal([]))
        XCTAssertNil(signal(stable + [0]))
        var gap = stable.enumerated().map { (hour: Int64($0.offset) * hourMS, oi: $0.element) }
        gap.append((hour: 10 * hourMS, oi: 104))
        XCTAssertNil(oiSignal(gap))
    }

    func testHourlyIndicatorsAndMissingData() {
        let hour = Int64(200) * hourMS
        var bars: [Int64: Candle] = [:]
        for age in 0...200 {
            let ts = hour - Int64(age) * hourMS
            bars[ts] = Candle(hour: ts, high: 210, low: 90, close: Double(200 - age), quoteVolume: 100, baseVolume: 1)
        }
        XCTAssertEqual(extremes(bars, hour).0, 210)
        XCTAssertEqual(rocMaroc(bars, hour, 9, 9).0!, (200.0 / 191.0 - 1) * 100, accuracy: 0.000001)
        XCTAssertEqual(vwap14(bars, hour), 100)
        XCTAssertEqual(rsi(bars, hour, 6), 100)
        XCTAssertEqual(boll(bars, hour).1, 190.5)
        bars.removeValue(forKey: hour - 7 * hourMS)
        XCTAssertNil(extremes(bars, hour).0)
        XCTAssertNil(vwap14(bars, hour))
        XCTAssertNil(boll(bars, hour).0)
        XCTAssertNil(rocMaroc(bars, hour, 9, 9).1)
    }

    func testCandleValidationAndCache() throws {
        let hour: Int64 = 200 * hourMS
        let values = [String(hour), "100", "110", "90", "100", "10", "2", "200", "1"]
        let bar = try XCTUnwrap(Candle(values))
        XCTAssertEqual(bar.open, 100)
        XCTAssertNil(Candle([String(hour), "100", "110", "90", "120", "10", "2", "200", "1"]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try Store(url: url)
        try store.save("BTC-USDT-SWAP", bar)
        try store.saveChartStat("BTC-USDT-SWAP", hour: hour, oi: 1_000)
        try store.saveChartStat("BTC-USDT-SWAP", hour: hour, sell: 20, buy: 30)
        try store.saveOIHistory("BTC-USDT-SWAP", [hour: 1_234])
        try store.saveChartStat("BTC-USDT-SWAP", hour: hour - 94 * hourMS, oi: 500)
        try store.saveChartStat("BTC-USDT-SWAP", hour: hour - 95 * hourMS, oi: 400)
        try store.execute("INSERT INTO oi_base VALUES (?,?,?)", ["BTC-USDT-SWAP", hour + hourMS, 10.0])
        try store.prune(hour: hour + hourMS, ids: ["BTC-USDT-SWAP"])
        let loaded = try store.load(hour: hour + hourMS, ids: ["BTC-USDT-SWAP"])
        XCTAssertEqual(loaded.candles["BTC-USDT-SWAP"]?[hour]?.baseVolume, 2)
        XCTAssertEqual(loaded.candles["BTC-USDT-SWAP"]?[hour]?.open, 100)
        XCTAssertEqual(loaded.oi["BTC-USDT-SWAP"], 10)
        XCTAssertEqual(loaded.oiHistory["BTC-USDT-SWAP"]?[hour], 1_234)
        let stat = try store.chartStats("BTC-USDT-SWAP", since: hour)
        XCTAssertEqual(stat[hour]?.oi, 1_000)
        XCTAssertEqual(stat[hour]?.sell, 20)
        XCTAssertEqual(stat[hour]?.buy, 30)
        let history = try store.chartStats("BTC-USDT-SWAP", since: 0)
        XCTAssertEqual(history[hour - 94 * hourMS]?.oi, 500)
        XCTAssertNil(history[hour - 95 * hourMS])
    }

    func testCachedCandleBackfillsOpenWithoutLosingHistory() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let old = try Store(url: url)
            try old.execute("INSERT INTO candles (inst_id,hour,high,low,close,volume,base_volume) VALUES (?,?,?,?,?,?,?)", ["BTC-USDT-SWAP", Int64(0), 110.0, 90.0, 100.0, 200.0, 2.0])
        }
        let store = try Store(url: url)
        let cached = try store.load(hour: hourMS, ids: ["BTC-USDT-SWAP"])
        XCTAssertEqual(cached.candles["BTC-USDT-SWAP"]?[0]?.close, 100)
        XCTAssertNil(cached.candles["BTC-USDT-SWAP"]?[0]?.open)
        try store.save("BTC-USDT-SWAP", Candle(hour: 0, high: 110, low: 90, close: 100, quoteVolume: 200, baseVolume: 2, open: 99))
        XCTAssertEqual(try store.load(hour: hourMS, ids: ["BTC-USDT-SWAP"]).candles["BTC-USDT-SWAP"]?[0]?.open, 99)
    }
}
