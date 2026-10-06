import AppKit
import CoreFoundation
import XCTest
@testable import PerpetualRadar

final class MonitorServiceTests: XCTestCase {
    @MainActor
    func testIPCAllowsConcurrentHistoryRequestsAndCancelsAbandonedWork() async throws {
        let name = "com.perpetualradar.tests.\(UUID())"
        var cancelled = false
        let server = try MonitorIPCServer(name: name) { data in
            let body = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            if body["slow"] as? Bool == true {
                do { try await Task.sleep(for: .seconds(10)) }
                catch { cancelled = true }
            }
            return try! JSONSerialization.data(withJSONObject: ["value": ["ok": true]])
        }
        defer { server.invalidate() }
        let slow = Task { _ = try await MonitorIPC.request(["slow": true], name: name) }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        let reply = try await MonitorIPC.request(["fast": true], name: name)
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertLessThan(start.duration(to: .now), .seconds(2), "A history load must not block snapshots or preferences.")
        slow.cancel(); _ = try? await slow.value
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(cancelled)
        XCTAssertThrowsError(try MonitorIPCServer(name: name) { _ in Data() })
    }

    @MainActor
    func testPackagedMonitorSurvivesQuitNotifiesReopensPausesAndQuitsCompletely() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RADAR_SERVICE_TESTS"] == "1", "Run after packaging with RADAR_SERVICE_TESTS=1; every process remains in the background.")
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let app = root.appendingPathComponent(".build/app/Perpetual Radar.app")
        let channel = UUID().uuidString, name = "com.perpetualradar.monitor.\(getuid()).\(channel)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(channel)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var processes: [Process] = []
        var monitorPID: Int32?
        defer {
            processes.filter(\.isRunning).forEach { $0.terminate() }
            if let monitorPID { kill(monitorPID, SIGTERM) }
            UserDefaults(suiteName: "RadarServiceTests.\(channel)")?.removePersistentDomain(forName: "RadarServiceTests.\(channel)")
            try? FileManager.default.removeItem(at: directory)
        }
        func launch(helper: Bool) throws -> Process {
            let process = Process()
            let bundle = helper ? app.appendingPathComponent("Contents/Library/LoginItems/Perpetual Radar Monitor.app") : app
            process.executableURL = bundle.appendingPathComponent("Contents/MacOS/PerpetualRadar")
            var environment = ProcessInfo.processInfo.environment
            environment["PERPETUAL_RADAR_TEST_CHANNEL"] = channel
            environment["PERPETUAL_RADAR_TEST_DIRECTORY"] = directory.path
            environment["PERPETUAL_RADAR_BACKGROUND"] = "1"
            environment["PERPETUAL_RADAR_READY_FILE"] = directory.appendingPathComponent(helper ? "helper-ready" : "ui-ready").path
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            let log = directory.appendingPathComponent("\(processes.count).log")
            FileManager.default.createFile(atPath: log.path, contents: Data())
            process.standardError = try FileHandle(forWritingTo: log)
            try process.run(); processes.append(process); return process
        }
        func request(_ body: [String: Any]) async throws -> [String: Any] { try await MonitorIPC.request(body, name: name) }
        func wait(_ condition: () async throws -> Bool) async throws {
            for _ in 0..<200 { if (try? await condition()) == true { return }; try await Task.sleep(for: .milliseconds(50)) }
            let logs = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "log" }.map { (try? String(contentsOf: $0, encoding: .utf8)) ?? "" }.joined(separator: "\n")
            XCTFail("Background lifecycle condition timed out. \(logs)")
            throw FilterError("Lifecycle timeout")
        }
        let ui = try launch(helper: false)
        try await wait { (try await request(["serviceInfo": true]))["samples"] as? Int ?? 0 >= 2 }
        var info = try await request(["serviceInfo": true])
        let helperPID = try XCTUnwrap(info["pid"] as? Int32)
        monitorPID = helperPID
        XCTAssertNotEqual(helperPID, ui.processIdentifier)
        XCTAssertNotNil(NSImage(systemSymbolName: MonitorDelegate.symbolName, accessibilityDescription: nil))
        XCTAssertEqual(info["menuSymbol"] as? String, "dot.radiowaves.left.and.right")
        XCTAssertEqual(info["appPath"] as? String, app.path)
        let config = try FilterCompiler.compile(source: "Close > 105").config.json
        let saved = try await request(["marketFiltersJSON": config, "frostedBackgroundOpacity": 0.55])
        XCTAssertEqual(saved["filterConfigJSON"] as? String, config)
        XCTAssertEqual(saved["frostedBackgroundOpacity"] as? Double, 0.55)
        let baseline = (try await request(["serviceInfo": true]))["samples"] as! Int
        try await wait { (try await request(["serviceInfo": true]))["samples"] as? Int ?? 0 >= baseline + 2 }
        _ = try await request(["testQuitUI": true])
        try await wait { !ui.isRunning }
        XCTAssertEqual(ui.terminationStatus, 0)
        _ = try await request(["testPrice": 110.0])
        try await wait { ((try await request(["serviceInfo": true]))["delivered"] as? [[String: String]])?.count == 1 }
        _ = try await request(["testPrice": 100.0])
        try await wait { ((try await request(["serviceInfo": true]))["delivered"] as? [[String: String]])?.count == 2 }
        info = try await request(["serviceInfo": true])
        let delivered = try XCTUnwrap(info["delivered"] as? [[String: String]])
        XCTAssertEqual(delivered.map { $0["direction"]! }, ["entered", "exited"])
        XCTAssertEqual(delivered.map { $0["instId"]! }, ["BTC-USDT-SWAP", "BTC-USDT-SWAP"])
        try FileManager.default.removeItem(at: directory.appendingPathComponent("ui-ready"))
        let reopened = try launch(helper: false)
        try await wait { FileManager.default.fileExists(atPath: directory.appendingPathComponent("ui-ready").path) }
        XCTAssertNotEqual(reopened.processIdentifier, ui.processIdentifier)
        info = try await request(["serviceInfo": true])
        XCTAssertEqual(info["pid"] as? Int32, helperPID, "Reopening must reuse the existing collector.")
        let restored = try await request([:])
        XCTAssertEqual(restored["filterConfigJSON"] as? String, config)
        XCTAssertEqual(restored["frostedBackgroundOpacity"] as? Double, 0.55)
        _ = try await request(["monitoringPaused": true])
        let pausedSamples = (try await request(["serviceInfo": true]))["samples"] as! Int
        _ = try await request(["testPrice": 110.0]); try await Task.sleep(for: .milliseconds(350))
        info = try await request(["serviceInfo": true])
        XCTAssertTrue(info["monitoringPaused"] as? Bool == true)
        XCTAssertEqual(info["samples"] as? Int, pausedSamples)
        _ = try await request(["monitoringPaused": false])
        try await wait { (try await request(["serviceInfo": true]))["samples"] as? Int ?? 0 > pausedSamples + 1 }
        info = try await request(["serviceInfo": true])
        XCTAssertEqual((info["delivered"] as? [[String: String]])?.count, 2, "Resuming establishes a quiet baseline.")
        let duplicate = try launch(helper: true)
        try await wait { !duplicate.isRunning }
        info = try await request(["serviceInfo": true])
        XCTAssertEqual(info["pid"] as? Int32, helperPID)
        _ = try await request(["monitoringPaused": true])
        kill(helperPID, SIGTERM)
        try await wait {
            let candidate = try await request(["serviceInfo": true])
            guard let pid = candidate["pid"] as? Int32, pid != helperPID else { return false }
            monitorPID = pid; return true
        }
        info = try await request(["serviceInfo": true])
        XCTAssertTrue(info["monitoringPaused"] as? Bool == true, "A restarted helper must preserve the pause setting.")
        XCTAssertEqual(info["samples"] as? Int, 0)
        let afterRestart = try await request([:])
        XCTAssertEqual(afterRestart["filterConfigJSON"] as? String, config)
        XCTAssertEqual(afterRestart["frostedBackgroundOpacity"] as? Double, 0.55)
        let quittingPID = monitorPID!
        _ = try await request(["quitCompletely": true])
        try await wait { !reopened.isRunning && CFMessagePortCreateRemote(nil, name as CFString) == nil && kill(quittingPID, 0) != 0 }
        XCTAssertEqual(reopened.terminationStatus, 0)
        XCTAssertNotEqual(kill(quittingPID, 0), 0, "Quit Completely must terminate the helper too.")
        monitorPID = nil
    }

    @MainActor
    func testPausePreferencePersistsAndNotificationRoutesValidateContracts() throws {
        let suite = "PauseTests.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite), url = directory.appendingPathComponent("radar.sqlite3")
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let radar = try Radar(defaults: defaults, storeURL: url)
        XCTAssertFalse(radar.monitoringPaused); try radar.setMonitoringPaused(true)
        XCTAssertTrue(try Radar(defaults: defaults, storeURL: url).monitoringPaused)
        XCTAssertEqual(RadarNotificationRoute.contract(in: URL(string: "perpetualradar://contract/BTC-USDT-SWAP")!), "BTC-USDT-SWAP")
        XCTAssertNil(RadarNotificationRoute.contract(in: URL(string: "perpetualradar://contract/BTC-USDT-SWAP/extra")!))
        XCTAssertNil(RadarNotificationRoute.contract(in: URL(string: "https://contract/BTC-USDT-SWAP")!))
        XCTAssertNil(RadarNotificationRoute.contract(in: URL(string: "perpetualradar://contract/../../../etc/passwd")!))
    }
}
