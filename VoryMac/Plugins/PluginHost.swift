import AppKit
import SwiftUI
import VoryCore
import WebKit

/// Hermes Desktop's disk plugins (`~/.hermes/desktop-plugins/<id>/plugin.js`), run by the Desktop's
/// own plugin SDK in one long-lived web view (the `PluginHost` bundle, built from the Desktop's
/// source: see `PluginHost/README.md`). The plugins' pages show in the sidebar under Plugins and
/// open in place of the chat. Their REST calls come back here and go out through this app's
/// signed-in client, so they work with any sign-in the app has (token, password, browser).
@MainActor @Observable
final class PluginHost {
    static let shared = PluginHost()

    struct Page: Identifiable, Hashable {
        let id: String
        var title: String
        var symbol: String
        var path: String
        var order: Double
    }

    /// The plugins' pages, for the sidebar.
    private(set) var pages: [Page] = []
    /// The plugin page in front, if any (over the chats and the app's pages).
    var selected: Page.ID?
    /// Why there are no plugin pages, when it is worth saying.
    private(set) var problem: String?

    /// The built bundle in the app's Resources (CI puts it there); without it, no plugins.
    static var bundleRoot: URL? {
        guard let r = Bundle.main.resourceURL?.appendingPathComponent("PluginHost", isDirectory: true),
              FileManager.default.fileExists(atPath: r.appendingPathComponent("index.html").path) else { return nil }
        return r
    }

    /// The real home folder, not a sandbox container's.
    static var pluginsDir: URL {
        var home = NSHomeDirectory()
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { home = String(cString: dir) }
        return URL(fileURLWithPath: home).appendingPathComponent(".hermes/desktop-plugins", isDirectory: true)
    }

    private(set) var webView: WKWebView?
    @ObservationIgnored private weak var runtime: GatewayRuntime?
    @ObservationIgnored private var gatewayBase = ""
    @ObservationIgnored private var started = false
    @ObservationIgnored private var mountedPath: String?

    /// Starts (or restarts) the host for the gateway in use.
    func attach(_ runtime: GatewayRuntime?) {
        guard runtime !== self.runtime else { return }
        self.runtime = runtime
        started = false
        mountedPath = nil
        pages = []
        selected = nil
        guard let runtime, let root = Self.bundleRoot else {
            webView = nil
            if runtime != nil { problem = "This build has no plugin host." }
            return
        }
        let plugins = Self.diskPlugins()
        guard !plugins.isEmpty else { webView = nil; problem = nil; return }
        let web = webView ?? makeWebView(root: root)
        webView = web
        Task { await start(runtime: runtime, plugins: plugins, in: web) }
    }

    /// Shows a plugin page.
    func open(_ page: Page) {
        selected = page.id
        mount(page.path)
    }

    private func mount(_ path: String) {
        guard started, mountedPath != path, let webView else { return }
        mountedPath = path
        webView.evaluateJavaScript("window.VibePluginHost.mount({kind:'route',path:\(Self.js(path))})")
    }

    // MARK: Setup

    private static func diskPlugins() -> [[String: Any]] {
        let dir = pluginsDir
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return ids.sorted().compactMap { id in
            let file = dir.appendingPathComponent(id).appendingPathComponent("plugin.js")
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            return ["id": id, "source": source, "file": file.path]
        }
    }

    private func makeWebView(root: URL) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(BundleScheme(root: root), forURLScheme: BundleScheme.scheme)
        let content = config.userContentController
        content.add(MessageRelay(host: self), name: "vibe")
        // Smoke over the window's aurora, as the rest of the app, not the Desktop's flat black.
        let css = """
        html,body,#root{background:transparent!important}
        .bg-background{background-color:rgba(12,14,30,.38)!important}
        """
        content.addUserScript(WKUserScript(
            source: "(()=>{const s=document.createElement('style');s.textContent=\(Self.js(css));document.documentElement.appendChild(s)})()",
            injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.underPageBackgroundColor = .clear
        #if DEBUG
        web.isInspectable = true
        #endif
        return web
    }

    @ObservationIgnored private var loaded: CheckedContinuation<Void, Never>?

    private func start(runtime: GatewayRuntime, plugins: [[String: Any]], in web: WKWebView) async {
        let signer = await runtime.api.signer
        gatewayBase = await runtime.api.gateway.base.absoluteString
        while gatewayBase.hasSuffix("/") { gatewayBase.removeLast() }
        if web.url == nil {
            await withCheckedContinuation { c in
                loaded = c
                web.load(URLRequest(url: URL(string: "\(BundleScheme.scheme)://host/index.html")!))
            }
        }
        guard runtime === self.runtime else { return }
        let bearer = signer.authMode.usesBearer
        let options: [String: Any] = [
            "gatewayUrl": gatewayBase,
            "token": (bearer ? signer.bearer : signer.sessionToken) ?? "",
            "profile": runtime.selectedProfile ?? "default",
            "auth": bearer ? "bearer" : "session-token",
            "transport": "native",
            "inPageToasts": true,
            "plugins": plugins,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: options),
              let text = String(data: json, encoding: .utf8) else { return }
        do {
            let result = try await web.callAsyncJavaScript(
                "return await window.VibePluginHost.start(\(text))", contentWorld: .page)
            started = true
            problem = nil
            if let r = result as? [String: Any], let list = r["plugins"] as? [[String: Any]] {
                let failed = list.filter { ($0["ok"] as? Bool) == false }.compactMap { $0["id"] as? String }
                if !failed.isEmpty { problem = "Didn't load: " + failed.joined(separator: ", ") }
            }
            await refreshPages()
        } catch {
            problem = "Plugins didn't start: \(error.localizedDescription)"
        }
    }

    private func refreshPages() async {
        guard let webView,
              let r = try? await webView.callAsyncJavaScript("return window.VibePluginHost.listContributions()", contentWorld: .page) as? [String: Any]
        else { return }
        let nav = (r["sidebarNav"] as? [[String: Any]]) ?? []
        let routes = (r["routes"] as? [[String: Any]]) ?? []
        let source = nav.isEmpty ? routes : nav
        var seen = Set<String>()
        pages = source.compactMap { c in
            guard let path = c["path"] as? String, seen.insert(path).inserted else { return nil }
            let title = (c["label"] as? String) ?? (c["title"] as? String) ?? (c["plugin"] as? String) ?? path
            return Page(id: path, title: title, symbol: Self.symbol(c["icon"] as? String),
                        path: path, order: (c["order"] as? Double) ?? 0)
        }
        .sorted { ($0.order, $0.title) < ($1.order, $1.title) }
        if let selected, !pages.contains(where: { $0.id == selected }) { self.selected = nil }
    }

    // MARK: Messages from the page

    fileprivate func received(_ body: Any) {
        guard let m = body as? [String: Any], let type = m["type"] as? String else { return }
        let id = m["requestId"] as? String
        switch type {
        case "loaded":
            loaded?.resume(); loaded = nil
        case "contributions", "contributionsChanged", "ready":
            Task { await refreshPages() }
        case "api":
            guard let id else { return }
            Task { resolve(id, await forward(m)) }
        case "navigate":
            if let path = m["path"] as? String, let page = pages.first(where: { path.hasPrefix($0.path) }) {
                selected = page.id
                mountedPath = path
            }
        case "openExternal":
            if let s = m["url"] as? String, let url = URL(string: s) { NSWorkspace.shared.open(url) }
        case "clipboard.write":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(m["text"] as? String ?? "", forType: .string)
        case "revealPath":
            if let p = m["path"] as? String { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
        case "openSession":
            if let sid = m["sessionId"] as? String {
                selected = nil
                ChatNavigation.onSelect?(ChatRoute(storedID: sid))
            }
        case "pickOpenPath":
            guard let id else { return }
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = true
            resolve(id, panel.runModal() == .OK ? panel.urls.map(\.path) : [String]())
        case "pickSavePath":
            guard let id else { return }
            let panel = NSSavePanel()
            let picked: Any = panel.runModal() == .OK ? (panel.url?.path as Any? ?? NSNull()) : NSNull()
            resolve(id, picked)
        default:
            break
        }
    }

    /// A plugin's REST call, through the app's own client: its sign-in, renewal and Access headers.
    private func forward(_ m: [String: Any]) async -> [String: Any] {
        guard let api = runtime?.api, let urlString = m["url"] as? String else { return ["error": "Not connected"] }
        let rest = urlString.hasPrefix(gatewayBase) ? String(urlString.dropFirst(gatewayBase.count)) : urlString
        guard let comps = URLComponents(string: rest.hasPrefix("/") ? rest : "/" + rest) else { return ["error": "Bad URL"] }
        let method = (m["method"] as? String) ?? "GET"
        var body: Data?
        var contentType: String?
        if let b64 = m["bodyBase64"] as? String, let bytes = Data(base64Encoded: b64) {
            let boundary = "vibe-\(UUID().uuidString)"
            let name = (m["uploadFilename"] as? String) ?? "file"
            let type = (m["uploadContentType"] as? String) ?? "application/octet-stream"
            var d = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: \(type)\r\n\r\n".utf8)
            d.append(bytes)
            d.append(Data("\r\n--\(boundary)--\r\n".utf8))
            body = d
            contentType = "multipart/form-data; boundary=\(boundary)"
        } else if let s = m["body"] as? String {
            body = Data(s.utf8)
            contentType = "application/json"
        }
        let request = RelayedRequest(method: method, path: comps.path, query: comps.queryItems ?? [],
                                     body: body, contentType: contentType, authenticated: true)
        do {
            let r = try await api.forward(request)
            return ["status": r.status, "body": String(decoding: r.body, as: UTF8.self)]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    private func resolve(_ id: String, _ value: Any) {
        guard let webView,
              let data = try? JSONSerialization.data(withJSONObject: ["v": value]),
              let text = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.VibePluginHost.resolveNative(\(Self.js(id)),(\(text)).v)")
    }

    // MARK: Helpers

    private static func js(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
    }

    /// The Desktop's codicon names, as SF Symbols.
    private static func symbol(_ codicon: String?) -> String {
        switch codicon ?? "" {
        case "play", "run-all", "debug-start": return "play.circle"
        case "checklist", "tasklist", "check-all": return "checklist"
        case "search", "telescope", "book": return "text.magnifyingglass"
        case "code", "file-code", "terminal": return "chevron.left.forwardslash.chevron.right"
        case "graph", "pulse", "dashboard": return "chart.xyaxis.line"
        case "beaker": return "flask"
        case "rocket": return "paperplane"
        case "workflow", "git-merge", "type-hierarchy": return "point.3.connected.trianglepath.dotted"
        case "calendar": return "calendar"
        case "settings-gear", "gear": return "gearshape"
        default: return "puzzlepiece.extension"
        }
    }
}

/// The page's messages, to the host (a separate object: the content controller keeps it strongly).
private final class MessageRelay: NSObject, WKScriptMessageHandler {
    weak var host: PluginHost?
    init(host: PluginHost) { self.host = host }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { host?.received(body) }
    }
}

/// Serves the bundle at `vibe-plugins://host/…`: a real origin, so the plugins' `import()` of
/// their own source (as blobs) is allowed, which file:// pages may not be.
private final class BundleScheme: NSObject, WKURLSchemeHandler {
    static let scheme = "vibe-plugins"
    let root: URL
    init(root: URL) { self.root = root.standardizedFileURL }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        let file = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
        guard file.path.hasPrefix(root.path), let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let types = ["html": "text/html", "js": "text/javascript", "css": "text/css", "woff2": "font/woff2",
                     "woff": "font/woff", "ttf": "font/ttf", "svg": "image/svg+xml", "png": "image/png", "json": "application/json"]
        let type = types[file.pathExtension.lowercased()] ?? "application/octet-stream"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type, "Content-Length": "\(data.count)"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// The web view, in SwiftUI.
struct PluginSurface: NSViewRepresentable {
    var webView: WKWebView
    func makeNSView(context: Context) -> NSView {
        let box = NSView()
        place(in: box)
        return box
    }
    func updateNSView(_ box: NSView, context: Context) {
        if webView.superview !== box { place(in: box) }
    }
    private func place(in box: NSView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            webView.topAnchor.constraint(equalTo: box.topAnchor),
            webView.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
    }
}

/// The plugin page in front, over the chat.
struct PluginPageArea: View {
    @State private var host = PluginHost.shared

    var body: some View {
        if host.selected != nil, let web = host.webView {
            PluginSurface(webView: web)
                .ignoresSafeArea(.container, edges: .top)
                .transition(.opacity)
        }
    }
}

/// The plugins' pages in the sidebar, under the app's own pages.
struct PluginNavSection<Row: View>: View {
    @State private var host = PluginHost.shared
    var row: (PluginHost.Page, Bool) -> Row

    var body: some View {
        if !host.pages.isEmpty || host.problem != nil {
            VStack(alignment: .leading, spacing: 1) {
                Text("PLUGINS")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
                    .padding(.top, 10)
                    .padding(.bottom, 3)
                ForEach(host.pages) { page in
                    row(page, host.selected == page.id)
                }
                if let problem = host.problem {
                    Text(problem).font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.top, 2)
                }
            }
        }
    }
}
