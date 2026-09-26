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
        XCTAssertNil(Candle([String(hour), "100", "110", "90", "120", "10", "2", "200", "1"]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try Store(url: url)
        try store.save("BTC-USDT-SWAP", bar)
        try store.execute("INSERT INTO oi_base VALUES (?,?,?)", ["BTC-USDT-SWAP", hour + hourMS, 10.0])
        try store.prune(hour: hour + hourMS, ids: ["BTC-USDT-SWAP"])
        let loaded = try store.load(hour: hour + hourMS, ids: ["BTC-USDT-SWAP"])
        XCTAssertEqual(loaded.candles["BTC-USDT-SWAP"]?[hour]?.baseVolume, 2)
        XCTAssertEqual(loaded.oi["BTC-USDT-SWAP"], 10)
    }
}
