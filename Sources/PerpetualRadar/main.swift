import AppKit
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandlerWithReply, WKNavigationDelegate, WKURLSchemeHandler {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var radar: Radar?
    private var startupError = ""
    private var webRoot: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let application = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Perpetual Radar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        application.submenu = appMenu; menu.addItem(application)
        NSApp.mainMenu = menu

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
        window.minSize = NSSize(width: 900, height: 540)
        window.contentView = webView
        window.center(); window.makeKeyAndOrderFront(nil)

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
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let parameters = message.body as? [String: Any] else { replyHandler(nil, "Invalid request"); return }
        if let width = parameters["fitWidth"] as? Double, width.isFinite, width > 0 {
            let requested = CGFloat(width)
            let available = (window.screen ?? NSScreen.main)?.visibleFrame.width ?? requested
            let target = min(ceil(requested), available)
            if let content = window.contentView, target > content.bounds.width + 1 {
                let center = window.frame.midX
                window.setContentSize(NSSize(width: target, height: content.bounds.height))
                var frame = window.frame
                let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? frame
                frame.origin.x = max(visible.minX, min(center - frame.width / 2, visible.maxX - frame.width))
                window.setFrame(frame, display: true)
            }
            replyHandler(["ok": true], nil)
            return
        }
        if !startupError.isEmpty { replyHandler(["rows": [], "updatedAt": NSNull(), "error": startupError], nil); return }
        let roc = parameters["rocPeriod"] as? Int ?? 9
        let maroc = parameters["marocPeriod"] as? Int ?? 9
        replyHandler(radar?.snapshot(rocPeriod: roc, marocPeriod: maroc), nil)
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
