import XCTest
@testable import PerpetualRadar

final class MarketFilterCombinationTests: XCTestCase {
    private let long = #"{"version":1,"match":"all","rules":[{"id":"long","field":"roc","operator":"positive","value":"","upper":""}]}"#
    private let short = #"{"version":1,"match":"any","rules":[{"id":"short","field":"roc","operator":"negative","value":"","upper":""},{"id":"rsi","field":"rsi6","operator":"between","value":"20","upper":"40"}]}"#
    private let selectionKey = "selectedMarketFilterCombinationID"

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
    func testWriteFailuresPreserveSavedCombinationsAndReadersAllowRetry() async throws {
        try withRadar { url, defaults, radar in
            XCTAssertTrue(try radar.saveMarketFilterCombination(name: "Long setup", filtersJSON: long))
            let original = radar.marketFilterCombinations
            let id = try XCTUnwrap(original.first?.id)
            let revision = try XCTUnwrap(radar.snapshot(rocPeriod: 9, marocPeriod: 9)["revision"] as? Int)
            let blocker = try Store(url: url)
            try blocker.execute("BEGIN IMMEDIATE")
            defer { try? blocker.execute("ROLLBACK") }
            XCTAssertThrowsError(try radar.saveMarketFilterCombination(name: "Short setup", filtersJSON: short))
            XCTAssertThrowsError(try radar.deleteMarketFilterCombination(id))
            XCTAssertEqual(radar.marketFilterCombinations, original)
            XCTAssertEqual(radar.selectedMarketFilterCombinationID, id)
            XCTAssertEqual(radar.snapshot(rocPeriod: 9, marocPeriod: 9, sinceRevision: revision)["unchanged"] as? Bool, true)
            try blocker.execute("ROLLBACK")
            XCTAssertEqual(try Radar(defaults: defaults, storeURL: url).marketFilterCombinations, original)
            XCTAssertEqual(try Radar(defaults: defaults, storeURL: url).selectedMarketFilterCombinationID, id)

            // WAL readers keep their snapshot without blocking a successful retry.
            try blocker.execute("BEGIN")
            XCTAssertEqual(try blocker.marketFilterCombinations(), original)
            XCTAssertTrue(try radar.saveMarketFilterCombination(name: "Short setup", filtersJSON: short))
            XCTAssertTrue(try radar.deleteMarketFilterCombination(id))
            XCTAssertEqual(try blocker.marketFilterCombinations(), original)
            try blocker.execute("COMMIT")
            XCTAssertEqual(try Radar(defaults: defaults, storeURL: url).marketFilterCombinations.map(\.name), ["Short setup"])
        }
    }

    @MainActor
    func testSelectedCombinationPersistsIndependentlyOfAppliedFiltersAndInvalidSelections() async throws {
        try withRadar { url, defaults, radar in
            XCTAssertTrue(try radar.setMarketFiltersJSON(short))
            XCTAssertTrue(try radar.saveMarketFilterCombination(name: "Long setup", filtersJSON: long))
            let longID = radar.selectedMarketFilterCombinationID
            XCTAssertTrue(try radar.saveMarketFilterCombination(name: "Short setup", filtersJSON: short))
            XCTAssertNotEqual(radar.selectedMarketFilterCombinationID, longID)
            let revision = try XCTUnwrap(radar.snapshot(rocPeriod: 9, marocPeriod: 9)["revision"] as? Int)
            XCTAssertTrue(try radar.setSelectedMarketFilterCombinationID(longID))
            let snapshot = radar.snapshot(rocPeriod: 9, marocPeriod: 9, sinceRevision: revision)
            XCTAssertNil(snapshot["unchanged"])
            XCTAssertEqual(snapshot[selectionKey] as? String, longID)
            XCTAssertEqual(radar.snapshot(rocPeriod: 0, marocPeriod: 9)[selectionKey] as? String, longID)
            XCTAssertEqual(radar.marketFiltersJSON, short)
            XCTAssertEqual(try Store(url: url).preference(forKey: selectionKey), longID)
            let reopened = try Radar(defaults: defaults, storeURL: url)
            XCTAssertEqual(reopened.selectedMarketFilterCombinationID, longID)
            XCTAssertEqual(reopened.marketFiltersJSON, short)

            let selectedRevision = try XCTUnwrap(snapshot["revision"] as? Int)
            XCTAssertTrue(try radar.setSelectedMarketFilterCombinationID(longID))
            XCTAssertFalse(try radar.setSelectedMarketFilterCombinationID("missing"))
            XCTAssertEqual(radar.snapshot(rocPeriod: 9, marocPeriod: 9, sinceRevision: selectedRevision)["unchanged"] as? Bool, true)
            XCTAssertEqual(try Radar(defaults: defaults, storeURL: url).selectedMarketFilterCombinationID, longID)
        }
    }

    @MainActor
    func testSaveAsSelectsNewCombinationAndDeletingOnlyClearsTheSelectedEntry() async throws {
        try withRadar { url, defaults, radar in
            XCTAssertTrue(try radar.setMarketFiltersJSON(short))
            XCTAssertTrue(try radar.saveMarketFilterCombination(name: "Long setup", filtersJSON: long))
            let longID = radar.selectedMarketFilterCombinationID
            XCTAssertTrue(try radar.saveMarketFilterCombination(name: "Short setup", filtersJSON: short))
            let shortID = radar.selectedMarketFilterCombinationID
            XCTAssertTrue(try radar.deleteMarketFilterCombination(longID))
            XCTAssertEqual(radar.selectedMarketFilterCombinationID, shortID)
            XCTAssertEqual(try Radar(defaults: defaults, storeURL: url).selectedMarketFilterCombinationID, shortID)
            XCTAssertTrue(try radar.saveMarketFilterCombination(name: "short SETUP", filtersJSON: short))
            XCTAssertEqual(radar.selectedMarketFilterCombinationID, shortID)
            XCTAssertTrue(try radar.saveMarketFilterCombination(name: "Another setup", filtersJSON: long))
            let anotherID = radar.selectedMarketFilterCombinationID
            XCTAssertNotEqual(anotherID, shortID)
            XCTAssertEqual(try Radar(defaults: defaults, storeURL: url).selectedMarketFilterCombinationID, anotherID)
            XCTAssertTrue(try radar.deleteMarketFilterCombination(anotherID))
            XCTAssertEqual(radar.selectedMarketFilterCombinationID, "")
            XCTAssertEqual(try Store(url: url).preference(forKey: selectionKey), "")
            let reopened = try Radar(defaults: defaults, storeURL: url)
            XCTAssertEqual(reopened.selectedMarketFilterCombinationID, "")
            XCTAssertEqual(reopened.marketFilterCombinations.map(\.id), [shortID])
            XCTAssertEqual(reopened.marketFiltersJSON, short)
        }
    }

    @MainActor
    func testSelectionWriteFailureRollsBackCombinationSaveAndDeletionUntilRetry() async throws {
        try withRadar { url, defaults, radar in
            XCTAssertTrue(try radar.saveMarketFilterCombination(name: "Long setup", filtersJSON: long))
            let id = radar.selectedMarketFilterCombinationID
            let original = radar.marketFilterCombinations
            let revision = try XCTUnwrap(radar.snapshot(rocPeriod: 9, marocPeriod: 9)["revision"] as? Int)
            let blocker = try Store(url: url)
            try blocker.execute("CREATE TRIGGER reject_selection BEFORE UPDATE ON preferences WHEN NEW.key='selectedMarketFilterCombinationID' BEGIN SELECT RAISE(ABORT,'Test selection write failure'); END")
            XCTAssertThrowsError(try radar.saveMarketFilterCombination(name: "Short setup", filtersJSON: short))
            XCTAssertThrowsError(try radar.saveMarketFilterCombination(name: "Long setup", filtersJSON: short))
            XCTAssertThrowsError(try radar.deleteMarketFilterCombination(id))
            XCTAssertThrowsError(try radar.setSelectedMarketFilterCombinationID(""))
            XCTAssertEqual(radar.marketFilterCombinations, original)
            XCTAssertEqual(radar.selectedMarketFilterCombinationID, id)
            XCTAssertEqual(radar.snapshot(rocPeriod: 9, marocPeriod: 9, sinceRevision: revision)["unchanged"] as? Bool, true)
            let reopened = try Radar(defaults: defaults, storeURL: url)
            XCTAssertEqual(reopened.marketFilterCombinations, original)
            XCTAssertEqual(reopened.selectedMarketFilterCombinationID, id)
            try blocker.execute("DROP TRIGGER reject_selection")
            XCTAssertTrue(try radar.saveMarketFilterCombination(name: "Short setup", filtersJSON: short))
            XCTAssertNotEqual(radar.selectedMarketFilterCombinationID, id)
            XCTAssertTrue(try radar.setSelectedMarketFilterCombinationID(id))
            XCTAssertTrue(try radar.deleteMarketFilterCombination(id))
            XCTAssertEqual(try Radar(defaults: defaults, storeURL: url).selectedMarketFilterCombinationID, "")
        }
    }

    @MainActor
    func testOlderDatabasesRecoverAppliedCombinationAndClearDanglingSelections() async throws {
        try withRadar { url, defaults, radar in
            XCTAssertTrue(try radar.setMarketFiltersJSON(long))
            let store = try Store(url: url)
            let combination = try store.saveMarketFilterCombination(name: "Long setup", filtersJSON: long)
            XCTAssertNil(try store.preference(forKey: selectionKey))
            XCTAssertEqual(try Radar(defaults: defaults, storeURL: url).selectedMarketFilterCombinationID, combination.id)
            XCTAssertEqual(try store.preference(forKey: selectionKey), combination.id)
            try store.setPreference("missing", forKey: selectionKey)
            let reopened = try Radar(defaults: defaults, storeURL: url)
            XCTAssertEqual(reopened.selectedMarketFilterCombinationID, "")
            XCTAssertEqual(reopened.marketFiltersJSON, long)
            XCTAssertEqual(try store.preference(forKey: selectionKey), "")
            XCTAssertEqual(try Radar(defaults: defaults, storeURL: url).selectedMarketFilterCombinationID, "")
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
