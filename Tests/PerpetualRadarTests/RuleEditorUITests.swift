import AppKit
import WebKit
import ScreenCaptureKit
import XCTest
@testable import PerpetualRadar

@MainActor
private final class BackgroundTestWindow: NSWindow {
    // WindowServer marks windows beyond the display edges as occluded. Keep
    // WebKit's real compositor clock active without showing or focusing them.
    override var occlusionState: NSWindow.OcclusionState {
        ProcessInfo.processInfo.environment["RADAR_VISUAL_TESTS"] == "1" ? super.occlusionState : super.occlusionState.union(.visible)
    }
}

// Exercises the actual packaged-origin WebKit renderer and promise bridge with
// native compile/evaluation/persistence and a deterministic 500-market feed.
@MainActor
private final class RuleUIBridge: NSObject, WKScriptMessageHandlerWithReply, WKURLSchemeHandler {
    private let renderingActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Run background WKWebView interaction and material verification")
    let root: URL
    let radar: Radar
    let suite: String
    let directory: URL
    var revision = 1
    var rows: [[String: Any]]
    var contexts: [FilterMarketData]
    var previewDelay: UInt64 = 0
    var filterSaveDelay: UInt64 = 0
    var filterSaveError: String?
    var pulseRows = false
    var pulse = 0.0
    var includeChartBars = false
    var chartSnapshotRGB: [Double] = []
    weak var windowBackground: WindowBackgroundView?
    var windowTintRGB: [Double] = []
    var notificationAuthorization = "authorized"
    var notificationTestCount = 0
    var notificationSettingsOpenCount = 0
    var notificationPermissionRequests = 0
    var notificationError = ""
    var launchAtLogin = "disabled"
    var loginSettingsOpenCount = 0
    let worker = FilterEvaluationWorker()
    init(root: URL) throws {
        self.root = root; suite = "RuleUI-\(UUID())"
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        radar = try Radar(defaults: UserDefaults(suiteName: suite)!, storeURL: directory.appendingPathComponent("radar.sqlite3"))
        let fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: root.deletingLastPathComponent().appendingPathComponent("Tests/Fixtures/filter-compatibility.json"))) as! [[String: Any]]
        let template = fixtures[0]["row"] as! [String: Any], hour = Int64(Date().timeIntervalSince1970 * 1000) / hourMS * hourMS
        var generated: [[String: Any]] = [], data: [FilterMarketData] = []
        let candles = Dictionary(uniqueKeysWithValues: (0...900).map { age in let ts = hour - Int64(age) * hourMS; return (ts, Candle(hour: ts, high: 111, low: 99, close: 110, quoteVolume: 100, baseVolume: 1, open: 105, confirmed: age != 0)) })
        for index in 0..<500 {
            var row = template; let id = String(format: "MKT%03d-USDT-SWAP", index)
            row["instId"] = id; row["turnover24hUSDT"] = index % 4 == 0 ? 5_000_000.0 : 20_000_000.0
            row["oiChange"] = index % 3 == 0 ? 2.0 : index % 3 == 1 ? 0.0 : -2.0
            generated.append(row)
            data.append(.init(id: id, hour: hour, now: hour + hourMS / 2, listedAt: hour - 3 * 365 * 24 * hourMS, candles: candles, stats: [:], quotes: [:], current: LegacyFilterReadings.from(row), previousEMA: 100))
        }
        rows = generated; contexts = data
        super.init()
    }
    func cleanUp() { ProcessInfo.processInfo.endActivity(renderingActivity); UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
    func snapshot() -> [String: Any] {
        var result = radar.snapshot(rocPeriod: 9, marocPeriod: 9)
        result["rows"] = rows; result["revision"] = revision
        result["notificationAuthorization"] = notificationAuthorization
        result["notificationError"] = notificationError; result["backgroundMonitoringError"] = ""
        result["monitoringPaused"] = radar.monitoringPaused
        result["launchAtLogin"] = launchAtLogin; result["launchAtLoginError"] = ""
        return result
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        let request = message.body as! [String: Any]
        if request["notificationsEnabled"] != nil || request["notificationAction"] != nil || request["monitoringPaused"] != nil || request["launchAtLogin"] != nil {
            do {
                if let enabled = request["notificationsEnabled"] as? Bool { try radar.setNotificationsEnabled(enabled); revision += 1 }
                if let paused = request["monitoringPaused"] as? Bool { try radar.setMonitoringPaused(paused); revision += 1 }
                if let enabled = request["launchAtLogin"] as? Bool {
                    if launchAtLogin == "requiresApproval", enabled { loginSettingsOpenCount += 1 }
                    else { launchAtLogin = enabled ? "enabled" : "disabled" }
                    revision += 1
                }
                if request["notificationAction"] as? String == "test" { notificationTestCount += 1 }
                if request["notificationAction"] as? String == "openSettings" { notificationSettingsOpenCount += 1 }
                if (request["notificationAction"] as? String == "requestPermission" || request["notificationsEnabled"] as? Bool == true), notificationAuthorization == "notDetermined" {
                    notificationPermissionRequests += 1; notificationAuthorization = "authorized"
                }
                replyHandler(snapshot(), nil)
            } catch { replyHandler(nil, String(describing: error)) }
            return
        }
        if let rgb = request["windowTintRGB"] as? [Double] {
            guard windowBackground?.setTint(rgb: rgb) == true else { replyHandler(nil, "Invalid window tint"); return }
            windowTintRGB = rgb
            replyHandler(["ok": true], nil)
            return
        }
        if let compile = request["compileMarketFilters"] as? [String: Any] { replyHandler(radar.compileMarketFilters(compile), nil); return }
        if let preview = request["previewMarketFilters"] as? [String: String] {
            var original = snapshot()
            if pulseRows { pulse += 0.01; original["rows"] = rows.map { var row = $0; row["price"] = 110 + pulse; return row } }
            let source = preview["filtersJSON"]!, token = preview["token"]!, delay = previewDelay
            Task {
                do {
                    let filter = try FilterCompiler.compile(FilterConfigV2.decode(source))
                    let results = await worker.evaluate(contexts, filter: filter)
                    if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                    var result = original; result["filterToken"] = token; result["filterResults"] = results.mapValues(\.rawValue); result["historyProgress"] = ["pending": 0, "completed": 0, "error": ""]
                    replyHandler(result, nil)
                } catch { replyHandler(nil, String(describing: error)) }
            }; return
        }
        if let explain = request["explainMarketFilters"] as? [String: String], let market = contexts.first(where: { $0.id == explain["instId"] }) {
            do { let filter = try FilterCompiler.compile(FilterConfigV2.decode(explain["filtersJSON"]!)); replyHandler(["instId": market.id, "filterToken": explain["token"]!, "revision": revision, "trace": FilterEvaluator(market: market, filter: filter).evaluate(explain: true).snapshot], nil) }
            catch { replyHandler(nil, String(describing: error)) }; return
        }
        if let json = request["marketFiltersJSON"] as? String {
            let delay = filterSaveDelay, error = filterSaveError
            Task {
                do {
                    if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                    if let error { replyHandler(nil, error); return }
                    _ = try radar.setMarketFiltersJSON(json); revision += 1
                    replyHandler(snapshot(), nil)
                } catch { replyHandler(nil, String(describing: error)) }
            }
            return
        }
        if let capture = request["captureChart"] as? [String: Any], let rgb = capture["backgroundRGB"] as? [Double] {
            chartSnapshotRGB = rgb
            replyHandler(["ok": true], nil)
            return
        }
        if request["chartInstId"] != nil {
            guard includeChartBars else { replyHandler(["bars": [], "revision": revision, "error": "Fixture chart"], nil); return }
            let hour = contexts[0].hour
            let bars: [[String: Any]] = (0..<96).map { index in
                let close = 105 + Double(index) * 0.05 + sin(Double(index) / 5)
                return ["hour": hour - Int64(95 - index) * hourMS, "open": close - 0.3, "high": close + 0.8, "low": close - 0.7, "close": close, "confirmed": index != 95,
                        "vwap": close - 0.4, "ema": 105.0, "logBBUpper": close + 1.5, "logBBMiddle": close, "logBBLower": close - 1.5,
                        "roc": sin(Double(index) / 5) * 2, "maroc": sin(Double(index) / 7), "rsi6": 50 + sin(Double(index) / 5) * 20,
                        "rsi12": 50 + sin(Double(index) / 7) * 10, "rsi24": 50 + sin(Double(index) / 9) * 5, "oi": 100_000_000 + index * 100_000, "buy": 1000 + index * 5, "sell": 800 + index * 3]
            }
            replyHandler(["bars": bars, "revision": revision, "error": "", "endHour": hour], nil)
            return
        }
        do {
            if request["frostedBackgroundEnabled"] != nil || request["frostedBackgroundOpacity"] != nil {
                _ = try radar.setFrostedBackground(enabled: request["frostedBackgroundEnabled"] as? Bool, opacity: request["frostedBackgroundOpacity"] as? Double)
                if let background = windowBackground, let window = background.window {
                    background.apply(enabled: radar.frostedBackgroundEnabled, opacity: radar.frostedBackgroundOpacity, to: window)
                }
                revision += 1
            }
            if let json = request["filterLibraryPreferencesJSON"] as? String { try radar.setFilterLibraryPreferences(json); revision += 1 }
            if let saved = request["saveMarketFilterCombination"] as? [String: String] { _ = try radar.saveMarketFilterCombination(name: saved["name"]!, filtersJSON: saved["filtersJSON"]!); revision += 1 }
            if let selected = request["selectedMarketFilterCombinationID"] as? String { _ = try radar.setSelectedMarketFilterCombinationID(selected); revision += 1 }
            if let id = request["deleteMarketFilterCombination"] as? String { _ = try radar.deleteMarketFilterCombination(id); revision += 1 }
            replyHandler(snapshot(), nil)
        } catch { replyHandler(nil, String(describing: error)) }
    }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let url = task.request.url!, file = root.appendingPathComponent(String(url.path.dropFirst()))
        do {
            let data = try Data(contentsOf: file), mime = ["html": "text/html", "js": "text/javascript", "css": "text/css", "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf"][file.pathExtension] ?? "application/octet-stream"
            task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: mime.hasPrefix("text/") ? "utf-8" : nil)); task.didReceive(data); task.didFinish()
        } catch { task.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class RuleEditorUITests: XCTestCase {
    private var visualUI: Bool { ProcessInfo.processInfo.environment["RADAR_VISUAL_TESTS"] == "1" }

    @MainActor
    private func uiConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.inactiveSchedulingPolicy = .none
        return configuration
    }

    @MainActor
    private func present(_ window: NSWindow) {
        NSApp.setActivationPolicy(.accessory)
        if visualUI {
            window.level = .floating
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // Keep a real laid-out WebKit window without occupying the user's
            // screen, changing focus, or creating a Dock icon during local CI.
            let edge = NSScreen.screens.map { $0.frame.maxX }.max() ?? 1440
            window.setFrameOrigin(NSPoint(x: edge + 1000, y: 0))
            window.orderBack(nil)
        }
    }

    @MainActor
    func testNotificationSettingsPermissionRecoveryAndContractRoutingInNativeWebKit() async throws {
        guard ProcessInfo.processInfo.environment["RADAR_UI_TESTS"] == "1" else { throw XCTSkip("Run npm run test:ui after building the Web renderer.") }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bridge = try RuleUIBridge(root: project.appendingPathComponent("dist")), configuration = uiConfiguration()
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "radar")
        configuration.setURLSchemeHandler(bridge, forURLScheme: "radar")
        let window = BackgroundTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        let view = WKWebView(frame: .zero, configuration: configuration)
        let background = WindowBackgroundView(contentView: view); bridge.windowBackground = background
        window.contentView = background
        present(window)
        defer { view.stopLoading(); window.orderOut(nil); configuration.userContentController.removeScriptMessageHandler(forName: "radar", contentWorld: .page); bridge.cleanUp() }
        view.load(URLRequest(url: URL(string: "radar://app/index.html")!))
        try await wait(view, "Number(document.querySelector('table[data-market-count]')?.dataset.marketCount) === 375")
        try await click(view, "Settings")
        try await wait(view, "document.body.innerText.includes('macOS notifications are allowed.')")
        try await click(view, "Test notification")
        try await wait(view, "document.querySelector('#filter-notifications')?.disabled === false")
        XCTAssertEqual(bridge.notificationTestCount, 1)
        try await click(view, "Enable background monitoring")
        try await wait(view, "document.querySelector('#background-monitoring')?.textContent === 'Paused' && document.querySelector('#background-monitoring')?.disabled === false")
        XCTAssertTrue(bridge.radar.monitoringPaused)
        try await click(view, "Enable background monitoring")
        try await wait(view, "document.querySelector('#background-monitoring')?.textContent === 'Running' && document.querySelector('#background-monitoring')?.disabled === false")
        XCTAssertFalse(bridge.radar.monitoringPaused)
        try await click(view, "Start monitoring at login")
        try await wait(view, "document.querySelector('#launch-at-login')?.dataset.state === 'on' && document.querySelector('#launch-at-login')?.disabled === false")
        XCTAssertEqual(bridge.launchAtLogin, "enabled")
        bridge.launchAtLogin = "requiresApproval"
        try await click(view, "Settings"); try await click(view, "Settings")
        try await wait(view, "document.body.innerText.includes('Open Login Items')")
        try await click(view, "Open Login Items")
        try await wait(view, "document.querySelector('#launch-at-login')?.disabled === false")
        XCTAssertEqual(bridge.loginSettingsOpenCount, 1)
        try await click(view, "Start monitoring at login")
        try await wait(view, "document.querySelector('#launch-at-login')?.dataset.state === 'off' && document.querySelector('#launch-at-login')?.disabled === false")
        try await click(view, "Enable filter notifications")
        try await wait(view, "document.querySelector('#filter-notifications')?.dataset.state === 'off'")
        XCTAssertFalse(bridge.radar.notificationsEnabled)
        let testDisabled = try await js(view, "Array.from(document.querySelectorAll('button')).find(x => x.textContent.trim() === 'Test notification').disabled") as? Bool
        XCTAssertEqual(testDisabled, true)
        bridge.notificationAuthorization = "denied"
        try await click(view, "Enable filter notifications")
        try await wait(view, "document.body.innerText.includes('Notifications are blocked.') && document.querySelector('#filter-notifications')?.dataset.state === 'on'")
        XCTAssertTrue(bridge.radar.notificationsEnabled)
        XCTAssertEqual(bridge.notificationPermissionRequests, 0)
        try await click(view, "Notification Settings")
        try await wait(view, "document.querySelector('#filter-notifications')?.disabled === false")
        XCTAssertEqual(bridge.notificationSettingsOpenCount, 1)
        bridge.notificationAuthorization = "notDetermined"
        try await click(view, "Settings"); try await click(view, "Settings")
        try await wait(view, "Array.from(document.querySelectorAll('button')).some(x => x.textContent.trim() === 'Allow notifications')")
        try await click(view, "Allow notifications")
        try await wait(view, "document.body.innerText.includes('macOS notifications are allowed.')")
        XCTAssertEqual(bridge.notificationPermissionRequests, 1)
        bridge.notificationError = "Cannot send notification: fixture failure"
        try await click(view, "Settings"); try await click(view, "Settings")
        try await wait(view, "document.querySelector('[role=alert]')?.textContent.includes('fixture failure')")
        try await click(view, "Settings")
        _ = try await js(view, "window.radarNotificationContract = 'MKT499-USDT-SWAP'; window.dispatchEvent(new Event('radar-open-contract')); true")
        try await wait(view, "document.querySelector('h1[title=\"MKT499-USDT-SWAP\"]') !== null")
        let consumed = try await js(view, "window.radarNotificationContract === undefined") as? Bool
        XCTAssertEqual(consumed, true)
    }

    @MainActor
    func testGlassTintAndAppearanceChangesKeepTheBackgroundAndContentSeparate() async throws {
        guard ProcessInfo.processInfo.environment["RADAR_UI_TESTS"] == "1" else { throw XCTSkip("Run npm run test:ui after building the Web renderer.") }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bridge = try RuleUIBridge(root: project.appendingPathComponent("dist")), configuration = uiConfiguration()
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "radar")
        configuration.setURLSchemeHandler(bridge, forURLScheme: "radar")
        configuration.userContentController.addUserScript(WKUserScript(source: "window.radarAppearance = { frostedBackgroundEnabled: true, frostedBackgroundOpacity: 0.3, nativeWindowBackground: true };", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let window = BackgroundTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .clear
        let background = WindowBackgroundView(contentView: view)
        bridge.windowBackground = background
        window.contentView = background
        window.appearance = NSAppearance(named: .darkAqua)
        present(window)
        background.apply(enabled: true, opacity: 0.3, to: window)
        defer { view.stopLoading(); window.orderOut(nil); configuration.userContentController.removeScriptMessageHandler(forName: "radar", contentWorld: .page); bridge.cleanUp() }
        view.load(URLRequest(url: URL(string: "radar://app/index.html")!))
        try await wait(view, "Number(document.querySelector('table[data-market-count]')?.dataset.marketCount) === 375 && document.documentElement.dataset.nativeWindowBackground === 'true'")
        let pixels = """
        (() => {
          const canvas = document.createElement('canvas'); canvas.width = canvas.height = 1;
          const context = canvas.getContext('2d');
          const read = color => { context.clearRect(0,0,1,1); context.fillStyle = color; context.fillRect(0,0,1,1); return Array.from(context.getImageData(0,0,1,1).data); };
          const style = getComputedStyle(document.body);
          return { tint: read(getComputedStyle(document.documentElement).getPropertyValue('--window-background-tint')), bodyFill: read(style.backgroundColor), text: read(style.color), contentOpacity: style.opacity, snapshotBackground: read(getComputedStyle(document.documentElement).getPropertyValue('--chart-snapshot-background')) };
        })()
        """
        let glassResult = try await js(view, pixels)
        let glass = try XCTUnwrap(glassResult as? [String: Any])
        let tint = try XCTUnwrap(glass["tint"] as? [Int])
        XCTAssertEqual(tint, [40, 44, 52, 255])
        XCTAssertEqual(glass["bodyFill"] as? [Int], [0, 0, 0, 0], "WebKit must not tint the native surface a second time.")
        XCTAssertEqual(bridge.windowTintRGB, [40 / 255.0, 44 / 255.0, 52 / 255.0])
        let nativeTintView = background.subviews[1]
        XCTAssertEqual(nativeTintView.frame, background.bounds)
        XCTAssertEqual(view.frame, background.convert(window.contentLayoutRect, from: nil))
        let nativeFill = try XCTUnwrap(NSColor(cgColor: try XCTUnwrap(nativeTintView.layer?.backgroundColor))?.usingColorSpace(.sRGB))
        XCTAssertEqual(nativeFill.alphaComponent, 0.3, accuracy: 1e-6)
        XCTAssertEqual(glass["text"] as? [Int], [255, 255, 255, 255])
        XCTAssertEqual(glass["contentOpacity"] as? String, "1")
        XCTAssertEqual(glass["snapshotBackground"] as? [Int], [40, 44, 52, 255], "Copied charts must have a matching opaque tint behind white text.")
        try await click(view, "Settings")
        try await wait(view, "document.querySelector('#background-opacity') !== null")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            try await wait(view, "window.matchMedia('(prefers-color-scheme: dark)').matches === \(appearance == .darkAqua)")
            for opacity in [0.0, 0.3, 0.65, 1.0] {
                try await input(view, "#background-opacity", String(opacity))
                _ = try await js(view, "document.querySelector('#background-opacity').dispatchEvent(new FocusEvent('focusout', {bubbles:true})); true")
                try await wait(view, "Number(document.documentElement.style.getPropertyValue('--window-background-opacity')) === \(opacity)")
                try await assertSharedSurfaces(view, opacity: opacity)
                XCTAssertEqual(try XCTUnwrap(nativeTintView.layer?.backgroundColor).alpha, opacity, accuracy: 1e-6, "The window tint keeps its own opacity while components weight their own defaults.")
            }
            // The same global weight must preserve independently configured
            // defaults, including a fully opaque floating material at weight 1.
            _ = try await js(view, "document.documentElement.style.setProperty('--control-default-opacity','0.8'); document.documentElement.style.setProperty('--panel-default-opacity','0.6'); document.documentElement.style.setProperty('--floating-default-opacity','1'); true")
            try await assertSharedSurfaces(view, opacity: 1, defaultOpacities: [0.8, 0.6, 1])
            try await input(view, "#background-opacity", "0.5")
            _ = try await js(view, "document.querySelector('#background-opacity').dispatchEvent(new FocusEvent('focusout', {bubbles:true})); true")
            try await wait(view, "document.documentElement.style.getPropertyValue('--window-background-opacity') === '0.5'")
            try await assertSharedSurfaces(view, opacity: 0.5, defaultOpacities: [0.8, 0.6, 1])
            _ = try await js(view, "for (const role of ['control','panel','floating']) document.documentElement.style.removeProperty(`--${role}-default-opacity`); true")
            try await assertSharedSurfaces(view, opacity: 0.5)
            _ = try await js(view, "document.querySelector('#frosted-background').click(); true")
            try await wait(view, "document.documentElement.dataset.frostedBackground === 'false'")
            try await assertSharedSurfaces(view, opacity: 1)
            XCTAssertEqual(nativeTintView.layer?.backgroundColor?.alpha, 1, "Disabling glass retains a fully opaque shared window background.")
            let disabledInput = try await js(view, "document.querySelector('#background-opacity').disabled") as? Bool
            XCTAssertEqual(disabledInput, true)
            _ = try await js(view, "document.querySelector('#frosted-background').click(); true")
            try await wait(view, "document.documentElement.dataset.frostedBackground === 'true'")
        }
        try await input(view, "#background-opacity", "1")
        _ = try await js(view, "document.querySelector('#background-opacity').dispatchEvent(new FocusEvent('focusout', {bubbles:true})); true")
        try await wait(view, "document.documentElement.dataset.translucentBackground === 'false' && document.documentElement.style.getPropertyValue('--window-background-opacity') === '1'")
        let solidResult = try await js(view, pixels)
        let solid = try XCTUnwrap(solidResult as? [String: Any])
        XCTAssertEqual((solid["tint"] as? [Int])?.last, 255)
        XCTAssertEqual(solid["bodyFill"] as? [Int], [0, 0, 0, 0])
        XCTAssertEqual(nativeTintView.layer?.backgroundColor?.alpha, 1)
        try await waitForTint(bridge, rgb: try XCTUnwrap(solid["tint"] as? [Int]).prefix(3).map { Double($0) / 255 })
        XCTAssertLessThan((solid["tint"] as? [Int])?.first ?? 255, 40, "Full opacity restores the solid Dark palette.")
        try await input(view, "#background-opacity", "0.3")
        _ = try await js(view, "document.querySelector('#background-opacity').dispatchEvent(new FocusEvent('focusout', {bubbles:true})); true")
        try await wait(view, "document.documentElement.dataset.translucentBackground === 'true'")
        _ = try await js(view, "document.querySelector('#frosted-background').click(); true")
        try await wait(view, "document.documentElement.dataset.frostedBackground === 'false'")
        let disabled = try await js(view, pixels) as? [String: Any]
        XCTAssertEqual(disabled?["tint"] as? [Int], solid["tint"] as? [Int])
        _ = try await js(view, "document.querySelector('#frosted-background').click(); true")
        try await wait(view, "document.documentElement.dataset.translucentBackground === 'true'")
        window.appearance = NSAppearance(named: .aqua)
        try await wait(view, "!window.matchMedia('(prefers-color-scheme: dark)').matches")
        let lightResult = try await js(view, pixels)
        let light = try XCTUnwrap(lightResult as? [String: Any])
        XCTAssertEqual(light["bodyFill"] as? [Int], [0, 0, 0, 0])
        XCTAssertGreaterThan((light["tint"] as? [Int])?.first ?? 0, 240, "An explicitly chosen Light appearance keeps its light tint.")
        XCTAssertLessThan((light["text"] as? [Int])?.first ?? 255, 40)
        try await waitForTint(bridge, rgb: try XCTUnwrap(light["tint"] as? [Int]).prefix(3).map { Double($0) / 255 })
        window.appearance = NSAppearance(named: .darkAqua)
        try await wait(view, "window.matchMedia('(prefers-color-scheme: dark)').matches")
        let restored = try await js(view, pixels) as? [String: Any]
        XCTAssertEqual(restored?["tint"] as? [Int], tint)
        try await waitForTint(bridge, rgb: [40 / 255.0, 44 / 255.0, 52 / 255.0])
        // Reloads must restore the native capability and re-send the design token.
        view.reload()
        try await wait(view, "document.documentElement.dataset.nativeWindowBackground === 'true' && Number(document.querySelector('table[data-market-count]')?.dataset.marketCount) === 375")
        let reloaded = try await js(view, pixels) as? [String: Any]
        XCTAssertEqual(reloaded?["bodyFill"] as? [Int], [0, 0, 0, 0])
        try await waitForTint(bridge, rgb: [40 / 255.0, 44 / 255.0, 52 / 255.0])
    }

    @MainActor
    private func assertSharedSurfaces(_ view: WKWebView, opacity: Double, defaultOpacities: [Double] = [0.2, 0.3, 0.55]) async throws {
        // Wait for control color transitions; inspect the renderer rather than
        // matching generated classes or the source token formulas.
        try await Task.sleep(nanoseconds: 200_000_000)
        try await wait(view, "Array.from(document.querySelectorAll('[data-surface=\"floating\"]')).every(x => x.closest('[data-state=\"closed\"]') || !x.getBoundingClientRect().width || !x.getBoundingClientRect().height || getComputedStyle(x).opacity === '1')", seconds: 2)
        let result = try await js(view, """
        (() => {
          const canvas = document.createElement('canvas'); canvas.width = canvas.height = 1;
          const context = canvas.getContext('2d'), root = getComputedStyle(document.documentElement);
          const read = color => { context.clearRect(0,0,1,1); context.fillStyle = color; context.fillRect(0,0,1,1); return Array.from(context.getImageData(0,0,1,1).data); };
          const p = Number(root.getPropertyValue('--window-background-opacity')), issues = [];
          for (const element of document.querySelectorAll('[data-surface]')) {
            if (!(element instanceof HTMLElement) || element.closest('[data-state="closed"]') || !element.getBoundingClientRect().width || !element.getBoundingClientRect().height) continue;
            const style = getComputedStyle(element), role = element.dataset.surface;
            const filter = style.backdropFilter || style.webkitBackdropFilter || 'none';
            const radius = Number(filter.match(/blur\\(([\\d.]+)px\\)/)?.[1] ?? 0);
            const parent = element.parentElement?.closest('[data-surface="control"], [data-surface="panel"], [data-surface="floating"]');
            const nativeTable = document.documentElement.dataset.nativeWindowBackground === 'true' && element.closest('[data-slot="table-container"]');
            const inherited = role === 'inherited' || role !== 'floating' && (parent || nativeTable && role === 'control');
            const expected = p === 1 || inherited ? 0 : ({control:12,panel:16,floating:24}[role] ?? 0) * (1-p);
            if (Math.abs(radius - expected) > 0.05 || expected === 0 && filter !== 'none') issues.push(`${element.dataset.slot ?? element.tagName} ${role}: filter=${filter}, expected=${expected}`);
            if (role === 'floating' && style.transitionProperty !== 'none') issues.push(`${element.dataset.slot ?? element.tagName}: implicit material transition`);
            if (p < 1 && role !== 'inherited' && read(style.backgroundColor)[3] === 255) issues.push(`${element.dataset.slot ?? element.tagName}: opaque component paint`);
            if (style.opacity !== '1' || read(style.color)[3] !== 255) issues.push(`${element.dataset.slot ?? element.tagName}: faded content`);
            if (!style.fontVariantNumeric.includes('tabular-nums')) issues.push(`${element.dataset.slot ?? element.tagName}: non-tabular numbers`);
          }
          const input = document.querySelector('#background-opacity');
          if (input && (getComputedStyle(input).backdropFilter || getComputedStyle(input).webkitBackdropFilter) !== 'none') issues.push('Settings input must reuse its floating owner');
          const defaults = Object.fromEntries(['control','panel','floating','state-hover','state-selection','state-accent','state-secondary','state-warning','table-header','overlay'].map(role => [role, Number(root.getPropertyValue(`--${role}-default-opacity`))]));
          const checkAlpha = (label, color, baseline) => {
            const actual = read(color)[3]/255, expected = baseline*p;
            if (Math.abs(actual-expected) > 1/255) issues.push(`${label}: alpha=${actual}, expected own default ${baseline} * global weight ${p}`);
          };
          for (const [role, tokens] of Object.entries({
            control: ['control','control-hover','selection','primary-surface','primary-surface-hover','secondary','muted','accent','destructive-surface','destructive-hover','chart-annotation'],
            panel: ['card','sidebar'], floating: ['popover'],
            'state-hover': ['state-hover'], 'state-selection': ['state-selection'], 'state-accent': ['state-accent'],
            'state-secondary': ['state-secondary'], 'state-warning': ['state-warning'], 'table-header': ['table-header'], overlay: ['overlay']
          })) {
            for (const token of tokens) checkAlpha(`--${token}`, root.getPropertyValue(`--${token}`), defaults[role]);
          }
          for (const element of document.querySelectorAll('[data-slot="input"], [data-slot="textarea"], [data-slot="input-group"], [data-slot="tabs-list"][data-surface="control"], [data-slot="select-trigger"], [data-slot="table-header"], [data-slot="table-footer"], [data-slot="dialog-footer"], [data-slot="dialog-overlay"], [data-surface="floating"]')) {
            if (!element.getBoundingClientRect().width || !element.getBoundingClientRect().height) continue;
            const role = element.dataset.surface === 'floating' ? 'floating' : element.dataset.slot === 'dialog-footer' ? 'state-hover' : element.dataset.slot === 'dialog-overlay' ? 'overlay' : ['table-header','table-footer'].includes(element.dataset.slot) ? 'table-header' : 'control';
            checkAlpha(element.dataset.slot, getComputedStyle(element).backgroundColor, defaults[role]);
          }
          return { issues, opacity: p, alphas: ['--control','--card','--popover','--primary-surface','--chart-snapshot-background'].map(name => read(root.getPropertyValue(name))[3]/255), positive: read(root.getPropertyValue('--positive')), destructive: read(root.getPropertyValue('--destructive')) };
        })()
        """) as? [String: Any]
        let values = try XCTUnwrap(result)
        XCTAssertEqual(values["issues"] as? [String], [], "Surface rendering contract: \(values)")
        XCTAssertEqual(values["opacity"] as? Double, opacity)
        let alphas = try XCTUnwrap(values["alphas"] as? [Double])
        for (actual, expected) in zip(alphas, [defaultOpacities[0] * opacity, defaultOpacities[1] * opacity, defaultOpacities[2] * opacity, defaultOpacities[0] * opacity, 1]) {
            XCTAssertEqual(actual, expected, accuracy: 1 / 255.0)
        }
        XCTAssertEqual(values["destructive"] as? [Int], [232, 85, 168, 255])
        let dark = try await js(view, "window.matchMedia('(prefers-color-scheme: dark)').matches") as? Bool
        XCTAssertEqual(values["positive"] as? [Int], dark == true ? [202, 253, 92, 255] : [142, 188, 57, 255])
    }

    @MainActor
    func testAllSurfaceFamiliesAndChartCaptureInNativeWebKit() async throws {
        guard ProcessInfo.processInfo.environment["RADAR_UI_TESTS"] == "1" else { throw XCTSkip("Run npm run test:ui after building the Web renderer.") }
        if visualUI {
            guard #available(macOS 14.4, *) else { throw XCTSkip("Current-process window capture requires macOS 14.4.") }
        }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bridge = try RuleUIBridge(root: project.appendingPathComponent("dist")), configuration = uiConfiguration()
        bridge.includeChartBars = true
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "radar")
        configuration.setURLSchemeHandler(bridge, forURLScheme: "radar")
        configuration.userContentController.addUserScript(WKUserScript(source: "window.radarAppearance = { frostedBackgroundEnabled: true, frostedBackgroundOpacity: 0.3, nativeWindowBackground: true };", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let window = BackgroundTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground"); view.underPageBackgroundColor = .clear
        let background = WindowBackgroundView(contentView: view)
        bridge.windowBackground = background; window.contentView = background
        // Keep WebKit's compositor/exit animations running when terminal or
        // editor windows become active during local CI.
        present(window)
        background.apply(enabled: true, opacity: 0.3, to: window)
        defer { view.stopLoading(); window.orderOut(nil); configuration.userContentController.removeScriptMessageHandler(forName: "radar", contentWorld: .page); bridge.cleanUp() }
        view.load(URLRequest(url: URL(string: "radar://app/index.html")!))
        try await wait(view, "Number(document.querySelector('table[data-market-count]')?.dataset.marketCount) === 375 && document.documentElement.dataset.nativeWindowBackground === 'true'")

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let theme = appearance == .darkAqua ? "dark" : "light"
            window.appearance = NSAppearance(named: appearance)
            try await wait(view, "window.matchMedia('(prefers-color-scheme: dark)').matches === \(appearance == .darkAqua)")
            try await assertSharedSurfaces(view, opacity: 0.3)
            try await click(view, "Settings")
            try await wait(view, "document.querySelector('#background-opacity') !== null")
            try await assertSharedSurfaces(view, opacity: 0.3)
            try await glassScreenshots(view, window: window, project: project, name: "settings-\(theme)")
            try await dismissFloating(view)

            try await click(view, "Filters")
            try await wait(view, "document.querySelector('[data-rule-layout]') !== null")
            try await assertSharedSurfaces(view, opacity: 0.3)
            try await glassScreenshots(view, window: window, project: project, name: "filters-\(theme)")
            _ = try await js(view, "document.querySelector('[aria-label=\"Add condition\"]').click(); true")
            try await wait(view, "document.querySelector('[data-rule-library]') !== null")
            try await assertSharedSurfaces(view, opacity: 0.3)
            try await glassScreenshots(view, window: window, project: project, name: "library-\(theme)")
            if visualUI { try await assertBackdropPixels(view, project: project, theme: theme) }
            try await input(view, "[data-rule-library] [cmdk-input]", "Price")
            _ = try await js(view, "document.querySelector('[data-library-id=\"metric:price\"]').click(); true")
            try await wait(view, "document.querySelector('[data-rule-library][data-state=\"open\"]') === null")
            try await validDraft(view)
            try await assertSharedSurfaces(view, opacity: 0.3)
            let timing = try await openMenu(view, selector: "[aria-label=\"Choose Left expression\"]", popover: true)
            XCTAssertLessThan(timing, 250)
            try await assertSharedSurfaces(view, opacity: 0.3)
            try await dismissFloating(view)

            try await click(view, "Formula")
            try await assertSharedSurfaces(view, opacity: 0.3)
            try await glassScreenshots(view, window: window, project: project, name: "formula-\(theme)")
            try await click(view, "Explain markets")
            try await wait(view, "document.querySelector('[role=dialog]') !== null")
            try await assertSharedSurfaces(view, opacity: 0.3)
            try await glassScreenshots(view, window: window, project: project, name: "explanation-\(theme)")
            try await click(view, "Done")
            try await wait(view, "document.querySelector('[role=dialog]') === null")
            try await click(view, "Filters")

            _ = try await js(view, "Array.from(document.querySelectorAll('button')).find(x => x.getAttribute('aria-label')?.startsWith('View ') && x.getAttribute('aria-label').includes('opportunity details')).click(); true")
            try await wait(view, "document.querySelector('[data-slot=\"popover-content\"]')?.innerText.includes('Opportunity')")
            try await assertSharedSurfaces(view, opacity: 0.3)
            try await glassScreenshots(view, window: window, project: project, name: "opportunity-\(theme)")
            try await dismissFloating(view)
            _ = try await js(view, "document.querySelector('tbody tr[tabindex]').click(); true")
            try await wait(view, "document.querySelector('section[aria-label$=\" chart\"] svg[role=img]') !== null")
            try await assertSharedSurfaces(view, opacity: 0.3)
            try await glassScreenshots(view, window: window, project: project, name: "chart-\(theme)")
            bridge.chartSnapshotRGB = []
            try await click(view, "Copy chart")
            let deadline = Date().addingTimeInterval(2)
            while bridge.chartSnapshotRGB.isEmpty && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            XCTAssertEqual(bridge.chartSnapshotRGB, appearance == .darkAqua ? [40 / 255.0, 44 / 255.0, 52 / 255.0] : [1, 1, 1])
            let image = try await view.takeSnapshot(configuration: nil)
            let opaque = try XCTUnwrap(opaqueChartSnapshot(image, backgroundRGB: bridge.chartSnapshotRGB))
            XCTAssertEqual(NSBitmapImageRep(data: opaque.tiffRepresentation!)?.colorAt(x: 0, y: 0)?.alphaComponent, 1)
            try await click(view, "Markets")
            try await wait(view, "document.querySelector('table[data-market-count]') !== null")
            try await click(view, "Filters"); try await click(view, "Rules"); try await click(view, "Filters")
        }
    }

    @MainActor
    private func dismissFloating(_ view: WKWebView) async throws {
        _ = try await js(view, "document.querySelector('[data-slot=\"popover-content\"][data-state=\"open\"]')?.dispatchEvent(new KeyboardEvent('keydown', {key:'Escape',bubbles:true})); true")
        try await wait(view, "document.querySelector('[data-slot=\"popover-content\"][data-state=\"open\"]') === null")
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    @MainActor
    private func glassScreenshots(_ view: WKWebView, window: NSWindow, project: URL, name: String) async throws {
        for width in [1440, 720] {
            window.setContentSize(NSSize(width: width, height: 900))
            present(window)
            try await wait(view, "innerWidth === \(width)")
            try await Task.sleep(nanoseconds: 200_000_000)
            try await assertSharedSurfaces(view, opacity: 0.3)
            let overflow = try await js(view, "document.documentElement.scrollWidth > innerWidth + 1") as? Bool
            XCTAssertEqual(overflow, false)
            let squeezedLabels = try await js(view, "(() => { const scale=Number(getComputedStyle(document.documentElement).getPropertyValue('--market-list-scale')); return Array.from(document.querySelectorAll('[aria-label=\"Rule decision details\"] summary > span.flex-1')).some(x=>x.getBoundingClientRect().width < 100*scale); })()") as? Bool
            XCTAssertEqual(squeezedLabels, false, "Portaled rule details must retain readable label widths when the window scales.")
            if !visualUI && name.starts(with: "explanation-") {
                try await screenshot(view, project.appendingPathComponent(".build/ui-qa/glass-dialog-layout-\(name)-\(width).png"))
            }
            if !visualUI { continue }
            let file = project.appendingPathComponent(".build/ui-qa/glass-\(name)-\(width).png")
            let image = try await nativeRendererSnapshot(view)
            // Flatten the native window capture for portable QA artifacts.
            let resolvedRGB = try await js(view, "(() => { const c = document.createElement('canvas'); c.width = c.height = 1; const x = c.getContext('2d'); x.fillStyle = getComputedStyle(document.documentElement).getPropertyValue('--chart-snapshot-background'); x.fillRect(0,0,1,1); return Array.from(x.getImageData(0,0,1,1).data).slice(0,3).map(v=>v/255); })()") as? [Double]
            let rgb = try XCTUnwrap(resolvedRGB)
            let opaque = try XCTUnwrap(opaqueChartSnapshot(image, backgroundRGB: rgb))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: opaque.tiffRepresentation!))
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
        }
        window.setContentSize(NSSize(width: 1440, height: 900))
        try await wait(view, "innerWidth === 1440")
        try await Task.sleep(nanoseconds: 400_000_000)
    }

    @MainActor
    private func assertBackdropPixels(_ view: WKWebView, project: URL, theme: String) async throws {
        let content = try await nativeRendererSnapshot(view)
        _ = try await js(view, "(() => { const source=document.querySelector('[data-rule-library]'); window.radarOriginalFilter={source,filter:source.style.backdropFilter,webkit:source.style.webkitBackdropFilter}; source.style.backdropFilter='none'; source.style.webkitBackdropFilter='none'; return true; })()")
        try await Task.sleep(nanoseconds: 200_000_000)
        let unfilteredContent = try await nativeRendererSnapshot(view)
        _ = try await js(view, "(() => { const {source,filter,webkit}=window.radarOriginalFilter; source.style.backdropFilter=filter; source.style.webkitBackdropFilter=webkit; delete window.radarOriginalFilter; return true; })()")
        let normal = try XCTUnwrap(NSBitmapImageRep(data: content.tiffRepresentation!)), unfiltered = try XCTUnwrap(NSBitmapImageRep(data: unfilteredContent.tiffRepresentation!))
        let contentBounds = try await js(view, "document.querySelector('[data-rule-library]').getBoundingClientRect().toJSON()") as? [String: Double]
        let contentRect = try XCTUnwrap(contentBounds), contentScale = Double(normal.pixelsWide) / view.bounds.width
        var difference = 0.0, samples = 0
        for y in stride(from: contentRect["y"]! + 32, to: contentRect["bottom"]! - 32, by: 3) {
            for x in stride(from: contentRect["x"]! + 32, to: contentRect["right"]! - 32, by: 3) {
                let a = try XCTUnwrap(normal.colorAt(x: Int(x * contentScale), y: Int(y * contentScale))?.usingColorSpace(.sRGB)), b = try XCTUnwrap(unfiltered.colorAt(x: Int(x * contentScale), y: Int(y * contentScale))?.usingColorSpace(.sRGB))
                difference += abs(a.redComponent-b.redComponent) + abs(a.greenComponent-b.greenComponent) + abs(a.blueComponent-b.blueComponent); samples += 3
            }
        }
        print("Glass actual app background pixel difference \(theme): \(difference / Double(samples))")
        XCTAssertGreaterThan(difference / Double(samples), 0.002, "The floating blur must affect the real scaled app content, not just a standalone backing fixture.")
        let bounds = try await js(view, """
        (() => {
          const fixture = document.createElement('div'); fixture.id = 'glass-pixel-fixture';
          fixture.style.cssText = 'position:absolute;inset:0;z-index:49;pointer-events:none;background:repeating-linear-gradient(90deg,#000 0px,#000 4px,#fff 4px,#fff 8px)';
          const source = document.querySelector('[data-rule-library]');
          source.dataset.qaGlassTest = 'true';
          const hideContent = document.createElement('style'); hideContent.id = 'glass-pixel-style';
          hideContent.textContent = '[data-qa-glass-test] > * { visibility:hidden!important }';
          document.querySelector('[data-market-list-content]').append(fixture);
          document.body.append(hideContent);
          window.radarSurfaceFixture = { source, filter:source.style.backdropFilter, webkit:source.style.webkitBackdropFilter };
          return source.getBoundingClientRect().toJSON();
        })()
        """) as? [String: Double]
        let rect = try XCTUnwrap(bounds)
        try await Task.sleep(nanoseconds: 200_000_000)
        let image = try await nativeRendererSnapshot(view)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: image.tiffRepresentation!))
        let scaleX = Double(bitmap.pixelsWide) / view.bounds.width, scaleY = Double(bitmap.pixelsHigh) / view.bounds.height
        func contrast(_ bitmap: NSBitmapImageRep) throws -> Double {
            let values = try (24..<216).map { offset -> Double in
                let color = try XCTUnwrap(bitmap.colorAt(x: Int((rect["x"]! + Double(offset)) * scaleX), y: Int((rect["y"]! + 120) * scaleY))?.usingColorSpace(.sRGB))
                return (color.redComponent + color.greenComponent + color.blueComponent) / 3
            }
            return values.max()! - values.min()!
        }
        let blurred = try contrast(bitmap)
        _ = try await js(view, "window.radarSurfaceFixture.source.style.backdropFilter='none'; window.radarSurfaceFixture.source.style.webkitBackdropFilter='none'; true")
        try await Task.sleep(nanoseconds: 200_000_000)
        let reference = try await nativeRendererSnapshot(view)
        let referenceBitmap = try XCTUnwrap(NSBitmapImageRep(data: reference.tiffRepresentation!))
        let sharp = try contrast(referenceBitmap)
        _ = try await js(view, "(() => { const {source,filter,webkit}=window.radarSurfaceFixture; source.style.backdropFilter=filter; source.style.webkitBackdropFilter=webkit; delete source.dataset.qaGlassTest; delete window.radarSurfaceFixture; document.querySelector('#glass-pixel-fixture').remove(); document.querySelector('#glass-pixel-style').remove(); return true; })()")
        print("Glass backdrop pixel contrast \(theme): blurred=\(blurred), unfiltered=\(sharp)")
        XCTAssertGreaterThan(sharp, 0.15, "The reference must contain visible stripes with the same tint alpha.")
        XCTAssertLessThan(blurred, sharp * 0.25, "The real floating material must blur app pixels, not merely paint a translucent tint.")
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".build/ui-qa"), withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: project.appendingPathComponent(".build/ui-qa/glass-backdrop-pixels-\(theme).png"))
    }

    @MainActor
    private func nativeRendererSnapshot(_ view: WKWebView) async throws -> NSImage {
        guard #available(macOS 14.4, *), let window = view.window, let contentView = window.contentView else { throw FilterError("Native window capture is unavailable.") }
        // This API enumerates only this process's capturable windows and needs
        // no screen recording consent. WK takeSnapshot omits backdrop filters.
        let scale = window.backingScaleFactor
        let capture = try await Self.nativeWindowImage(id: CGWindowID(window.windowNumber), width: Int(window.frame.width * scale), height: Int(window.frame.height * scale))
        let rect = view.convert(view.bounds, to: contentView)
        let sx = CGFloat(capture.width) / window.frame.width, sy = CGFloat(capture.height) / window.frame.height
        let crop = CGRect(x: rect.minX * sx, y: (window.frame.height - rect.maxY) * sy, width: rect.width * sx, height: rect.height * sy)
        let image = try XCTUnwrap(capture.cropping(to: crop))
        return NSImage(cgImage: image, size: view.bounds.size)
    }

    private nonisolated static func nativeWindowImage(id: CGWindowID, width: Int, height: Int) async throws -> CGImage {
        guard #available(macOS 14.4, *) else { throw FilterError("Current-process window capture is unavailable.") }
        // Keep ScreenCaptureKit's legacy non-Sendable objects in one executor;
        // only the immutable CGImage crosses back into AppKit's main actor.
        let content = try await SCShareableContent.currentProcess
        let ownWindow = try XCTUnwrap(content.windows.first(where: { $0.windowID == id }))
        let filter = SCContentFilter(desktopIndependentWindow: ownWindow), config = SCStreamConfiguration()
        config.width = width; config.height = height
        config.ignoreShadowsSingleWindow = true; config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    @MainActor
    private func js(_ view: WKWebView, _ script: String) async throws -> Any? { try await view.evaluateJavaScript(script) }
    @MainActor
    private func waitForTint(_ bridge: RuleUIBridge, rgb: [Double]) async throws {
        let deadline = Date().addingTimeInterval(2)
        while bridge.windowTintRGB != rgb && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(bridge.windowTintRGB, rgb)
    }
    @MainActor
    private func wait(_ view: WKWebView, _ predicate: String, seconds: Double = 12) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { if try await js(view, predicate) as? Bool == true { return }; try await Task.sleep(nanoseconds: 50_000_000) }
        let body = try await js(view, "document.body.innerText") as? String ?? ""
        let diagnostics = try await js(view, "JSON.stringify({dialogs:Array.from(document.querySelectorAll('[role=dialog]')).map(x=>({state:x.dataset.state,animation:getComputedStyle(x).animationName,opacity:getComputedStyle(x).opacity,animations:x.getAnimations().map(a=>({state:a.playState,time:a.currentTime}))})),visibility:document.visibilityState,height:innerHeight,scrollY,documentHeight:document.documentElement.scrollHeight})") as? String ?? ""
        print("UI diagnostics: \(diagnostics)")
        XCTFail("UI timed out: \(predicate)\n\(body.prefix(1500))")
        throw FilterError("UI predicate failed.")
    }
    @MainActor
    private func click(_ view: WKWebView, _ label: String) async throws {
        try await wait(view, "Array.from(document.querySelectorAll('button')).some(x => (x.textContent.trim() === \(formulaQuote(label)) || x.getAttribute('aria-label') === \(formulaQuote(label))) && !x.disabled && x.getBoundingClientRect().height > 0)")
        _ = try await js(view, "(() => { const x = Array.from(document.querySelectorAll('button')).find(x => x.textContent.trim() === \(formulaQuote(label)) || x.getAttribute('aria-label') === \(formulaQuote(label))); if (!x) throw new Error('Missing button: ' + \(formulaQuote(label))); x.dispatchEvent(new MouseEvent('mousedown', {bubbles:true,button:0})); x.click(); return true; })()")
        if label == "Formula" { try await wait(view, "document.querySelector('textarea') !== null") }
        if label == "Add condition" {
            try await wait(view, "document.querySelector('[data-rule-library]') !== null")
            try await input(view, "[data-rule-library] [cmdk-input]", "Price")
            _ = try await js(view, "document.querySelector('[data-library-id=\"metric:price\"]').click(); true")
            try await wait(view, "document.querySelector('[data-rule-library]') === null && document.querySelector('[aria-label=\"Choose Left expression\"]') !== null")
        }
    }
    @MainActor
    private func input(_ view: WKWebView, _ selector: String, _ text: String, textarea: Bool = false) async throws {
        _ = try await js(view, "(() => { const x = document.querySelector(\(formulaQuote(selector))); if (!(x instanceof \(textarea ? "HTMLTextAreaElement" : "HTMLInputElement"))) throw new Error('Missing input: ' + \(formulaQuote(selector)) + '\\nInputs: ' + Array.from(document.querySelectorAll('input')).map(x => x.getAttribute('aria-label')).join(', ')); Object.getOwnPropertyDescriptor(\(textarea ? "HTMLTextAreaElement" : "HTMLInputElement").prototype, 'value').set.call(x, \(formulaQuote(text))); x.dispatchEvent(new Event('input', {bubbles:true})); return true; })()")
    }
    @MainActor
    private func screenshot(_ view: WKWebView, _ file: URL) async throws {
        try await Task.sleep(nanoseconds: 350_000_000)
        let image = try await view.takeSnapshot(configuration: nil), data = image.tiffRepresentation!, bitmap = NSBitmapImageRep(data: data)!
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])!.write(to: file)
    }

    @MainActor
    private func openMenu(_ view: WKWebView, selector: String, popover: Bool = false) async throws -> Double {
        if selector.contains("Rule type") || selector.contains("Wrap rule") {
            if try await js(view, "document.querySelector(\(formulaQuote(selector))) === null") as? Bool == true { try await click(view, "Structure & name") }
        }
        try await wait(view, "(() => { const x = document.querySelector(\(formulaQuote(selector))); return Boolean(x && !x.disabled && x.getBoundingClientRect().height > 0); })()")
        // Other overlays can still be mounted while their exit animation runs.
        // Measure the trigger's own popup rather than another overlay in DOM.
        let predicate = popover ? "document.getElementById(trigger.getAttribute('aria-controls'))" : "document.querySelector('[data-slot=\"select-content\"][data-state=\"open\"]')"
        let script = """
        const trigger = document.querySelector(\(formulaQuote(selector)));
        if (!trigger) throw new Error('Missing menu trigger');
        const start = performance.now();
        \(popover ? "trigger.click();" : "trigger.dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowDown', bubbles:true}));")
        const dispatched = performance.now() - start;
        let firstFrame = 0, animation = '', frames = 0;
        await new Promise((resolve, reject) => {
          const timeout = setTimeout(() => reject(new Error('Menu did not open: ' + \(formulaQuote(selector)) + '; trigger=' + trigger.outerHTML + '; focus=' + document.activeElement?.outerHTML?.slice(0, 400) + '; menus=' + Array.from(document.querySelectorAll('[data-slot="popover-content"], [data-slot="select-content"]')).map(x => x.outerHTML.slice(0, 500)))), 2000);
          const frame = () => { const menu = \(predicate); frames += 1;
            if (!firstFrame) firstFrame = performance.now() - start;
            if (menu) animation = getComputedStyle(menu).animationDuration;
            if (menu && menu.dataset.state === 'open' && menu.getBoundingClientRect().height > 0 && Number(getComputedStyle(menu).opacity) > 0.9) {
              requestAnimationFrame(() => { clearTimeout(timeout); resolve(); });
            } else requestAnimationFrame(frame);
          }; requestAnimationFrame(frame);
        });
        return { elapsed: performance.now() - start, dispatched, firstFrame, animation, frames };
        """
        let result = try await view.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        print("Menu \(selector) timing: \(result ?? [:])")
        return try XCTUnwrap(result?["elapsed"] as? Double)
    }

    @MainActor
    private func option(_ view: WKWebView, _ label: String) async throws {
        _ = try await js(view, "(() => { const item = Array.from(document.querySelectorAll('[data-slot=\"select-item\"]')).find(x => x.textContent.trim() === \(formulaQuote(label))); if (!item) throw new Error('Missing option'); item.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter',bubbles:true})); return true; })()")
        try await wait(view, "document.querySelector('[data-slot=\"select-content\"]') === null")
    }

    @MainActor
    private func metric(_ view: WKWebView, _ key: String) async throws -> Double {
        let latency = try await openMenu(view, selector: "[aria-label=\"Choose Left expression\"]", popover: true)
        try await input(view, "[cmdk-input]", key)
        try await wait(view, "Array.from(document.querySelectorAll('[cmdk-item]')).some(x => x.dataset.value?.endsWith(\(formulaQuote(" " + key))))")
        _ = try await js(view, "Array.from(document.querySelectorAll('[cmdk-item]')).find(x => x.dataset.value?.endsWith(\(formulaQuote(" " + key)))).click(); true")
        try await wait(view, "document.querySelector('[data-expression-field=\"Left expression\"]')?.dataset.expressionSource === \(formulaQuote(key))")
        try await wait(view, "document.querySelector('[data-slot=\"popover-content\"]') === null")
        return latency
    }

    @MainActor
    private func expression(_ view: WKWebView, field: String, choice: String) async throws {
        _ = try await openMenu(view, selector: "[aria-label=\(formulaQuote("Choose " + field))]", popover: true)
        let picker = "[data-expression-picker=\(formulaQuote(field))][data-state=\"open\"]"
        try await wait(view, "document.querySelector(\(formulaQuote(picker))) !== null")
        try await input(view, "\(picker) [cmdk-input]", choice)
        let predicate = "Array.from(document.querySelector(\(formulaQuote(picker))).querySelectorAll('[cmdk-item]')).find(x => x.dataset.functionName?.toLowerCase() === \(formulaQuote(choice.lowercased())))"
        try await wait(view, "Boolean(\(predicate))")
        _ = try await js(view, "\(predicate).click(); true")
        try await wait(view, "document.querySelector('[data-slot=\"popover-content\"]') === null")
    }

    @MainActor
    private func validDraft(_ view: WKWebView) async throws {
        try await wait(view, "Array.from(document.querySelectorAll('button')).some(x => x.textContent.trim() === 'Apply filters' && !x.disabled) && !document.body.innerText.includes('Compiling…')")
    }

    @MainActor
    private func startRuleDrag(_ view: WKWebView, source: String) async throws {
        _ = try await js(view, """
        (() => {
          const node = document.querySelector('[data-rule-outline-id="\(source)"]');
          const handle = node.querySelector('button[draggable="true"]');
          handle.scrollIntoView({block:'center'});
          const bounds = handle.getBoundingClientRect();
          window.radarRuleDragOrigin = {left:bounds.left + scrollX, top:bounds.top + scrollY, width:bounds.width, height:bounds.height};
          window.radarRuleDrag = new DataTransfer();
          handle.dispatchEvent(new DragEvent('dragstart', {bubbles:true, cancelable:true, dataTransfer:window.radarRuleDrag}));
          return true;
        })()
        """)
        try await wait(view, "getComputedStyle(document.querySelector('[data-rule-outline-id=\"\(source)\"] > [data-surface=\"panel\"]')).opacity === '0.5'")
        let sourceState = try await js(view, """
        (() => {
          const handle = document.querySelector('[data-rule-outline-id="\(source)"] button[draggable="true"]');
          const bounds = handle.getBoundingClientRect();
          const hit = document.elementFromPoint(bounds.left + bounds.width / 2, bounds.top + bounds.height / 2);
          const current = {left:bounds.left + scrollX, top:bounds.top + scrollY, width:bounds.width, height:bounds.height};
          return {interactive:!handle.disabled && !handle.closest('[inert]') && handle.contains(hit),
            stationary:Object.keys(current).every(key => Math.abs(current[key] - window.radarRuleDragOrigin[key]) < 0.5)};
        })()
        """) as? [String: Bool]
        XCTAssertEqual(sourceState?["interactive"], true, "The native drag handle must remain interactive and reachable throughout the drag.")
        XCTAssertEqual(sourceState?["stationary"], true, "Drop hints must not move the native drag source during dragstart.")
    }

    @MainActor
    private func ruleDragEvent(_ view: WKWebView, type: String, target: String, position: Double = 0.5) async throws -> Bool {
        let result = try await js(view, """
        (() => {
          const node = document.querySelector('[data-rule-outline-id="\(target)"]');
          const heading = node.querySelector(':scope > [data-surface="panel"]').firstElementChild;
          const bounds = heading.getBoundingClientRect();
          const event = new DragEvent('\(type)', {bubbles:true, cancelable:true, dataTransfer:window.radarRuleDrag,
            clientX:bounds.left + bounds.width / 2, clientY:bounds.top + bounds.height * \(position)});
          heading.dispatchEvent(event);
          return event.defaultPrevented;
        })()
        """)
        return result as? Bool == true
    }

    @MainActor
    private func ruleChildIDs(_ view: WKWebView, parent: String) async throws -> [String] {
        let result = try await js(view, """
        (() => {
          const parent = document.querySelector('[data-rule-outline-id="\(parent)"]');
          return Array.from(parent.querySelectorAll('[data-rule-outline-id]'))
            .filter(child => child.parentElement.closest('[data-rule-outline-id]') === parent).map(child => child.dataset.ruleOutlineId);
        })()
        """)
        return try XCTUnwrap(result as? [String])
    }

    @MainActor
    func testDraggingConditionsAcrossGroupCards() async throws {
        guard ProcessInfo.processInfo.environment["RADAR_UI_TESTS"] == "1" else { throw XCTSkip("Run npm run test:ui after building the Web renderer.") }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bridge = try RuleUIBridge(root: project.appendingPathComponent("dist")), configuration = uiConfiguration()
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "radar")
        configuration.setURLSchemeHandler(bridge, forURLScheme: "radar")
        let window = BackgroundTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 1100), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1440, height: 1100), configuration: configuration)
        window.contentView = view; present(window)
        defer { view.stopLoading(); window.orderOut(nil); configuration.userContentController.removeScriptMessageHandler(forName: "radar", contentWorld: .page); bridge.cleanUp() }
        view.load(URLRequest(url: URL(string: "radar://app/index.html")!))
        try await wait(view, "document.querySelector('table[data-market-count]') !== null")
        try await click(view, "Filters")
        let parentIs = { (child: String, parent: String) in "document.querySelector('[data-rule-outline-id=\"\(child)\"]').parentElement.closest('[data-rule-outline-id]').dataset.ruleOutlineId === '\(parent)'" }
        for layout in ["Sentence rows", "Guided cards"] {
            try await click(view, "Reset draft"); try await click(view, "Formula")
            try await input(view, "textarea", "all(all(Price > 100, RSI(14) > 40), any(Volume > 10, Price < 200))", textarea: true)
            try await validDraft(view); try await click(view, "Rules"); try await click(view, layout)
            let rootResult = try await js(view, "document.querySelector('[data-rule-outline-id]').dataset.ruleOutlineId")
            let root = try XCTUnwrap(rootResult as? String), groups = try await ruleChildIDs(view, parent: root)
            let origin = groups[0], target = groups[1]
            let originChildren = try await ruleChildIDs(view, parent: origin), targetChildren = try await ruleChildIDs(view, parent: target)
            let source = originChildren[0]
            // Drop onto a selected group card, including its taller guided inspector.
            _ = try await js(view, "document.querySelector('[data-rule-outline-id=\"\(target)\"] button[aria-label^=\"Edit \"]').click(); true")
            try await startRuleDrag(view, source: source)
            let accepted = try await ruleDragEvent(view, type: "dragover", target: target)
            XCTAssertTrue(accepted, layout)
            try await wait(view, "document.querySelector('[data-rule-outline-id=\"\(target)\"] > [data-filter-drop-target]') !== null")
            _ = try await ruleDragEvent(view, type: "drop", target: target)
            try await wait(view, parentIs(source, target)); try await validDraft(view)
            try await click(view, "Undo filter edit"); try await wait(view, parentIs(source, origin))
            try await click(view, "Redo filter edit"); try await wait(view, parentIs(source, target))
            // Row edges still insert before and after siblings, including the final row.
            try await startRuleDrag(view, source: source)
            _ = try await ruleDragEvent(view, type: "dragover", target: targetChildren[0], position: 0.1)
            _ = try await ruleDragEvent(view, type: "drop", target: targetChildren[0], position: 0.1)
            var ordered = try await ruleChildIDs(view, parent: target)
            XCTAssertEqual(ordered, [source] + targetChildren, layout)
            try await startRuleDrag(view, source: source)
            _ = try await ruleDragEvent(view, type: "dragover", target: targetChildren[1], position: 0.9)
            try await wait(view, "document.querySelector('[data-rule-outline-id=\"\(targetChildren[1])\"] > [data-filter-insertion-line]') !== null")
            _ = try await ruleDragEvent(view, type: "drop", target: targetChildren[1], position: 0.9)
            ordered = try await ruleChildIDs(view, parent: target)
            XCTAssertEqual(ordered, targetChildren + [source], layout)
            try await startRuleDrag(view, source: source)
            _ = try await ruleDragEvent(view, type: "dragover", target: originChildren[1], position: 0.1)
            _ = try await ruleDragEvent(view, type: "drop", target: originChildren[1], position: 0.1)
            try await wait(view, parentIs(source, origin))
            ordered = try await ruleChildIDs(view, parent: origin)
            XCTAssertEqual(ordered, originChildren, layout)
            // Collapsed groups accept the drop and reveal the moved condition.
            _ = try await js(view, "document.querySelector('[data-rule-outline-id=\"\(target)\"] button[aria-label=\"Collapse rule\"]').click(); true")
            try await wait(view, "document.querySelector('[data-rule-outline-id=\"\(target)\"]').querySelectorAll('[data-rule-outline-id]').length === 0")
            try await startRuleDrag(view, source: source)
            _ = try await ruleDragEvent(view, type: "dragover", target: target)
            _ = try await ruleDragEvent(view, type: "drop", target: target)
            try await wait(view, parentIs(source, target)); try await validDraft(view)
            try await click(view, "Undo filter edit"); try await wait(view, parentIs(source, origin))
            // A newly added empty group becomes valid once it receives a condition.
            _ = try await js(view, "document.querySelector('[data-rule-outline-id=\"\(root)\"] button[aria-label^=\"Edit \"]').click(); true")
            try await click(view, "Add group")
            let withEmpty = try await ruleChildIDs(view, parent: root), empty = try XCTUnwrap(withEmpty.last)
            try await startRuleDrag(view, source: source)
            _ = try await ruleDragEvent(view, type: "dragover", target: empty)
            _ = try await ruleDragEvent(view, type: "drop", target: empty)
            try await wait(view, parentIs(source, empty)); try await validDraft(view)
            // Invalid descendant targets clear feedback and cannot use a stale valid destination.
            try await startRuleDrag(view, source: empty)
            _ = try await ruleDragEvent(view, type: "dragover", target: target)
            try await wait(view, "document.querySelector('[data-filter-drop-target]') !== null")
            let invalid = try await ruleDragEvent(view, type: "dragover", target: source)
            XCTAssertFalse(invalid, layout)
            try await wait(view, "document.querySelector('[data-filter-drop-target], [data-filter-insertion-line]') === null")
            _ = try await ruleDragEvent(view, type: "dragover", target: target)
            try await wait(view, "document.querySelector('[data-filter-drop-target]') !== null")
            _ = try await ruleDragEvent(view, type: "drop", target: source)
            try await wait(view, parentIs(empty, root)); try await wait(view, parentIs(source, empty))
            try await wait(view, "document.querySelector('[data-filter-drop-group], [data-filter-drop-target], [data-filter-insertion-line]') === null")
            // Rejected drops add no undo revision; cancelling a drag leaves the tree unchanged.
            try await click(view, "Undo filter edit"); try await wait(view, parentIs(source, origin))
            try await click(view, "Redo filter edit"); try await wait(view, parentIs(source, empty))
            try await startRuleDrag(view, source: source)
            _ = try await ruleDragEvent(view, type: "dragover", target: target)
            _ = try await ruleDragEvent(view, type: "dragend", target: source)
            try await wait(view, "document.querySelector('[data-filter-drop-group], [data-filter-drop-target]') === null")
            try await wait(view, parentIs(source, empty)); try await validDraft(view)
            try await click(view, "Apply filters")
            try await wait(view, "document.body.innerText.includes('Filters applied and saved.')")
            let saved = try FilterConfigV2.decode(bridge.radar.marketFiltersV2JSON)
            let moved = saved.root.children.first(where: { $0.id == empty })?.children.first
            XCTAssertEqual(moved?.id, source, layout); XCTAssertEqual(moved?.left, "Price", layout); XCTAssertEqual(moved?.right, "100", layout)
        }
    }

    @MainActor
    func testVisualFunctionCoverageRelativeVolumeCountTextAndCrossingControls() async throws {
        guard ProcessInfo.processInfo.environment["RADAR_UI_TESTS"] == "1" else { throw XCTSkip("Run npm run test:ui after building the Web renderer.") }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bridge = try RuleUIBridge(root: project.appendingPathComponent("dist")), configuration = uiConfiguration()
        bridge.pulseRows = true
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "radar")
        configuration.setURLSchemeHandler(bridge, forURLScheme: "radar")
        let window = BackgroundTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 1100), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1440, height: 1100), configuration: configuration)
        window.contentView = view; present(window)
        defer { view.stopLoading(); window.orderOut(nil); configuration.userContentController.removeScriptMessageHandler(forName: "radar", contentWorld: .page); bridge.cleanUp() }
        view.load(URLRequest(url: URL(string: "radar://app/index.html")!))
        try await wait(view, "Number(document.querySelector('table[data-market-count]')?.dataset.marketCount) === 375")
        try await click(view, "Filters"); try await click(view, "Reset draft"); try await click(view, "Add condition")
        try await validDraft(view)
        // Every native metric, scalar function and arithmetic operation has a visual entry.
        _ = try await openMenu(view, selector: "[aria-label=\"Choose Left expression\"]", popover: true)
        let entryValues = try await js(view, "Array.from(document.querySelectorAll('[cmdk-item]')).map(x => x.dataset.value)") as? [String]
        let entries = try XCTUnwrap(entryValues)
        for metric in FilterCatalog.metrics { XCTAssertTrue(entries.contains { $0.hasSuffix(" " + metric.key) }, metric.key) }
        for name in ["EMA", "RSI", "ROC", "MAROC", "LogBBUpper", "LogBBMiddle", "LogBBLower", "VWAP", "PriorHigh", "PriorLow", "BreakoutAge", "BreakdownAge", "abs", "mean", "sum", "highest", "lowest", "stddev", "lag", "change", "closed", "live"] { XCTAssertTrue(entries.contains { $0.hasSuffix(" " + name) }, name) }
        XCTAssertEqual(entries.filter { $0.hasPrefix("arithmetic ") }.count, 4)
        _ = try await js(view, "document.querySelector('[data-slot=\"popover-content\"]').dispatchEvent(new KeyboardEvent('keydown', {key:'Escape',bubbles:true})); true")
        try await wait(view, "document.querySelector('[data-slot=\"popover-content\"]') === null")
        // Every scalar template compiles and exposes editable parameters.
        for name in ["EMA", "RSI", "ROC", "MAROC", "LogBBUpper", "LogBBMiddle", "LogBBLower", "VWAP", "PriorHigh", "PriorLow", "BreakoutAge", "BreakdownAge", "abs", "mean", "sum", "highest", "lowest", "stddev", "lag", "change", "closed", "live"] {
            try await expression(view, field: "Right expression", choice: name)
            try await validDraft(view)
            let parts = try await js(view, "document.querySelector('[aria-label=\"Toggle Right expression parameters\"]') !== null") as? Bool
            XCTAssertEqual(parts, true, name)
        }
        // Build Volume > mean(lag(Volume, 1), 20) * 2 entirely with visual controls.
        _ = try await metric(view, "Volume")
        _ = try await openMenu(view, selector: "[aria-label=\"Comparison\"]"); try await option(view, "Greater than >")
        try await expression(view, field: "Right expression", choice: "mean")
        try await expression(view, field: "Right expression Source expression", choice: "lag")
        try await validDraft(view)
        _ = try await openMenu(view, selector: "[aria-label=\"Transform Right expression\"]"); try await option(view, "Multiply ×")
        try await validDraft(view)
        try await input(view, "[aria-label=\"Right expression Left operand Window hours\"]", "")
        try await wait(view, "document.body.innerText.includes('Last valid preview remains active')")
        let retained = try await js(view, "document.querySelector('[data-expression-field=\"Right expression Left operand Source expression\"]')?.dataset.expressionSource") as? String
        XCTAssertEqual(retained, "lag(Volume, 1)")
        // Incomplete visual blocks survive tab changes, panel folding and chart navigation.
        try await click(view, "Formula"); try await click(view, "Rules")
        try await wait(view, "document.querySelector('[aria-label=\"Right expression Left operand Window hours\"]')?.value === '' && document.querySelector('[aria-label=\"Right expression Left operand Source expression Offset hours\"]')?.value === '1'")
        try await click(view, "Filters"); try await click(view, "Filters")
        try await wait(view, "document.querySelector('[aria-label=\"Right expression Left operand Window hours\"]')?.value === ''")
        _ = try await js(view, "document.querySelector('tbody tr[tabindex]').click(); true")
        try await wait(view, "document.body.innerText.includes('Fixture chart')")
        try await click(view, "Markets")
        try await wait(view, "document.querySelector('[aria-label=\"Right expression Left operand Window hours\"]')?.value === '' && document.querySelector('[aria-label=\"Right expression Left operand Source expression Offset hours\"]')?.value === '1'")
        try await input(view, "[aria-label=\"Right expression Left operand Window hours\"]", "20")
        try await validDraft(view)
        try await screenshot(view, project.appendingPathComponent(".build/ui-qa/visual-relative-volume.png"))
        try await click(view, "Formula")
        try await wait(view, "document.querySelector('textarea')?.value.includes('(Volume > (mean(lag(Volume, 1), 20) * 2))')")
        try await click(view, "Rules")
        try await wait(view, "document.querySelector('[aria-label=\"Right expression Left operand Source expression Offset hours\"]')?.value === '1'")
        // Existing conditions can be wrapped in counts and unwrapped without losing their expression.
        _ = try await openMenu(view, selector: "[aria-label=\"Wrap rule\"]"); try await option(view, "Occurrence count")
        try await input(view, "[aria-label=\"Window hours\"]", "48")
        try await input(view, "[aria-label=\"Count threshold\"]", "3")
        _ = try await openMenu(view, selector: "[aria-label=\"Count comparison\"]"); try await option(view, "Between (inclusive)")
        try await input(view, "[aria-label=\"Maximum count\"]", "24")
        try await validDraft(view)
        try await click(view, "Formula")
        try await wait(view, "document.querySelector('textarea')?.value.includes(', 48, \"between\", 3, 24)')")
        try await click(view, "Rules")
        _ = try await openMenu(view, selector: "[aria-label=\"Wrap rule\"]"); try await option(view, "Remove wrapper")
        try await validDraft(view)
        let source = try await js(view, "document.querySelector('[data-expression-field=\"Right expression\"]')?.dataset.expressionSource") as? String
        XCTAssertEqual(source, "(mean(lag(Volume, 1), 20) * 2)")
        // Switching from a range to a crossing removes the inactive maximum control.
        _ = try await metric(view, "Close")
        try await expression(view, field: "Right expression", choice: "EMA")
        try await wait(view, "document.querySelector('[aria-label=\"Right expression Period (h)\"]') !== null")
        try await input(view, "[aria-label=\"Right expression Period (h)\"]", "480")
        _ = try await openMenu(view, selector: "[aria-label=\"Comparison\"]"); try await option(view, "Between (inclusive)")
        _ = try await openMenu(view, selector: "[data-rule-kind=\"condition\"] [aria-label=\"Rule type\"]"); try await option(view, "Crosses above")
        try await validDraft(view)
        let crossingControls = try await js(view, "document.querySelector('[data-expression-field=\"Maximum expression\"]') === null && document.querySelector('[data-expression-field=\"Right expression\"]')?.dataset.expressionSource === 'EMA(480)'") as? Bool
        XCTAssertEqual(crossingControls, true)
        _ = try await metric(view, "oiTrend")
        try await validDraft(view)
        let risingControl = try await js(view, "document.querySelector('[aria-label=\"Right value\"]')?.textContent.includes('Rising')") as? Bool
        XCTAssertEqual(risingControl, true)
        // Arithmetic selections replace incompatible category thresholds before compilation.
        _ = try await openMenu(view, selector: "[aria-label=\"Choose Left expression\"]", popover: true)
        try await input(view, "[cmdk-input]", "arithmetic Add")
        _ = try await js(view, "Array.from(document.querySelectorAll('[cmdk-item]')).find(x => x.dataset.value === 'arithmetic Add +').click(); true")
        try await validDraft(view)
        let numericThreshold = try await js(view, "document.querySelector('[aria-label=\"Right expression\"]')?.value") as? String
        XCTAssertEqual(numericThreshold, "0")
        // Symbols use a literal text control; named categories inherit their value choices.
        _ = try await metric(view, "Symbol")
        try await input(view, "[aria-label=\"Right text value\"]", "MKT000-USDT-SWAP")
        try await validDraft(view)
        try await wait(view, "Number(document.querySelector('table[data-market-count]')?.dataset.marketCount) === 1")
        try await click(view, "Formula")
        try await input(view, "textarea", "let trend = closed(oiTrend); trend == \"rising\"", textarea: true)
        try await validDraft(view); try await click(view, "Rules")
        try await wait(view, "document.querySelector('[aria-label=\"Right value\"]')?.textContent.includes('Rising')")
        // Completion inserts a concrete template at the caret instead of invalid placeholders.
        try await click(view, "Formula")
        try await input(view, "textarea", "available()", textarea: true)
        _ = try await js(view, "document.querySelector('textarea').setSelectionRange(10,10); true")
        try await click(view, "Insert metric / function (Ctrl+Space)")
        try await wait(view, "document.querySelector('[cmdk-input]') !== null")
        try await input(view, "[cmdk-input]", "RSI(n)")
        _ = try await js(view, "Array.from(document.querySelectorAll('[cmdk-item]')).find(x => x.dataset.value === 'RSI(n)').click(); true")
        try await validDraft(view)
        try await wait(view, "document.querySelector('textarea')?.value === 'available(RSI(14))'")
        // A closed stage's condition and capture keep the same hour when visually wrapped.
        let hour = bridge.contexts[0].hour
        bridge.contexts[0].candles[hour - hourMS] = Candle(hour: hour - hourMS, high: 101, low: 99, close: 100, quoteVolume: 100, baseVolume: 1, open: 100)
        let sequence = #"sequence(2, stage("break", closed(Close == 100), 2, capture("level", Close)), stage("finish", Close > break.level, 2))"#
        try await input(view, "textarea", sequence, textarea: true)
        try await validDraft(view); try await click(view, "Rules")
        _ = try await openMenu(view, selector: "fieldset[aria-label=\"break\"] [aria-label=\"Wrap rule\"]")
        try await option(view, "AND group")
        try await validDraft(view)
        try await click(view, "Formula")
        let sequenceSource = try await js(view, "document.querySelector('textarea').value") as? String
        let sequenceFormula = try XCTUnwrap(sequenceSource)
        XCTAssertTrue(sequenceFormula.contains("closed(all("))
        let compiled = try FilterCompiler.compile(source: sequenceFormula)
        let trace = FilterEvaluator(market: bridge.contexts[0], filter: compiled).evaluate(explain: true)
        let event = try XCTUnwrap(trace.children.first)
        XCTAssertEqual(event.result, .yes)
        XCTAssertEqual(event.eventHours, [hour - hourMS, hour])
        XCTAssertEqual(event.children.first?.readings["break.level"]?.number, 100)
        try await input(view, "textarea", "let trend = closed(oiTrend); trend == \"rising\"", textarea: true)
        try await validDraft(view); try await click(view, "Rules")
        window.setContentSize(NSSize(width: 720, height: 1000))
        window.appearance = NSAppearance(named: .darkAqua)
        try await screenshot(view, project.appendingPathComponent(".build/ui-qa/visual-functions-dark-narrow.png"))
        let overflowing = try await js(view, "document.documentElement.scrollWidth > window.innerWidth + 1") as? Bool
        XCTAssertEqual(overflowing, false)
    }

    @MainActor
    func testConditionLibraryTemplatesGuidedCardsUndoBulkAndInlineReadings() async throws {
        guard ProcessInfo.processInfo.environment["RADAR_UI_TESTS"] == "1" else { throw XCTSkip("Run npm run test:ui after building the Web renderer.") }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bridge = try RuleUIBridge(root: project.appendingPathComponent("dist")), configuration = uiConfiguration()
        bridge.pulseRows = true
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "radar")
        configuration.setURLSchemeHandler(bridge, forURLScheme: "radar")
        let window = BackgroundTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 1100), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1440, height: 1100), configuration: configuration)
        window.contentView = view; present(window)
        defer { view.stopLoading(); window.orderOut(nil); configuration.userContentController.removeScriptMessageHandler(forName: "radar", contentWorld: .page); bridge.cleanUp() }
        view.load(URLRequest(url: URL(string: "radar://app/index.html")!))
        try await wait(view, "Number(document.querySelector('table[data-market-count]')?.dataset.marketCount) === 375")
        try await click(view, "Filters"); try await click(view, "Reset draft")
        let latency = try await openMenu(view, selector: "[aria-label=\"Add condition\"]", popover: true)
        try await input(view, "[data-rule-library] [cmdk-input]", "持仓趋势")
        try await wait(view, "document.querySelector('[data-library-id=\"metric:oiTrend\"]') !== null")
        _ = try await js(view, "document.querySelector('[data-library-id=\"metric:oiTrend\"]').click(); true")
        try await validDraft(view)
        try await wait(view, "Number(document.querySelector('table[data-market-count]')?.dataset.marketCount) === 167 && document.querySelector('[data-rule-preview]')?.innerText.includes('rising')")
        XCTAssertLessThan(latency, 250)
        let noFormula = try await js(view, "document.querySelector('textarea') === null") as? Bool
        XCTAssertEqual(noFormula, true)
        try await click(view, "Guided cards")
        try await wait(view, "document.querySelector('[data-rule-layout=\"guided\"] [data-expression-field=\"Left expression\"]') !== null")
        XCTAssertEqual(bridge.radar.filterLibraryPreferences.layout, "guided")
        _ = try await openMenu(view, selector: "[aria-label=\"Right value\"]"); try await option(view, "Falling")
        try await wait(view, "Number(document.querySelector('table[data-market-count]')?.dataset.marketCount) === 166")
        try await click(view, "Undo filter edit")
        try await wait(view, "document.querySelector('[aria-label=\"Right value\"]')?.textContent.includes('Rising') && Number(document.querySelector('table[data-market-count]')?.dataset.marketCount) === 167")
        try await click(view, "Redo filter edit")
        try await wait(view, "document.querySelector('[aria-label=\"Right value\"]')?.textContent.includes('Falling')")
        try await click(view, "Sentence rows")
        try await wait(view, "document.querySelector('[aria-label=\"Selected rule editor\"]') !== null")
        try await click(view, "Reset draft"); try await click(view, "Body above EMA")
        try await validDraft(view)
        try await wait(view, "document.querySelector('[aria-label=\"Body EMA period hours\"]')?.value === '200' && document.querySelector('[aria-label=\"Window hours\"]')?.value === '48'")
        try await input(view, "[aria-label=\"Body EMA period hours\"]", "")
        try await wait(view, "document.body.innerText.includes('Last valid preview remains active') && document.querySelector('[aria-label=\"Body EMA period hours\"]')?.value === ''")
        try await input(view, "[aria-label=\"Body EMA period hours\"]", "480")
        try await validDraft(view)
        try await click(view, "Formula")
        let bodyResult = try await js(view, "document.querySelector('textarea').value") as? String
        let bodyFormula = try XCTUnwrap(bodyResult)
        XCTAssertTrue(bodyFormula.contains("Open > EMA(480)")); XCTAssertTrue(bodyFormula.contains("Close > EMA(480)")); XCTAssertTrue(bodyFormula.contains(", 48)"))
        try await click(view, "Rules")
        try await wait(view, "document.querySelector('[aria-label=\"Body EMA period hours\"]')?.value === '480'")
        try await screenshot(view, project.appendingPathComponent(".build/ui-qa/sentence-body-window.png"))
        try await click(view, "Reset draft"); try await click(view, "Volume surge")
        try await validDraft(view)
        try await wait(view, "document.querySelector('[aria-label=\"Right expression Left operand Source expression Offset hours\"]')?.value === '1'")
        try await click(view, "Reset draft"); try await click(view, "Break & retest")
        try await validDraft(view)
        try await wait(view, "document.querySelector('[aria-label=\"Sequence stages\"]')?.innerText.includes('Capture: Level')")
        _ = try await js(view, "Array.from(document.querySelector('[aria-label=\"Sequence stages\"]').querySelectorAll('button')).find(x => x.textContent.includes('1.')).click(); true")
        try await input(view, "[aria-label=\"Stage name\"]", "breakout")
        _ = try await js(view, "document.querySelector('[aria-label=\"Stage name\"]').dispatchEvent(new FocusEvent('focusout', {bubbles:true})); true")
        try await validDraft(view)
        try await click(view, "Formula")
        let renamedResult = try await js(view, "document.querySelector('textarea').value") as? String
        let renamed = try XCTUnwrap(renamedResult)
        XCTAssertTrue(renamed.contains("breakout.level")); XCTAssertFalse(renamed.contains("break.level"))
        try await click(view, "Rules")
        try await click(view, "Reset draft"); try await click(view, "OI rising"); try await click(view, "OI rising")
        _ = try await js(view, "Array.from(document.querySelectorAll('[aria-label*=\"for bulk editing\"]')).forEach(x => x.click()); true")
        try await wait(view, "document.body.innerText.includes('2 selected')")
        try await click(view, "Set Closed"); try await validDraft(view)
        try await click(view, "Undo filter edit"); try await validDraft(view)
        try await click(view, "Reset draft")
        _ = try await openMenu(view, selector: "[aria-label=\"Add condition\"]", popover: true)
        try await click(view, "Favorite OI rising")
        try await wait(view, "Boolean(document.querySelector('[aria-label=\"Favorite OI rising\"][aria-pressed=\"true\"]'))")
        XCTAssertTrue(bridge.radar.filterLibraryPreferences.favorites.contains("preset:oi"))
        _ = try await js(view, "document.querySelector('[data-rule-library]').dispatchEvent(new KeyboardEvent('keydown', {key:'Escape',bubbles:true})); true")
        try await wait(view, "document.querySelector('[data-rule-library]') === null")
        window.setContentSize(NSSize(width: 720, height: 1000)); window.appearance = NSAppearance(named: .darkAqua)
        try await screenshot(view, project.appendingPathComponent(".build/ui-qa/sentence-builder-dark-narrow.png"))
        let overflow = try await js(view, "document.documentElement.scrollWidth > window.innerWidth + 1") as? Bool
        XCTAssertEqual(overflow, false)
    }

    @MainActor
    func testCategoricalMenusAndFormulaRoundTripStayResponsiveWithFiveHundredMarkets() async throws {
        guard ProcessInfo.processInfo.environment["RADAR_UI_TESTS"] == "1" else { throw XCTSkip("Run npm run test:ui after building the Web renderer.") }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bridge = try RuleUIBridge(root: project.appendingPathComponent("dist")), configuration = uiConfiguration()
        bridge.pulseRows = true
        for index in bridge.contexts.indices {
            let hour = bridge.contexts[index].hour
            bridge.contexts[index].stats[hour - 2 * hourMS] = .init(oi: 100_000_000, sell: nil, buy: nil)
            bridge.contexts[index].stats[hour - hourMS] = .init(oi: 99_000_000 + Double(index % 3) * 1_000_000, sell: nil, buy: nil)
        }
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "radar")
        configuration.setURLSchemeHandler(bridge, forURLScheme: "radar")
        let window = BackgroundTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900), configuration: configuration)
        window.contentView = view; present(window)
        defer { view.stopLoading(); window.orderOut(nil); configuration.userContentController.removeScriptMessageHandler(forName: "radar", contentWorld: .page); bridge.cleanUp() }
        view.load(URLRequest(url: URL(string: "radar://app/index.html")!))
        try await wait(view, "Number(document.querySelector('table[data-market-count]')?.dataset.marketCount) === 375")
        try await click(view, "Filters"); try await click(view, "Reset draft")
        try await wait(view, "Number(document.querySelector('table[data-market-count]')?.dataset.marketCount) === 500")
        let rendered = try await js(view, "document.querySelectorAll('tbody tr[data-market-index]').length") as? Int
        XCTAssertLessThan(try XCTUnwrap(rendered), 50, "Offscreen contracts should not delay menus.")
        _ = try await view.callAsyncJavaScript("await document.fonts.ready; await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))); window.scrollTo({top: document.documentElement.scrollHeight, behavior: 'instant'}); return true;", arguments: [:], in: nil, contentWorld: .page)
        try await wait(view, "document.querySelector('tr[data-market-index=\"499\"]') !== null")
        _ = try await js(view, "(() => { const row = document.querySelector('tr[data-market-index=\"499\"]'); row.focus(); row.dispatchEvent(new KeyboardEvent('keydown', {key:'Home',bubbles:true})); return true; })()")
        try await wait(view, "document.activeElement?.dataset.marketIndex === '0'")
        _ = try await js(view, "document.activeElement.dispatchEvent(new KeyboardEvent('keydown', {key:'End',bubbles:true})); true")
        try await wait(view, "document.activeElement?.dataset.marketIndex === '499'")
        _ = try await js(view, "document.querySelector('[aria-label=\"Search contracts\"]').focus(); window.scrollTo({top:0,behavior:'instant'}); true")
        try await wait(view, "document.querySelector('tr[data-market-index=\"0\"]') !== null")
        _ = try await js(view, "document.querySelector('tr[data-market-index=\"0\"] button[aria-label*=\"opportunity details\"]').focus(); true")
        _ = try await openMenu(view, selector: "tr[data-market-index=\"0\"] button[aria-label*=\"opportunity details\"]", popover: true)
        _ = try await js(view, "window.scrollTo({top:document.documentElement.scrollHeight,behavior:'instant'}); true")
        try await wait(view, "document.querySelector('tr[data-market-index=\"499\"]') !== null && document.querySelector('tr[data-market-index=\"0\"]') !== null && document.querySelector('[data-slot=\"popover-content\"]') !== null")
        _ = try await js(view, "document.querySelector('[data-slot=\"popover-content\"]').dispatchEvent(new KeyboardEvent('keydown', {key:'Escape',bubbles:true})); true")
        try await wait(view, "document.querySelector('[data-slot=\"popover-content\"]') === null")
        _ = try await js(view, "document.querySelector('[aria-label=\"Search contracts\"]').focus(); window.scrollTo({top:0,behavior:'instant'}); true")
        try await wait(view, "document.querySelector('tr[data-market-index=\"0\"]') !== null")
        var timings: [Double] = []
        timings.append(try await openMenu(view, selector: "[aria-label=\"Rule type\"]"))
        try await option(view, "All (AND)")
        try await click(view, "Add condition")
        // Select OI entirely by its visible name and ordinary terminology, without entering a formula.
        timings.append(try await openMenu(view, selector: "[aria-label=\"Choose Left expression\"]", popover: true))
        let metricFirst = try await js(view, "(() => { const items = Array.from(document.querySelectorAll('[cmdk-item]')); return items.findIndex(x => x.dataset.metricKey === 'oiTrend') < items.findIndex(x => x.dataset.value === 'EMA EMA'); })()") as? Bool
        XCTAssertEqual(metricFirst, true)
        try await input(view, "[cmdk-input]", "Open interest trend")
        try await wait(view, "document.querySelector('[cmdk-item][data-metric-key=\"oiTrend\"]')?.textContent.includes('OI Trend')")
        _ = try await js(view, "document.querySelector('[cmdk-item][data-metric-key=\"oiTrend\"]').click(); true")
        try await wait(view, "document.querySelector('[data-slot=\"popover-content\"]') === null")
        try await wait(view, "document.querySelector('[aria-label=\"Right value\"]')?.textContent.includes('Rising') && Number(document.querySelector('table[data-market-count]')?.dataset.marketCount) === 167")
        let visualOI = try await js(view, "document.querySelector('[aria-label=\"Choose Left expression\"]')?.textContent === 'OI Trend' && document.querySelector('[aria-label=\"Left expression\"]') === null") as? Bool
        XCTAssertEqual(visualOI, true, "A selected indicator should show its name, not require a formula input.")
        timings.append(try await openMenu(view, selector: "[aria-label=\"Comparison\"]"))
        let operators = try await js(view, "Array.from(document.querySelectorAll('[data-slot=\"select-item\"]')).map(x => x.textContent.trim())") as? [String]
        XCTAssertEqual(operators, ["Equals", "Does not equal", "Available", "Unavailable"])
        let retainedMenu = try await view.callAsyncJavaScript("""
        Array.from(document.querySelectorAll('[data-slot="select-item"]')).find(x => x.textContent.trim() === 'Equals').dispatchEvent(new KeyboardEvent('keydown', {key:'Enter',bubbles:true}));
        await new Promise(resolve => requestAnimationFrame(resolve));
        document.querySelector('[aria-label="Choose Left expression"]').click();
        await new Promise(resolve => setTimeout(resolve, 250));
        return Boolean(document.querySelector('[data-expression-picker="Left expression"][data-state="open"]')?.contains(document.activeElement));
        """, arguments: [:], in: nil, contentWorld: .page) as? Bool
        XCTAssertEqual(retainedMenu, true, "Closing the preceding select must not dismiss the next indicator menu.")
        _ = try await js(view, "document.querySelector('[data-slot=\"popover-content\"]')?.dispatchEvent(new KeyboardEvent('keydown', {key:'Escape',bubbles:true})); true")
        try await wait(view, "document.querySelector('[data-slot=\"popover-content\"]') === null")
        for (label, count) in [("Falling", 166), ("Flat", 167), ("Rising", 167)] {
            timings.append(try await openMenu(view, selector: "[aria-label=\"Right value\"]"))
            try await option(view, label)
            try await wait(view, "Number(document.querySelector('table[data-market-count]')?.dataset.marketCount) === \(count) && !document.body.innerText.includes('Compiling…')")
        }
        // Closed must use the last two completed OI readings, independently of the live direction.
        _ = try await js(view, "Array.from(document.querySelector('[data-rule-kind=\"condition\"] [aria-label=\"Evaluation hour\"]').querySelectorAll('button')).find(x => x.textContent.trim() === 'Closed').click(); true")
        try await validDraft(view)
        try await wait(view, "Number(document.querySelector('table[data-market-count]')?.dataset.marketCount) === 166")
        try await screenshot(view, project.appendingPathComponent(".build/ui-qa/oi-trend-closed.png"))
        _ = try await js(view, "Array.from(document.querySelector('[data-rule-kind=\"condition\"] [aria-label=\"Evaluation hour\"]').querySelectorAll('button')).find(x => x.textContent.trim() === 'Live').click(); true")
        try await validDraft(view)
        try await wait(view, "Number(document.querySelector('table[data-market-count]')?.dataset.marketCount) === 167")
        try await screenshot(view, project.appendingPathComponent(".build/ui-qa/oi-trend-rules.png"))
        try await click(view, "Formula")
        try await wait(view, "document.querySelector('textarea')?.value.includes('oiTrend == \"rising\"')")
        try await click(view, "Rules")
        let restored = try await js(view, "document.querySelector('[aria-label=\"Right value\"]').textContent.includes('Rising')") as? Bool
        XCTAssertEqual(restored, true)
        // Direct expression editing is optional and returning to the visual control preserves the rule.
        try await click(view, "Edit Left expression formula")
        try await wait(view, "document.activeElement?.getAttribute('aria-label') === 'Left expression'")
        try await input(view, "[aria-label=\"Left expression\"]", "oiTrend")
        try await click(view, "Use visual Left expression")
        try await wait(view, "document.querySelector('[aria-label=\"Choose Left expression\"]')?.textContent === 'OI Trend' && document.querySelector('[aria-label=\"Left expression\"]') === null")
        timings.append(try await openMenu(view, selector: "[aria-label=\"Right value\"]"))
        try await option(view, "Another indicator / value…")
        try await click(view, "Edit Right expression formula")
        try await input(view, "[aria-label=\"Right expression\"]", "emaTrend")
        try await wait(view, "Array.from(document.querySelectorAll('button')).some(x => x.textContent.trim() === 'Apply filters' && !x.disabled)")
        try await click(view, "Formula")
        try await wait(view, "document.querySelector('textarea')?.value.includes('oiTrend == emaTrend')")
        try await click(view, "Rules")
        let custom = try await js(view, "document.querySelector('[data-expression-field=\"Right expression\"]')?.dataset.expressionSource") as? String
        XCTAssertEqual(custom, "emaTrend")
        timings.append(try await openMenu(view, selector: "[aria-label=\"Right value\"]"))
        try await option(view, "Rising")
        timings.append(try await metric(view, "emaBody"))
        try await wait(view, "document.querySelector('[aria-label=\"Right value\"]')?.textContent.includes('Entire body above')")
        timings.append(try await openMenu(view, selector: "[aria-label=\"Wrap rule\"]"))
        try await option(view, "Every hour")
        try await input(view, "[aria-label=\"Window hours\"]", "48")
        try await wait(view, "Array.from(document.querySelectorAll('button')).some(x => x.textContent.trim() === 'Apply filters' && !x.disabled)")
        try await click(view, "Formula")
        try await wait(view, "document.querySelector('textarea')?.value.includes('every((emaBody == \"above\"), 48)')")
        print("500-market menu paint timings (ms): \(timings.map { Int($0) }); max=\(Int(timings.max() ?? 0))")
        XCTAssertLessThan(timings.max() ?? 0, 250, "Menus must open promptly, including their animation and first paint.")
    }

    @MainActor
    func testUnsavedFilterWarningPersistsThroughCollapseAndFailedSave() async throws {
        guard ProcessInfo.processInfo.environment["RADAR_UI_TESTS"] == "1" else { throw XCTSkip("Run npm run test:ui after building the Web renderer.") }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bridge = try RuleUIBridge(root: project.appendingPathComponent("dist")), configuration = uiConfiguration()
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "radar")
        configuration.setURLSchemeHandler(bridge, forURLScheme: "radar")
        let window = BackgroundTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900), configuration: configuration)
        window.contentView = view; present(window)
        defer { view.stopLoading(); window.orderOut(nil); configuration.userContentController.removeScriptMessageHandler(forName: "radar", contentWorld: .page); bridge.cleanUp() }
        view.load(URLRequest(url: URL(string: "radar://app/index.html")!))
        try await wait(view, "Number(document.querySelector('table[data-market-count]')?.dataset.marketCount) === 375")

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let theme = appearance == .darkAqua ? "dark" : "light"
            window.appearance = NSAppearance(named: appearance)
            try await wait(view, "window.matchMedia('(prefers-color-scheme: dark)').matches === \(appearance == .darkAqua)")
            try await wait(view, "document.querySelector('[data-filter-unsaved]') === null && document.querySelector('[data-filter-unsaved-badge]') === null")
            try await click(view, "Filters")
            try await click(view, "Formula")
            try await input(view, "textarea", "Close > 0", textarea: true)
            try await validDraft(view)
            try await wait(view, "document.querySelector('[data-filter-unsaved]')?.textContent.includes('Apply filters to save them') && document.querySelector('[data-filter-unsaved-badge]')?.textContent.includes('Unsaved changes')")
            let accessible = try await js(view, "document.querySelector('[data-filter-unsaved]')?.getAttribute('role') === 'status' && document.querySelector('[data-filter-unsaved]')?.getAttribute('aria-live') === 'polite'") as? Bool
            XCTAssertEqual(accessible, true)
            try await assertSharedSurfaces(view, opacity: 0.3)
            try await screenshot(view, project.appendingPathComponent(".build/ui-qa/filters-unsaved-expanded-\(theme).png"))
            try await click(view, "Filters")
            try await wait(view, "document.querySelector('textarea') === null && document.querySelector('[data-filter-unsaved] button')?.disabled === false")
            try await screenshot(view, project.appendingPathComponent(".build/ui-qa/filters-unsaved-collapsed-\(theme).png"))
            window.setContentSize(NSSize(width: 720, height: 900))
            try await wait(view, "window.innerWidth === 720")
            let fits = try await js(view, """
            (() => {
              const alert = document.querySelector('[data-filter-unsaved]').getBoundingClientRect();
              const description = document.querySelector('[data-filter-unsaved] [data-slot=alert-description]').getBoundingClientRect();
              const action = document.querySelector('[data-filter-unsaved] button').getBoundingClientRect();
              return document.documentElement.scrollWidth <= window.innerWidth + 1 && description.right < action.left && action.right <= alert.right && action.bottom <= alert.bottom;
            })()
            """) as? Bool
            XCTAssertEqual(fits, true, "The unsaved warning and save action must fit the scaled native layout.")
            try await screenshot(view, project.appendingPathComponent(".build/ui-qa/filters-unsaved-narrow-\(theme).png"))
            window.setContentSize(NSSize(width: 1440, height: 900))
            try await wait(view, "window.innerWidth === 1440")

            let saved = bridge.radar.marketFiltersJSON, revision = bridge.revision
            bridge.filterSaveDelay = 400_000_000
            bridge.filterSaveError = "Filter save failed. Try again."
            try await click(view, "Apply filters")
            try await wait(view, "document.querySelector('[data-filter-unsaved]')?.getAttribute('aria-busy') === 'true' && document.querySelector('[data-filter-unsaved] button')?.disabled === true")
            try await wait(view, "Array.from(document.querySelectorAll('[role=alert]')).some(x => x.textContent.includes('Filter save failed. Try again.')) && document.querySelector('[data-filter-unsaved] button')?.disabled === false")
            XCTAssertEqual(bridge.radar.marketFiltersJSON, saved)
            XCTAssertEqual(bridge.revision, revision)
            try await screenshot(view, project.appendingPathComponent(".build/ui-qa/filters-unsaved-failure-\(theme).png"))
            bridge.filterSaveDelay = 0; bridge.filterSaveError = nil
            try await click(view, "Apply filters")
            try await wait(view, "document.querySelector('[data-filter-unsaved]') === null && document.querySelector('[data-filter-unsaved-badge]') === null && document.body.innerText.includes('Filters applied and saved.')")
            XCTAssertEqual(bridge.revision, revision + 1)
            try await wait(view, "Number(document.querySelector('table[data-market-count]')?.dataset.marketCount) === 500")

            try await click(view, "Filters")
            try await input(view, "textarea", "Close >", textarea: true)
            try await wait(view, "document.querySelector('[data-filter-unsaved]')?.textContent.includes('Fix the rule errors') && document.querySelector('[data-filter-unsaved] button')?.disabled === true")
            try await click(view, "Discard changes")
            try await wait(view, "document.querySelector('[data-filter-unsaved]') === null && document.querySelector('[data-filter-unsaved-badge]') === null && Number(document.querySelector('table[data-market-count]')?.dataset.marketCount) === 500")
            try await click(view, "Filters")
        }
    }

    @MainActor
    func testNativeRulesFormulaDraftRecoveryExplanationsAndLargeMarketResponsiveness() async throws {
        guard ProcessInfo.processInfo.environment["RADAR_UI_TESTS"] == "1" else { throw XCTSkip("Run npm run test:ui after building the Web renderer.") }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bridge = try RuleUIBridge(root: project.appendingPathComponent("dist")), configuration = uiConfiguration()
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "radar")
        configuration.setURLSchemeHandler(bridge, forURLScheme: "radar")
        let window = BackgroundTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900), configuration: configuration)
        window.contentView = view; window.appearance = NSAppearance(named: .aqua); present(window)
        defer { view.stopLoading(); window.orderOut(nil); configuration.userContentController.removeScriptMessageHandler(forName: "radar", contentWorld: .page); bridge.cleanUp() }
        view.load(URLRequest(url: URL(string: "radar://app/index.html")!))
        try await wait(view, "Number(document.querySelector('table[data-market-count]')?.dataset.marketCount) === 375")
        try await wait(view, "document.querySelector('[data-filter-summary] [data-slot=\"collapsible-trigger\"]')?.getAttribute('aria-expanded') === 'false' && document.querySelector('[aria-label=\"Combination name\"]') === null && document.querySelector('[data-filter-rules]')?.textContent.includes('24h turnover')")
        try await screenshot(view, project.appendingPathComponent(".build/ui-qa/markets-light.png"))
        try await click(view, "Filters")
        try await wait(view, "document.querySelector('[aria-label=\"Combination name\"]') !== null")
        try await input(view, "[aria-label=\"Combination name\"]", "Unsaved draft")
        try await click(view, "Formula")
        try await input(view, "textarea", "let relativeVolume = Volume / mean(lag(Volume, 1), 20); relativeVolume > 2", textarea: true)
        try await wait(view, "Number(document.querySelector('table[data-market-count]')?.dataset.marketCount) === 500 && Array.from(document.querySelectorAll('button')).some(x => x.textContent.trim() === 'Apply filters' && !x.disabled)")
        try await click(view, "Save combination")
        try await wait(view, "document.body.innerText.includes('Combination saved')")
        try await wait(view, "document.querySelector('[data-filter-unsaved]') !== null")
        XCTAssertEqual(bridge.radar.marketFilterCombinations.count, 1)
        try await click(view, "Filters")
        try await wait(view, "document.querySelector('[data-filter-name]')?.textContent === 'Unsaved draft' && document.querySelector('[data-filter-count]')?.textContent === '1 condition' && document.querySelector('[data-filter-rules]')?.textContent.includes('Relative Volume > 2') && document.querySelector('[aria-label=\"Combination name\"]') === null")
        try await screenshot(view, project.appendingPathComponent(".build/ui-qa/filters-collapsed-light.png"))
        try await click(view, "Filters")
        try await input(view, "[aria-label=\"Combination name\"]", "Draft name not saved")
        try await click(view, "Rules")
        try await wait(view, "Array.from(document.querySelectorAll('[data-expression-field=\"Left expression\"]')).some(x => x.dataset.expressionSource === 'relativeVolume')")
        try await screenshot(view, project.appendingPathComponent(".build/ui-qa/rules-light.png"))
        try await click(view, "Formula")
        try await input(view, "textarea", "Close >", textarea: true)
        try await wait(view, "document.body.innerText.includes('Last valid preview remains active')")
        try await wait(view, "document.querySelector('[data-filter-name]')?.textContent === 'Unsaved draft' && document.querySelector('[data-filter-rules]')?.textContent.includes('Relative Volume > 2')")
        let retained = try await js(view, "Number(document.querySelector('table[data-market-count]')?.dataset.marketCount)") as? Int
        XCTAssertEqual(retained, 500)
        let disabled = try await js(view, "Array.from(document.querySelectorAll('button')).filter(x => ['Apply filters','Save combination'].includes(x.textContent.trim())).every(x => x.disabled)") as? Bool
        XCTAssertEqual(disabled, true)
        // Chart navigation and panel unmounting must preserve invalid source and combination name.
        _ = try await js(view, "document.querySelector('tbody tr[tabindex]').click(); true")
        try await wait(view, "document.body.innerText.includes('Fixture chart')")
        try await click(view, "Markets")
        try await wait(view, "document.querySelector('textarea')?.value === 'Close >'")
        let name = try await js(view, "document.querySelector('[aria-label=\"Combination name\"]').value") as? String
        XCTAssertEqual(name, "Draft name not saved")
        try await click(view, "Filters"); try await click(view, "Filters")
        try await wait(view, "document.querySelector('textarea')?.value === 'Close >'")
        // A slow old draft response must not overwrite a later valid preview.
        bridge.previewDelay = 800_000_000
        try await input(view, "textarea", "Close > 200", textarea: true)
        try await Task.sleep(nanoseconds: 250_000_000)
        bridge.previewDelay = 0
        try await input(view, "textarea", "Close > 0", textarea: true)
        try await wait(view, "Number(document.querySelector('table[data-market-count]')?.dataset.marketCount) === 500 && !document.body.innerText.includes('Compiling…')")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let count = try await js(view, "Number(document.querySelector('table[data-market-count]')?.dataset.marketCount)") as? Int
        XCTAssertEqual(count, 500)
        try await click(view, "Apply filters")
        try await wait(view, "document.body.innerText.includes('Filters applied and saved')")
        try await wait(view, "document.querySelector('[data-filter-name]')?.textContent === 'Custom filters' && document.querySelector('[data-filter-rules]')?.textContent === 'Candle close > 0'")
        try await input(view, "textarea", "closed(spread > 0)", textarea: true)
        try await wait(view, "document.body.innerText.includes('500 Unknown')")
        try await click(view, "Explain markets")
        try await wait(view, "document.querySelector('[aria-label=\"Rule decision details\"]')?.innerText.includes('Spread has no quote snapshot')")
        try await screenshot(view, project.appendingPathComponent(".build/ui-qa/explanation-light.png"))
        try await click(view, "Done")
        try await wait(view, "document.querySelector('[role=\"dialog\"]') === null")
        try await input(view, "textarea", "Close > 0", textarea: true)
        try await wait(view, "Number(document.querySelector('table[data-market-count]')?.dataset.marketCount) === 500")
        // The real scaling container must retain its design layout at narrow native widths.
        window.setContentSize(NSSize(width: 720, height: 900))
        window.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(nanoseconds: 200_000_000)
        let overflow = try await js(view, "document.documentElement.scrollWidth > window.innerWidth + 1") as? Bool
        XCTAssertEqual(overflow, false)
        try await screenshot(view, project.appendingPathComponent(".build/ui-qa/formula-dark-narrow.png"))
        let start = Date()
        try await input(view, "[aria-label=\"Search contracts\"]", "MKT499")
        try await wait(view, "Number(document.querySelector('table[data-market-count]')?.dataset.marketCount) === 1", seconds: 2)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "Typing search must remain responsive with 500 contracts.")
    }
}
