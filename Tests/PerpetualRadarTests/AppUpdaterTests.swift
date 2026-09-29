import XCTest
@testable import PerpetualRadar

final class AppUpdaterTests: XCTestCase {
    func testManifestUsesOnlyTheExpectedAppAndDigest() throws {
        let revision = String(repeating: "a", count: 40)
        let digest = String(repeating: "b", count: 64)
        let data = try JSONSerialization.data(withJSONObject: [
            "revision": revision,
            "asset_url": "https://github.com/notCorwin/Perpetual-Radar/releases/download/autobuild/Perpetual.Radar.app.tar",
            "digest": "sha256:\(digest)",
            "published_at": "2026-09-27T00:00:00Z",
        ])

        guard case .success(let available) = AppUpdater.parse(data: data, currentRevision: String(repeating: "c", count: 40)) else {
            return XCTFail("Expected an available update")
        }
        XCTAssertEqual(available?.revision, revision)
        XCTAssertEqual(available?.expectedSHA256, digest)
        XCTAssertEqual(available?.publishedAt, Date(timeIntervalSince1970: 1_790_467_200))
        guard case .success(let latest) = AppUpdater.parse(data: data, currentRevision: revision) else {
            return XCTFail("Expected the installed revision to be current")
        }
        XCTAssertNil(latest)

        let missingDigest = try JSONSerialization.data(withJSONObject: [
            "revision": revision,
            "asset_url": "https://github.com/notCorwin/Perpetual-Radar/releases/download/autobuild/Perpetual.Radar.app.tar",
        ])
        guard case .failure(.invalidResponse) = AppUpdater.parse(data: missingDigest, currentRevision: nil) else {
            return XCTFail("Expected an unsigned release to be rejected")
        }
        let wrongURL = try JSONSerialization.data(withJSONObject: [
            "revision": revision,
            "asset_url": "https://example.com/Perpetual.Radar.app.tar",
            "digest": "sha256:\(digest)",
        ])
        guard case .failure(.invalidResponse) = AppUpdater.parse(data: wrongURL, currentRevision: nil) else {
            return XCTFail("Expected an unexpected download location to be rejected")
        }

        let immutableURL = "https://github.com/notCorwin/Perpetual-Radar/releases/download/build-\(revision)-123-1/Perpetual.Radar.app.tar"
        let immutableManifest = try JSONSerialization.data(withJSONObject: [
            "revision": revision,
            "asset_url": "https://github.com/notCorwin/Perpetual-Radar/releases/download/autobuild/Perpetual.Radar.app.tar",
            "immutable_asset_url": immutableURL,
            "digest": "sha256:\(digest)",
        ])
        guard case .success(let immutableUpdate) = AppUpdater.parse(data: immutableManifest, currentRevision: nil) else {
            return XCTFail("Expected a revision-specific update")
        }
        XCTAssertEqual(immutableUpdate?.assetURL.absoluteString, immutableURL)

        let versionedURL = "https://github.com/notCorwin/Perpetual-Radar/releases/download/autobuild/Perpetual.Radar.app.\(revision).123-1.tar"
        let versionedManifest = try JSONSerialization.data(withJSONObject: [
            "revision": revision,
            "asset_url": "https://github.com/notCorwin/Perpetual-Radar/releases/download/autobuild/Perpetual.Radar.app.tar",
            "versioned_asset_url": versionedURL,
            "digest": "sha256:\(digest)",
        ])
        guard case .success(let versionedUpdate) = AppUpdater.parse(data: versionedManifest, currentRevision: nil) else {
            return XCTFail("Expected an autobuild versioned asset")
        }
        XCTAssertEqual(versionedUpdate?.assetURL.absoluteString, versionedURL)

        let invalidVersionedManifest = try JSONSerialization.data(withJSONObject: [
            "revision": revision,
            "asset_url": "https://github.com/notCorwin/Perpetual-Radar/releases/download/autobuild/Perpetual.Radar.app.tar",
            "versioned_asset_url": versionedURL.replacingOccurrences(of: revision, with: String(repeating: "c", count: 40)),
            "digest": "sha256:\(digest)",
        ])
        guard case .failure(.invalidResponse) = AppUpdater.parse(data: invalidVersionedManifest, currentRevision: nil) else {
            return XCTFail("Expected a mismatched autobuild asset to be rejected")
        }

        let wrongRevisionURL = immutableURL.replacingOccurrences(of: revision, with: String(repeating: "c", count: 40))
        let mismatchedManifest = try JSONSerialization.data(withJSONObject: [
            "revision": revision,
            "asset_url": "https://github.com/notCorwin/Perpetual-Radar/releases/download/autobuild/Perpetual.Radar.app.tar",
            "immutable_asset_url": wrongRevisionURL,
            "digest": "sha256:\(digest)",
        ])
        guard case .failure(.invalidResponse) = AppUpdater.parse(data: mismatchedManifest, currentRevision: nil) else {
            return XCTFail("Expected a mismatched release URL to be rejected")
        }
    }

    func testRateLimitHonorsResponseHeaders() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let url = URL(string: "https://github.com")!
        let primary = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil,
                                                    headerFields: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "2000"]))
        XCTAssertEqual(AppUpdater.retryDate(for: primary, now: now), Date(timeIntervalSince1970: 2_001))
        let secondary = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil,
                                                      headerFields: ["Retry-After": "120"]))
        XCTAssertEqual(AppUpdater.retryDate(for: secondary, now: now), Date(timeIntervalSince1970: 1_120))
        let generic = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: [:]))
        XCTAssertEqual(AppUpdater.retryDate(for: generic, now: now), Date(timeIntervalSince1970: 1_060))
    }

    func testArchiveMustContainOnlyTheExpectedApp() {
        XCTAssertEqual(AppUpdater.archiveAppRoot(from: "Perpetual Radar.app/\nPerpetual Radar.app/Contents/Info.plist\n"), "Perpetual Radar.app")
        XCTAssertNil(AppUpdater.archiveAppRoot(from: "Other.app/Contents/Info.plist\n"))
        XCTAssertNil(AppUpdater.archiveAppRoot(from: "Perpetual Radar.app/Contents/Info.plist\n../other\n"))
    }

    func testInstallReplacesTheExpectedApp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PerpetualRadarTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("Perpetual Radar.app")
        let release = root.appendingPathComponent("release/Perpetual Radar.app")
        let archive = root.appendingPathComponent("update.tar")
        try makeApp(at: current, marker: "old")
        try makeApp(at: release, marker: "new")

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cf", archive.path, "-C", release.deletingLastPathComponent().path, "Perpetual Radar.app"]
        try tar.run()
        tar.waitUntilExit()
        XCTAssertEqual(tar.terminationStatus, 0)

        let updater = AppUpdater(currentAppURL: current, relauncher: { _, _ in })
        try updater.install(downloadedFile: archive, expectedRevision: "unknown")
        let marker = current.appendingPathComponent("Contents/Resources/marker")
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "new")
    }

    private func makeApp(at url: URL, marker: String) throws {
        let contents = url.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/PerpetualRadar")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data(marker.utf8).write(to: contents.appendingPathComponent("Resources/marker"))
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleExecutable": "PerpetualRadar",
            "CFBundleIdentifier": "com.perpetualradar.macos",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "Perpetual Radar",
            "CFBundlePackageType": "APPL",
        ], format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
    }
}
