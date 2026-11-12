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
    @Namespace private var glass

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(model.tabs) { tab in
                        TabPill(tab: tab, selected: tab.id == model.selected, closable: model.tabs.count > 1 || tab.route != nil) {
                            withAnimation(.smooth(duration: 0.22)) { model.selected = tab.id }
                        } close: {
                            withAnimation(.smooth(duration: 0.22)) { model.close(tab.id) }
                        }
                        .glassEffectID(tab.id, in: glass)
                    }
                    Button {
                        withAnimation(.smooth(duration: 0.22)) { model.newTab() }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .help("New tab (⌘T)")
                    .keyboardShortcut("t", modifiers: .command)
                }
                .padding(.horizontal, 4)
            }
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
            Circle().fill(selected ? Color.accentColor : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
            Text(tab.title)
                .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
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
        .frame(height: 28)
        .contentShape(.capsule)
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .glassEffect(selected ? .regular.tint(Color.accentColor.opacity(0.22)).interactive() : .regular.interactive(), in: .capsule)
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
                        TabStrip().frame(minWidth: 120, idealWidth: 420, maxWidth: 560)
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
            }
            .toolbar(removing: .title)
            // The thread fades out under the title bar instead of running behind the tabs.
            .scrollEdgeEffectStyle(.hard, for: .top)
    }
}
