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
    var pulseRows = false
    var pulse = 0.0
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
    func cleanUp() { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
    func snapshot() -> [String: Any] { var result = radar.snapshot(rocPeriod: 9, marocPeriod: 9); result["rows"] = rows; result["revision"] = revision; return result }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        let request = message.body as! [String: Any]
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
        let predicate = popover ? "document.querySelector('[data-slot=\"popover-content\"][data-state=\"open\"]')" : "document.querySelector('[data-slot=\"select-content\"][data-state=\"open\"]')"
        let script = """
        const trigger = document.querySelector(\(formulaQuote(selector)));
        if (!trigger) throw new Error('Missing menu trigger');
        const start = performance.now();
        \(popover ? "trigger.click();" : "trigger.dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowDown', bubbles:true}));")
        const dispatched = performance.now() - start;
        let firstFrame = 0, animation = '', frames = 0;
        await new Promise((resolve, reject) => {
          const timeout = setTimeout(() => reject(new Error('Menu did not open')), 2000);
          const frame = () => { const menu = \(predicate); frames += 1;
            if (!firstFrame) firstFrame = performance.now() - start;
            if (menu) animation = getComputedStyle(menu).animationDuration;
            if (menu && menu.getBoundingClientRect().height > 0 && Number(getComputedStyle(menu).opacity) > 0.9) {
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
        try await wait(view, "document.querySelector('[aria-label=\"Left expression\"]')?.value === \(formulaQuote(key))")
        try await wait(view, "document.querySelector('[data-slot=\"popover-content\"]') === null")
        return latency
    }

    @MainActor
    private func expression(_ view: WKWebView, field: String, choice: String) async throws {
        _ = try await openMenu(view, selector: "[aria-label=\(formulaQuote("Choose " + field))]", popover: true)
        let picker = "[data-expression-picker=\(formulaQuote(field))][data-state=\"open\"]"
        try await wait(view, "document.querySelector(\(formulaQuote(picker))) !== null")
        try await input(view, "\(picker) [cmdk-input]", choice)
        let predicate = "Array.from(document.querySelector(\(formulaQuote(picker))).querySelectorAll('[cmdk-item]')).find(x => x.dataset.value?.toLowerCase().endsWith(\(formulaQuote(" " + choice.lowercased()))))"
        try await wait(view, "Boolean(\(predicate))")
        _ = try await js(view, "\(predicate).click(); true")
        try await wait(view, "document.querySelector('[data-slot=\"popover-content\"]') === null")
    }

    @MainActor
    private func validDraft(_ view: WKWebView) async throws {
        try await wait(view, "Array.from(document.querySelectorAll('button')).some(x => x.textContent.trim() === 'Apply filters' && !x.disabled) && !document.body.innerText.includes('Compiling…')")
    }

    @MainActor
    func testVisualFunctionCoverageRelativeVolumeCountTextAndCrossingControls() async throws {
        guard ProcessInfo.processInfo.environment["RADAR_UI_TESTS"] == "1" else { throw XCTSkip("Run npm run test:ui after building the Web renderer.") }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bridge = try RuleUIBridge(root: project.appendingPathComponent("dist")), configuration = WKWebViewConfiguration()
        bridge.pulseRows = true
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "radar")
        configuration.setURLSchemeHandler(bridge, forURLScheme: "radar")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 1100), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1440, height: 1100), configuration: configuration)
        window.contentView = view; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
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
        let retained = try await js(view, "document.querySelector('[aria-label=\"Right expression Left operand Source expression\"]')?.value") as? String
        XCTAssertEqual(retained, "lag(Volume, 1)")
        try await input(view, "[aria-label=\"Right expression Left operand Window hours\"]", "20")
        try await validDraft(view)
        try await screenshot(view, project.appendingPathComponent(".build/ui-qa/visual-relative-volume.png"))
        try await click(view, "Formula")
        try await wait(view, "document.querySelector('textarea')?.value.includes('(Volume > (mean(lag(Volume, 1), 20) * 2))')")
        try await click(view, "Rules")
        try await wait(view, "document.querySelector('[aria-label=\"Right expression Left operand Source expression Offset hours\"]')?.value === '1'")
        // Existing conditions can be wrapped in counts and unwrapped without losing their expression.
        _ = try await openMenu(view, selector: "[data-rule-kind=\"condition\"] [aria-label=\"Wrap rule\"]"); try await option(view, "Occurrence count")
        try await input(view, "[aria-label=\"Window hours\"]", "48")
        try await input(view, "[aria-label=\"Count threshold\"]", "3")
        _ = try await openMenu(view, selector: "[aria-label=\"Count comparison\"]"); try await option(view, "Between (inclusive)")
        try await input(view, "[aria-label=\"Maximum count\"]", "24")
        try await validDraft(view)
        try await click(view, "Formula")
        try await wait(view, "document.querySelector('textarea')?.value.includes(', 48, \"between\", 3, 24)')")
        try await click(view, "Rules")
        _ = try await openMenu(view, selector: "[data-rule-kind=\"count\"] [aria-label=\"Wrap rule\"]"); try await option(view, "Remove wrapper")
        try await validDraft(view)
        let source = try await js(view, "document.querySelector('[aria-label=\"Right expression\"]')?.value") as? String
        XCTAssertEqual(source, "(mean(lag(Volume, 1), 20) * 2)")
        // Switching from a range to a crossing removes the inactive maximum control.
        _ = try await metric(view, "Close")
        try await expression(view, field: "Right expression", choice: "EMA")
        try await wait(view, "document.querySelector('[aria-label=\"Right expression Period (h)\"]') !== null")
        try await input(view, "[aria-label=\"Right expression Period (h)\"]", "480")
        _ = try await openMenu(view, selector: "[aria-label=\"Comparison\"]"); try await option(view, "Between (inclusive)")
        _ = try await openMenu(view, selector: "[data-rule-kind=\"condition\"] [aria-label=\"Rule type\"]"); try await option(view, "Crosses above")
        try await validDraft(view)
        let crossingControls = try await js(view, "document.querySelector('[aria-label=\"Maximum expression\"]') === null && document.querySelector('[aria-label=\"Right expression\"]')?.value === 'EMA(480)'") as? Bool
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
        _ = try await openMenu(view, selector: "[data-rule-kind=\"sequence\"] fieldset[aria-label=\"break\"] [aria-label=\"Wrap rule\"]")
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
    func testCategoricalMenusAndFormulaRoundTripStayResponsiveWithFiveHundredMarkets() async throws {
        guard ProcessInfo.processInfo.environment["RADAR_UI_TESTS"] == "1" else { throw XCTSkip("Run npm run test:ui after building the Web renderer.") }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bridge = try RuleUIBridge(root: project.appendingPathComponent("dist")), configuration = WKWebViewConfiguration()
        bridge.pulseRows = true
        configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "radar")
        configuration.setURLSchemeHandler(bridge, forURLScheme: "radar")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1440, height: 900), configuration: configuration)
        window.contentView = view; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        defer { view.stopLoading(); window.orderOut(nil); configuration.userContentController.removeScriptMessageHandler(forName: "radar", contentWorld: .page); bridge.cleanUp() }
        view.load(URLRequest(url: URL(string: "radar://app/index.html")!))
        try await wait(view, "Number(document.querySelector('table[data-market-count]')?.dataset.marketCount) === 375")
        try await click(view, "Filters"); try await click(view, "Reset draft")
        try await wait(view, "Number(document.querySelector('table[data-market-count]')?.dataset.marketCount) === 500")
        let rendered = try await js(view, "document.querySelectorAll('tbody tr[data-market-index]').length") as? Int
        XCTAssertLessThan(try XCTUnwrap(rendered), 50, "Offscreen contracts should not delay menus.")
        _ = try await js(view, "window.scrollTo({top: document.documentElement.scrollHeight, behavior: 'instant'}); true")
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
        timings.append(try await metric(view, "oiTrend"))
        try await wait(view, "document.querySelector('[aria-label=\"Right value\"]')?.textContent.includes('Rising') && Number(document.querySelector('table[data-market-count]')?.dataset.marketCount) === 167")
        timings.append(try await openMenu(view, selector: "[aria-label=\"Comparison\"]"))
        let operators = try await js(view, "Array.from(document.querySelectorAll('[data-slot=\"select-item\"]')).map(x => x.textContent.trim())") as? [String]
        XCTAssertEqual(operators, ["Equals", "Does not equal", "Available", "Unavailable"])
        try await option(view, "Equals")
        for (label, count) in [("Falling", 166), ("Flat", 167), ("Rising", 167)] {
            timings.append(try await openMenu(view, selector: "[aria-label=\"Right value\"]"))
            try await option(view, label)
            try await wait(view, "Number(document.querySelector('table[data-market-count]')?.dataset.marketCount) === \(count) && !document.body.innerText.includes('Compiling…')")
        }
        try await screenshot(view, project.appendingPathComponent(".build/ui-qa/oi-trend-rules.png"))
        try await click(view, "Formula")
        try await wait(view, "document.querySelector('textarea')?.value.includes('oiTrend == \"rising\"')")
        try await click(view, "Rules")
        let restored = try await js(view, "document.querySelector('[aria-label=\"Right value\"]').textContent.includes('Rising')") as? Bool
        XCTAssertEqual(restored, true)
        timings.append(try await openMenu(view, selector: "[aria-label=\"Right value\"]"))
        try await option(view, "Custom expression…")
        try await input(view, "[aria-label=\"Right expression\"]", "emaTrend")
        try await wait(view, "Array.from(document.querySelectorAll('button')).some(x => x.textContent.trim() === 'Apply filters' && !x.disabled)")
        try await click(view, "Formula")
        try await wait(view, "document.querySelector('textarea')?.value.includes('oiTrend == emaTrend')")
        try await click(view, "Rules")
        let custom = try await js(view, "document.querySelector('[aria-label=\"Right expression\"]').value") as? String
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
        try await wait(view, "Number(document.querySelector('table[data-market-count]')?.dataset.marketCount) === 375")
        try await screenshot(view, project.appendingPathComponent(".build/ui-qa/markets-light.png"))
        try await click(view, "Filters")
        try await wait(view, "document.querySelector('[aria-label=\"Combination name\"]') !== null")
        try await input(view, "[aria-label=\"Combination name\"]", "Unsaved draft")
        try await click(view, "Formula")
        try await input(view, "textarea", "let relativeVolume = Volume / mean(lag(Volume, 1), 20); relativeVolume > 2", textarea: true)
        try await wait(view, "Number(document.querySelector('table[data-market-count]')?.dataset.marketCount) === 500 && Array.from(document.querySelectorAll('button')).some(x => x.textContent.trim() === 'Apply filters' && !x.disabled)")
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
