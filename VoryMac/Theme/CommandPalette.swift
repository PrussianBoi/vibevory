import SwiftUI
import VoryCore

/// ⌘K (or ⌘P), as in Hermes Desktop: a glass box near the top of the window that searches
/// sessions, pages, plugins and actions, all from the keyboard.
@MainActor @Observable
final class CommandPaletteState {
    static let shared = CommandPaletteState()
    var shown = false
    func toggle() { withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) { shown.toggle() } }
    func close() { withAnimation(.smooth(duration: 0.18)) { shown = false } }
}

struct PaletteItem: Identifiable {
    var id: String
    var group: String
    var title: String
    var detail: String? = nil
    var symbol: String
    var shortcut: String? = nil
    var run: @MainActor () -> Void
}

struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Binding var chatPath: NavigationPath
    var tabs: [AppModel.AppTab]
    @State private var state = CommandPaletteState.shared
    @State private var store = SidebarSessions.shared
    @State private var plugins = PluginHost.shared
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private static let groupOrder = ["Go to", "Sessions", "Plugins", "Commands", "Profiles"]

    var body: some View {
        if state.shown {
            ZStack(alignment: .top) {
                // Clicking outside closes it; nothing is dimmed, as in Desktop.
                Color.black.opacity(0.001).ignoresSafeArea().onTapGesture { state.close() }
                box
                    .padding(.top, 64)
                    .transition(.asymmetric(insertion: .scale(scale: 0.97, anchor: .top).combined(with: .opacity), removal: .opacity))
            }
            .onAppear { query = ""; highlighted = 0; focused = true }
        }
    }

    private var box: some View {
        let list = items
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                TextField("Search sessions, views, and actions", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit { run(list) }
                    .onKeyPress(.downArrow) { move(1, list.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, list.count); return .handled }
                    .onKeyPress(.escape) { state.close(); return .handled }
                    .onChange(of: query) { _, _ in highlighted = 0 }
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        if list.isEmpty {
                            Text("Nothing matches \u{201C}\(query)\u{201D}").font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
                                .padding(16)
                        }
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, item in
                            if i == 0 || list[i - 1].group != item.group {
                                Text(item.group.uppercased()).font(.system(size: 9.5, weight: .medium)).tracking(1.5)
                                    .foregroundStyle(.white.opacity(0.36))
                                    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
                            }
                            row(item, on: i == highlighted)
                                .id(item.id)
                                .onTapGesture { highlighted = i; run(list) }
                                .onHover { if $0 { highlighted = i } }
                        }
                    }
                    .padding(.bottom, 6)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 400)
                .onChange(of: highlighted) { _, i in
                    if list.indices.contains(i) { proxy.scrollTo(list[i].id) }
                }
            }

            Rectangle().fill(.white.opacity(0.07)).frame(height: 0.5)
            HStack(spacing: 14) {
                Text("↑↓ move"); Text("↵ open"); Text("esc close")
            }
            .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.36))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .frame(width: 544)
        // Thicker frost than elsewhere: a list read over whatever is behind it.
        .vibeGlass(RoundedRectangle(cornerRadius: 16, style: .continuous), tint: .black.opacity(0.12), frost: 0.85)
        .shadow(color: .black.opacity(0.45), radius: 40, y: 24)
    }

    private func row(_ item: PaletteItem, on: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbol).font(.system(size: 12)).frame(width: 16).foregroundStyle(.white.opacity(0.58))
            Text(item.title).font(.system(size: 12)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
            if let d = item.detail {
                Text(d).font(.system(size: 11)).foregroundStyle(.white.opacity(0.36)).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let k = item.shortcut {
                Text(k).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.white.opacity(0.06), in: .rect(cornerRadius: 5))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.white.opacity(on ? 0.09 : 0), in: .rect(cornerRadius: 8))
        .padding(.horizontal, 6)
        .contentShape(.rect)
    }

    private func move(_ by: Int, _ count: Int) {
        guard count > 0 else { return }
        highlighted = (highlighted + by + count) % count
    }

    private func run(_ list: [PaletteItem]) {
        guard list.indices.contains(highlighted) else { return }
        let item = list[highlighted]
        state.close()
        item.run()
    }

    // MARK: The items

    private var items: [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        var all: [PaletteItem] = []

        all.append(PaletteItem(id: "new", group: "Go to", title: "New session", symbol: "plus", shortcut: "⌘N") { HermesActions.newSession(model) })
        all.append(PaletteItem(id: "settings", group: "Go to", title: "Settings", symbol: "gearshape", shortcut: "⌘,") { HermesActions.settings(model) })
        all.append(PaletteItem(id: "capabilities", group: "Go to", title: "Capabilities", detail: "skills, plugins", symbol: "sparkles") { HermesActions.open(.capabilities, model) })
        all.append(PaletteItem(id: "messaging", group: "Go to", title: "Messaging", symbol: "bubble.left") { HermesActions.open(.messaging, model) })
        for tab in tabs where tab != .chats && tab != .settings {
            let title = tab == .files ? "Artifacts" : tab == .cron ? "Scheduled jobs" : tab.title
            all.append(PaletteItem(id: "tab.\(tab.rawValue)", group: "Go to", title: title, symbol: tab.symbol) { HermesActions.open(tab, model) })
        }

        for page in plugins.pages {
            all.append(PaletteItem(id: "plugin.\(page.id)", group: "Plugins", title: page.title, symbol: page.symbol) {
                DesktopPages.shared.selected = nil
                plugins.open(page)
            })
        }

        all.append(PaletteItem(id: "sidebar", group: "Commands", title: SidebarChrome.shared.pinned ? "Hide sidebar" : "Pin sidebar", symbol: "sidebar.left", shortcut: "⌘B") { SidebarChrome.shared.toggle() })
        all.append(PaletteItem(id: "newtab", group: "Commands", title: "New tab", symbol: "plus.square.on.square", shortcut: "⌘T") { ChatTabs.shared.newTab() })
        all.append(PaletteItem(id: "reloadSessions", group: "Commands", title: "Reload sessions", symbol: "arrow.clockwise") {
            Task { await SidebarSessions.shared.load(model.runtime) }
        })

        if let rt = model.runtime {
            for p in rt.profiles where p.name != (rt.selectedProfile ?? "default") {
                all.append(PaletteItem(id: "profile.\(p.name)", group: "Profiles", title: "Switch to \(p.displayName?.isEmpty == false ? p.displayName! : p.name)", symbol: "person.crop.circle") {
                    rt.selectedProfile = p.name
                })
            }
        }

        // Sessions: the recent ones with no query, every match with one.
        let sessions = q.isEmpty ? Array(store.sessions.prefix(6))
            : store.sessions.filter { $0.displayTitle.localizedCaseInsensitiveContains(q) || ($0.preview ?? "").localizedCaseInsensitiveContains(q) }
        for s in sessions.prefix(30) {
            all.append(PaletteItem(id: "session.\(s.id)", group: "Sessions", title: s.displayTitle, detail: SidebarSessions.age(s), symbol: s.pinned == true ? "pin" : "bubble.left") {
                PluginHost.shared.selected = nil
                DesktopPages.shared.selected = nil
                model.selectedTab = .chats
                ChatNavigation.select(ChatRoute(storedID: s.id, title: s.displayTitle, profile: s.profile), in: &chatPath)
            })
        }

        let matched = q.isEmpty ? all : all.filter {
            $0.group == "Sessions" || $0.title.localizedCaseInsensitiveContains(q) || ($0.detail ?? "").localizedCaseInsensitiveContains(q)
        }
        return matched.sorted { (Self.groupOrder.firstIndex(of: $0.group) ?? 9) < (Self.groupOrder.firstIndex(of: $1.group) ?? 9) }
    }
}

/// The detail column's Desktop pages: Capabilities (skills, plugins) and Messaging (the platforms).
struct DesktopPageArea: View {
    @State private var pages = DesktopPages.shared
    @State private var tab = 0

    var body: some View {
        if let page = pages.selected {
            NavigationStack {
                Group {
                    switch page {
                    case .capabilities:
                        VStack(spacing: 0) {
                            Picker("", selection: $tab) {
                                Text("Skills").tag(0)
                                Text("Plugins").tag(1)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 220)
                            .padding(.top, 10)
                            if tab == 0 { SkillsView() } else { PluginsView() }
                        }
                    case .messaging:
                        ChannelsView()
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
            .transition(.opacity)
        }
    }
}
