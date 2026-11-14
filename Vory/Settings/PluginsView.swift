import SwiftUI
import VoryCore

/// Settings › Plugins: install one (a catalog name or a GitHub link), then what is installed on the
/// gateway with a switch each, and the plugins Hermes ships with behind one row.
struct PluginsView: View {
    @Environment(AppModel.self) private var model
    @State private var hub: PluginsHub?
    @State private var catalog: [CatalogEntry]?
    @State private var error: String?
    @State private var loading = false
    @State private var query = ""
    @State private var installing = false
    @State private var busy: Set<String> = []
    @State private var note: (text: String, bad: Bool)?
    /// Whether a source has a UI part (`desktop/plugin.js`), by its raw URL; nil while checking.
    @State private var uiPart: [String: Bool] = [:]

    private var runtime: GatewayRuntime? { model.runtime }
    private static func isCompanion(_ p: PluginsHub.Plugin) -> Bool { let n = p.name.lowercased(); return n.contains("vory") || n == "hermes-push" || n == "hermes_push" }
    private var companion: PluginsHub.Plugin? { hub?.plugins.first(where: Self.isCompanion) }
    private var visible: [PluginsHub.Plugin] { (hub?.plugins ?? []).filter { !Self.isCompanion($0) && $0.userHidden != true }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
    private var installed: [PluginsHub.Plugin] { visible.filter { $0.source != "bundled" && $0.runtimeStatus != "bundled" } }
    private var bundled: [PluginsHub.Plugin] { visible.filter { $0.source == "bundled" || $0.runtimeStatus == "bundled" } }

    var body: some View {
        SettingsList {
            SettingsHeaderSection(title: "Plugins", symbol: "puzzlepiece.extension.fill", color: .orange,
                                  description: "What the gateway loads beside the agent. Install one by its catalog name or a GitHub link.")
            if !DeviceWords.isMac {
            Section {
                if let c = companion {
                    PluginRow(plugin: c, highlight: true)
                    let bundled = PushSetupModel.bundledPluginVersion
                    if let v = c.version, v != bundled {
                        Label("This build carries companion \(bundled); Settings › Companion updates it.", systemImage: "arrow.down.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else if hub != nil {
                    Label("Artha's companion is not in this gateway's plugin list. Settings › Companion installs it, or shows it running if the gateway loads it another way.", systemImage: "bell.slash")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: { Text("Artha") }
            }
            installSection
            Section {
                if loading, hub == nil { ProgressView() }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                ForEach(installed) { p in installedRow(p) }
                if hub != nil, installed.isEmpty { Text("Nothing installed yet.").foregroundStyle(.secondary) }
            } header: { Text("Installed") }
            if !bundled.isEmpty {
                Section {
                    NavigationLink {
                        SettingsList { Section { ForEach(bundled) { p in PluginRow(plugin: p, highlight: false) } } }.pushedPage()
                    } label: {
                        HStack { Text("Plugins Hermes ships with"); Spacer(); Text("\(bundled.count)").foregroundStyle(.secondary) }
                    }
                } header: { Text("Built in") }
            }
        }
        .untitledPage()
        .reloadable { await load() }
        .task(id: runtime?.connection.id) { await load() }
        #if DEBUG
        .task {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-vibe-plugin-query"), args.indices.contains(i + 1) { query = args[i + 1] }
        }
        #endif
    }

    // MARK: Install

    /// What the typed text points at: a catalog entry, a GitHub link, or nothing yet.
    private enum Target { case catalog(CatalogEntry), link(String), empty }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var target: Target {
        let q = trimmed
        guard !q.isEmpty else { return .empty }
        if q.contains("/") { return Self.githubRepo(q) != nil ? .link(q) : .empty }
        if let e = catalog?.first(where: { $0.name.caseInsensitiveCompare(q) == .orderedSame || ($0.title ?? "").caseInsensitiveCompare(q) == .orderedSame }) { return .catalog(e) }
        return .empty
    }

    /// Up to three catalog names that start with (or contain) what is typed, when nothing matches exactly.
    private var suggestions: [CatalogEntry] {
        let q = trimmed.lowercased()
        guard q.count >= 2, !q.contains("/"), case .empty = target, let catalog else { return [] }
        let starts = catalog.filter { $0.name.hasPrefix(q) }
        let contains = catalog.filter { !$0.name.hasPrefix(q) && ($0.name.contains(q) || ($0.title ?? "").lowercased().contains(q)) }
        return Array((starts + contains).prefix(3))
    }

    @ViewBuilder private var installSection: some View {
        Section {
            HStack(spacing: 10) {
                TextField("Catalog name or GitHub link", text: $query)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit { install() }
                    .accessibilityIdentifier("plugins.install.field")
                if installing { ProgressView().controlSize(.small) }
                else {
                    #if os(macOS)
                    MacCapsuleButton(title: "Install", prominent: true) { install() }.disabled(!canInstall)
                    #else
                    Button("Install") { install() }.disabled(!canInstall)
                    #endif
                }
            }
            switch target {
            case .catalog(let e): preview(e)
            case .link(let url): linkPreview(url)
            case .empty:
                ForEach(suggestions) { e in
                    Button { query = e.name } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.displayName)
                            Text(e.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                if trimmed.count >= 2, suggestions.isEmpty, catalog != nil, !trimmed.contains("/") {
                    Text("No catalog plugin by that name.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let note { Text(note.text).font(.caption).foregroundStyle(note.bad ? Color(red: 1, green: 0.55, blue: 0.55) : .secondary) }
        } header: { Text("Install") } footer: {
            Text("Catalog plugins install at the commit Nous reviewed. A GitHub link installs whatever is there, unreviewed.")
        }
    }

    private var canInstall: Bool {
        switch target {
        case .catalog(let e): return e.installed != true
        case .link: return true
        case .empty: return false
        }
    }

    private func preview(_ e: CatalogEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: Self.symbol(e.category))
                .font(.system(size: 15)).foregroundStyle(.white.opacity(0.9))
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.1), in: .rect(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(e.displayName).font(.headline)
                    Text(e.tierLabel).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.white.opacity(0.1), in: Capsule())
                    if e.installed == true { Text("Installed").font(.caption2.weight(.semibold)).foregroundStyle(.green) }
                }
                Text([e.maintainer, [e.version, e.shaShort].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " @ ")].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                Text(e.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(parts(e)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .task(id: e.name) { await checkUIPart(e.uiPartURL) }
    }

    private func linkPreview(_ url: String) -> some View {
        let repo = Self.githubRepo(url) ?? url
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "link")
                .font(.system(size: 15)).foregroundStyle(.white.opacity(0.9))
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.1), in: .rect(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(repo).font(.headline)
                Text("Not in the catalog, so nobody reviewed it. Installs the latest commit.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    /// "Hermes part · 7 tools · needs SPOTIFY_KEY · UI part" in words.
    private func parts(_ e: CatalogEntry) -> String {
        var bits: [String] = []
        let c = e.capabilities
        let tools = c?.providesTools?.count ?? 0, hooks = c?.providesHooks?.count ?? 0
        var hermes = "Hermes part"
        if tools > 0 { hermes += " · \(tools) tool\(tools == 1 ? "" : "s")" }
        if hooks > 0 { hermes += " · \(hooks) hook\(hooks == 1 ? "" : "s")" }
        bits.append(hermes)
        #if os(macOS)
        switch uiPart[e.uiPartURL] {
        case true?: bits.append("UI part")
        case false?: bits.append("no UI part")
        case nil: break
        }
        #endif
        if let env = c?.requiresEnv, !env.isEmpty { bits.append("needs " + env.joined(separator: ", ")) }
        return bits.joined(separator: "  ·  ")
    }

    private func install() {
        guard canInstall, !installing, let rt = runtime else { return }
        let t = target
        var body: [String: JSONValue] = ["identifier": .string(""), "enable": .bool(true)]
        var uiURL: String?
        switch t {
        case .catalog(let e): body["catalog_name"] = .string(e.name); uiURL = e.uiPartURL
        case .link(let url): body["identifier"] = .string(url); uiURL = Self.githubRepo(url).map { "https://raw.githubusercontent.com/\($0)/HEAD/desktop/plugin.js" }
        case .empty: return
        }
        installing = true; note = nil
        Task {
            defer { installing = false }
            do {
                let r: JSONValue = try await rt.api.send("POST", "/api/dashboard/agent-plugins/install", profile: rt.selectedProfile, json: .object(body))
                if r["consent_required"]?.boolValue == true || r["scan_blocked"]?.boolValue == true {
                    note = ("The gateway wants a person to confirm this one. Run hermes plugins install on it.", true)
                    return
                }
                let name = r["plugin_name"]?.stringValue ?? trimmed
                var text = "Installed \(name)."
                #if os(macOS)
                if let uiURL, await Self.installUIPart(from: uiURL, as: name) {
                    text += " Its UI part is in the sidebar."
                    PluginHost.shared.reload()
                }
                #endif
                if let missing = r["missing_env"]?.arrayValue?.compactMap(\.stringValue), !missing.isEmpty {
                    text += " It needs " + missing.joined(separator: ", ") + " in API Keys & Environment."
                }
                note = (text, false)
                query = ""
                await load()
            } catch {
                note = (Self.message(error), true)
            }
        }
    }

    // MARK: Installed

    private func installedRow(_ p: PluginsHub.Plugin) -> some View {
        HStack(spacing: 12) {
            Image(systemName: p.hasDashboardManifest == true ? "rectangle.on.rectangle" : "puzzlepiece.extension")
                .foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(p.name)
                    if let v = p.version, !v.isEmpty { Text(v).font(.caption).foregroundStyle(.secondary) }
                }
                Text(subtitle(p)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if busy.contains(p.name) { ProgressView().controlSize(.small) }
            if p.canRemove == true {
                Menu {
                    Button("Remove", role: .destructive) { remove(p) }
                } label: { Image(systemName: "ellipsis").foregroundStyle(.secondary) }
                .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden).fixedSize()
                .disabled(busy.contains(p.name))
            }
            Toggle("Enabled", isOn: Binding(get: { p.runtimeStatus == "enabled" }, set: { setEnabled(p, $0) }))
                .labelsHidden().toggleStyle(.switch)
                .disabled(busy.contains(p.name))
        }
        .rowActions { if p.canRemove == true { Button("Remove", role: .destructive) { remove(p) } } }
    }

    private func subtitle(_ p: PluginsHub.Plugin) -> String {
        var bits: [String] = []
        #if os(macOS)
        bits.append(Self.hasUIPart(p.name) ? "Hermes + UI parts" : "Hermes part")
        #endif
        if p.authRequired == true, let c = p.authCommand, !c.isEmpty { bits.append("sign in: \(c)") }
        else if let d = p.description, !d.isEmpty { bits.append(d) }
        return bits.joined(separator: " · ")
    }

    private func setEnabled(_ p: PluginsHub.Plugin, _ on: Bool) {
        mutate(p, "POST", "/api/dashboard/agent-plugins/\(p.name)/\(on ? "enable" : "disable")")
    }

    private func remove(_ p: PluginsHub.Plugin) {
        mutate(p, "DELETE", "/api/dashboard/agent-plugins/\(p.name)") {
            #if os(macOS)
            if Self.hasUIPart(p.name) {
                try? FileManager.default.removeItem(at: PluginHost.pluginsDir.appendingPathComponent(p.name))
                PluginHost.shared.reload()
            }
            #endif
        }
    }

    private func mutate(_ p: PluginsHub.Plugin, _ method: String, _ path: String, after: @escaping @MainActor () -> Void = {}) {
        guard let rt = runtime, !busy.contains(p.name) else { return }
        busy.insert(p.name)
        Task {
            defer { busy.remove(p.name) }
            do {
                let _: JSONValue = try await rt.api.send(method, path, profile: rt.selectedProfile, json: .object([:]))
                after()
                note = nil
            } catch { note = (Self.message(error), true) }
            await load()
        }
    }

    // MARK: Loading

    private func load() async {
        guard let rt = runtime else { return }
        loading = true; defer { loading = false }
        do {
            hub = try await rt.api.get("/api/dashboard/plugins/hub", profile: rt.selectedProfile)
            error = nil
        } catch {
            if let e = error as? HermesAPIError, case .http(let code, _) = e, code == 404 { self.error = "This gateway has no plugins hub yet (it needs a newer Hermes)." }
            else if let e = error as? HermesAPIError, case .decoding = e { self.error = "This gateway answered without a plugin list (it needs a newer Hermes)." }
            else { self.error = error.localizedDescription }
        }
        if let c: CatalogState = try? await rt.api.get("/api/dashboard/plugins/catalog", profile: rt.selectedProfile) { catalog = c.entries }
    }

    private func checkUIPart(_ url: String) async {
        #if os(macOS)
        guard uiPart[url] == nil, let u = URL(string: url) else { return }
        var req = URLRequest(url: u); req.httpMethod = "HEAD"; req.timeoutInterval = 10
        if let (_, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse {
            uiPart[url] = http.statusCode == 200
        }
        #endif
    }

    // MARK: Helpers

    private static func message(_ error: Error) -> String {
        if let e = error as? HermesAPIError, case .http(_, let detail) = e, !detail.isEmpty {
            if let d = try? JSONDecoder().decode([String: String].self, from: Data(detail.utf8)), let m = d["detail"] { return m }
            return detail
        }
        return error.localizedDescription
    }

    /// "owner/repo" from a GitHub link (https://github.com/owner/repo, with or without .git or a path after).
    static func githubRepo(_ text: String) -> String? {
        var s = text.trimmingCharacters(in: .whitespaces)
        for p in ["https://", "http://", "www."] where s.hasPrefix(p) { s.removeFirst(p.count) }
        guard s.hasPrefix("github.com/") else { return nil }
        let parts = s.dropFirst("github.com/".count).split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        var repo = parts[1]
        if repo.hasSuffix(".git") { repo.removeLast(4) }
        return repo.isEmpty ? nil : "\(parts[0])/\(repo)"
    }

    private static func symbol(_ category: String?) -> String {
        switch category ?? "" {
        case "memory": return "brain"
        case "platform": return "bubble.left.and.bubble.right"
        case "web": return "globe"
        case "voice": return "waveform"
        case "automation": return "gearshape.2"
        case "models": return "cpu"
        case "desktop": return "macwindow"
        default: return "puzzlepiece.extension"
        }
    }

    #if os(macOS)
    static func hasUIPart(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: PluginHost.pluginsDir.appendingPathComponent(name).appendingPathComponent("plugin.js").path)
    }

    /// Saves a plugin's UI part (`desktop/plugin.js`, one bundled file) where the plugin host loads it.
    /// False when the plugin has none.
    static func installUIPart(from url: String, as name: String) async -> Bool {
        guard let u = URL(string: url), let (data, resp) = try? await URLSession.shared.data(from: u),
              (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return false }
        let dir = PluginHost.pluginsDir.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent("plugin.js"), options: .atomic)
            return true
        } catch { return false }
    }
    #endif
}

/// `GET /api/dashboard/plugins/catalog`: the curated catalog with what is installed.
struct CatalogState: Decodable { var entries: [CatalogEntry] }

struct CatalogEntry: Decodable, Identifiable, Hashable {
    struct Capabilities: Decodable, Hashable {
        var providesTools: [String]?
        var providesHooks: [String]?
        var requiresEnv: [String]?
    }
    var name: String
    var repo: String
    var sha: String
    var subdir: String?
    var description: String?
    var maintainer: String?
    var tier: String?
    var category: String?
    var version: String?
    var title: String?
    var shaShort: String?
    var installed: Bool?
    var capabilities: Capabilities?
    var id: String { name }

    /// The catalog's title, else the name in words ("brave-search" → "Brave Search").
    var displayName: String {
        if let title, !title.isEmpty { return title }
        return name.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
    var tierLabel: String { (tier ?? "community").capitalized }
    /// The description's first sentence.
    var summary: String {
        let flat = (description ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if let r = flat.range(of: ". ") { return String(flat[..<r.lowerBound]) + "." }
        return flat
    }
    /// Where the UI part would be at the reviewed commit.
    var uiPartURL: String {
        let repoPath = PluginsView.githubRepo(repo) ?? ""
        let sub = (subdir ?? "").isEmpty ? "" : "\(subdir!)/"
        return "https://raw.githubusercontent.com/\(repoPath)/\(sha)/\(sub)desktop/plugin.js"
    }
}

struct PluginRow: View {
    var plugin: PluginsHub.Plugin
    var highlight: Bool

    private var status: (text: String, color: Color) {
        switch plugin.runtimeStatus ?? "" {
        case "enabled": return ("Enabled", .green)
        case "disabled": return ("Disabled", .secondary)
        case "bundled": return ("Bundled", .blue)
        default: return (plugin.removedReason == nil ? "Unknown" : "Removed", .orange)
        }
    }

    var body: some View {
        NavigationLink { PluginDetailView(plugin: plugin).pushedPage() } label: {
            HStack(spacing: 12) {
                Image(systemName: highlight ? "bell.badge.fill" : plugin.hasDashboardManifest == true ? "rectangle.on.rectangle" : "puzzlepiece.extension")
                    .foregroundStyle(highlight ? Color.vory : .secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(plugin.name).font(.body.weight(highlight ? .semibold : .regular))
                        if let v = plugin.version, !v.isEmpty { Text(v).font(.caption).foregroundStyle(.secondary) }
                    }
                    if let d = plugin.description, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer()
                Text(status.text).font(.caption2.weight(.semibold)).foregroundStyle(status.color)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(status.color.opacity(0.12), in: Capsule())
            }
        }
    }
}

struct PluginDetailView: View {
    var plugin: PluginsHub.Plugin

    var body: some View {
        SettingsList {
            Section {
                LabeledContent("Name", value: plugin.name)
                if let v = plugin.version, !v.isEmpty { LabeledContent("Version", value: v) }
                LabeledContent("Status", value: (plugin.runtimeStatus ?? "").isEmpty ? "unknown" : plugin.runtimeStatus!)
                if let s = plugin.source, !s.isEmpty { LabeledContent("Source", value: s) }
                if let p = plugin.path, !p.isEmpty { LabeledContent("Path") { Text(p).font(.caption.monospaced()).textSelection(.enabled).multilineTextAlignment(.trailing) } }
            }
            if let d = plugin.description, !d.isEmpty { Section("About") { Text(d) } }
            Section("Can") {
                Label(plugin.hasDashboardManifest == true ? "Adds a page to the dashboard" : "Agent-side only", systemImage: plugin.hasDashboardManifest == true ? "rectangle.on.rectangle" : "cpu")
                if plugin.canUpdateGit == true { Label("Updates from its git checkout", systemImage: "arrow.triangle.branch") }
                if plugin.authRequired == true {
                    Label("Needs a sign-in on the gateway", systemImage: "person.badge.key")
                    if let c = plugin.authCommand, !c.isEmpty { Text(c).font(.caption.monospaced()).textSelection(.enabled) }
                }
            }
            if let r = plugin.removedReason, !r.isEmpty { Section("Removed") { Text(r).foregroundStyle(.orange) } }
        }
        .navigationTitle(plugin.name).navigationBarTitleDisplayMode(.inline)
    }
}
