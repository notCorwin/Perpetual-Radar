import XCTest
@testable import PerpetualRadar

final class MarketFilterCombinationTests: XCTestCase {
    private let long = #"{"version":1,"match":"all","rules":[{"id":"long","field":"roc","operator":"positive","value":"","upper":""}]}"#
    private let short = #"{"version":1,"match":"any","rules":[{"id":"short","field":"roc","operator":"negative","value":"","upper":""},{"id":"rsi","field":"rsi6","operator":"between","value":"20","upper":"40"}]}"#

    @MainActor
    private func withRadar(_ body: (URL, UserDefaults, Radar) throws -> Void) throws {
        let suite = "MarketFilterCombinationTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("radar.sqlite3")
        try body(url, defaults, Radar(defaults: defaults, storeURL: url))
    }

    @MainActor
    func testNamedCombinationsPersistIndependentlyOfTheAppliedConfiguration() async throws {
        try withRadar { url, defaults, radar in
            XCTAssertTrue(try radar.setMarketFiltersJSON(long))
            let revision = try XCTUnwrap(radar.snapshot(rocPeriod: 9, marocPeriod: 9)["revision"] as? Int)
            XCTAssertTrue(try radar.saveMarketFilterCombination(name: "Short setup", filtersJSON: short))
            XCTAssertTrue(try radar.saveMarketFilterCombination(name: "Long setup", filtersJSON: long))
            XCTAssertEqual(radar.marketFiltersJSON, long)
            let changed = radar.snapshot(rocPeriod: 9, marocPeriod: 9, sinceRevision: revision)
            XCTAssertNil(changed["unchanged"])
            XCTAssertEqual((changed["marketFilterCombinations"] as? [[String: String]])?.count, 2)
            XCTAssertTrue(JSONSerialization.isValidJSONObject(changed))
            XCTAssertEqual((radar.snapshot(rocPeriod: 0, marocPeriod: 9)["marketFilterCombinations"] as? [[String: String]])?.count, 2)

            let reopened = try Radar(defaults: defaults, storeURL: url)
            XCTAssertEqual(reopened.marketFilterCombinations, radar.marketFilterCombinations)
            XCTAssertEqual(reopened.marketFilterCombinations.map(\.name), ["Long setup", "Short setup"])
            XCTAssertEqual(reopened.marketFilterCombinations.map(\.filtersJSON), [long, short])
            XCTAssertEqual(reopened.marketFiltersJSON, long)
        }
    }

    @MainActor
    func testSavingAnExistingNameUpdatesItsConfigurationAndPreservesItsIdentity() async throws {
        try withRadar { url, defaults, radar in
            XCTAssertTrue(try radar.saveMarketFilterCombination(name: "  Long setup  ", filtersJSON: long))
            let original = try XCTUnwrap(radar.marketFilterCombinations.first)
            XCTAssertEqual(original.name, "Long setup")
            XCTAssertTrue(try radar.saveMarketFilterCombination(name: "long SETUP", filtersJSON: short))
            XCTAssertEqual(radar.marketFilterCombinations.count, 1)
            XCTAssertEqual(radar.marketFilterCombinations.first?.id, original.id)
            XCTAssertEqual(radar.marketFilterCombinations.first?.name, "long SETUP")
            XCTAssertEqual(radar.marketFilterCombinations.first?.filtersJSON, short)
            XCTAssertTrue(try radar.saveMarketFilterCombination(name: "Élan", filtersJSON: long))
            let accentedID = try XCTUnwrap(radar.marketFilterCombinations.first { $0.name == "Élan" }?.id)
            XCTAssertTrue(try radar.saveMarketFilterCombination(name: "élan", filtersJSON: short))
            XCTAssertEqual(radar.marketFilterCombinations.count, 2)
            XCTAssertEqual(radar.marketFilterCombinations.first { $0.name == "élan" }?.id, accentedID)
            XCTAssertEqual(try Radar(defaults: defaults, storeURL: url).marketFilterCombinations, radar.marketFilterCombinations)
        }
    }

    @MainActor
    func testDeletingACombinationPersistsWithoutClearingTheAppliedFilters() async throws {
        try withRadar { url, defaults, radar in
            XCTAssertTrue(try radar.setMarketFiltersJSON(long))
            XCTAssertTrue(try radar.saveMarketFilterCombination(name: "Long setup", filtersJSON: long))
            let id = try XCTUnwrap(radar.marketFilterCombinations.first?.id)
            let revision = try XCTUnwrap(radar.snapshot(rocPeriod: 9, marocPeriod: 9)["revision"] as? Int)
            XCTAssertTrue(try radar.deleteMarketFilterCombination(id))
            XCTAssertNil(radar.snapshot(rocPeriod: 9, marocPeriod: 9, sinceRevision: revision)["unchanged"])
            let reopened = try Radar(defaults: defaults, storeURL: url)
            XCTAssertTrue(reopened.marketFilterCombinations.isEmpty)
            XCTAssertEqual(reopened.marketFiltersJSON, long)
            let deletedRevision = try XCTUnwrap(radar.snapshot(rocPeriod: 9, marocPeriod: 9)["revision"] as? Int)
            XCTAssertFalse(try radar.deleteMarketFilterCombination(id))
            XCTAssertEqual(radar.snapshot(rocPeriod: 9, marocPeriod: 9, sinceRevision: deletedRevision)["unchanged"] as? Bool, true)
        }
    }

    @MainActor
    func testInvalidNamesAndConfigurationsDoNotOverwriteSavedCombinations() async throws {
        try withRadar { url, _, radar in
            XCTAssertTrue(try radar.saveMarketFilterCombination(name: "Long setup", filtersJSON: long))
            let original = radar.marketFilterCombinations
            let revision = try XCTUnwrap(radar.snapshot(rocPeriod: 9, marocPeriod: 9)["revision"] as? Int)
            for name in ["", " \n\t", String(repeating: "x", count: 81)] {
                XCTAssertFalse(try radar.saveMarketFilterCombination(name: name, filtersJSON: short))
            }
            for value in ["broken", "null", #"{"version":2,"match":"all","rules":[]}"#] {
                XCTAssertFalse(try radar.saveMarketFilterCombination(name: "Long setup", filtersJSON: value))
            }
            XCTAssertEqual(radar.marketFilterCombinations, original)
            XCTAssertEqual(try Store(url: url).marketFilterCombinations(), original)
            XCTAssertEqual(radar.snapshot(rocPeriod: 9, marocPeriod: 9, sinceRevision: revision)["unchanged"] as? Bool, true)
        }
    }

    @MainActor
    func testWriteAndCommitFailuresPreserveSavedCombinationsUntilRetry() async throws {
        try withRadar { url, defaults, radar in
            XCTAssertTrue(try radar.saveMarketFilterCombination(name: "Long setup", filtersJSON: long))
            let original = radar.marketFilterCombinations
            let id = try XCTUnwrap(original.first?.id)
            let revision = try XCTUnwrap(radar.snapshot(rocPeriod: 9, marocPeriod: 9)["revision"] as? Int)
            let blocker = try Store(url: url)
            for transaction in ["BEGIN IMMEDIATE", "BEGIN"] {
                try blocker.execute(transaction)
                _ = try blocker.marketFilterCombinations()
                XCTAssertThrowsError(try radar.saveMarketFilterCombination(name: "Short setup", filtersJSON: short))
                XCTAssertThrowsError(try radar.deleteMarketFilterCombination(id))
                XCTAssertEqual(radar.marketFilterCombinations, original)
                XCTAssertEqual(radar.snapshot(rocPeriod: 9, marocPeriod: 9, sinceRevision: revision)["unchanged"] as? Bool, true)
                try blocker.execute("ROLLBACK")
                XCTAssertEqual(try Radar(defaults: defaults, storeURL: url).marketFilterCombinations, original)
            }
            XCTAssertTrue(try radar.saveMarketFilterCombination(name: "Short setup", filtersJSON: short))
            XCTAssertTrue(try radar.deleteMarketFilterCombination(id))
            XCTAssertEqual(try Radar(defaults: defaults, storeURL: url).marketFilterCombinations.map(\.name), ["Short setup"])
        }
    }

    @MainActor
    func testMalformedStoredCombinationsAreSkippedOnStartup() async throws {
        try withRadar { url, defaults, radar in
            XCTAssertTrue(try radar.saveMarketFilterCombination(name: "Long setup", filtersJSON: long))
            let store = try Store(url: url)
            _ = try store.saveMarketFilterCombination(name: "Broken setup", filtersJSON: "broken")
            XCTAssertEqual(try Radar(defaults: defaults, storeURL: url).marketFilterCombinations, radar.marketFilterCombinations)
        }
    }
}
