import AppKit
import JavaScriptCore
import SwiftUI
import VoryCore

/// Hermes Desktop's disk plugins (`~/.hermes/desktop-plugins/<id>/plugin.js`), run natively: the
/// plugin code runs in JavaScriptCore (no web view) under `plugin-runtime.js` (built from
/// `PluginNative/`), a React renderer whose output is a plain tree. Every render comes here as a
/// `PluginNode` tree and `PluginRenderer.swift` draws it with SwiftUI controls, so a plugin page
/// looks like the rest of the app. Their REST calls go out through this app's signed-in client.
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

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var kind: String
        var title: String?
        var message: String
    }

    /// The plugins' pages, for the sidebar.
    private(set) var pages: [Page] = []
    /// The plugin page in front, if any (over the chats and the app's pages).
    var selected: Page.ID? {
        didSet { if selected != oldValue { mountSelected() } }
    }
    /// Why there are no plugin pages, when it is worth saying.
    private(set) var problem: String?
    /// The latest tree of each mounted root ("page" is the page in front).
    private(set) var trees: [String: PluginNode] = [:]
    private(set) var toasts: [Toast] = []

    /// The real home folder, not a sandbox container's.
    static var pluginsDir: URL {
        var home = NSHomeDirectory()
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { home = String(cString: dir) }
        return URL(fileURLWithPath: home).appendingPathComponent(".hermes/desktop-plugins", isDirectory: true)
    }

    @ObservationIgnored private var context: JSContext?
    @ObservationIgnored private weak var runtime: GatewayRuntime?
    @ObservationIgnored private var timers: [Int: Timer] = [:]
    @ObservationIgnored private var mountedPath: String?

    /// Starts (or restarts) the plugins for the gateway in use.
    func attach(_ runtime: GatewayRuntime?) {
        guard runtime !== self.runtime else { return }
        self.runtime = runtime
        stop()
        guard let runtime else { return }
        let plugins = Self.diskPlugins()
        guard !plugins.isEmpty else { return }
        guard let url = Bundle.main.url(forResource: "plugin-runtime", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            problem = "This build has no plugin runtime."
            return
        }
        let ctx = makeContext()
        context = ctx
        ctx.evaluateScript(source, withSourceURL: url)
        if let e = ctx.exception {
            problem = "Plugins didn't start: \(e)"
            context = nil
            return
        }
        let start: [String: Any] = ["profile": runtime.selectedProfile ?? "default", "gateway": "open"]
        vibe("start")?.call(withArguments: [start])
        var failed: [String] = []
        for (id, code) in plugins {
            let r = vibe("load")?.call(withArguments: [id, code])
            if r?.forProperty("ok")?.toBool() != true {
                failed.append(id)
                NSLog("[plugins] %@ didn't load: %@", id, r?.forProperty("error")?.toString() ?? "?")
            }
        }
        problem = failed.isEmpty ? nil : "Didn't load: " + failed.joined(separator: ", ")
        refreshPages()
        mountSelected()
    }

    /// Shows a plugin page.
    func open(_ page: Page) {
        selected = page.id
    }

    /// Runs a palette command a plugin registered.
    func runPalette(_ id: String) {
        vibe("runPalette")?.call(withArguments: [id])
    }

    /// A native control's event, back to the plugin (`args` as its handler gets them).
    func dispatch(_ handler: String, _ args: [Any] = [["$event": true]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: args),
              let json = String(data: data, encoding: .utf8) else { return }
        vibe("dispatch")?.call(withArguments: [handler, json])
    }

    func dismissToast(_ id: Toast.ID) {
        withAnimation(.smooth) { toasts.removeAll { $0.id == id } }
    }

    // MARK: Setup

    private func stop() {
        timers.values.forEach { $0.invalidate() }
        timers = [:]
        context = nil
        trees = [:]
        pages = []
        mountedPath = nil
        selected = nil
        problem = nil
    }

    private func mountSelected() {
        guard context != nil else { return }
        guard let path = selected else {
            if mountedPath != nil {
                vibe("unmount")?.call(withArguments: ["page"])
                trees["page"] = nil
                mountedPath = nil
            }
            return
        }
        guard mountedPath != path else { return }
        mountedPath = path
        trees["page"] = nil
        vibe("mount")?.call(withArguments: ["page", "route", path])
    }

    private static func diskPlugins() -> [(String, String)] {
        let dir = pluginsDir
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return ids.sorted().compactMap { id in
            let file = dir.appendingPathComponent(id).appendingPathComponent("plugin.js")
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            return (id, source)
        }
    }

    private func vibe(_ name: String) -> JSValue? {
        context?.objectForKeyedSubscript("__vibe")?.objectForKeyedSubscript(name)
    }

    private func makeContext() -> JSContext {
        let ctx = JSContext()!
        ctx.name = "Artha plugins"
        ctx.exceptionHandler = { _, e in NSLog("[plugins] JS exception: %@", e?.toString() ?? "?") }
        let native = JSValue(newObjectIn: ctx)!
        let send: @convention(block) (String, String) -> Void = { [weak self] type, json in
            MainActor.assumeIsolated { self?.received(type, json) }
        }
        let call: @convention(block) (String, String, String) -> Void = { [weak self] type, json, id in
            MainActor.assumeIsolated { self?.request(type, json, id) }
        }
        let setTimer: @convention(block) (Int, Double, Bool) -> Void = { [weak self] id, ms, repeats in
            MainActor.assumeIsolated { self?.setTimer(id, ms, repeats) }
        }
        let clearTimer: @convention(block) (Int) -> Void = { [weak self] id in
            MainActor.assumeIsolated { _ = self?.timers.removeValue(forKey: id).map { $0.invalidate() } }
        }
        let storageGet: @convention(block) (String) -> Any = { key in
            UserDefaults.standard.string(forKey: "vibe.plugin." + key) ?? NSNull()
        }
        let storageSet: @convention(block) (String, JSValue) -> Void = { key, value in
            if value.isNull || value.isUndefined { UserDefaults.standard.removeObject(forKey: "vibe.plugin." + key) }
            else { UserDefaults.standard.set(value.toString(), forKey: "vibe.plugin." + key) }
        }
        native.setObject(send, forKeyedSubscript: "send" as NSString)
        native.setObject(call, forKeyedSubscript: "call" as NSString)
        native.setObject(setTimer, forKeyedSubscript: "setTimer" as NSString)
        native.setObject(clearTimer, forKeyedSubscript: "clearTimer" as NSString)
        native.setObject(storageGet, forKeyedSubscript: "storageGet" as NSString)
        native.setObject(storageSet, forKeyedSubscript: "storageSet" as NSString)
        ctx.setObject(native, forKeyedSubscript: "__native" as NSString)
        return ctx
    }

    private func setTimer(_ id: Int, _ ms: Double, _ repeats: Bool) {
        timers[id]?.invalidate()
        let timer = Timer(timeInterval: max(ms, 1) / 1000, repeats: repeats) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !repeats { self.timers[id] = nil }
                self.vibe("fire")?.call(withArguments: [id])
            }
        }
        timers[id] = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    // MARK: Messages from the plugins

    private func received(_ type: String, _ json: String) {
        let m = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        switch type {
        case "render":
            guard let root = m["root"] as? String, let tree = m["tree"] else { return }
            trees[root] = PluginNode(tree)
        case "contributions":
            refreshPages()
        case "toast":
            let toast = Toast(kind: m["kind"] as? String ?? "info", title: m["title"] as? String,
                              message: m["message"] as? String ?? "")
            withAnimation(.smooth) { toasts.append(toast) }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                self?.dismissToast(toast.id)
            }
        case "navigate":
            if let path = m["path"] as? String, let page = pages.first(where: { path.hasPrefix($0.path) }) {
                selected = page.id
            }
        case "openSession":
            if let sid = m["sessionId"] as? String {
                selected = nil
                ChatNavigation.onSelect?(ChatRoute(storedID: sid))
            }
        case "openExternal":
            if let s = m["url"] as? String, let url = URL(string: s) { NSWorkspace.shared.open(url) }
        case "clipboard":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(m["text"] as? String ?? "", forType: .string)
        case "revealPath":
            if let p = m["path"] as? String { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
        case "log":
            NSLog("[plugins] js %@: %@", m["level"] as? String ?? "log", String((m["text"] as? String ?? "").prefix(500)))
        default:
            break
        }
    }

    private func request(_ type: String, _ json: String, _ id: String) {
        let m = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        Task {
            let result: [String: Any]
            switch type {
            case "api": result = await forward(m)
            case "rpc": result = await rpc(m)
            default: result = ["error": "Not available in this app: \(type)"]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: result),
                  let text = String(data: data, encoding: .utf8) else { return }
            vibe("resolve")?.call(withArguments: [id, true, text])
        }
    }

    /// A plugin's REST call, through the app's own client: its sign-in, renewal and Access headers.
    private func forward(_ m: [String: Any]) async -> [String: Any] {
        guard let api = runtime?.api, let path = m["path"] as? String,
              let comps = URLComponents(string: path.hasPrefix("/") ? path : "/" + path) else { return ["error": "Not connected"] }
        let method = (m["method"] as? String) ?? "GET"
        let body = (m["body"] as? String).map { Data($0.utf8) }
        let request = RelayedRequest(method: method, path: comps.path, query: comps.queryItems ?? [],
                                     body: body, contentType: body == nil ? nil : "application/json", authenticated: true)
        do {
            let r = try await api.forward(request)
            return ["status": r.status, "body": String(decoding: r.body, as: UTF8.self)]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    /// `host.request`: the gateway's JSON-RPC, over the app's own socket.
    private func rpc(_ m: [String: Any]) async -> [String: Any] {
        guard let runtime, let method = m["method"] as? String else { return ["error": "Not connected"] }
        do {
            let data = try JSONSerialization.data(withJSONObject: m["params"] ?? [String: Any]())
            let params = (try? JSONDecoder().decode([String: JSONValue].self, from: data)) ?? [:]
            let value = try await runtime.rpc(method, params)
            let out = try JSONEncoder().encode(value)
            return ["result": (try? JSONSerialization.jsonObject(with: out, options: .fragmentsAllowed)) ?? NSNull()]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    private func refreshPages() {
        guard let json = vibe("contributions")?.call(withArguments: [])?.toString(),
              let list = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] else { return }
        let routes = Set(list.filter { $0["area"] as? String == "routes" }
            .compactMap { ($0["data"] as? [String: Any])?["path"] as? String })
        let nav = list.filter { $0["area"] as? String == "sidebar.nav" }
        let source = nav.isEmpty ? list.filter { $0["area"] as? String == "routes" } : nav
        var seen = Set<String>()
        pages = source.compactMap { c in
            let data = c["data"] as? [String: Any] ?? [:]
            guard let path = data["path"] as? String, routes.contains(path), seen.insert(path).inserted else { return nil }
            let title = (data["label"] as? String) ?? (c["title"] as? String) ?? (c["plugin"] as? String) ?? path
            let icon = (data["codicon"] as? String) ?? (data["icon"] as? String)
            return Page(id: path, title: title, symbol: PluginSymbols.symbol(icon), path: path,
                        order: (c["order"] as? Double) ?? 0)
        }
        .sorted { ($0.order, $0.title) < ($1.order, $1.title) }
        if let selected, !pages.contains(where: { $0.id == selected }) { self.selected = nil }
        #if DEBUG
        // `-vibe-open-plugin <path>`: opens that plugin page once it is there (the CI screenshots).
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-vibe-open-plugin"), args.indices.contains(i + 1),
           let page = pages.first(where: { $0.path == args[i + 1] }), selected == nil {
            open(page)
        }
        #endif
    }
}

/// One node of a plugin's rendered tree: an element (`div`, `Button`, …) or a run of text.
struct PluginNode: Identifiable {
    let id: Int
    let type: String
    let props: [String: Any]
    let children: [PluginNode]
    let text: String?

    init(_ any: Any, index: Int = 0) {
        let m = any as? [String: Any] ?? [:]
        type = m["t"] as? String ?? "#text"
        text = m["s"] as? String
        // Text runs have no id of their own: keep them apart from element ids.
        id = (m["i"] as? Int) ?? -(index + 1)
        props = m["p"] as? [String: Any] ?? [:]
        children = (m["c"] as? [Any] ?? []).enumerated().map { PluginNode($0.element, index: $0.offset) }
    }

    var isText: Bool { type == "#text" }
    var className: String { props["className"] as? String ?? "" }

    func string(_ key: String) -> String? {
        if let s = props[key] as? String { return s }
        if let n = props[key] as? NSNumber { return n.stringValue }
        if let el = props[key] as? [String: Any], let s = el["$el"] as? String { return s }
        return nil
    }

    func bool(_ key: String) -> Bool { (props[key] as? NSNumber)?.boolValue ?? false }
    func handler(_ key: String) -> String? { (props[key] as? [String: Any])?["$fn"] as? String }

    /// All the text inside, flattened.
    var plainText: String { text ?? children.map(\.plainText).joined() }
}

enum PluginSymbols {
    /// The Desktop's codicon names, as SF Symbols.
    static func symbol(_ codicon: String?) -> String {
        switch codicon ?? "" {
        case "play", "run-all", "debug-start": "play.circle"
        case "checklist", "tasklist", "check-all": "checklist"
        case "check": "checkmark"
        case "search", "telescope": "magnifyingglass"
        case "book": "book"
        case "code", "file-code": "chevron.left.forwardslash.chevron.right"
        case "terminal": "terminal"
        case "graph", "pulse", "dashboard": "chart.xyaxis.line"
        case "beaker": "flask"
        case "rocket": "paperplane"
        case "workflow", "git-merge", "type-hierarchy": "point.3.connected.trianglepath.dotted"
        case "git-branch": "arrow.triangle.branch"
        case "calendar": "calendar"
        case "settings-gear", "gear", "settings": "gearshape"
        case "add", "plus": "plus"
        case "close", "x": "xmark"
        case "trash": "trash"
        case "edit", "pencil": "pencil"
        case "refresh", "sync": "arrow.clockwise"
        case "chevron-right": "chevron.right"
        case "chevron-down": "chevron.down"
        case "chevron-left": "chevron.left"
        case "chevron-up": "chevron.up"
        case "arrow-right": "arrow.right"
        case "arrow-left": "arrow.left"
        case "debug-pause": "pause"
        case "debug-stop", "primitive-square": "stop"
        case "inbox": "tray"
        case "archive": "archivebox"
        case "folder", "folder-opened": "folder"
        case "file", "file-text", "note": "doc.text"
        case "link", "link-external": "arrow.up.right.square"
        case "copy": "doc.on.doc"
        case "star", "star-empty": "star"
        case "star-full": "star.fill"
        case "warning": "exclamationmark.triangle"
        case "error": "xmark.octagon"
        case "info": "info.circle"
        case "pass", "pass-filled": "checkmark.circle"
        case "circle-large-outline", "circle-outline": "circle"
        case "loading", "sync~spin": "arrow.triangle.2.circlepath"
        case "filter": "line.3.horizontal.decrease"
        case "list-unordered", "list-flat": "list.bullet"
        case "person", "account": "person"
        case "comment", "comment-discussion": "bubble.left"
        case "eye": "eye"
        case "clock", "history", "watch": "clock"
        case "lightbulb": "lightbulb"
        case "tag": "tag"
        case "globe": "globe"
        case "save": "square.and.arrow.down"
        case "ellipsis", "kebab-vertical": "ellipsis"
        case "zap", "symbol-event": "bolt"
        case "sparkle": "sparkles"
        case "credit-card": "creditcard"
        default: "puzzlepiece.extension"
        }
    }
}

/// The plugin page in front, over the chat, drawn natively.
struct PluginPageArea: View {
    @State private var host = PluginHost.shared

    var body: some View {
        if host.selected != nil {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let tree = host.trees["page"] {
                        PluginRootView(node: tree)
                    } else {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(.top, 44)
                VStack(alignment: .trailing, spacing: 8) {
                    ForEach(host.toasts) { t in PluginToastView(toast: t) }
                }
                .padding(18)
            }
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
