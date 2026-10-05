import AppKit
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, WKScriptMessageHandlerWithReply, WKNavigationDelegate, WKURLSchemeHandler {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var radar: Radar?
    private var startupError = ""
    private var webRoot: URL?
    private let updater = AppUpdater()
    private var updateTimer: Timer?
    private var updateState = "idle"
    private var update: AppUpdate?
    private var isCheckingUpdate = false
    private var isInstallingUpdate = false
    private var isPresentingUpdate = false
    private var automaticInstallRetryAfter: Date?
    private lazy var checkUpdatesItem = NSMenuItem(title: "Check for Updates", action: #selector(checkForUpdatesNow), keyEquivalent: "")
    private lazy var automaticUpdatesItem = NSMenuItem(title: "Automatically Install Updates", action: #selector(toggleAutomaticUpdates), keyEquivalent: "")
    private let appearanceMenu = NSMenu(title: "Appearance")
    private nonisolated static let automaticUpdatesKey = "AutomaticallyInstallUpdates"

    nonisolated static func automaticUpdatesEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: automaticUpdatesKey) as? Bool ?? true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["PERPETUAL_RADAR_UPDATE_ROLLBACK"] == "1" {
            automaticInstallRetryAfter = Date().addingTimeInterval(5 * 60)
        }
        if let path = ProcessInfo.processInfo.environment["PERPETUAL_RADAR_PID_FILE"], !path.isEmpty {
            FileManager.default.createFile(atPath: path, contents: Data(String(ProcessInfo.processInfo.processIdentifier).utf8))
        }
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) { NSApp.applicationIconImage = icon }
        let menu = NSMenu()
        let application = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.delegate = self
        checkUpdatesItem.target = self
        appMenu.addItem(checkUpdatesItem)
        automaticUpdatesItem.target = self
        automaticUpdatesItem.state = Self.automaticUpdatesEnabled() ? .on : .off
        appMenu.addItem(automaticUpdatesItem)
        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        for (title, value) in [("System", "system"), ("Light", "light"), ("Dark", "dark")] {
            let item = NSMenuItem(title: title, action: #selector(changeAppearance(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            appearanceMenu.addItem(item)
        }
        appearanceItem.submenu = appearanceMenu
        appMenu.addItem(appearanceItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Perpetual Radar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        application.submenu = appMenu; menu.addItem(application)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu; menu.addItem(windowItem)
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowMenu

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "radar")
        configuration.setURLSchemeHandler(self, forURLScheme: "radar")
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Perpetual Radar"
        applyAppearance(UserDefaults.standard.string(forKey: "appearance") ?? "system")
        window.minSize = NSSize(width: 400, height: 300)
        window.contentView = webView
        window.center(); window.makeKeyAndOrderFront(nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(resumeAfterWake),
                                                        name: NSWorkspace.didWakeNotification, object: nil)

        do {
            radar = try Radar()
            radar?.start()
        } catch { startupError = "Cannot open local cache: \(error.localizedDescription)" }

        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Web/index.html")
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/index.html")
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) {
            webRoot = bundled.deletingLastPathComponent()
            webView.load(URLRequest(url: URL(string: "radar://app/index.html")!))
        } else if FileManager.default.fileExists(atPath: development.path) {
            webRoot = development.deletingLastPathComponent()
            webView.load(URLRequest(url: URL(string: "radar://app/index.html")!))
        } else {
            let message = "Build the interface with npm run build, then launch the app again."
            webView.loadHTMLString("<html><body style='font:14px system-ui;padding:40px'>\(message)</body></html>", baseURL: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        if let path = ProcessInfo.processInfo.environment["PERPETUAL_RADAR_READY_FILE"], !path.isEmpty {
            FileManager.default.createFile(atPath: path, contents: Data())
        }
        let timer = Timer(timeInterval: 15, target: self,
                          selector: #selector(checkForUpdatesAutomatically), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        updateTimer?.invalidate()
        updater.cancel()
    }

    @objc private func resumeAfterWake(_ notification: Notification) {
        radar?.resumeAfterWake()
        webView.reload()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    func menuWillOpen(_ menu: NSMenu) { renderUpdateItem() }

    @objc private func changeAppearance(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        UserDefaults.standard.set(value, forKey: "appearance")
        applyAppearance(value)
    }

    private func applyAppearance(_ value: String) {
        window.appearance = value == "light" ? NSAppearance(named: .aqua) : value == "dark" ? NSAppearance(named: .darkAqua) : nil
        for item in appearanceMenu.items { item.state = (item.representedObject as? String == value) ? .on : .off }
    }

    @objc private func checkForUpdatesNow() {
        if updateState == "available", let update { presentUpdate(update) }
        else { checkForUpdates(silently: false) }
    }
    @objc private func checkForUpdatesAutomatically() { checkForUpdates(silently: true) }

    @objc private func toggleAutomaticUpdates() {
        let enabled = !Self.automaticUpdatesEnabled()
        UserDefaults.standard.set(enabled, forKey: Self.automaticUpdatesKey)
        automaticUpdatesItem.state = enabled ? .on : .off
        if enabled, updateState == "available", let update,
           !isInstallingUpdate, !isPresentingUpdate {
            installUpdate(update, automatically: true)
        }
    }

    private func renderUpdateItem() {
        if updateState == "available", let update {
            let revision = update.revision == "unknown" ? "" : " · \(update.revision.prefix(7))"
            let age: String
            if let publishedAt = update.publishedAt {
                let formatter = RelativeDateTimeFormatter()
                formatter.locale = Locale(identifier: "en_US")
                formatter.unitsStyle = .abbreviated
                age = " · \(formatter.localizedString(for: publishedAt, relativeTo: Date()))"
            } else { age = "" }
            checkUpdatesItem.title = "Update Available\(revision)\(age)"
        } else {
            checkUpdatesItem.title = updateState == "installing" ? "Installing Update…" : "Check for Updates"
        }
        checkUpdatesItem.isEnabled = !isCheckingUpdate && !isInstallingUpdate
    }

    private func checkForUpdates(silently: Bool) {
        guard !isCheckingUpdate, !isInstallingUpdate, !isPresentingUpdate else { return }
        isCheckingUpdate = true
        updateState = "checking"
        renderUpdateItem()
        updater.check { [weak self] result in
            guard let self else { return }
            isCheckingUpdate = false
            switch result {
            case .success(let found):
                update = found
                updateState = found == nil ? "latest" : "available"
                if let found {
                    if Self.automaticUpdatesEnabled(),
                       automaticInstallRetryAfter.map({ $0 <= Date() }) ?? true {
                        installUpdate(found, automatically: true)
                    } else if !silently {
                        presentUpdate(found)
                    }
                } else if !silently {
                    showUpdateAlert("Up to Date", "You have the latest version of Perpetual Radar.")
                }
            case .failure(let error):
                updateState = update == nil ? "failed" : "available"
                if !silently { showUpdateAlert("Update Check Failed", error.localizedDescription) }
            }
            renderUpdateItem()
        }
    }

    private func presentUpdate(_ update: AppUpdate) {
        guard !isInstallingUpdate, !isPresentingUpdate else { return }
        isPresentingUpdate = true
        let alert = NSAlert()
        alert.messageText = "Update Available"
        let revision = update.revision == "unknown" ? "" : " (\(update.revision.prefix(7)))"
        alert.informativeText = "\(update.name)\(revision) is available. Download and install it now?"
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Later")
        let shouldInstall = alert.runModal() == .alertFirstButtonReturn
        isPresentingUpdate = false
        guard shouldInstall else { return }
        installUpdate(update, automatically: false)
    }

    private func installUpdate(_ update: AppUpdate, automatically: Bool) {
        guard !isInstallingUpdate else { return }
        isInstallingUpdate = true
        updateState = "installing"
        renderUpdateItem()
        updater.downloadAndInstall(update) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                NSApp.terminate(nil)
            case .failure(let error):
                isInstallingUpdate = false
                updateState = "available"
                if automatically { automaticInstallRetryAfter = Date().addingTimeInterval(5 * 60) }
                renderUpdateItem()
                if !automatically { showUpdateAlert("Update Failed", error.localizedDescription) }
            }
        }
    }

    private func showUpdateAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let parameters = message.body as? [String: Any] else { replyHandler(nil, "Invalid request"); return }
        if let bounds = parameters["captureChart"] as? [String: Any] {
            guard let x = bounds["x"] as? Double, x.isFinite,
                  let y = bounds["y"] as? Double, y.isFinite,
                  let width = bounds["width"] as? Double, width.isFinite, width > 0,
                  let height = bounds["height"] as? Double, height.isFinite, height > 0 else {
                replyHandler(nil, "Invalid chart bounds"); return
            }
            let rect = CGRect(x: x, y: y, width: width, height: height).intersection(webView.bounds)
            guard !rect.isNull, rect.width > 0, rect.height > 0 else {
                replyHandler(nil, "Chart is outside the window"); return
            }
            let configuration = WKSnapshotConfiguration()
            configuration.rect = rect
            configuration.afterScreenUpdates = true
            webView.takeSnapshot(with: configuration) { image, error in
                guard let image else {
                    replyHandler(nil, error?.localizedDescription ?? "Could not capture chart screenshot"); return
                }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                guard pasteboard.writeObjects([image]) else {
                    replyHandler(nil, "Could not copy chart screenshot"); return
                }
                replyHandler(["ok": true], nil)
            }
            return
        }
        if let id = parameters["chartInstId"] as? String {
            guard let radar else { replyHandler(["bars": [], "error": startupError, "revision": -1], nil); return }
            if let endHour = parameters["chartEndHour"] as? Int64 {
                Task { replyHandler(await radar.loadHistoricalChart(id, endingAt: endHour), nil) }
            } else if parameters["loadChart"] as? Bool == true {
                Task { replyHandler(await radar.loadChart(id), nil) }
            } else { replyHandler(radar.chartSnapshot(id, sinceRevision: parameters["sinceRevision"] as? Int), nil) }
            return
        }
        if let requested = parameters["minimum24hTurnoverUSDT"] {
            guard let threshold = requested as? Int, radar?.setMinimum24hTurnoverUSDT(threshold) == true else {
                replyHandler(nil, "Invalid 24h turnover threshold"); return
            }
        }
        if let requested = parameters["spreadFilterEnabled"] {
            guard let enabled = requested as? Bool, let radar else {
                replyHandler(nil, "Invalid spread filter setting"); return
            }
            radar.setSpreadFilterEnabled(enabled)
        }
        if let requested = parameters["maximumSpreadPercent"] {
            guard let maximum = requested as? Double, radar?.setMaximumSpreadPercent(maximum) == true else {
                replyHandler(nil, "Maximum spread must be between 0 and 100%"); return
            }
        }
        if let requested = parameters["contractAgeFilterEnabled"] {
            guard let enabled = requested as? Bool, let radar else {
                replyHandler(nil, "Invalid contract age filter setting"); return
            }
            radar.setContractAgeFilterEnabled(enabled)
        }
        if let requested = parameters["minimumContractAgeMonths"] {
            guard let minimum = requested as? Int, radar?.setMinimumContractAgeMonths(minimum) == true else {
                replyHandler(nil, "Minimum contract age must be a whole number from 1 to 1200 months"); return
            }
        }
        if let requested = parameters["marketFiltersJSON"] {
            guard let filters = requested as? String, let radar else {
                replyHandler(nil, "Invalid market filter configuration"); return
            }
            do {
                guard try radar.setMarketFiltersJSON(filters) else {
                    replyHandler(nil, "Invalid market filter configuration"); return
                }
            } catch {
                replyHandler(nil, "Cannot save filters: \(error.localizedDescription)"); return
            }
        }
        if let requested = parameters["saveMarketFilterCombination"] {
            guard let request = requested as? [String: Any], let name = request["name"] as? String,
                  let filters = request["filtersJSON"] as? String, let radar else {
                replyHandler(nil, "Invalid filter combination"); return
            }
            do {
                guard try radar.saveMarketFilterCombination(name: name, filtersJSON: filters) else {
                    replyHandler(nil, "Use a name from 1 to 80 characters and valid filter conditions"); return
                }
            } catch {
                replyHandler(nil, "Cannot save combination: \(error.localizedDescription)"); return
            }
        }
        if let requested = parameters["selectedMarketFilterCombinationID"] {
            guard let id = requested as? String, let radar else {
                replyHandler(nil, "Invalid filter combination selection"); return
            }
            do {
                guard try radar.setSelectedMarketFilterCombinationID(id) else {
                    replyHandler(nil, "The saved combination no longer exists"); return
                }
            } catch {
                replyHandler(nil, "Cannot remember combination: \(error.localizedDescription)"); return
            }
        }
        if let requested = parameters["deleteMarketFilterCombination"] {
            guard let id = requested as? String, let radar else {
                replyHandler(nil, "Invalid filter combination"); return
            }
            do {
                guard try radar.deleteMarketFilterCombination(id) else {
                    replyHandler(nil, "The saved combination no longer exists"); return
                }
            } catch {
                replyHandler(nil, "Cannot delete combination: \(error.localizedDescription)"); return
            }
        }
        if !startupError.isEmpty {
            replyHandler(["rows": [], "updatedAt": NSNull(), "error": startupError, "revision": -1,
                          "minimum24hTurnoverUSDT": radar?.minimum24hTurnoverUSDT ?? 10_000_000,
                          "spreadFilterEnabled": radar?.spreadFilterEnabled ?? true,
                          "maximumSpreadPercent": radar?.maximumSpreadPercent ?? 0.15,
                          "contractAgeFilterEnabled": radar?.contractAgeFilterEnabled ?? true,
                          "minimumContractAgeMonths": radar?.minimumContractAgeMonths ?? defaultMinimumContractAgeMonths,
                          "marketFiltersJSON": radar?.marketFiltersJSON ?? "{\"version\":1,\"match\":\"all\",\"rules\":[]}",
                          "marketFilterCombinations": radar?.marketFilterCombinations.map(\.snapshot) ?? [],
                          "selectedMarketFilterCombinationID": radar?.selectedMarketFilterCombinationID ?? ""], nil)
            return
        }
        let roc = parameters["rocPeriod"] as? Int ?? 9
        let maroc = parameters["marocPeriod"] as? Int ?? 9
        replyHandler(radar?.snapshot(rocPeriod: roc, marocPeriod: maroc,
                                     sinceRevision: parameters["sinceRevision"] as? Int), nil)
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let root = webRoot, let url = task.request.url, url.host == "app",
              !url.path.contains("..") else {
            task.didFailWithError(NSError(domain: "PerpetualRadar", code: 404)); return
        }
        let file = root.appendingPathComponent(String(url.path.dropFirst()))
        guard file.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"),
              let data = try? Data(contentsOf: file) else {
            task.didFailWithError(NSError(domain: "PerpetualRadar", code: 404)); return
        }
        let mime: String
        switch file.pathExtension {
        case "html": mime = "text/html"
        case "js": mime = "text/javascript"
        case "css": mime = "text/css"
        case "woff": mime = "font/woff"
        case "woff2": mime = "font/woff2"
        case "ttf": mime = "font/ttf"
        default: mime = "application/octet-stream"
        }
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: mime.hasPrefix("text/") ? "utf-8" : nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, url.scheme == "https" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate = AppDelegate()
application.delegate = delegate
application.run()
