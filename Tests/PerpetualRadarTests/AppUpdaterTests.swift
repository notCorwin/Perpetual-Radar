import XCTest
@testable import PerpetualRadar

final class AppUpdaterTests: XCTestCase {
    func testReleaseUsesOnlyTheExpectedAppAndDigest() throws {
        let revision = String(repeating: "a", count: 40)
        let digest = String(repeating: "b", count: 64)
        let data = try JSONSerialization.data(withJSONObject: [
            "name": "autobuild",
            "target_commitish": revision,
            "assets": [[
                "name": "Perpetual.Radar.app.tar",
                "browser_download_url": "https://github.com/notCorwin/Perpetual-Radar/releases/download/autobuild/Perpetual.Radar.app.tar",
                "digest": "sha256:\(digest)",
            ]],
        ])

        guard case .success(let available) = AppUpdater.parse(data: data, currentRevision: String(repeating: "c", count: 40)) else {
            return XCTFail("Expected an available update")
        }
        XCTAssertEqual(available?.revision, revision)
        XCTAssertEqual(available?.expectedSHA256, digest)
        guard case .success(let latest) = AppUpdater.parse(data: data, currentRevision: revision) else {
            return XCTFail("Expected the installed revision to be current")
        }
        XCTAssertNil(latest)

        let missingDigest = try JSONSerialization.data(withJSONObject: [
            "target_commitish": revision,
            "assets": [[
                "name": "Perpetual.Radar.app.tar",
                "browser_download_url": "https://github.com/notCorwin/Perpetual-Radar/releases/download/autobuild/Perpetual.Radar.app.tar",
            ]],
        ])
        guard case .failure(.invalidResponse) = AppUpdater.parse(data: missingDigest, currentRevision: nil) else {
            return XCTFail("Expected an unsigned release to be rejected")
        }
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
