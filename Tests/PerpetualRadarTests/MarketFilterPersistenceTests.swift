import XCTest
@testable import PerpetualRadar

final class MarketFilterPersistenceTests: XCTestCase {
    private let configuration = #"{"version":1,"match":"any","rules":[{"id":"rsi-range","field":"rsi6","operator":"between","value":"30","upper":"70"},{"id":"momentum","field":"roc","operator":"abs-gte","value":"2.5","upper":""}]}"#
    private let emptyConfiguration = #"{"version":1,"match":"all","rules":[]}"#
    private let key = "marketFiltersJSON"

    @MainActor
    private func withDatabase(_ body: (URL, UserDefaults, String) throws -> Void) throws {
        let suite = "MarketFilterPersistenceTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try body(directory.appendingPathComponent("radar.sqlite3"), defaults, suite)
    }

    @MainActor
    func testAppliedFiltersSurviveClosingTheDatabaseAndRemovingPreferences() async throws {
        try withDatabase { url, defaults, suite in
            var radar: Radar? = try Radar(defaults: defaults, storeURL: url)
            XCTAssertTrue(try XCTUnwrap(radar).setMarketFiltersJSON(configuration))
            XCTAssertNil(defaults.object(forKey: key))
            radar = nil
            defaults.removePersistentDomain(forName: suite)

            let reopened = try Radar(defaults: XCTUnwrap(UserDefaults(suiteName: suite)), storeURL: url)
            XCTAssertEqual(reopened.marketFiltersJSON, configuration)
            XCTAssertEqual(reopened.snapshot(rocPeriod: 9, marocPeriod: 9)[key] as? String, configuration)
            XCTAssertEqual(try Store(url: url).preference(forKey: key), configuration)
        }
    }

    @MainActor
    func testLegacyFiltersMigrateOnceAndClearingDoesNotRestoreThem() async throws {
        try withDatabase { url, defaults, _ in
            defaults.set(configuration, forKey: key)
            let radar = try Radar(defaults: defaults, storeURL: url)
            XCTAssertEqual(radar.marketFiltersJSON, configuration)
            XCTAssertEqual(try Store(url: url).preference(forKey: key), configuration)
            XCTAssertNil(defaults.object(forKey: key))

            XCTAssertTrue(try radar.setMarketFiltersJSON(emptyConfiguration))
            defaults.set(configuration, forKey: key)
            XCTAssertEqual(try Radar(defaults: defaults, storeURL: url).marketFiltersJSON, emptyConfiguration)
            XCTAssertEqual(try Store(url: url).preference(forKey: key), emptyConfiguration)
            XCTAssertNil(defaults.object(forKey: key))
        }
    }

    @MainActor
    func testInvalidStoredConfigurationIsResetWithoutRestoringStalePreferences() async throws {
        try withDatabase { url, defaults, _ in
            let store = try Store(url: url)
            try store.setPreference("broken", forKey: key)
            defaults.set(configuration, forKey: key)

            XCTAssertEqual(try Radar(defaults: defaults, storeURL: url).marketFiltersJSON, emptyConfiguration)
            XCTAssertEqual(try store.preference(forKey: key), emptyConfiguration)
            XCTAssertNil(defaults.object(forKey: key))
            XCTAssertEqual(try Radar(defaults: defaults, storeURL: url).marketFiltersJSON, emptyConfiguration)
        }
    }

    @MainActor
    func testInvalidLegacyConfigurationStartsWithPersistedEmptyFilters() async throws {
        try withDatabase { url, defaults, _ in
            defaults.set("broken", forKey: key)
            XCTAssertEqual(try Radar(defaults: defaults, storeURL: url).marketFiltersJSON, emptyConfiguration)
            XCTAssertEqual(try Store(url: url).preference(forKey: key), emptyConfiguration)
            XCTAssertNil(defaults.object(forKey: key))
        }
    }

    @MainActor
    func testWriteFailureKeepsAppliedFiltersAndRevisionUntilRetrySucceeds() async throws {
        try withDatabase { url, defaults, _ in
            let radar = try Radar(defaults: defaults, storeURL: url)
            XCTAssertTrue(try radar.setMarketFiltersJSON(configuration))
            let revision = try XCTUnwrap(radar.snapshot(rocPeriod: 9, marocPeriod: 9)["revision"] as? Int)
            let blocker = try Store(url: url)
            try blocker.execute("BEGIN IMMEDIATE")
            defer { try? blocker.execute("ROLLBACK") }

            XCTAssertThrowsError(try radar.setMarketFiltersJSON(emptyConfiguration))
            XCTAssertEqual(radar.marketFiltersJSON, configuration)
            XCTAssertEqual(try blocker.preference(forKey: key), configuration)
            XCTAssertEqual(radar.snapshot(rocPeriod: 9, marocPeriod: 9, sinceRevision: revision)["unchanged"] as? Bool, true)
            XCTAssertNil(defaults.object(forKey: key))

            try blocker.execute("ROLLBACK")
            XCTAssertTrue(try radar.setMarketFiltersJSON(emptyConfiguration))
            let changed = radar.snapshot(rocPeriod: 9, marocPeriod: 9, sinceRevision: revision)
            XCTAssertNil(changed["unchanged"])
            XCTAssertEqual(changed[key] as? String, emptyConfiguration)
            XCTAssertEqual(try Radar(defaults: defaults, storeURL: url).marketFiltersJSON, emptyConfiguration)
        }
    }

    @MainActor
    func testFailedMigrationRetainsLegacyFiltersForRetry() async throws {
        try withDatabase { url, defaults, _ in
            defaults.set(configuration, forKey: key)
            let blocker = try Store(url: url)
            try blocker.execute("BEGIN IMMEDIATE")
            defer { try? blocker.execute("ROLLBACK") }

            XCTAssertThrowsError(try Radar(defaults: defaults, storeURL: url))
            XCTAssertEqual(defaults.string(forKey: key), configuration)
            XCTAssertNil(try blocker.preference(forKey: key))

            try blocker.execute("ROLLBACK")
            XCTAssertEqual(try Radar(defaults: defaults, storeURL: url).marketFiltersJSON, configuration)
            XCTAssertEqual(try blocker.preference(forKey: key), configuration)
            XCTAssertNil(defaults.object(forKey: key))
        }
    }
}
