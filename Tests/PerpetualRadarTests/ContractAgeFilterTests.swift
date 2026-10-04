import XCTest
@testable import PerpetualRadar

final class ContractAgeFilterTests: XCTestCase {
    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)!
    }

    private func listedAt(_ value: String) -> Int64 {
        Int64((date(value).timeIntervalSince1970 * 1000).rounded())
    }

    func testSixMonthBoundaryIsInclusiveAndUsesTheListingTimeOfDay() {
        let listing = listedAt("2026-04-04T12:34:56.789Z")
        let anniversary = date("2026-10-04T12:34:56.789Z")
        XCTAssertFalse(passesContractAgeFilter(listing, enabled: true, minimumMonths: 6,
                                              now: anniversary.addingTimeInterval(-0.001)))
        XCTAssertTrue(passesContractAgeFilter(listing, enabled: true, minimumMonths: 6, now: anniversary))
        XCTAssertTrue(passesContractAgeFilter(listing - 1, enabled: true, minimumMonths: 6, now: anniversary))
        XCTAssertFalse(passesContractAgeFilter(listing + 1, enabled: true, minimumMonths: 6, now: anniversary))
    }

    func testCalendarMonthsHandleMonthEndsLeapYearsAndYearRollover() {
        for (listing, months, anniversary) in [
            ("2023-08-31T08:30:00.000Z", 6, "2024-02-29T08:30:00.000Z"),
            ("2024-08-31T08:30:00.000Z", 6, "2025-02-28T08:30:00.000Z"),
            ("2024-02-29T08:30:00.000Z", 12, "2025-02-28T08:30:00.000Z"),
            ("2026-01-31T08:30:00.000Z", 1, "2026-02-28T08:30:00.000Z"),
            ("2025-12-04T08:30:00.000Z", 6, "2026-06-04T08:30:00.000Z"),
        ] {
            let boundary = date(anniversary)
            XCTAssertFalse(passesContractAgeFilter(listedAt(listing), enabled: true, minimumMonths: months,
                                                  now: boundary.addingTimeInterval(-0.001)), listing)
            XCTAssertTrue(passesContractAgeFilter(listedAt(listing), enabled: true, minimumMonths: months,
                                                 now: boundary), listing)
        }
    }

    func testMonthsAreNotApproximatedAs180Days() {
        let now = date("2026-10-04T00:00:00.000Z")
        let listing180DaysAgo = Int64(now.addingTimeInterval(-180 * 24 * 60 * 60).timeIntervalSince1970 * 1000)
        XCTAssertFalse(passesContractAgeFilter(listing180DaysAgo, enabled: true, minimumMonths: 6, now: now))
        XCTAssertTrue(passesContractAgeFilter(listedAt("2026-04-04T00:00:00.000Z"), enabled: true,
                                             minimumMonths: 6, now: now))
    }

    func testDisabledFilterIncludesNewAndUnknownListings() {
        let now = date("2026-10-04T00:00:00.000Z")
        let young = listedAt("2026-09-04T00:00:00.000Z")
        for listing in [nil, 0, -1, young, young + 100 * 24 * hourMS] as [Int64?] {
            XCTAssertFalse(passesContractAgeFilter(listing, enabled: true, minimumMonths: 6, now: now))
            XCTAssertTrue(passesContractAgeFilter(listing, enabled: false, minimumMonths: 6, now: now))
        }
        XCTAssertTrue(passesContractAgeFilter(young, enabled: true, minimumMonths: 1, now: now))
        XCTAssertFalse(passesContractAgeFilter(young, enabled: true, minimumMonths: 2, now: now))
    }

    @MainActor
    func testDefaultSettingsPersistAndChangesInvalidateSnapshots() async throws {
        let suite = "ContractAgeFilterTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let storeURL = directory.appendingPathComponent("radar.sqlite3")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let radar = try Radar(defaults: defaults, storeURL: storeURL)
        XCTAssertTrue(radar.contractAgeFilterEnabled)
        XCTAssertEqual(radar.minimumContractAgeMonths, 6)
        let initial = radar.snapshot(rocPeriod: 9, marocPeriod: 9)
        let initialRevision = try XCTUnwrap(initial["revision"] as? Int)
        XCTAssertEqual(initial["contractAgeFilterEnabled"] as? Bool, true)
        XCTAssertEqual(initial["minimumContractAgeMonths"] as? Int, 6)
        XCTAssertEqual(radar.snapshot(rocPeriod: 9, marocPeriod: 9, sinceRevision: initialRevision)["unchanged"] as? Bool, true)

        radar.setContractAgeFilterEnabled(false)
        let disabled = radar.snapshot(rocPeriod: 9, marocPeriod: 9, sinceRevision: initialRevision)
        XCTAssertNil(disabled["unchanged"])
        XCTAssertEqual(disabled["contractAgeFilterEnabled"] as? Bool, false)
        XCTAssertTrue(radar.setMinimumContractAgeMonths(12))
        let changed = radar.snapshot(rocPeriod: 9, marocPeriod: 9)
        XCTAssertGreaterThan(try XCTUnwrap(changed["revision"] as? Int), initialRevision)
        XCTAssertEqual(changed["minimumContractAgeMonths"] as? Int, 12)

        let reopened = try Radar(defaults: defaults, storeURL: storeURL)
        XCTAssertFalse(reopened.contractAgeFilterEnabled)
        XCTAssertEqual(reopened.minimumContractAgeMonths, 12)
        reopened.setContractAgeFilterEnabled(true)
        XCTAssertTrue(try Radar(defaults: defaults, storeURL: storeURL).contractAgeFilterEnabled)
        let invalidPeriods = reopened.snapshot(rocPeriod: 0, marocPeriod: 9)
        XCTAssertEqual(invalidPeriods["contractAgeFilterEnabled"] as? Bool, true)
        XCTAssertEqual(invalidPeriods["minimumContractAgeMonths"] as? Int, 12)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(changed))
    }

    @MainActor
    func testInvalidAgesDoNotOverwritePreferencesOrChangeRevision() async throws {
        let suite = "ContractAgeFilterTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let storeURL = directory.appendingPathComponent("radar.sqlite3")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let radar = try Radar(defaults: defaults, storeURL: storeURL)
        XCTAssertTrue(radar.setMinimumContractAgeMonths(3))
        let revision = try XCTUnwrap(radar.snapshot(rocPeriod: 9, marocPeriod: 9)["revision"] as? Int)
        for value in [-1, 0, 1201, Int.max] {
            XCTAssertFalse(radar.setMinimumContractAgeMonths(value))
            XCTAssertEqual(radar.minimumContractAgeMonths, 3)
            XCTAssertEqual(defaults.integer(forKey: "minimumContractAgeMonths"), 3)
            XCTAssertEqual(radar.snapshot(rocPeriod: 9, marocPeriod: 9, sinceRevision: revision)["unchanged"] as? Bool, true)
            defaults.set(value, forKey: "minimumContractAgeMonths")
            XCTAssertEqual(try Radar(defaults: defaults, storeURL: storeURL).minimumContractAgeMonths, 6)
            defaults.set(3, forKey: "minimumContractAgeMonths")
        }
        for value in [1, 6, 12, 1200] {
            XCTAssertTrue(radar.setMinimumContractAgeMonths(value))
        }
    }
}
