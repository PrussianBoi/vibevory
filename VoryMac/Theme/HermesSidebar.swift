import SwiftUI
import VoryCore

// MARK: - State

/// The sidebar's place in the window, as Hermes Desktop has it: pinned beside the chats, or hidden
/// and sliding in as a floating Liquid Glass panel when the pointer reaches the window's left edge.
/// ⌘B (or the button by the window controls) switches between the two.
@MainActor @Observable
final class SidebarChrome {
    static let shared = SidebarChrome()
    static let width: CGFloat = 260
    private static let pinnedKey = "vibe.sidebarPinned"

    var pinned: Bool = UserDefaults.standard.object(forKey: SidebarChrome.pinnedKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(pinned, forKey: Self.pinnedKey); revealed = false }
    }
    /// Unpinned, and slid in over the chat.
    var revealed = false
    private var hideTask: Task<Void, Never>?

    func toggle() { withAnimation(.smooth(duration: 0.3)) { pinned.toggle() } }

    /// The pointer reached the left edge, or is over the floating panel.
    func reveal() {
        hideTask?.cancel()
        guard !pinned, !revealed else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { revealed = true }
    }

    /// The pointer left the panel: it slides out after a moment, unless the pointer comes back.
    func leave() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(380))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.26)) { self.revealed = false }
        }
    }
}

/// Desktop's own pages that Vory has no tab for: shown in the detail column in place of the chats.
enum DesktopPage: String, Hashable { case capabilities, messaging }

@MainActor @Observable
final class DesktopPages {
    static let shared = DesktopPages()
    var selected: DesktopPage?
}

/// The sessions the sidebar lists, loaded from the gateway: Pinned, the chats by day, each
/// messaging platform's chats, and the scheduled jobs.
@MainActor @Observable
final class SidebarSessions {
    static let shared = SidebarSessions()

    var sessions: [StoredSession] = []
    /// Sessions the sidebar never lists: scheduled jobs and one-shot command-line runs.
    static let hiddenSources: Set<String> = ["cron", "oneshot"]
    var jobs: [Job] = []
    var limit = 60
    var loading = false
    var error: String?
    var searchHits: [StoredSession] = []

    struct Job: Identifiable, Hashable {
        var id: String
        var name: String
        var enabled: Bool
        var next: Date?
    }

    /// Hermes's messaging platforms: their chats get a section each, as in Desktop.
    static let platforms: [String: String] = [
        "telegram": "Telegram", "discord": "Discord", "slack": "Slack", "whatsapp": "WhatsApp",
        "signal": "Signal", "matrix": "Matrix", "email": "Email", "sms": "SMS", "mattermost": "Mattermost",
        "imessage": "iMessage", "bluebubbles": "iMessage", "homeassistant": "Home Assistant",
        "dingtalk": "DingTalk", "feishu": "Feishu", "wecom": "WeCom", "weixin": "WeChat", "qq": "QQ",
    ]

    func load(_ runtime: GatewayRuntime?) async {
        guard let runtime else { sessions = []; jobs = []; return }
        loading = sessions.isEmpty
        defer { loading = false }
        let q = [URLQueryItem(name: "order", value: "recent"), URLQueryItem(name: "limit", value: String(limit)),
                 URLQueryItem(name: "archived", value: "exclude"), URLQueryItem(name: "exclude_sources", value: "cron")]
        do {
            let r: SessionListResponse = try await runtime.api.get("/api/sessions", query: q, profile: runtime.selectedProfile)
            // VibeVory: no one-shot runs either (`hermes -z` from scripts): each call is a session of its own.
            sessions = r.sessions.filter { $0.archived != true && !Self.hiddenSources.contains($0.source ?? "") }
            error = nil
        } catch {
            if sessions.isEmpty { self.error = error.localizedDescription }
        }
        if let r: JSONValue = try? await runtime.api.get("/api/cron/jobs") {
            let arr = r["jobs"]?.arrayValue ?? r["items"]?.arrayValue ?? r.arrayValue ?? []
            jobs = arr.compactMap { j in
                guard let id = j["id"]?.stringValue ?? j["job_id"]?.stringValue else { return nil }
                let next = j["next_run_at"]?.stringValue.flatMap { ISO8601DateFormatter().date(from: $0) }
                    ?? j["next_run_at"]?.doubleValue.map { Date(timeIntervalSince1970: $0) }
                return Job(id: id, name: j["name"]?.stringValue ?? "Job", enabled: j["enabled"]?.boolValue ?? true, next: next)
            }
        }
    }

    func search(_ q: String, runtime: GatewayRuntime?) async {
        let q = q.trimmingCharacters(in: .whitespaces)
        guard let runtime, !q.isEmpty else { searchHits = []; return }
        let local = sessions.filter { $0.displayTitle.localizedCaseInsensitiveContains(q) || ($0.preview ?? "").localizedCaseInsensitiveContains(q) }
        searchHits = local
        if let r: JSONValue = try? await runtime.api.get("/api/sessions/search", query: [URLQueryItem(name: "q", value: q)], profile: runtime.selectedProfile) {
            let arr = r["sessions"]?.arrayValue ?? r["results"]?.arrayValue ?? r.arrayValue ?? []
            let remote = arr.compactMap { try? $0.decode(StoredSession.self) }
            var seen = Set(local.map(\.id))
            searchHits = local + remote.filter { !Self.hiddenSources.contains($0.source ?? "") && seen.insert($0.id).inserted }
        }
    }

    func patch(_ s: StoredSession, _ fields: [String: JSONValue], runtime: GatewayRuntime?) async {
        guard let runtime else { return }
        var body = fields
        if case .bool(true)? = body["archived"], s.pinned == true { body["pinned"] = .bool(false) }
        if let i = sessions.firstIndex(where: { $0.id == s.id }) {
            withAnimation(.snappy) {
                if case .bool(let v)? = body["pinned"] { sessions[i].pinned = v }
                if case .string(let v)? = body["title"] { sessions[i].title = v }
                if case .bool(true)? = body["archived"] { sessions.remove(at: i) }
            }
        }
        do { try await SessionMutation.patch(runtime.api, id: s.id, profile: s.profile ?? runtime.selectedProfile, fields: body) }
        catch { self.error = error.localizedDescription }
        await load(runtime)
    }

    func delete(_ s: StoredSession, runtime: GatewayRuntime?) async {
        guard let runtime else { return }
        if let chat = runtime.chatForStored(s.id) { runtime.closeChat(chat) }
        withAnimation(.snappy) { sessions.removeAll { $0.id == s.id } }
        do { try await SessionMutation.delete(runtime.api, id: s.id, profile: s.profile ?? runtime.selectedProfile) }
        catch { self.error = error.localizedDescription }
        await load(runtime)
    }

    /// Desktop's day groups.
    static func bucket(_ s: StoredSession, now: Date = Date()) -> String {
        guard let d = s.lastDate else { return "Older" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Earlier today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if cal.isDate(d, equalTo: now, toGranularity: .weekOfYear) { return "Earlier this week" }
        if let last = cal.date(byAdding: .weekOfYear, value: -1, to: now), cal.isDate(d, equalTo: last, toGranularity: .weekOfYear) { return "Last week" }
        if cal.isDate(d, equalTo: now, toGranularity: .month) { return "Earlier this month" }
        return "Older"
    }

    static func age(_ s: StoredSession, now: Date = Date()) -> String {
        guard let d = s.lastDate else { return "" }
        let m = Int(now.timeIntervalSince(d) / 60)
        if m < 1 { return "now" }
        if m < 60 { return "\(m)m" }
        if m < 60 * 24 { return "\(m / 60)h" }
        return "\(m / 60 / 24)d"
    }
}

// MARK: - The sidebar

/// Hermes Desktop's sidebar: search, the pages, Pinned, Sessions by day, each messaging platform,
/// Scheduled jobs, and the profiles at the foot. Small light type over the aurora.
struct HermesSidebar: View {
    @Environment(AppModel.self) private var model
    var tabs: [AppModel.AppTab]
    @Binding var chatPath: NavigationPath
    /// True for the floating panel, which brings its own glass.
    var floating = false

    @State private var store = SidebarSessions.shared
    @State private var plugins = PluginHost.shared
    @State private var pages = DesktopPages.shared
    @State private var chatTabs = ChatTabs.shared
    @State private var query = ""
    @State private var renaming: StoredSession?
    @State private var prewarm: Task<Void, Never>?
    @State private var renameText = ""
    @State private var deleting: StoredSession?
    @AppStorage("vibe.sidebar.pinnedOpen") private var pinnedOpen = true
    @AppStorage("vibe.sidebar.sessionsOpen") private var sessionsOpen = true
    @AppStorage("vibe.sidebar.jobsOpen") private var jobsOpen = false
    @AppStorage("vibe.sidebar.platformsOpen") private var platformsOpenRaw = ""

    private var runtime: GatewayRuntime? { model.runtime }
    private var selectedID: String? {
        guard plugins.selected == nil, pages.selected == nil, model.selectedTab == .chats else { return nil }
        if case .chat(let c)? = chatTabs.current?.route { return c.storedID }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            SidebarSearchField(text: $query)
                .padding(.horizontal, 10)
                .padding(.top, floating ? 40 : 46)
                .padding(.bottom, 8)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 1) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        nav
                        sections
                    } else {
                        results
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            ProfileRail()
        }
        .font(.system(size: 12))
        .task(id: runtime?.connection.id) { await store.load(runtime) }
        .task(id: runtime?.selectedProfile) { await store.load(runtime) }
        // Kept current while the window is open: new chats, titles, the jobs' countdowns.
        .task(id: runtime?.connection.id) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                await store.load(runtime)
            }
        }
        .onChange(of: model.selectedTab) { _, _ in Task { await store.load(runtime) } }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(200))
            await store.search(query, runtime: runtime)
        }
        .alert("Rename session", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                if let s = renaming { Task { await store.patch(s, ["title": .string(renameText)], runtime: runtime) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .alert("Delete \u{201C}\(deleting?.displayTitle ?? "")\u{201D}?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let s = deleting { Task { await store.delete(s, runtime: runtime) } }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("This removes the session and its transcript from the gateway.") }
    }

    // MARK: Pages

    @ViewBuilder private var nav: some View {
        SideNavRow(symbol: "plus.bubble", title: "New session", shortcut: "⌘N", selected: false) { HermesActions.newSession(model) }
        SideNavRow(symbol: "sparkles", title: "Capabilities", selected: pages.selected == .capabilities) { HermesActions.open(.capabilities, model) }
        SideNavRow(symbol: "bubble.left", title: "Messaging", selected: pages.selected == .messaging) { HermesActions.open(.messaging, model) }
        if tabs.contains(.files) {
            SideNavRow(symbol: "doc.on.doc", title: "Artifacts", selected: isTab(.files)) { HermesActions.open(.files, model) }
        }
        if tabs.contains(.cron) {
            SideNavRow(symbol: "clock", title: "Scheduled jobs", selected: isTab(.cron)) { HermesActions.open(.cron, model) }
        }
        // Vory's other pages the person keeps in the sidebar (Bots, Projects, Board…), after Desktop's own.
        ForEach(tabs.filter { ![.chats, .dashboard, .files, .cron, .settings].contains($0) }, id: \.self) { tab in
            SideNavRow(symbol: tab.symbol, title: tab.title, selected: isTab(tab),
                       badge: tab == .approvals ? (runtime?.needsAttention.count ?? 0) : 0) { HermesActions.open(tab, model) }
        }
        // Plugins add their pages here, as Desktop's `sidebar.nav` area does.
        PluginNavRows()
    }

    private func isTab(_ tab: AppModel.AppTab) -> Bool { model.selectedTab == tab && plugins.selected == nil && pages.selected == nil }

    // MARK: Sections

    private var pinned: [StoredSession] { store.sessions.filter { $0.pinned == true } }
    private var local: [StoredSession] { store.sessions.filter { $0.pinned != true && SidebarSessions.platforms[$0.source ?? ""] == nil } }
    private var byPlatform: [(String, [StoredSession])] {
        let rows = store.sessions.filter { $0.pinned != true && SidebarSessions.platforms[$0.source ?? ""] != nil }
        return Dictionary(grouping: rows) { $0.source ?? "" }.sorted { $0.key < $1.key }
    }

    @ViewBuilder private var sections: some View {
        SectionHeader(title: "Pinned", open: $pinnedOpen)
        if pinnedOpen {
            if pinned.isEmpty {
                Label("Right-click a chat to pin it", systemImage: "pin")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.36))
                    .padding(.horizontal, 9).padding(.vertical, 4)
            } else {
                ForEach(pinned) { row($0) }
            }
        }

        SectionHeader(title: "Sessions", open: $sessionsOpen) {
            HeaderButton(symbol: "plus", help: "New session") { HermesActions.newSession(model) }
        }
        if sessionsOpen {
            if store.loading && store.sessions.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(8)
            } else if let e = store.error, store.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(e).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(3)
                    Button("Retry") { Task { await store.load(runtime) } }.buttonStyle(.link).font(.system(size: 11))
                }
                .padding(.horizontal, 9)
            } else if local.isEmpty {
                Text("No sessions yet").font(.system(size: 11)).foregroundStyle(.white.opacity(0.36)).padding(.horizontal, 9).padding(.vertical, 4)
            } else {
                let groups = Dictionary(grouping: local) { SidebarSessions.bucket($0) }
                ForEach(["Earlier today", "Yesterday", "Earlier this week", "Last week", "Earlier this month", "Older"], id: \.self) { b in
                    if let rows = groups[b], !rows.isEmpty {
                        Text(b).font(.system(size: 10)).foregroundStyle(.white.opacity(0.36))
                            .padding(.horizontal, 9).padding(.top, 8).padding(.bottom, 2)
                        ForEach(rows) { row($0) }
                    }
                }
                if store.sessions.count >= store.limit {
                    Button {
                        store.limit += 40
                        Task { await store.load(runtime) }
                    } label: {
                        Label("Load more", systemImage: "ellipsis").font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                            .padding(.horizontal, 9).frame(height: 24)
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        ForEach(byPlatform, id: \.0) { source, rows in
            let open = Binding(get: { platformsOpenRaw.split(separator: ",").contains(Substring(source)) },
                               set: { on in
                                   var set = Set(platformsOpenRaw.split(separator: ",").map(String.init))
                                   if on { set.insert(source) } else { set.remove(source) }
                                   platformsOpenRaw = set.sorted().joined(separator: ",")
                               })
            SectionHeader(title: SidebarSessions.platforms[source] ?? source.capitalized, open: open)
            if open.wrappedValue { ForEach(rows.prefix(10)) { row($0) } }
        }

        if tabs.contains(.cron), !store.jobs.isEmpty {
            SectionHeader(title: "Scheduled jobs", open: $jobsOpen)
            if jobsOpen {
                ForEach(store.jobs) { job in
                    Button { HermesActions.open(.cron, model) } label: {
                        HStack(spacing: 8) {
                            StatusDot(color: job.enabled ? .white.opacity(0.18) : .white.opacity(0.08))
                            Text(job.name).lineLimit(1).foregroundStyle(.white.opacity(job.enabled ? 0.88 : 0.45))
                            Spacer(minLength: 4)
                            if let next = job.next, job.enabled {
                                Text(next, style: .relative).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.36)).lineLimit(1)
                            } else if !job.enabled {
                                Text("Paused").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.36))
                            }
                        }
                        .padding(.horizontal, 9).frame(height: 26).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var results: some View {
        SectionHeader(title: "Results", open: .constant(true), collapsible: false)
        if store.searchHits.isEmpty {
            Text("No sessions match \u{201C}\(query)\u{201D}").font(.system(size: 11)).foregroundStyle(.white.opacity(0.36)).padding(.horizontal, 9).padding(.vertical, 4)
        } else {
            ForEach(store.searchHits) { row($0) }
        }
    }

    // MARK: Rows

    private func row(_ s: StoredSession) -> some View {
        SessionRowView(session: s, selected: selectedID == s.id,
                       state: state(of: s)) {
            open(s)
        }
        // VibeVory: resting the pointer on a chat starts loading it (attach and history), so a click a moment later
        // finds it ready instead of waiting on the gateway.
        .onHover { inside in
            prewarm?.cancel()
            guard inside, let runtime, selectedID != s.id else { return }
            let (id, title, profile) = (s.id, s.displayTitle, s.profile)
            prewarm = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                _ = try? await runtime.openChat(storedID: id, title: title, profile: profile)
            }
        }
        .contextMenu {
            Button { ChatTabs.shared.newTab(); open(s) } label: { Label("Open in new tab", systemImage: "macwindow.badge.plus") }
            Divider()
            Button { renameText = s.displayTitle; renaming = s } label: { Label("Rename…", systemImage: "pencil") }
            Button { Task { await store.patch(s, ["pinned": .bool(!(s.pinned ?? false))], runtime: runtime) } } label: {
                Label(s.pinned == true ? "Unpin" : "Pin", systemImage: s.pinned == true ? "pin.slash" : "pin")
            }
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s.id, forType: .string) } label: { Label("Copy ID", systemImage: "doc.on.doc") }
            Divider()
            Button { Task { await store.patch(s, ["archived": .bool(true)], runtime: runtime) } } label: { Label("Archive", systemImage: "archivebox") }
            Button(role: .destructive) { deleting = s } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func state(of s: StoredSession) -> SessionRowView.State {
        guard let runtime else { return .idle }
        if runtime.needsAttention.contains(s.id) { return .needsYou }
        if runtime.chatForStored(s.id)?.isRunning == true { return .working }
        return .idle
    }

    private func open(_ s: StoredSession) {
        plugins.selected = nil
        pages.selected = nil
        model.selectedTab = .chats
        ChatNavigation.select(ChatRoute(storedID: s.id, title: s.displayTitle, profile: s.profile), in: &chatPath)
        if SidebarChrome.shared.revealed { SidebarChrome.shared.leave() }
    }
}

// MARK: - What the sidebar and ⌘K do

@MainActor
enum HermesActions {
    static func newSession(_ model: AppModel) {
        PluginHost.shared.selected = nil
        DesktopPages.shared.selected = nil
        // VibeVory: a new chat is the start page (greeting, model, composer), in a fresh tab, or the
        // empty tab already open. The chat itself starts with the first message sent there.
        let tabs = ChatTabs.shared
        if tabs.current?.route != nil { tabs.newTab() }
        model.selectedTab = .chats
    }

    static func open(_ page: DesktopPage, _ model: AppModel) {
        PluginHost.shared.selected = nil
        withAnimation(.smooth(duration: 0.2)) { DesktopPages.shared.selected = page }
    }

    static func open(_ tab: AppModel.AppTab, _ model: AppModel) {
        PluginHost.shared.selected = nil
        DesktopPages.shared.selected = nil
        if model.selectedTab == tab { model.tabReselected[tab, default: 0] += 1 } else { model.selectedTab = tab }
    }

    static func settings(_ model: AppModel) { open(.settings, model) }
}

// MARK: - Pieces

private let dim = Color.white.opacity(0.58)
private let faint = Color.white.opacity(0.36)

struct SidebarSearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(faint)
            TextField("Search sessions…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(faint) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(Color.white.opacity(focused ? 0.08 : 0.045), in: .rect(cornerRadius: 7))
    }
}

struct SideNavRow: View {
    var symbol: String
    var title: String
    var shortcut: String? = nil
    var selected: Bool
    var badge: Int = 0
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 16).foregroundStyle(selected ? .white.opacity(0.9) : dim)
                Text(title).foregroundStyle(selected ? .white.opacity(0.92) : dim)
                Spacer(minLength: 4)
                if badge > 0 {
                    Text("\(badge)").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 5).frame(height: 15)
                        .background(Color.orange.opacity(0.8), in: .capsule)
                } else if let shortcut {
                    Text(shortcut).font(.system(size: 10)).foregroundStyle(faint)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(Color.white.opacity(selected ? 0.07 : (hovering ? 0.045 : 0)), in: .rect(cornerRadius: 7))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Plugin pages, as rows among the pages.
private struct PluginNavRows: View {
    @State private var host = PluginHost.shared
    var body: some View {
        ForEach(host.pages) { page in
            SideNavRow(symbol: page.symbol, title: page.title, selected: host.selected == page.id) {
                DesktopPages.shared.selected = nil
                host.open(page)
            }
        }
    }
}

struct SectionHeader<Trailing: View>: View {
    var title: String
    @Binding var open: Bool
    var collapsible = true
    @ViewBuilder var trailing: () -> Trailing
    @State private var hovering = false

    init(title: String, open: Binding<Bool>, collapsible: Bool = true, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title; self._open = open; self.collapsible = collapsible; self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 6) {
            if collapsible {
                Image(systemName: "chevron.right").font(.system(size: 7, weight: .semibold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .foregroundStyle(faint)
            }
            Text(title.uppercased()).font(.system(size: 9.5, weight: .medium)).tracking(1.5).foregroundStyle(faint)
            Spacer(minLength: 4)
            trailing().opacity(hovering ? 1 : 0.0)
        }
        .padding(.horizontal, 9)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .contentShape(.rect)
        .onTapGesture { if collapsible { withAnimation(.smooth(duration: 0.22)) { open.toggle() } } }
        .onHover { hovering = $0 }
        .accessibilityAddTraits(.isHeader)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, open: Binding<Bool>, collapsible: Bool = true) {
        self.init(title: title, open: open, collapsible: collapsible) { EmptyView() }
    }
}

struct HeaderButton: View {
    var symbol: String
    var help: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium)).foregroundStyle(faint).frame(width: 16, height: 16).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct StatusDot: View {
    var color: Color
    var glow: Bool = false
    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6)
            .shadow(color: glow ? color.opacity(0.7) : .clear, radius: 4)
    }
}

struct SessionRowView: View {
    enum State { case idle, working, needsYou }
    var session: StoredSession
    var selected: Bool
    var state: State
    var action: () -> Void
    @SwiftUI.State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                switch state {
                case .needsYou: StatusDot(color: Color(red: 1, green: 0.81, blue: 0.48), glow: true)
                case .working: StatusDot(color: Color(red: 0.62, green: 0.71, blue: 1), glow: true)
                case .idle: StatusDot(color: .white.opacity(0.18))
                }
                Text(session.displayTitle).lineLimit(1).foregroundStyle(.white.opacity(selected ? 0.95 : 0.85))
                Spacer(minLength: 4)
                Text(SidebarSessions.age(session)).font(.system(size: 10.5)).foregroundStyle(faint)
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(Color.white.opacity(selected ? 0.08 : (hovering ? 0.045 : 0)), in: .rect(cornerRadius: 7))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(session.preview ?? session.displayTitle)
        .accessibilityLabel(session.displayTitle)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The profiles at the foot of the sidebar, as Desktop's profile rail: the one in use lit.
struct ProfileRail: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let rt = model.runtime
        HStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(rt?.profiles ?? [], id: \.name) { p in
                        let on = (rt?.selectedProfile ?? "default") == p.name
                        Button { rt?.selectedProfile = p.name } label: {
                            HStack(spacing: 5) {
                                if on { StatusDot(color: dotColor, glow: true) }
                                Text(p.displayName?.isEmpty == false ? p.displayName! : p.name)
                                    .font(.system(size: 11)).lineLimit(1)
                                    .foregroundStyle(.white.opacity(on ? 0.92 : 0.58))
                            }
                            .padding(.horizontal, 9).frame(height: 22)
                            .background(Color.white.opacity(on ? 0.1 : 0.05), in: .capsule)
                            .overlay(Capsule().strokeBorder(.white.opacity(on ? 0.14 : 0), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .help(p.description ?? p.name)
                    }
                }
            }
            .scrollIndicators(.never)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5) }
        .help(model.runtime.map { "\($0.connection.name) · \($0.socketState.label)" } ?? "Not connected")
    }

    private var dotColor: Color {
        guard let s = model.runtime?.socketState else { return .gray }
        switch s {
        case .open: return Color(red: 0.49, green: 0.88, blue: 0.69)
        case .connecting, .reconnecting, .idle: return .orange
        case .authRejected, .failed, .unreachable: return .red
        }
    }
}
