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
    func testPackagedOnDemandResearchMinimizeCloseQuitCrashAndManualResume() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RADAR_SERVICE_TESTS"] == "1", "Package the app and set RADAR_SERVICE_TESTS=1.")
        let app = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/app/Perpetual Radar.app")
        let channel = UUID().uuidString, name = "com.perpetualradar.monitor.\(getuid()).\(channel)", suite = "RadarServiceTests.\(channel)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(channel), defaults = UserDefaults(suiteName: suite)!
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let store = try ResearchStore(directory: directory.appendingPathComponent("Research"))
        try ResearchFixture.seed(store, bars: ResearchFixture.bars(through: ResearchFixture.hour+3048*hourMS))
        let spec = try ResearchFixture.spec(through: ResearchFixture.hour+3000*hourMS), plan = ResearchFixture.plan(spec)
        try store.put(plan.id, kind: "plan", plan)
        defaults.set(false, forKey: "BackgroundMonitoring"); defaults.set(false, forKey: "AutomaticallyInstallUpdates")
        var processes: [Process] = [], helperPID: Int32?
        defer {
            processes.filter(\.isRunning).forEach { $0.terminate() }
            if let helperPID { kill(helperPID, SIGTERM) }
            defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory)
        }
        func launch() throws -> Process {
            let process = Process(); process.executableURL = app.appendingPathComponent("Contents/MacOS/PerpetualRadar")
            var environment = ProcessInfo.processInfo.environment
            environment["PERPETUAL_RADAR_TEST_CHANNEL"] = channel; environment["PERPETUAL_RADAR_TEST_DIRECTORY"] = directory.path
            environment["PERPETUAL_RADAR_BACKGROUND"] = "1"; process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            let log = URL(fileURLWithPath: "/tmp/perp-research-packaged-\(processes.count).log")
            FileManager.default.createFile(atPath: log.path, contents: Data()); process.standardError = try FileHandle(forWritingTo: log)
            try process.run(); processes.append(process); return process
        }
        func request(_ body: [String: Any], interface: Bool = false) async throws -> [String: Any] {
            try await MonitorIPC.request(body, name: name + (interface ? ".interface-tests" : ""))
        }
        func wait(_ label: String, _ condition: () async throws -> Bool) async throws {
            for _ in 0..<240 { if (try? await condition()) == true { return }; try await Task.sleep(for: .milliseconds(50)) }
            throw FilterError("On-demand lifecycle timed out at \(label); processes: \(processes.map { "\($0.processIdentifier):\($0.isRunning)" }), helper: \(String(describing: helperPID)), checkpoint: \(String(describing: try? store.objects("checkpoint", as: Checkpoint.self)))")
        }
        let ui = try launch()
        try await wait("startup") { (try await request(["serviceInfo": true]))["samples"] as? Int ?? 0 >= 2 }
        let info = try await request(["serviceInfo": true]); helperPID = try XCTUnwrap(info["pid"] as? Int32)
        XCTAssertEqual(info["backgroundMonitoringEnabled"] as? Bool, false)
        let longStrategy = LongStrategy(name: "Packaged Long",entryJSON: try FilterCompiler.compile(source: "Close > 0").config.json,exitJSON: try FilterCompiler.compile(source: "LongHeldHours >= 3").config.json)
        let longReply = try await request(["longDecision": ["action": "save", "strategy": try JSONSerialization.jsonObject(with: Data(try researchJSON(longStrategy).utf8))]])
        let savedLong = try XCTUnwrap(longReply["saved"] as? [String: Any])
        XCTAssertEqual(savedLong["revision"] as? Int,1)
        let liveLong = try await request(["longDecision": ["action": "evaluate", "strategyID": longStrategy.id]])
        XCTAssertNotNil(liveLong["decisions"] as? [[String: Any]],"The packaged helper must serve the Long evaluation bridge.")
        _ = try await request(["workspace": "research"], interface: true)
        let samples = (try await request(["serviceInfo": true]))["samples"] as! Int
        try await Task.sleep(for: .milliseconds(350))
        let researchInfo = try await request(["serviceInfo": true])
        XCTAssertEqual(researchInfo["samples"] as? Int, samples)
        _ = try await request(["research": ["action": "prepare", "planID": plan.id]], interface: true)
        try await wait("ready") { ((try await request(["research": ["action": "inventory"]], interface: true))["job"] as? [String: Any])?["phase"] as? String == "ready" }
        let inventory = try await request(["research": ["action": "inventory"]], interface: true)
        let studyID = try XCTUnwrap((inventory["job"] as? [String: Any])?["resultID"] as? String)
        _ = try await request(["research": ["action": "run", "studyID": studyID]], interface: true)
        _ = try await request(["minimize": true], interface: true)
        try await wait("minimized") { (try await request([:], interface: true))["minimized"] as? Bool == true }
        try await wait("checkpoint") { (try store.get("checkpoint:\(studyID)", as: Checkpoint.self))?.nextHour != nil }
        _ = try await request(["close": true], interface: true)
        let oldHelper = helperPID!
        try await wait("closed") { !ui.isRunning && CFMessagePortCreateRemote(nil, name as CFString) == nil && kill(oldHelper,0) != 0 }
        XCTAssertEqual(ui.terminationStatus, 0)
        XCTAssertFalse(defaults.bool(forKey: AppUpdater.backgroundRelaunchKey))
        XCTAssertEqual(try store.get("checkpoint:\(studyID)", as: Checkpoint.self)?.phase, "paused")
        let checkpoint = try researchJSON(store.get("checkpoint:\(studyID)", as: Checkpoint.self))
        helperPID = nil
        let reopened = try launch()
        try await wait("reopened") { (try await request(["serviceInfo": true]))["pid"] != nil }
        let reopenedInfo = try await request(["serviceInfo": true]); helperPID = try XCTUnwrap(reopenedInfo["pid"] as? Int32)
        let restoredLong = try await request(["longDecision": ["action": "inventory"]])
        XCTAssertEqual(restoredLong["selectedID"] as? String,longStrategy.id)
        XCTAssertEqual((restoredLong["strategies"] as? [[String: Any]])?.first?["exitJSON"] as? String,savedLong["exitJSON"] as? String)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try researchJSON(store.get("checkpoint:\(studyID)", as: Checkpoint.self)), checkpoint, "Reopening must not resume research automatically.")
        _ = try await request(["workspace": "research", "research": ["action": "resume", "studyID": studyID]], interface: true)
        try await Task.sleep(for: .milliseconds(150))
        _ = try await request(["testQuitUI": true])
        let quitHelper = helperPID!
        try await wait("quit") { !reopened.isRunning && kill(quitHelper,0) != 0 }
        XCTAssertEqual(try store.get("checkpoint:\(studyID)", as: Checkpoint.self)?.phase, "paused")
        helperPID = nil
        let crashing = try launch()
        try await wait("crash-startup") { (try await request(["serviceInfo": true]))["pid"] != nil }
        let crashingInfo = try await request(["serviceInfo": true]); helperPID = try XCTUnwrap(crashingInfo["pid"] as? Int32)
        let orphan = helperPID!
        kill(crashing.processIdentifier, SIGKILL)
        try await wait("crash-exit") { !crashing.isRunning && kill(orphan,0) != 0 && CFMessagePortCreateRemote(nil, name as CFString) == nil }
        helperPID = nil
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, foreground, "Packaged CI must never take focus.")
    }

    @MainActor
    func testPackagedMonitorSurvivesQuitNotifiesReopensPausesAndQuitsCompletely() async throws {
        try await checkPackagedMonitorLifecycle(preferencesMatchBundleIdentifier: false)
    }

    @MainActor
    func testPackagedInterfaceStartsWithItsOwnPreferencesDomain() async throws {
        try await checkPackagedMonitorLifecycle(preferencesMatchBundleIdentifier: true)
    }

    @MainActor
    private func checkPackagedMonitorLifecycle(preferencesMatchBundleIdentifier: Bool) async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RADAR_SERVICE_TESTS"] == "1", "Run after packaging with RADAR_SERVICE_TESTS=1; every process remains in the background.")
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var app = root.appendingPathComponent(".build/app/Perpetual Radar.app")
        let channel = UUID().uuidString, name = "com.perpetualradar.monitor.\(getuid()).\(channel)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(channel)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "RadarServiceTests.\(channel)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        var processes: [Process] = []
        var monitorPID: Int32?
        defer {
            processes.filter(\.isRunning).forEach { $0.terminate() }
            if let monitorPID { kill(monitorPID, SIGTERM) }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        if preferencesMatchBundleIdentifier {
            // Mirror the production app's own preference domain without touching real settings.
            let isolatedApp = directory.appendingPathComponent("Perpetual Radar.app")
            try FileManager.default.copyItem(at: app, to: isolatedApp)
            app = isolatedApp
            let plistURL = app.appendingPathComponent("Contents/Info.plist")
            var plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), options: [], format: nil) as? [String: Any])
            plist["CFBundleIdentifier"] = suite
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)
            let signer = Process()
            signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            signer.arguments = ["--force", "--sign", "-", app.path]
            signer.standardOutput = FileHandle.nullDevice; signer.standardError = FileHandle.nullDevice
            try signer.run(); signer.waitUntilExit()
            XCTAssertEqual(signer.terminationStatus, 0)
        }
        defaults.set(true, forKey: "BackgroundMonitoring")
        defaults.set(false, forKey: "AutomaticallyInstallUpdates")
        defaults.set(false, forKey: AppUpdater.backgroundRelaunchKey)
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
        func wait(_ label: String, _ condition: () async throws -> Bool) async throws {
            for _ in 0..<200 { if (try? await condition()) == true { return }; try await Task.sleep(for: .milliseconds(50)) }
            let logs = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "log" }.map { (try? String(contentsOf: $0, encoding: .utf8)) ?? "" }.joined(separator: "\n")
            XCTFail("Background lifecycle timed out at \(label); processes: \(processes.map { "\($0.processIdentifier):\($0.isRunning)" }); \(logs)")
            throw FilterError("Lifecycle timeout")
        }
        let ui = try launch(helper: false)
        try await wait("startup") {
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("ui-ready").path) else { return false }
            return (try await request(["serviceInfo": true]))["samples"] as? Int ?? 0 >= 2
        }
        var info = try await request(["serviceInfo": true])
        let helperPID = try XCTUnwrap(info["pid"] as? Int32)
        monitorPID = helperPID
        XCTAssertNotEqual(helperPID, ui.processIdentifier)
        XCTAssertNotNil(NSImage(systemSymbolName: MonitorDelegate.symbolName, accessibilityDescription: nil))
        XCTAssertEqual(info["menuSymbol"] as? String, "dot.radiowaves.left.and.right")
        XCTAssertEqual(info["appPath"] as? String, app.path)
        XCTAssertEqual(info["automaticUpdatesEnabled"] as? Bool, false, "The helper must read the interface's existing preferences.")
        let config = try FilterCompiler.compile(source: "Close > 105").config.json
        let saved = try await request(["marketFiltersJSON": config, "frostedBackgroundOpacity": 0.55])
        XCTAssertEqual(saved["filterConfigJSON"] as? String, config)
        XCTAssertEqual(saved["frostedBackgroundOpacity"] as? Double, 0.55)
        let baseline = (try await request(["serviceInfo": true]))["samples"] as! Int
        try await wait("rule-samples") { (try await request(["serviceInfo": true]))["samples"] as? Int ?? 0 >= baseline + 2 }
        _ = try await request(["testQuitUI": true])
        try await wait("ui-quit") { !ui.isRunning }
        XCTAssertEqual(ui.terminationStatus, 0)
        XCTAssertTrue(defaults.bool(forKey: AppUpdater.backgroundRelaunchKey), "Interface writes must use the shared preference domain.")
        _ = try await request(["testPrice": 110.0])
        try await wait("notification-enter") { ((try await request(["serviceInfo": true]))["delivered"] as? [[String: String]])?.count == 1 }
        _ = try await request(["testPrice": 100.0])
        try await wait("notification-exit") { ((try await request(["serviceInfo": true]))["delivered"] as? [[String: String]])?.count == 2 }
        info = try await request(["serviceInfo": true])
        let delivered = try XCTUnwrap(info["delivered"] as? [[String: String]])
        XCTAssertEqual(delivered.map { $0["direction"]! }, ["entered", "exited"])
        XCTAssertEqual(delivered.map { $0["instId"]! }, ["BTC-USDT-SWAP", "BTC-USDT-SWAP"])
        try FileManager.default.removeItem(at: directory.appendingPathComponent("ui-ready"))
        let reopened = try launch(helper: false)
        try await wait("reopen") { FileManager.default.fileExists(atPath: directory.appendingPathComponent("ui-ready").path) }
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
        try await wait("unpause") { (try await request(["serviceInfo": true]))["samples"] as? Int ?? 0 > pausedSamples + 1 }
        info = try await request(["serviceInfo": true])
        XCTAssertEqual((info["delivered"] as? [[String: String]])?.count, 2, "Resuming establishes a quiet baseline.")
        let duplicate = try launch(helper: true)
        try await wait("duplicate-helper") { !duplicate.isRunning }
        info = try await request(["serviceInfo": true])
        XCTAssertEqual(info["pid"] as? Int32, helperPID)
        _ = try await request(["monitoringPaused": true])
        kill(helperPID, SIGTERM)
        try await wait("helper-restart") {
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
        try await wait("quit-completely") { !reopened.isRunning && CFMessagePortCreateRemote(nil, name as CFString) == nil && kill(quittingPID, 0) != 0 }
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
