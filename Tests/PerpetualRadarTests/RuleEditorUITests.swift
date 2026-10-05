import AppKit
import WebKit
import XCTest
@testable import PerpetualRadar

// Exercises the actual packaged-origin WebKit renderer and promise bridge with
// native compile/evaluation/persistence and a deterministic 500-market feed.
@MainActor
private final class RuleUIBridge: NSObject, WKScriptMessageHandlerWithReply, WKURLSchemeHandler {
    let root: URL
    let radar: Radar
    let suite: String
    let directory: URL
    var revision = 1
    var rows: [[String: Any]]
    var contexts: [FilterMarketData]
    var previewDelay: UInt64 = 0
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
            generated.append(row)
            data.append(.init(id: id, hour: hour, now: hour + hourMS / 2, listedAt: hour - 3 * 365 * 24 * hourMS, candles: candles, stats: [:], quotes: [:], current: LegacyFilterReadings.from(row), previousEMA: 100))
        }
        rows = generated; contexts = data
        super.init()
    }
    func cleanUp() { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
    func snapshot() -> [String: Any] { var result = radar.snapshot(rocPeriod: 9, marocPeriod: 9); result["rows"] = rows; result["revision"] = revision; return result }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        let request = message.body as! [String: Any]
        if let compile = request["compileMarketFilters"] as? [String: Any] { replyHandler(radar.compileMarketFilters(compile), nil); return }
        if let preview = request["previewMarketFilters"] as? [String: String] {
            let original = snapshot(), source = preview["filtersJSON"]!, token = preview["token"]!, delay = previewDelay
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
        if request["chartInstId"] != nil { replyHandler(["bars": [], "revision": revision, "error": "Fixture chart"], nil); return }
        do {
            if let json = request["marketFiltersJSON"] as? String { _ = try radar.setMarketFiltersJSON(json); revision += 1 }
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
    @MainActor
    private func js(_ view: WKWebView, _ script: String) async throws -> Any? { try await view.evaluateJavaScript(script) }
    @MainActor
    private func wait(_ view: WKWebView, _ predicate: String, seconds: Double = 12) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { if try await js(view, predicate) as? Bool == true { return }; try await Task.sleep(nanoseconds: 50_000_000) }
        let body = try await js(view, "document.body.innerText") as? String ?? ""
        XCTFail("UI timed out: \(predicate)\n\(body.prefix(1500))")
        throw FilterError("UI predicate failed.")
    }
    @MainActor
    private func click(_ view: WKWebView, _ label: String) async throws {
        _ = try await js(view, "(() => { const x = Array.from(document.querySelectorAll('button')).find(x => x.textContent.trim() === \(formulaQuote(label))); x?.dispatchEvent(new MouseEvent('mousedown', {bubbles:true,button:0})); x?.click(); return true; })()")
        if label == "Formula" { try await wait(view, "document.querySelector('textarea') !== null") }
    }
    @MainActor
    private func input(_ view: WKWebView, _ selector: String, _ text: String, textarea: Bool = false) async throws {
        _ = try await js(view, "(() => { const x = document.querySelector(\(formulaQuote(selector))); Object.getOwnPropertyDescriptor(\(textarea ? "HTMLTextAreaElement" : "HTMLInputElement").prototype, 'value').set.call(x, \(formulaQuote(text))); x.dispatchEvent(new Event('input', {bubbles:true})); return true; })()")
    }
    @MainActor
    private func screenshot(_ view: WKWebView, _ file: URL) async throws {
        try await Task.sleep(nanoseconds: 350_000_000)
        let image = try await view.takeSnapshot(configuration: nil), data = image.tiffRepresentation!, bitmap = NSBitmapImageRep(data: data)!
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bitmap.representation(using: .png, properties: [:])!.write(to: file)
    }

    @MainActor
    func testNativeRulesFormulaDraftRecoveryExplanationsAndLargeMarketResponsiveness() async throws {
        guard ProcessInfo.processInfo.environment["RADAR_UI_TESTS"] == "1" else { throw XCTSkip("Run npm run test:ui after building the Web renderer.") }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bridge = try RuleUIBridge(root: project.appendingPathComponent("dist")), configuration = WKWebViewConfiguration()
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "radar")
        configuration.setURLSchemeHandler(bridge, forURLScheme: "radar")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900), configuration: configuration)
        window.contentView = view; window.appearance = NSAppearance(named: .aqua); window.orderFront(nil)
        defer { view.stopLoading(); window.orderOut(nil); configuration.userContentController.removeScriptMessageHandler(forName: "radar", contentWorld: .page); bridge.cleanUp() }
        view.load(URLRequest(url: URL(string: "radar://app/index.html")!))
        try await wait(view, "document.querySelectorAll('tbody tr[tabindex]').length === 375")
        try await screenshot(view, project.appendingPathComponent(".build/ui-qa/markets-light.png"))
        try await click(view, "Filters")
        try await wait(view, "document.querySelector('[aria-label=\"Combination name\"]') !== null")
        try await input(view, "[aria-label=\"Combination name\"]", "Unsaved draft")
        try await click(view, "Formula")
        try await input(view, "textarea", "let relativeVolume = Volume / mean(lag(Volume, 1), 20); relativeVolume > 2", textarea: true)
        try await wait(view, "document.querySelectorAll('tbody tr[tabindex]').length === 500 && Array.from(document.querySelectorAll('button')).some(x => x.textContent.trim() === 'Apply filters' && !x.disabled)")
        try await click(view, "Save combination")
        try await wait(view, "document.body.innerText.includes('Combination saved')")
        XCTAssertEqual(bridge.radar.marketFilterCombinations.count, 1)
        try await input(view, "[aria-label=\"Combination name\"]", "Draft name not saved")
        try await click(view, "Rules")
        try await wait(view, "Array.from(document.querySelectorAll('[aria-label=\"Left expression\"]')).some(x => x.value === 'relativeVolume')")
        try await screenshot(view, project.appendingPathComponent(".build/ui-qa/rules-light.png"))
        try await click(view, "Formula")
        try await input(view, "textarea", "Close >", textarea: true)
        try await wait(view, "document.body.innerText.includes('Last valid preview remains active')")
        let retained = try await js(view, "document.querySelectorAll('tbody tr[tabindex]').length") as? Int
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
        try await wait(view, "document.querySelectorAll('tbody tr[tabindex]').length === 500 && !document.body.innerText.includes('Compiling…')")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let count = try await js(view, "document.querySelectorAll('tbody tr[tabindex]').length") as? Int
        XCTAssertEqual(count, 500)
        try await click(view, "Apply filters")
        try await wait(view, "document.body.innerText.includes('Filters applied and saved')")
        try await input(view, "textarea", "closed(spread > 0)", textarea: true)
        try await wait(view, "document.body.innerText.includes('500 Unknown')")
        try await click(view, "Explain markets")
        try await wait(view, "document.querySelector('[aria-label=\"Rule decision details\"]')?.innerText.includes('Spread has no quote snapshot')")
        try await screenshot(view, project.appendingPathComponent(".build/ui-qa/explanation-light.png"))
        try await click(view, "Done")
        try await wait(view, "document.querySelector('[role=\"dialog\"]') === null")
        try await input(view, "textarea", "Close > 0", textarea: true)
        try await wait(view, "document.querySelectorAll('tbody tr[tabindex]').length === 500")
        // The real scaling container must retain its design layout at narrow native widths.
        window.setContentSize(NSSize(width: 720, height: 900))
        window.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(nanoseconds: 200_000_000)
        let overflow = try await js(view, "document.documentElement.scrollWidth > window.innerWidth + 1") as? Bool
        XCTAssertEqual(overflow, false)
        try await screenshot(view, project.appendingPathComponent(".build/ui-qa/formula-dark-narrow.png"))
        let start = Date()
        try await input(view, "[aria-label=\"Search contracts\"]", "MKT499")
        try await wait(view, "document.querySelectorAll('tbody tr[tabindex]').length === 1", seconds: 2)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "Typing search must remain responsive with 500 contracts.")
    }
}
