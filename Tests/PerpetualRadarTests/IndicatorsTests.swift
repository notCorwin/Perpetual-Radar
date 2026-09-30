import XCTest
@testable import PerpetualRadar

final class IndicatorsTests: XCTestCase {
    func test96HourExtremesIncludeOldestHourAndExcludeCurrentAndOlderCandles() {
        let hour = Int64(200) * hourMS
        var bars: [Int64: Candle] = [:]
        for age in 0...97 {
            let ts = hour - Int64(age) * hourMS
            let outsideWindow = age == 0 || age == 97
            bars[ts] = Candle(hour: ts, high: outsideWindow ? 1_000 : age == 96 ? 300 : 200,
                              low: outsideWindow ? 1 : age == 96 ? 50 : 90,
                              close: 100, quoteVolume: 100, baseVolume: 1)
        }
        let result = extremes(bars, hour)
        XCTAssertEqual(result.high, 300)
        XCTAssertEqual(result.low, 50)
        XCTAssertEqual(result.highHoursAgo, 96)
        XCTAssertEqual(logChange(100, result.high)!, log(100.0 / 300), accuracy: 0.000001)
        XCTAssertEqual(logChange(100, result.low)!, log(2), accuracy: 0.000001)

        let recentHour = hour - 5 * hourMS
        bars[recentHour] = Candle(hour: recentHour, high: 300, low: 90, close: 100, quoteVolume: 100, baseVolume: 1)
        XCTAssertEqual(extremes(bars, hour).highHoursAgo, 5)
        let nextHour = hour + hourMS
        bars[nextHour] = Candle(hour: nextHour, high: 2_000, low: 1, close: 100, quoteVolume: 100, baseVolume: 1)
        XCTAssertEqual(extremes(bars, nextHour).high, 1_000)
        XCTAssertEqual(extremes(bars, nextHour).highHoursAgo, 1)
    }

    func test96HourExtremesRequireEveryCompletedCandle() throws {
        let hour = Int64(200) * hourMS
        var bars: [Int64: Candle] = [:]
        for age in 1...96 {
            let ts = hour - Int64(age) * hourMS
            bars[ts] = Candle(hour: ts, high: 210, low: 90, close: 100, quoteVolume: 100, baseVolume: 1)
        }
        XCTAssertEqual(extremes(bars, hour).highHoursAgo, 1)
        let oldest = hour - 96 * hourMS
        bars.removeValue(forKey: oldest)
        XCTAssertNil(extremes(bars, hour).high)
        XCTAssertNil(extremes(bars, hour).low)
        XCTAssertNil(extremes(bars, hour).highHoursAgo)
        bars[oldest] = try XCTUnwrap(Candle([String(oldest), "100", "210", "90", "100", "1", "1", "100", "0"]))
        XCTAssertNil(extremes(bars, hour).high)
        XCTAssertNil(extremes(bars, hour).low)
        XCTAssertNil(extremes(bars, hour).highHoursAgo)
    }

    func testOpenInterestLogChangeRequiresPositiveHourlyValues() {
        XCTAssertEqual(logChange(120, 100)!, log(1.2), accuracy: 0.000001)
        XCTAssertEqual(logChange(80, 100)!, log(0.8), accuracy: 0.000001)
        XCTAssertNil(logChange(nil, 100))
        XCTAssertNil(logChange(100, nil))
        XCTAssertNil(logChange(0, 100))
        XCTAssertNil(logChange(100, 0))
    }

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

    func testHourlyIndicatorsAndMissingData() {
        let hour = Int64(200) * hourMS
        var bars: [Int64: Candle] = [:]
        for age in 0...200 {
            let ts = hour - Int64(age) * hourMS
            bars[ts] = Candle(hour: ts, high: 210, low: 90, close: Double(200 - age), quoteVolume: 100, baseVolume: 1)
        }
        XCTAssertEqual(extremes(bars, hour).0, 210)
        XCTAssertEqual(rocMaroc(bars, hour, 9, 9).0!, (200.0 / 191.0 - 1) * 100, accuracy: 0.000001)
        var expectedMAROC = 0.0
        for age in 0..<9 {
            let current = Double(200 - age)
            let previous = Double(191 - age)
            expectedMAROC += (current / previous - 1) * 100 / 9
        }
        XCTAssertEqual(rocMaroc(bars, hour, 9, 9).1!, expectedMAROC, accuracy: 0.000001)
        XCTAssertEqual(vwap14(bars, hour), 100)
        XCTAssertEqual(rsi(bars, hour, 6), 100)
        let geometricMean = exp((181...200).map { log(Double($0)) }.reduce(0, +) / 20)
        XCTAssertEqual(logBB(bars, hour).1!, geometricMean, accuracy: 0.000001)
        bars.removeValue(forKey: hour - 7 * hourMS)
        XCTAssertNil(extremes(bars, hour).0)
        XCTAssertNil(vwap14(bars, hour))
        XCTAssertNil(logBB(bars, hour).0)
        XCTAssertNil(rocMaroc(bars, hour, 9, 9).1)
    }

    func testLogBBRemainsPositiveForWidePriceRanges() throws {
        let hour = Int64(20) * hourMS
        var bars: [Int64: Candle] = [:]
        for age in 0..<20 {
            let ts = hour - Int64(age) * hourMS
            bars[ts] = Candle(hour: ts, high: 100, low: 1, close: age.isMultiple(of: 2) ? 1 : 100,
                              quoteVolume: 100, baseVolume: 1)
        }
        let (upper, middle, lower) = logBB(bars, hour)
        XCTAssertEqual(try XCTUnwrap(upper), 1_000, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(middle), 10, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(lower), 0.1, accuracy: 0.000001)
        bars.removeValue(forKey: hour - 19 * hourMS)
        XCTAssertNil(logBB(bars, hour).0)
        bars[hour - 19 * hourMS] = Candle(hour: hour - 19 * hourMS, high: 100, low: 0,
                                         close: 0, quoteVolume: 100, baseVolume: 1)
        XCTAssertNil(logBB(bars, hour).0)
    }

    func testCandleValidationAndPermanentHistory() throws {
        let hour: Int64 = 200 * hourMS
        let values = [String(hour), "100", "110", "90", "100", "10", "2", "200", "1"]
        let bar = try XCTUnwrap(Candle(values))
        XCTAssertEqual(bar.open, 100)
        XCTAssertNil(Candle([String(hour), "100", "110", "90", "120", "10", "2", "200", "1"]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try Store(url: url)
        try store.save("BTC-USDT-SWAP", bar)
        let olderHour = hour - 300 * hourMS
        try store.save("BTC-USDT-SWAP", Candle(hour: olderHour, high: 110, low: 90, close: 100, quoteVolume: 200, baseVolume: 2, open: 99))
        try store.saveChartStat("BTC-USDT-SWAP", hour: hour, oi: 1_000)
        try store.saveChartStat("BTC-USDT-SWAP", hour: hour, sell: 20, buy: 30)
        try store.saveChartStat("BTC-USDT-SWAP", hour: hour - hourMS, oi: 800)
        try store.saveChartStat("ETH-USDT-SWAP", hour: hour - hourMS, oi: 600)
        try store.saveChartStat("BTC-USDT-SWAP", hour: hour - 94 * hourMS, oi: 500)
        try store.saveChartStat("BTC-USDT-SWAP", hour: hour - 95 * hourMS, oi: 400)
        let loaded = try store.load(hour: hour + hourMS, ids: ["BTC-USDT-SWAP"])
        XCTAssertEqual(loaded.candles["BTC-USDT-SWAP"]?[hour]?.baseVolume, 2)
        XCTAssertEqual(loaded.candles["BTC-USDT-SWAP"]?[hour]?.open, 100)
        let stat = try store.chartStats("BTC-USDT-SWAP", since: hour)
        XCTAssertEqual(stat[hour]?.oi, 1_000)
        XCTAssertEqual(stat[hour]?.sell, 20)
        XCTAssertEqual(stat[hour]?.buy, 30)
        XCTAssertEqual(try store.openInterest(hour: hour - hourMS), ["BTC-USDT-SWAP": 800, "ETH-USDT-SWAP": 600])
        let reopened = try Store(url: url)
        let history = try reopened.chartStats("BTC-USDT-SWAP", since: 0)
        XCTAssertEqual(history[hour - 94 * hourMS]?.oi, 500)
        XCTAssertEqual(history[hour - 95 * hourMS]?.oi, 400)
        XCTAssertEqual(try reopened.load(hour: olderHour + hourMS, ids: ["BTC-USDT-SWAP"]).candles["BTC-USDT-SWAP"]?[olderHour]?.open, 99)
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
        XCTAssertNil(try store.oldestCandleHour("BTC-USDT-SWAP"))
        try store.save("BTC-USDT-SWAP", Candle(hour: 0, high: 110, low: 90, close: 100, quoteVolume: 200, baseVolume: 2, open: 99))
        XCTAssertEqual(try store.load(hour: hourMS, ids: ["BTC-USDT-SWAP"]).candles["BTC-USDT-SWAP"]?[0]?.open, 99)
        XCTAssertEqual(try store.oldestCandleHour("BTC-USDT-SWAP"), 0)
    }

    func testCandleBatchRollsBackOnWriteFailure() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try Store(url: url)
        try store.execute("CREATE TRIGGER reject_second BEFORE INSERT ON candles WHEN NEW.hour = \(hourMS) BEGIN SELECT RAISE(ABORT, 'rejected'); END")
        let first = Candle(hour: 0, high: 110, low: 90, close: 100, quoteVolume: 200, baseVolume: 2, open: 99)
        let second = Candle(hour: hourMS, high: 110, low: 90, close: 100, quoteVolume: 200, baseVolume: 2, open: 99)
        XCTAssertThrowsError(try store.saveCandles("BTC-USDT-SWAP", [first, second]))
        XCTAssertTrue(try store.load(hour: hourMS, ids: ["BTC-USDT-SWAP"]).candles.isEmpty)
    }

    func testHistoricalPageAndBoundedIndicatorWindow() throws {
        let id = "BTC-USDT-SWAP"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try Store(url: url)
        let end = Int64(400) * hourMS
        let rows: [Any] = [
            [String(end - hourMS), "100", "110", "90", "100", "1", "2", "200", "1"],
            [String(end), "100", "110", "90", "100", "1", "2", "200", "0"],
            [String(end + hourMS), "100", "110", "90", "100", "1", "2", "200", "1"],
        ]
        XCTAssertEqual(historicalPage(rows, before: end).map(\.hour), [end - hourMS])
        XCTAssertTrue(historicalPage([], before: end).isEmpty)
        try store.saveCandles(id, (0...400).map { index in
            Candle(hour: Int64(index) * hourMS, high: 110, low: 90, close: 100 + Double(index % 5), quoteVolume: 200, baseVolume: 2, open: 100)
        })
        let window = try store.candles(id, since: 50 * hourMS, through: end)
        XCTAssertEqual(window.count, 351)
        XCTAssertNotNil(rsi(window, end - 95 * hourMS, 24))
        XCTAssertEqual(try store.oldestCandleHour(id), 0)
        try store.saveChartStat(id, hour: end, oi: 12)
        XCTAssertTrue(try store.chartStats(id, since: 0, through: end - hourMS).isEmpty)
    }

    func testHistoricalBoundaryUsesOldestSavedCandleOnlyAfterExhaustion() throws {
        let id = "BTC-USDT-SWAP"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try Store(url: url)
        let latest = Int64(500) * hourMS
        let olderLocal = Int64(10) * hourMS
        try store.save(id, Candle(hour: olderLocal, high: 110, low: 90, close: 100, quoteVolume: 200, baseVolume: 2, open: 99))
        let oldest = try store.oldestCandleHour(id)
        XCTAssertEqual(boundedHistoryEnd(0, oldest: oldest, exhausted: true, latest: latest), olderLocal + 95 * hourMS)
        XCTAssertEqual(boundedHistoryEnd(0, oldest: oldest, exhausted: false, latest: latest), 0)
        XCTAssertEqual(boundedHistoryEnd(450 * hourMS, oldest: oldest, exhausted: true, latest: latest), 450 * hourMS)
        XCTAssertEqual(boundedHistoryEnd(0, oldest: nil, exhausted: true, latest: latest), 0)
    }
}
