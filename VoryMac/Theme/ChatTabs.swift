import SwiftUI
import VoryCore

/// What a tab holds: a chat or a group chat.
enum TabRoute: Hashable {
    case chat(ChatRoute)
    case room(RoomRoute)

    init?(_ any: Any) {
        if let c = any as? ChatRoute { self = .chat(c) }
        else if let r = any as? RoomRoute { self = .room(r) }
        else { return nil }
    }

    /// The same chat in another tab: a stored chat's id, or a room's id. A fresh chat matches nothing.
    var key: String? {
        switch self {
        case .chat(let c): return c.storedID
        case .room(let r): return "room:" + r.room.roomId
        }
    }

    var title: String {
        switch self {
        case .chat(let c):
            let t = c.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return t.isEmpty ? "New chat" : t
        case .room(let r): return r.room.name.isEmpty ? "Group chat" : r.room.name
        }
    }

    var path: NavigationPath {
        var p = NavigationPath()
        switch self {
        case .chat(let c): p.append(c)
        case .room(let r): p.append(r)
        }
        return p
    }
}

/// The open chats as tabs above the conversation, as in Hermes Desktop: choosing a chat in the
/// sidebar opens it in the tab in front (or goes to the tab that already has it), + opens a new one.
@MainActor @Observable
final class ChatTabs {
    static let shared = ChatTabs()

    struct Tab: Identifiable, Hashable {
        let id = UUID()
        var route: TabRoute?
        var title: String { route?.title ?? "New chat" }
    }

    private(set) var tabs: [Tab] = [Tab()]
    var selected: UUID?

    private init() {
        selected = tabs.first?.id
        // Every selection the chat list makes comes through here (ChatNavigation.select).
        ChatNavigation.onSelect = { any in
            guard let route = TabRoute(any) else { return }
            MainActor.assumeIsolated { ChatTabs.shared.show(route) }
        }
    }

    var current: Tab? { tabs.first { $0.id == selected } }

    /// A chat chosen in the sidebar: its own tab if one has it, else the tab in front.
    func show(_ route: TabRoute) {
        if let key = route.key, let t = tabs.first(where: { $0.route?.key == key }) {
            selected = t.id
            return
        }
        if let i = tabs.firstIndex(where: { $0.id == selected }) {
            tabs[i].route = route
        } else {
            let t = Tab(route: route)
            tabs.append(t)
            selected = t.id
        }
    }

    /// A new, empty tab in front.
    func newTab() {
        let t = Tab()
        tabs.append(t)
        selected = t.id
    }

    func close(_ id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: i)
        if tabs.isEmpty { tabs = [Tab()] }
        if selected == id { selected = tabs[min(i, tabs.count - 1)].id }
    }

    /// ⌥⌘← / ⌥⌘→.
    func step(_ by: Int) {
        guard let i = tabs.firstIndex(where: { $0.id == selected }), !tabs.isEmpty else { return }
        selected = tabs[(i + by + tabs.count) % tabs.count].id
    }
}

/// The tabs as Liquid Glass pills, with + at the end.
struct TabStrip: View {
    @State private var model = ChatTabs.shared

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.tabs) { tab in
                        TabPill(tab: tab, selected: tab.id == model.selected, closable: model.tabs.count > 1 || tab.route != nil) {
                            withAnimation(.smooth(duration: 0.22)) { model.selected = tab.id }
                        } close: {
                            withAnimation(.smooth(duration: 0.22)) { model.close(tab.id) }
                        }
                    }
                    Button {
                        withAnimation(.smooth(duration: 0.22)) { model.newTab() }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)).frame(width: 24, height: 24).contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .help("New tab (⌘T)")
                    .keyboardShortcut("t", modifiers: .command)
                }
                .padding(.horizontal, 4)
        }
        .scrollClipDisabled()
        .background(alignment: .center) {
            // ⌥⌘← / ⌥⌘→ walk the tabs.
            HStack {
                Button("") { model.step(-1) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("") { model.step(1) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            }
            .opacity(0).accessibilityHidden(true)
        }
    }
}

private struct TabPill: View {
    var tab: ChatTabs.Tab
    var selected: Bool
    var closable: Bool
    var select: () -> Void
    var close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
                        Text(tab.title)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(selected ? 0.9 : 0.4))
                .lineLimit(1)
                .frame(maxWidth: 200, alignment: .leading)
            if closable {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                        .opacity(hovering || selected ? 0.8 : 0)
                }
                .buttonStyle(.plain)
                .help("Close tab")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, closable ? 6 : 12)
        .frame(height: 24)
        .contentShape(.capsule)
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .background { if selected { Capsule().fill(.white.opacity(0.08)).overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5)) } else if hovering { Capsule().fill(.white.opacity(0.04)) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The chat tabs in the window's title bar, where Hermes Desktop has them, in place of the title.
/// Only while the Chats page is on show: it stays mounted behind the other pages.
struct ChatTabsChrome: ViewModifier {
    @Environment(\.macPageShown) private var pageShown

    func body(content: Content) -> some View {
        content
            .toolbar {
                if pageShown {
                    ToolbarItem(placement: .navigation) {
                        HStack(spacing: 0) {
                            TitleBarLeading()
                            TabStrip().frame(minWidth: 120, idealWidth: 420, maxWidth: 560)
                        }
                    }
                    .sharedBackgroundVisibility(.hidden)
                    ToolbarItem(placement: .primaryAction) { TitleBarTrailing() }
                        .sharedBackgroundVisibility(.hidden)
                }
            }
            .toolbar(removing: .title)
    }
}

/// By the window controls, as in Desktop: the sidebar button (⌘B), then room for the pinned
/// sidebar so what follows starts over the detail column.
struct TitleBarLeading: View {
    @State private var chrome = SidebarChrome.shared

    var body: some View {
        HStack(spacing: 0) {
            TitleBarButton(symbol: "sidebar.left", help: chrome.pinned ? "Hide sidebar (⌘B)" : "Pin sidebar (⌘B)") { chrome.toggle() }
                .keyboardShortcut("b", modifiers: .command)
            // The traffic lights end near 78 pt; the toolbar item starts just after them.
            Color.clear.frame(width: chrome.pinned ? max(0, SidebarChrome.width - 78 - 30 - 6) : 6, height: 1)
        }
    }
}

/// The top right, as in Desktop: Settings (⌘,) and the layout menu.
struct TitleBarTrailing: View {
    @Environment(AppModel.self) private var model
    @State private var chrome = SidebarChrome.shared

    var body: some View {
        HStack(spacing: 2) {
            TitleBarButton(symbol: "gearshape", help: "Open settings (⌘,)") { HermesActions.settings(model) }
            Menu {
                Toggle("Pin sidebar", isOn: Binding(get: { chrome.pinned }, set: { _ in chrome.toggle() }))
                Button("Command palette…") { CommandPaletteState.shared.toggle() }
            } label: {
                Image(systemName: "rectangle.split.2x1").font(.system(size: 13)).foregroundStyle(.white.opacity(0.58))
                    .frame(width: 28, height: 24).contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Layout")
        }
    }
}

struct TitleBarButton: View {
    var symbol: String
    var help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13))
                .foregroundStyle(.white.opacity(hovering ? 0.85 : 0.58))
                .frame(width: 28, height: 24)
                .background(.white.opacity(hovering ? 0.07 : 0), in: .rect(cornerRadius: 7))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
