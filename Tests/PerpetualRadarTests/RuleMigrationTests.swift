import XCTest
@testable import PerpetualRadar

final class RuleMigrationTests: XCTestCase {
    private let legacy = #"{"version":1,"match":"any","rules":[{"id":"long","field":"roc","operator":"positive","value":"","upper":""},{"id":"short","field":"roc","operator":"negative","value":"","upper":""}]}"#
    func testMigrationPreservesSpreadBoundaryAndMakesFormerGatesVisible() throws {
        let empty = #"{"version":1,"match":"all","rules":[]}"#
        let config = try FilterConfigV2.migrate(empty, turnover: 10_000_000, spread: 0.15, ageMonths: 6)
        let compiled = try FilterCompiler.compile(config), hour = Int64(10_000) * hourMS
        XCTAssertTrue(compiled.formula.contains("1e-10"))
        let roundedBoundary = try XCTUnwrap(spreadPercent(["bidPx": "99.925", "askPx": "100.075"]))
        for spread in [roundedBoundary, 0.15 + 5e-11, 0.15 + 2e-10, nil] as [Double?] {
            let context = FilterMarketData(id: "BTC-USDT-SWAP", hour: hour, now: hour + 1, listedAt: 1, candles: [:], stats: [:], quotes: [hour: .init(turnover: 10_000_000, spread: spread, timestamp: hour + 1)])
            XCTAssertEqual(FilterEvaluator(market: context, filter: compiled).evaluate().result == .yes, passesSpreadFilter(spread, enabled: true, maximum: 0.15))
        }
        let cleared = try FilterCompiler.compile(FilterConfigV2())
        let missing = FilterMarketData(id: "USDC-USDT-SWAP", hour: hour, now: hour, listedAt: nil, candles: [:], stats: [:], quotes: [:])
        XCTAssertEqual(FilterEvaluator(market: missing, filter: cleared).evaluate().result, .yes)
    }
    @MainActor
    func testTransactionMigratesAppliedAndCombinationsPreservingIdentityOrderAndSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RuleMigration-\(UUID())"), url = directory.appendingPathComponent("radar.sqlite3")
        let suite = "RuleMigration-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        defaults.set(30_000_000, forKey: "minimum24hTurnoverUSDT")
        defaults.set(false, forKey: "spreadFilterEnabled")
        let db = try Store(url: url)
        try db.setPreference(legacy, forKey: "marketFiltersJSON")
        let second = try db.saveMarketFilterCombination(name: "Zulu", filtersJSON: legacy), first = try db.saveMarketFilterCombination(name: "Alpha", filtersJSON: legacy)
        try db.setPreference(second.id, forKey: "selectedMarketFilterCombinationID")
        let radar = try Radar(defaults: defaults, storeURL: url)
        XCTAssertEqual(radar.selectedMarketFilterCombinationID, second.id)
        XCTAssertEqual(radar.marketFilterCombinations.map(\.id), [first.id, second.id])
        let config = try FilterConfigV2.decode(radar.marketFiltersV2JSON)
        XCTAssertEqual(config.root.kind, "all")
        XCTAssertEqual(config.root.children[0].children.map(\.left), ["turnover", "ListingAgeMonths", "Symbol"])
        XCTAssertEqual(config.root.children[0].children[0].right, "30")
        XCTAssertEqual(config.root.children[1].kind, "any")
        XCTAssertEqual(config.root.children[1].children.map(\.id), ["long", "short"])
        XCTAssertTrue(radar.marketFilterCombinations.allSatisfy { $0.filtersV2JSON != nil })
        let reopened = try Radar(defaults: defaults, storeURL: url)
        XCTAssertEqual(reopened.marketFiltersV2JSON, radar.marketFiltersV2JSON)
        XCTAssertEqual(reopened.marketFilterCombinations.map(\.filtersV2JSON), radar.marketFilterCombinations.map(\.filtersV2JSON))
        XCTAssertTrue(try reopened.setMarketFiltersJSON(FilterConfigV2().json))
        XCTAssertTrue(try FilterConfigV2.decode(reopened.marketFiltersV2JSON).root.children.isEmpty)
        XCTAssertTrue(try Radar(defaults: defaults, storeURL: url).marketFilterCombinations.allSatisfy { $0.filtersV2JSON != nil })
    }

    @MainActor
    func testMigrationAndV2SaveFailuresRollbackBothConfigurationsAndSelection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RuleMigration-\(UUID())"), url = directory.appendingPathComponent("radar.sqlite3")
        let suite = "RuleMigration-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let db = try Store(url: url)
        let original = try db.saveMarketFilterCombination(name: "Existing", filtersJSON: legacy)
        try db.setPreference(legacy, forKey: "marketFiltersJSON")
        try db.execute("CREATE TRIGGER reject_v2 BEFORE UPDATE OF filters_v2_json ON market_filter_combinations BEGIN SELECT RAISE(ABORT,'migration failed'); END")
        XCTAssertThrowsError(try Radar(defaults: defaults, storeURL: url))
        XCTAssertNil(try db.preference(forKey: "marketFiltersV2JSON"))
        XCTAssertNil(try db.marketFilterCombinations()[0].filtersV2JSON)
        XCTAssertEqual(try db.preference(forKey: "marketFiltersJSON"), legacy)
        try db.execute("DROP TRIGGER reject_v2")
        let radar = try Radar(defaults: defaults, storeURL: url), applied = radar.marketFiltersV2JSON
        let changed = try FilterCompiler.compile(source: "Close > 200").config.json
        try db.execute("CREATE TRIGGER reject_save BEFORE UPDATE ON preferences WHEN NEW.key='marketFiltersV2JSON' BEGIN SELECT RAISE(ABORT,'save failed'); END")
        XCTAssertThrowsError(try radar.setMarketFiltersJSON(changed))
        XCTAssertEqual(radar.marketFiltersV2JSON, applied)
        XCTAssertEqual(radar.marketFiltersJSON, legacy)
        XCTAssertEqual(try db.preference(forKey: "marketFiltersJSON"), legacy)
        try db.execute("DROP TRIGGER reject_save")
        try db.execute("CREATE TRIGGER reject_selection BEFORE INSERT ON preferences WHEN NEW.key='selectedMarketFilterCombinationID' BEGIN SELECT RAISE(ABORT,'selection failed'); END")
        try db.execute("DELETE FROM preferences WHERE key='selectedMarketFilterCombinationID'")
        XCTAssertThrowsError(try radar.saveMarketFilterCombination(name: "Existing", filtersJSON: changed))
        XCTAssertEqual(try db.marketFilterCombinations()[0].id, original.id)
        XCTAssertEqual(try db.marketFilterCombinations()[0].filtersJSON, legacy)
        XCTAssertEqual(radar.marketFiltersV2JSON, applied)
        try db.execute("DROP TRIGGER reject_selection")
        XCTAssertTrue(try radar.saveMarketFilterCombination(name: "Existing", filtersJSON: changed))
        XCTAssertEqual(radar.marketFilterCombinations[0].id, original.id)
        XCTAssertEqual(radar.selectedMarketFilterCombinationID, original.id)
    }
}
