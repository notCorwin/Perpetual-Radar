import XCTest
@testable import PerpetualRadar

final class MarketFilterTests: XCTestCase {
    private let hour = Int64(500) * hourMS
    private func candle(_ age: Int, high: Double = 120, low: Double = 80, confirmed: Bool = true) -> Candle {
        Candle([String(hour - Int64(age) * hourMS), "100", String(high), String(low), "100", "1", "1", "100", confirmed ? "1" : "0"])!
    }
    private func history() -> [Int64: Candle] {
        Dictionary(uniqueKeysWithValues: (0...150).map { age in
            let bar = candle(age)
            return (bar.hour, bar)
        })
    }

    func testCompletedExtremeWindowsIncludeTheirLastHourAndExcludeLiveAndOlderHours() {
        var bars = history()
        bars[hour] = candle(0, high: 999, low: 1, confirmed: false)
        bars[hour - 48 * hourMS] = candle(48, high: 130, low: 70)
        bars[hour - 96 * hourMS] = candle(96, high: 150, low: 60)
        bars[hour - 97 * hourMS] = candle(97, high: 800, low: 2)
        XCTAssertEqual(priorExtremes(bars, hour, hours: 48).high, 130)
        XCTAssertEqual(priorExtremes(bars, hour, hours: 48).low, 70)
        XCTAssertEqual(priorExtremes(bars, hour, hours: 96).high, 150)
        XCTAssertEqual(priorExtremes(bars, hour, hours: 96).low, 60)
        bars.removeValue(forKey: hour - 96 * hourMS)
        XCTAssertNil(priorExtremes(bars, hour, hours: 96).high)
        XCTAssertEqual(priorExtremes(bars, hour, hours: 48).high, 130)
        bars[hour - 1 * hourMS] = candle(1, confirmed: false)
        XCTAssertNil(priorExtremes(bars, hour, hours: 48).low)
        XCTAssertNil(priorExtremes(bars, hour, hours: 0).high)
    }

    func test96HourBreakoutDiffersFrom48HourBreakoutAndPreservesStrictEquality() throws {
        var bars = history()
        bars[hour - 96 * hourMS] = candle(96, high: 150, low: 60)
        bars[hour] = candle(0, high: 150, low: 60, confirmed: false)
        let short = recentExtremesBreaks(bars, hour)
        guard case .event(let shortHigh) = short.highBreakout else { return XCTFail("Expected a 48h breakout") }
        XCTAssertEqual(shortHigh.hoursAgo, 0)
        let equal = recentExtremesBreaks(bars, hour, lookbackHours: 96)
        XCTAssertEqual(equal.highBreakout, .none)
        XCTAssertEqual(equal.lowBreakdown, .none)
        bars[hour] = candle(0, high: 151, low: 59, confirmed: false)
        let broken = recentExtremesBreaks(bars, hour, lookbackHours: 96)
        guard case .event(let high) = broken.highBreakout,
              case .event(let low) = broken.lowBreakdown else { return XCTFail("Expected both 96h breaks") }
        XCTAssertEqual(high.priorAgeHours, 96)
        XCTAssertEqual(high.priorPrice, 150)
        XCTAssertEqual(low.priorPrice, 60)
        XCTAssertTrue(high.live)
        XCTAssertTrue(low.live)
    }

    func test96HourSearchNeedsFullHistoryAndUsesTheSame48HourEventWindow() {
        var bars = history()
        XCTAssertEqual(recentExtremesBreaks(bars, hour, listedAt: hour - 95 * hourMS, lookbackHours: 96).highBreakout, .insufficientHistory)
        bars.removeValue(forKey: hour - 80 * hourMS)
        XCTAssertEqual(recentExtremesBreaks(bars, hour, lookbackHours: 96).highBreakout, .loading)
        bars = history()
        bars[hour - 47 * hourMS] = candle(47, high: 130)
        guard case .event(let last) = recentExtremesBreaks(bars, hour, lookbackHours: 96).highBreakout else { return XCTFail("Expected last-hour event") }
        XCTAssertEqual(last.hoursAgo, 47)
        bars = history()
        bars[hour - 48 * hourMS] = candle(48, high: 130)
        XCTAssertEqual(recentExtremesBreaks(bars, hour, lookbackHours: 96).highBreakout, .none)
    }

    @MainActor
    func testFilterPreferencesPersistAndInvalidateUnchangedSnapshots() async throws {
        let suite = "MarketFilterTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("radar.sqlite3")
        let radar = try Radar(defaults: defaults, storeURL: url)
        let initial = radar.snapshot(rocPeriod: 9, marocPeriod: 9)
        let revision = try XCTUnwrap(initial["revision"] as? Int)
        let config = "{\"version\":1,\"match\":\"all\",\"rules\":[{\"id\":\"roc-1\",\"field\":\"roc\",\"operator\":\"abs-gte\",\"value\":\"2\",\"upper\":\"\"}]}"
        XCTAssertTrue(try radar.setMarketFiltersJSON(config))
        let changed = radar.snapshot(rocPeriod: 9, marocPeriod: 9, sinceRevision: revision)
        XCTAssertNil(changed["unchanged"])
        XCTAssertEqual(changed["marketFiltersJSON"] as? String, config)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(changed))
        XCTAssertEqual(try Radar(defaults: defaults, storeURL: url).marketFiltersJSON, config)
        XCTAssertEqual(radar.snapshot(rocPeriod: 0, marocPeriod: 9)["marketFiltersJSON"] as? String, config)
        for invalid in ["broken", "null", "[]", "{\"version\":2,\"match\":\"all\",\"rules\":[]}", "{\"version\":1,\"match\":\"unknown\",\"rules\":[]}", "{\"version\":1,\"match\":\"all\",\"rules\":[{}]}"] {
            XCTAssertFalse(try radar.setMarketFiltersJSON(invalid))
            XCTAssertEqual(radar.marketFiltersJSON, config)
        }
        let cleared = "{\"version\":1,\"match\":\"all\",\"rules\":[]}"
        XCTAssertTrue(try radar.setMarketFiltersJSON(cleared))
        XCTAssertEqual(try Radar(defaults: defaults, storeURL: url).marketFiltersJSON, cleared)
        defaults.set("broken", forKey: "marketFiltersJSON")
        XCTAssertEqual(try Radar(defaults: defaults, storeURL: url).marketFiltersJSON, cleared)
    }
}
