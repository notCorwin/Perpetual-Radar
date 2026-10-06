import AppKit
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, WKScriptMessageHandlerWithReply, WKNavigationDelegate, WKURLSchemeHandler {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var windowBackground: WindowBackgroundView!
    private let monitorClient = MonitorClient()
    private var frostedBackgroundEnabled = MonitorRuntime.defaults.object(forKey: "LastWindowFrostedEnabled") as? Bool ?? true
    private var frostedBackgroundOpacity = MonitorRuntime.defaults.object(forKey: "LastWindowFrostedOpacity") as? Double ?? 0.3
    private var pendingNotificationInstId: String?
    private var filterPreviewTask: Task<Void, Never>?
    private var filterExplainTask: Task<Void, Never>?
    private var startupError = ""
    private var webRoot: URL?
    private lazy var checkUpdatesItem = NSMenuItem(title: "Check for Updates", action: #selector(checkForUpdatesNow), keyEquivalent: "")
    private lazy var automaticUpdatesItem = NSMenuItem(title: "Automatically Install Updates", action: #selector(toggleAutomaticUpdates), keyEquivalent: "")
    private let appearanceMenu = NSMenu(title: "Appearance")
    private nonisolated static let automaticUpdatesKey = "AutomaticallyInstallUpdates"

    nonisolated static func automaticUpdatesEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: automaticUpdatesKey) as? Bool ?? true
    }

    nonisolated static func preferredAppearance(in defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: "appearance") ?? "dark"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launchInBackground = ProcessInfo.processInfo.environment["PERPETUAL_RADAR_BACKGROUND"] == "1"
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
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
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
        configureBackgroundScript(in: configuration.userContentController)
        configuration.setURLSchemeHandler(self, forURLScheme: "radar")
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Perpetual Radar"
        window.isReleasedWhenClosed = false
        applyAppearance(Self.preferredAppearance())
        window.minSize = NSSize(width: 400, height: 300)
        windowBackground = WindowBackgroundView(contentView: webView)
        window.contentView = windowBackground
        window.delegate = self
        applyWindowBackground()
        window.center()
        if !launchInBackground { window.makeKeyAndOrderFront(nil) }
        updateRelaunchPresentation()
        applyWindowBackground()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(resumeAfterWake),
                                                        name: NSWorkspace.didWakeNotification, object: nil)

        DistributedNotificationCenter.default().addObserver(self, selector: #selector(quitInterface), name: MonitorRuntime.quitUI, object: nil)
        Task {
            do {
                try await monitorClient.ensureRunning()
                let info = try await monitorClient.request(["serviceInfo": true])
                let settings = try await monitorClient.request(["notificationAction": !launchInBackground && info["notificationsEnabled"] as? Bool == true ? "requestPermission" : "refresh"])
                acceptNativeSettings(settings)
                MonitorRuntime.markReady()
            } catch { startupError = error.localizedDescription }
        }

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
        if !launchInBackground { NSApp.activate(ignoringOtherApps: true) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        filterPreviewTask?.cancel(); filterExplainTask?.cancel()
        MonitorRuntime.defaults.set(true, forKey: AppUpdater.backgroundRelaunchKey)
    }

    @objc private func quitInterface() { NSApp.terminate(nil) }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let id = RadarNotificationRoute.contract(in: url) else { continue }
            pendingNotificationInstId = id
            showWindow(); openNotificationContract()
        }
    }

    private func acceptNativeSettings(_ snapshot: [String: Any]) {
        if let enabled = snapshot["frostedBackgroundEnabled"] as? Bool, let opacity = snapshot["frostedBackgroundOpacity"] as? Double {
            frostedBackgroundEnabled = enabled; frostedBackgroundOpacity = opacity
            MonitorRuntime.defaults.set(enabled, forKey: "LastWindowFrostedEnabled")
            MonitorRuntime.defaults.set(opacity, forKey: "LastWindowFrostedOpacity")
            applyWindowBackground(); configureBackgroundScript(in: webView.configuration.userContentController)
        }
        if let title = snapshot["updateMenuTitle"] as? String { checkUpdatesItem.title = title }
        if let enabled = snapshot["updateMenuEnabled"] as? Bool { checkUpdatesItem.isEnabled = enabled }
        if let enabled = snapshot["automaticUpdatesEnabled"] as? Bool { automaticUpdatesItem.state = enabled ? .on : .off }
    }

    @objc private func showWindow() {
        guard let window else { return }
        NSApp.setActivationPolicy(.regular)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        updateRelaunchPresentation()
        applyWindowBackground()
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        MonitorRuntime.defaults.set(true, forKey: AppUpdater.backgroundRelaunchKey)
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { if let info = try? await monitorClient.request(["serviceInfo": true]) { acceptNativeSettings(info) } }
    }

    private func updateRelaunchPresentation() {
        guard let window else { return }
        MonitorRuntime.defaults.set(!window.isVisible || window.isMiniaturized || NSApp.isHidden, forKey: AppUpdater.backgroundRelaunchKey)
    }

    func windowDidMiniaturize(_ notification: Notification) { updateRelaunchPresentation() }
    func windowDidDeminiaturize(_ notification: Notification) { updateRelaunchPresentation() }
    func applicationDidHide(_ notification: Notification) { updateRelaunchPresentation() }
    func applicationDidUnhide(_ notification: Notification) { updateRelaunchPresentation() }

    private func openNotificationContract() {
        guard let id = pendingNotificationInstId, let webView, !webView.isLoading else { return }
        pendingNotificationInstId = nil
        webView.callAsyncJavaScript("window.radarNotificationContract = instId; window.dispatchEvent(new Event('radar-open-contract'));",
            arguments: ["instId": id], in: nil, in: .page, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { openNotificationContract() }

    @objc private func resumeAfterWake(_ notification: Notification) {
        applyWindowBackground()
        webView.reload()
    }

    func windowDidBecomeKey(_ notification: Notification) { applyWindowBackground() }
    func windowDidEnterFullScreen(_ notification: Notification) { applyWindowBackground() }
    func windowDidExitFullScreen(_ notification: Notification) { applyWindowBackground() }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    func menuWillOpen(_ menu: NSMenu) {
        Task { if let info = try? await monitorClient.request(["serviceInfo": true]) { acceptNativeSettings(info) } }
    }

    @objc private func changeAppearance(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        UserDefaults.standard.set(value, forKey: "appearance")
        applyAppearance(value)
    }

    private func applyAppearance(_ value: String) {
        window.appearance = value == "light" ? NSAppearance(named: .aqua) : value == "dark" ? NSAppearance(named: .darkAqua) : nil
        for item in appearanceMenu.items { item.state = (item.representedObject as? String == value) ? .on : .off }
    }

    private func configureBackgroundScript(in controller: WKUserContentController) {
        let enabled = frostedBackgroundEnabled
        let opacity = frostedBackgroundOpacity
        // Keep the document-start settings current for wake and WebKit process reloads.
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(
            source: "window.radarAppearance = { frostedBackgroundEnabled: \(enabled), frostedBackgroundOpacity: \(opacity), nativeWindowBackground: true };",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    private func applyWindowBackground() {
        windowBackground.apply(enabled: frostedBackgroundEnabled, opacity: frostedBackgroundOpacity, to: window)
    }

    @objc private func checkForUpdatesNow() { sendUpdateAction("check") }
    @objc private func toggleAutomaticUpdates() { sendUpdateAction("toggleAutomatic") }
    private func sendUpdateAction(_ action: String) {
        Task {
            do { acceptNativeSettings(try await monitorClient.request(["updateAction": action])) }
            catch {
                let alert = NSAlert(); alert.messageText = "Cannot Reach Background Monitor"
                alert.informativeText = error.localizedDescription; alert.runModal()
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let parameters = message.body as? [String: Any] else { replyHandler(nil, "Invalid request"); return }
        if let requested = parameters["windowTintRGB"] {
            guard let rgb = requested as? [Double], windowBackground.setTint(rgb: rgb) else { replyHandler(nil, "Invalid window tint"); return }
            replyHandler(["ok": true], nil)
            return
        }
        if let bounds = parameters["captureChart"] as? [String: Any] {
            guard let x = bounds["x"] as? Double, x.isFinite,
                  let y = bounds["y"] as? Double, y.isFinite,
                  let width = bounds["width"] as? Double, width.isFinite, width > 0,
                  let height = bounds["height"] as? Double, height.isFinite, height > 0,
                  let backgroundRGB = bounds["backgroundRGB"] as? [Double], backgroundRGB.count == 3,
                  backgroundRGB.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
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
                guard let image = opaqueChartSnapshot(image, backgroundRGB: backgroundRGB) else {
                    replyHandler(nil, "Could not prepare chart screenshot"); return
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
        let requestTask = Task {
            do {
                let result = try await monitorClient.request(parameters)
                try Task.checkCancellation()
                acceptNativeSettings(result)
                replyHandler(result, nil)
            } catch { replyHandler(nil, error.localizedDescription) }
        }
        if parameters["previewMarketFilters"] != nil { filterPreviewTask?.cancel(); filterPreviewTask = requestTask }
        if parameters["explainMarketFilters"] != nil { filterExplainTask?.cancel(); filterExplainTask = requestTask }
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

let application = NSApplication.shared
application.setActivationPolicy(MonitorRuntime.isHelper || ProcessInfo.processInfo.environment["PERPETUAL_RADAR_BACKGROUND"] == "1" ? .accessory : .regular)
let delegate: any NSApplicationDelegate = MonitorRuntime.isHelper ? MonitorDelegate() : AppDelegate()
application.delegate = delegate
application.run()
