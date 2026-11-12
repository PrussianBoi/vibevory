import SwiftUI
import VoryCore

/// The Mac window's root: the first-run tour until a gateway is saved, then the app. The lock
/// covers either while it is on.
struct MacRootView: View {
    @Environment(AppModel.self) private var model
    /// Asked once, on the first connection: the Companion on this gateway, or one to install.
    @AppStorage("companionPromptShown") private var companionPromptShown = false
    @AppStorage("notificationsSetupCardDone") private var setupCardDone = false
    @State private var showCompanionPrompt = false
    @State private var showInstaller = false
    @State private var companionFound: String?
    @State private var voiceSession = HandsFreeSession.shared
    @Environment(\.openWindow) private var openWindow
    /// DEBUG: `-vory-show-welcome` shows the first screen over a configured app.
    static let forceWelcome: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-vory-show-welcome")
        #else
        return false
        #endif
    }()

    var body: some View {
        ZStack {
            if model.hasConnections && !Self.forceWelcome {
                MainSplitView()
            } else {
                OnboardingView()
                    .frame(minWidth: 520, minHeight: 680)
                    // No name in the title bar and no strip behind it: the first screens run
                    // to the top of the window, with only the three window buttons over them.
                    .toolbar(removing: .title)
                    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            }
            if model.lock.isLocked {
                MacLockView()
                    .toolbar(removing: .title)
                    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            }
        }
        // The aurora behind the whole window: the columns and lists are clear, so it shows
        // through the sidebar's Liquid Glass and between the messages.
        .containerBackground(for: .window) { AuroraBackground() }
        // The first time a gateway comes up on this Mac (its own first connection, or one the
        // keychain already held): what the Companion needs from here, if anything.
        .onChange(of: model.runtime?.connection.id, initial: true) { _, _ in offerCompanion() }
        // "Read replies aloud": a reply that finishes in the chat on screen is spoken.
        .task { VoiceCoordinator.shared.observeReplies() }
        // The window's open action, kept for the places with no view to ask (an App Intent run
        // while the window is closed).
        .task { MacWindow.openMain = { openWindow(id: MacWindow.main) } }
        // Voice mode's window opens when a session starts, wherever it was started from.
        .onChange(of: voiceSession.isActive) { _, on in if on { openWindow(id: MacWindow.voice) } }
        #if DEBUG
        .task { if AppModel.forceSignIn, let c = model.store.active { model.signInPrompt = [c] } }
        #endif
        // One sheet at a time, and none over the lock: the sign-in a restore owes comes first,
        // the Companion prompt once that is settled (its check needs a signed-in gateway).
        .onChange(of: model.signInPrompt.isEmpty) { _, _ in offerCompanion() }
        .onChange(of: model.needsSignIn == nil) { _, _ in offerCompanion() }
        .onChange(of: model.lock.isLocked) { _, _ in offerCompanion() }
        .sheet(isPresented: Binding(get: { !model.signInPrompt.isEmpty && !model.lock.isLocked && !showCompanionPrompt && !showInstaller },
                                    set: { if !$0 { model.signInPrompt = [] } })) {
            GatewaySignInSheet(connections: model.signInPrompt).withAppModel()
        }
        .sheet(isPresented: $showCompanionPrompt) {
            CompanionPromptSheet(found: companionFound, install: {
                setupCardDone = true
                showCompanionPrompt = false
                showInstaller = true
            }, allow: {
                setupCardDone = true
                showCompanionPrompt = false
                Task { _ = await model.push.requestAuthorization() }
            }, later: {
                setupCardDone = false
                showCompanionPrompt = false
            })
            .withAppModel()
        }
        .sheet(isPresented: $showInstaller) {
            NavigationStack {
                SetupWizardHost()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showInstaller = false } } }
            }
            .frame(minWidth: 560, minHeight: 680)
            .withAppModel()
        }
    }
}

extension MacRootView {
    /// Shows the Companion prompt, once, when a gateway is up and nothing stands in its way.
    private func offerCompanion() {
        // Not in Artha: it has no Companion of its own to offer (the Vory Companion prompt is gone).
        guard false else { return }
        // Never for the demo (#494): it used the prompt up, and the person's own gateway was never offered it.
        guard !companionPromptShown, let rt = model.runtime, !rt.isEphemeral, model.signInPrompt.isEmpty, model.needsSignIn == nil, !model.lock.isLocked else { return }
        companionPromptShown = true
        Task {
            // The gateway must have answered before it can be asked about the Companion: asked
            // too soon, the probe found nothing and offered an install to a gateway that had
            // one (a restored gateway, with the Companion set up from the phone, got that).
            for _ in 0..<40 where rt.profileHome == nil {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard model.runtime === rt, rt.profileHome != nil else {
                // Not connected within ten seconds: not asked now, and asked again next time.
                companionPromptShown = false
                return
            }
            let probe = PushSetupModel()
            await probe.checkCompanion(runtime: rt)
            guard probe.companionCheckError == nil else { companionPromptShown = false; return }
            companionFound = probe.installedVersion
            showCompanionPrompt = true
        }
    }
}

/// The iOS tab bar as a sidebar: the same tabs, in the user's order, with no limit of four.
/// Chats get three columns like Messages (list in the middle, the open chat beside it); the
/// other tabs take the rest of the window.
private struct MainSplitView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(TabLayout.storageKey) private var tabLayoutRaw = ""
    @State private var columns = NavigationSplitViewVisibility.all
    /// The detail column's stack: the chat (or group chat) beside the list.
    @State private var chatPath = NavigationPath()
    /// Settings › Home › "Open Vory on": the page the window starts on, as on the phone.
    @AppStorage("launchTab") private var launchTab = "chats"
    @State private var openedOnLaunchTab = false
    @State private var appearedAt = Date.distantPast
    /// The rail's other pages, kept mounted once visited (first visit order). See `body`.
    @State private var kept: [AppModel.AppTab] = []
    /// Decided 2026-10-13: a page left with a
    /// page pushed on it keeps it, as the phone's tabs do. Setting this key (`defaults write <bundle id>
    /// mac.pages.popOnLeave -bool YES`) goes back to 1.5 (18)'s way: a page left is re-created at its
    /// root a moment after the switch, out of sight.
    static let popOnLeaveKey = "mac.pages.popOnLeave"
    /// Bumped to re-create a page left behind when `popOnLeaveKey` is set.
    @State private var resets: [AppModel.AppTab: Int] = [:]
    /// What each page had the keyboard focus on when it was left, given back when it shows again (#640).
    @State private var pageFocus = PageFocus()
    /// How long after the window appears a page that the gateway has to vouch for (the Board)
    /// may still take the start: its plugin is probed once the gateway answers, a second or two in.
    private static let launchTabGrace: TimeInterval = 8

    /// The pages in the rail, less the ones the gateway cannot show (the Board without its plugin).
    private var tabs: [AppModel.AppTab] { TabLayout.parse(tabLayoutRaw).visible(hiding: model.hiddenTabs) }

    /// The window's own liveness (visible and in front), to combine with the page's.
    @Environment(\.botsLive) private var windowLive

    @State private var plugins = PluginHost.shared
    @State private var desk = DesktopPages.shared
    @State private var chrome = SidebarChrome.shared

    private var chatsInFront: Bool { model.selectedTab == .chats && plugins.selected == nil && desk.selected == nil }

    private var detail: some View {
        let chats = model.selectedTab == .chats
        return ZStack {
          ZStack {
            ChatTabsArea(path: $chatPath)
                // A renamed bot's open chat is stale (#315): back to the placeholder.
                .onReceive(NotificationCenter.default.publisher(for: .hermesBotRenamed)) { _ in chatPath = NavigationPath() }
                .modifier(MacPage(shown: chats && plugins.selected == nil && desk.selected == nil, windowLive: windowLive))
            ForEach(keptPages, id: \.self) { tab in
                page(tab)
                    .id(resets[tab, default: 0])
                    .modifier(MacPage(shown: model.selectedTab == tab && plugins.selected == nil && desk.selected == nil, windowLive: windowLive))
            }
          }
          // A plugin or Desktop page in front hides the rest (the page is smoke over the aurora, not paint).
          .opacity(plugins.selected == nil && desk.selected == nil ? 1 : 0)
          .allowsHitTesting(plugins.selected == nil && desk.selected == nil)
          PluginPageArea()
          DesktopPageArea()
        }
        .animation(.smooth(duration: 0.2), value: plugins.selected)
        .animation(.smooth(duration: 0.2), value: desk.selected)
        .task(id: model.runtime?.connection.id) { plugins.attach(model.runtime) }
    }

    var body: some View {
        // Hermes Desktop's layout, in SwiftUI: one sidebar (the pages, then the chats) and, beside
        // it, the chat tabs or the page chosen. The pages stay mounted once visited, so a switch
        // is an opacity change (see `MacPage`).
        // Hermes Desktop's layout, in SwiftUI: the sidebar pinned beside the chats, or hidden and
        // sliding in as floating Liquid Glass from the window's left edge (⌘B switches); beside
        // it, the chat tabs or the page chosen. The pages stay mounted once visited, so a switch
        // is an opacity change (see `MacPage`).
        HStack(spacing: 0) {
            if chrome.pinned {
                HermesSidebar(tabs: tabs, chatPath: $chatPath)
                    .frame(width: SidebarChrome.width - 16)
                    .frame(maxHeight: .infinity)
                    // VibeVory: see-through Liquid Glass over the aurora, inset from the window's edges.
                    .vibeGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .padding(8)
                    .ignoresSafeArea(.container, edges: .top)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            detail
        }
        .overlay(alignment: .topLeading) {
            if !chrome.pinned {
                ZStack(alignment: .topLeading) {
                    // The left edge: the pointer arriving here slides the sidebar in.
                    Color.clear.frame(width: 8).frame(maxHeight: .infinity).contentShape(.rect)
                        .onHover { if $0 { chrome.reveal() } }
                    if chrome.revealed {
                        HermesSidebar(tabs: tabs, chatPath: $chatPath, floating: true)
                            .frame(width: SidebarChrome.width)
                            .frame(maxHeight: .infinity)
                            .vibeGlass(RoundedRectangle(cornerRadius: 18, style: .continuous), frost: 0.6)
                            .shadow(color: .black.opacity(0.4), radius: 30, y: 18)
                            .padding(8)
                            .onHover { inside in if inside { chrome.reveal() } else { chrome.leave() } }
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                .ignoresSafeArea(.container, edges: .top)
            }
        }
        // ⌘K over everything, as in Desktop.
        .overlay { CommandPalette(chatPath: $chatPath, tabs: tabs) }
        .background {
            // Vory's chat list, out of sight: it still answers ⌘N and voice requests and opens what
            // they ask for (the sidebar above is Desktop's, drawn apart from it).
            ChatListView(detailPath: $chatPath)
                .environment(\.macPageShown, false)
                .frame(width: 1, height: 1)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            HStack {
                Button("") { CommandPaletteState.shared.toggle() }.keyboardShortcut("k", modifiers: .command)
                Button("") { CommandPaletteState.shared.toggle() }.keyboardShortcut("p", modifiers: .command)
            }
            .opacity(0).accessibilityHidden(true)
        }
        // The title bar's buttons on every page but the chats (whose own toolbar has them with the tabs).
        .toolbar {
            if !chatsInFront {
                ToolbarItem(placement: .navigation) { TitleBarLeading() }.sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .primaryAction) { TitleBarTrailing() }.sharedBackgroundVisibility(.hidden)
            }
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .animation(.smooth(duration: 0.3), value: chrome.pinned)
        #if DEBUG
        // CI screenshots: `-vibe-sidebar hidden|reveal`, `-vibe-open-palette`.
        .task {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-vibe-sidebar"), args.indices.contains(i + 1) {
                chrome.pinned = false
                if args[i + 1] == "reveal" { try? await Task.sleep(for: .seconds(5)); chrome.reveal() }
            }
            if args.contains("-vibe-open-palette") { try? await Task.sleep(for: .seconds(6)); CommandPaletteState.shared.toggle() }
        }
        #endif
        #if DEBUG
        .overlay {
            if ProcessInfo.processInfo.arguments.contains("-vibe-glass-lab") {
                ZStack { AuroraBackground(); GlassLab() }.ignoresSafeArea()
            }
        }
        #endif
        // Room for the rail, the list and a reading column with a table in it: narrower than this
        // the bubbles squeezed to a few words a line.
        .frame(minWidth: 860, minHeight: 520)
        // The chosen first page, once, when it is still in the rail and the gateway can show it
        // (the Board without its plugin opened blank on the phone). A page the gateway has to
        // vouch for is hidden until its probe answers, so the start waits a few seconds for it,
        // and only while nothing else has been chosen meanwhile.
        .onAppear { appearedAt = Date(); openOnLaunchTab(tabs) }
        // Signpost intervals for the hitch traces (Smooth, 1.5): a page switch and a chat open
        // on the Mac, so Instruments can score each one by name; free when nothing listens.
        .onChange(of: model.selectedTab, initial: true) { was, now in
            if now != .chats, !kept.contains(now) { kept.append(now) }
            guard was != now else { return }
            Smooth.animate("page")
            if was != .chats, UserDefaults.standard.bool(forKey: Self.popOnLeaveKey) {
                Task { @MainActor in resets[was, default: 0] += 1 }
            }
            // The keyboard focus leaves the page that hides: it stays mounted, and its composer,
            // list or field kept the focus (keys and pastes aimed at a page not on show). The
            // window holds it, as when the page was torn down. What the page had is kept for it, and
            // the page that shows gets back what it had (#640), once it is on show.
            if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(MacWindow.main) == true }) {
                if !pageFocus.leave(was, in: w) {
                    Perf.stamp("page: the focus stayed with \(String(describing: w.firstResponder))")
                }
                let focus = pageFocus
                Task { @MainActor in focus.back(now, in: w) }
            }
        }
        .onChange(of: chatPath) { _, _ in
            Smooth.animate("chatOpen")
            // A chat opened (the sidebar, ⌘N, a notification) brings the chats back in front.
            plugins.selected = nil
            desk.selected = nil
            if model.selectedTab != .chats { model.selectedTab = .chats }
        }
        .onChange(of: tabs) { _, now in
            kept.removeAll { !now.contains($0) }
            openOnLaunchTab(now)
            // The page showing left the rail (the plugin went, or the layout changed): back to Chats.
            if !now.contains(model.selectedTab) { model.selectedTab = .chats }
        }
    }

    /// The pages mounted beside Chats: those visited and still in the rail, and the one being
    /// shown now (in the same pass, so a first visit never draws a frame with no page).
    private var keptPages: [AppModel.AppTab] {
        var pages = kept.filter { tabs.contains($0) }
        let now = model.selectedTab
        if now != .chats, !pages.contains(now) { pages.append(now) }
        return pages
    }

    private func openOnLaunchTab(_ now: [AppModel.AppTab]) {
        guard !openedOnLaunchTab, let tab = AppModel.AppTab(rawValue: launchTab), tab != .chats else { openedOnLaunchTab = true; return }
        guard Date().timeIntervalSince(appearedAt) < Self.launchTabGrace, model.selectedTab == .chats else { openedOnLaunchTab = true; return }
        guard now.contains(tab) else { return }
        openedOnLaunchTab = true
        model.selectedTab = tab
    }

    @ViewBuilder private func page(_ tab: AppModel.AppTab) -> some View {
        switch tab {
        case .chats: EmptyView()   // the three-column layout above
        case .dashboard: NavigationStack { DashboardView() }
        case .bots: BotsView()
        case .files: FilesView()
        case .projects: NavigationStack { ProjectsView() }
        case .status: NavigationStack { StatusView() }
        case .sessions: NavigationStack { SessionsView() }
        case .cron: NavigationStack { CronView() }
        case .kanban: NavigationStack { MacBoardView() }
        case .approvals: NavigationStack { ApprovalsView() }
        case .system: NavigationStack { SystemView() }
        // Settings pages are Forms; grouped is the Mac's System Settings look.
        case .settings: SettingsView().formStyle(.grouped)
        }
    }
}

/// A page of the window's ZStack, on show or kept behind the one that is: hidden, it is not
/// drawn, not hit-testable, not read by accessibility, and its faces hold still (`botsLive`),
/// the four rules the iPhone's RootView applies to its tabs. The Mac's window toolbar items are
/// declared by the pages, so a hidden page drops its own (they read `macPageShown`).
private struct MacPage: ViewModifier {
    var shown: Bool
    var windowLive: Bool
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
            .environment(\.botsLive, windowLive && shown)
            .environment(\.macPageShown, shown)
    }
}

/// Vory itself, alive: the flat finish animates and keeps its colour in a background window
/// (the live glass one took on the window's inactive look).
private let liveVory = BotLookSpec(shape: "cloud", eyes: "classic", hex: "#3B7BFF", finish: "flat")

/// The tabs as a rail: an icon and a word each, the chosen one on a tinted tile, ⌘1…⌘9 to
/// switch, and the gateway at the foot. Narrow on purpose; the chat list is the wide column.
private struct Sidebar: View {
    @Environment(AppModel.self) private var model
    var tabs: [AppModel.AppTab]
    /// Whether this rail declares the pages' ⌘ numbers (only the rail on show does).
    var shortcuts = true

    static let width: CGFloat = 84

    var body: some View {
        // Every page can sit here, as many as wanted; with all of them on in a short window
        // the rail scrolls.
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) {
                ForEach(Array(tabs.enumerated()), id: \.element) { i, tab in
                    RailItem(tab: tab, selected: model.selectedTab == tab, badge: badge(tab), shortcut: i < 9 ? Character("\(i + 1)") : nil, shortcutOn: shortcuts) {
                        // The page already showing, chosen again (a click or its ⌘ number): back to
                        // its top, as a second tap on the phone's tab bar does.
                        if model.selectedTab == tab { model.tabReselected[tab, default: 0] += 1 } else { model.selectedTab = tab }
                    }
                }
                RailMore()
            }
            .padding(.top, 6).padding(.horizontal, 6).padding(.bottom, 4)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contextMenu { RailPages() }
        // The rail does not fold away, so it needs no toggle (which would not fit over it anyway).
        .toolbar(removing: .sidebarToggle)
        .safeAreaInset(edge: .bottom, spacing: 0) { GatewayFooter() }
        // Outermost, and as a closed range: set inside the toolbar modifier the column came out 144 pt wide.
        .navigationSplitViewColumnWidth(min: Self.width, ideal: Self.width, max: Self.width)
    }

    private func badge(_ tab: AppModel.AppTab) -> Int {
        switch tab {
        case .chats, .approvals: return model.runtime?.needsAttention.count ?? 0
        case .settings: return model.companionUpdateAvailable ? 1 : 0
        default: return 0
        }
    }
}

private struct RailItem: View {
    var tab: AppModel.AppTab
    var selected: Bool
    var badge: Int
    var shortcut: Character?
    var shortcutOn = true
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        let button = Button(action: action) {
            VStack(spacing: 3) {
                // The same icons as the iPhone's tab bar: the Vory outline for Bots, and each
                // symbol as it is drawn there (no filled variant for the chosen one).
                RailIcon(tab: tab)
                    .frame(height: 24)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 { CountBadge(badge).scaleEffect(0.78).offset(x: 12, y: -8) }
                    }
                Text(tab.title).font(.caption2.weight(selected ? .semibold : .regular)).lineLimit(1)
            }
            .foregroundStyle(selected ? Color.accentColor : .secondary)
            .frame(width: Sidebar.width - 12, height: 54)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.14) : (hovering ? Color.primary.opacity(0.06) : .clear))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(shortcut.map { "\(tab.title) (⌘\($0))" } ?? tab.title)
        // One name for VoiceOver (the icon and the word read as one), with what waits there.
        .accessibilityLabel(badge > 0 ? "\(tab.title), \(badge) need\(badge == 1 ? "s" : "") you" : tab.title)
        .accessibilityHint(shortcut.map { "Shows \(tab.title). Command \($0)." } ?? "Shows \(tab.title).")
        .accessibilityIdentifier("rail.\(tab.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        // Optional rather than an if/else, so the button keeps its identity when the rail hides.
        button.keyboardShortcut(shortcutOn ? shortcut.map { KeyboardShortcut(KeyEquivalent($0), modifiers: .command) } : nil)
    }
}

/// A page's icon as the iPhone's tab bar draws it.
private struct RailIcon: View {
    var tab: AppModel.AppTab
    var size: CGFloat = 19

    var body: some View {
        if tab == .bots {
            VoryOutlineIcon().frame(width: size * 1.5, height: size * 1.28)
        } else {
            Image(systemName: tab.symbol).font(.system(size: size, weight: .medium))
        }
    }
}

/// The pages as switches: on puts a page in the rail, off takes it out. Chats and Settings stay.
/// `rows`: laid out for the popover (icon, name, switch at the edge); otherwise menu items.
private struct RailPages: View {
    @Environment(AppModel.self) private var model
    @AppStorage(TabLayout.storageKey) private var tabLayoutRaw = ""
    var rows = false

    private var layout: TabLayout { TabLayout.parse(tabLayoutRaw) }

    private func shown(_ tab: AppModel.AppTab) -> Binding<Bool> {
        Binding(get: { layout.contains(tab) }, set: { on in
            var l = layout
            l.set(tab, enabled: on)
            tabLayoutRaw = l.encoded
            // The page being looked at left the rail: back to Chats.
            if !on, model.selectedTab == tab { model.selectedTab = .chats }
        })
    }

    var body: some View {
        // The ones in the rail first, in their order, then the rest.
        ForEach(layout.tabs + AppModel.AppTab.allCases.filter { !layout.contains($0) }, id: \.self) { tab in
            // A page the gateway cannot show (the Board without its plugin) stays listed,
            // greyed, with the one line that says what it needs.
            let unavailable = model.hiddenTabs.contains(tab)
            if rows {
                HStack(spacing: 10) {
                    RailIcon(tab: tab, size: 14).frame(width: 24).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tab.title).foregroundStyle(unavailable ? .secondary : .primary)
                        if unavailable, let plugin = tab.needsPlugin {
                            Text("Needs the \(plugin) plugin turned on on the gateway.").font(.caption2).foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 12)
                    Toggle("Show \(tab.title) in the sidebar", isOn: shown(tab)).labelsHidden()
                        .toggleStyle(.switch).controlSize(.small)
                        .disabled(TabLayout.required.contains(tab) || unavailable)
                }
            } else {
                Toggle(isOn: shown(tab)) {
                    if unavailable, let plugin = tab.needsPlugin { Label("\(tab.title) (needs the \(plugin) plugin)", systemImage: tab.symbol) }
                    else { Label(tab.title, systemImage: tab.symbol) }
                }
                .disabled(TabLayout.required.contains(tab) || unavailable)
            }
        }
    }
}

/// The last thing in the rail: the way to put more pages in it, or take some out.
private struct RailMore: View {
    @State private var choosing = false
    @State private var hovering = false

    var body: some View {
        Button { choosing = true } label: {
            VStack(spacing: 3) {
                Image(systemName: "ellipsis.circle").font(.system(size: 19, weight: .medium)).frame(height: 24).accessibilityHidden(true)
                Text("More").font(.caption2).lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .frame(width: Sidebar.width - 12, height: 54)
            .background { RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering || choosing ? Color.primary.opacity(0.06) : .clear) }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Choose the pages in the sidebar")
        .accessibilityLabel("More pages")
        .accessibilityHint("Chooses the pages in the sidebar.")
        .accessibilityIdentifier("rail.more")
        .popover(isPresented: $choosing, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Pages in the sidebar").font(.headline)
                VStack(alignment: .leading, spacing: 8) { RailPages(rows: true) }
                Text("Switch on as many as you like. Their order is in Settings › Appearance.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 240)
            .withAppModel()
        }
    }
}

/// The detail column before a chat is chosen.
private struct NoChatView: View {
    @Environment(\.macPageShown) private var shown
    var body: some View {
        VStack(spacing: 12) {
            // The guide plays only while something is working; idle, it holds still (#248).
            BotFaceView(spec: liveVory, size: 72, mood: BotFaceView.Mood(profile: "vory-mac-empty", state: BotAmbient.shared.decorativeActive ? .guide : .idle))
            Text("No chat selected").font(.title3.weight(.semibold))
            Text("Pick one from the list, or press ⌘N for a new one.").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Something of this column's own in the toolbar, however small: with nothing here the
        // list's buttons slid from over the list to the far end of the window, and came back
        // when a chat was opened.
        .toolbar {
            if shown {
                ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
                    .sharedBackgroundVisibility(.hidden)
            }
        }
        // The placeholder must not bring a toolbar strip with it: in dark mode it showed as a
        // lighter band across the top of the empty column.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}

/// The gateway under the sidebar: its name, the socket, and the way to its form.
private struct GatewayFooter: View {
    @Environment(AppModel.self) private var model
    @State private var editing = false

    private var name: String { model.runtime?.connection.name ?? model.store.active?.name ?? "No gateway" }
    /// The socket, and with a backup address (#283) the address in use.
    private var state: String { model.runtime.map { [$0.addressLabel, $0.socketState.label].compactMap { $0 }.joined(separator: " · ") } ?? (model.activationError ?? "Connecting…") }
    private var dot: Color {
        guard let s = model.runtime?.socketState else { return .secondary }
        switch s {
        case .open: return .green
        case .connecting, .reconnecting, .idle: return .orange
        case .authRejected, .failed, .unreachable: return .red
        }
    }

    var body: some View {
        // In the demo (#392) there is no gateway form to open: the click goes to Settings, where Leave demo is.
        Button { if model.isInDemo { model.selectedTab = .settings } else { editing = true } } label: {
            VStack(spacing: 4) {
                BotFaceView(spec: liveVory, size: 30, active: model.runtime != nil && BotAmbient.shared.decorativeActive, mood: BotFaceView.Mood(profile: "vory-mac-footer"))
                    .overlay(alignment: .bottomTrailing) {
                        Circle().fill(dot).frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                            .offset(x: 2, y: 2)
                    }
                Text(name).font(.caption2.weight(.medium)).lineLimit(1).foregroundStyle(.secondary)
                if model.isInDemo { DemoTag() }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("\(name) · \(state)\nClick to edit the gateway")
        .accessibilityLabel("Gateway \(name)\(model.isInDemo ? ", demo" : ""), \(state)")
        .accessibilityHint(model.isInDemo ? "Opens Settings, to leave the demo." : "Edits the gateway.")
        .accessibilityIdentifier("rail.gateway")
        .disabled(model.store.active == nil)
        .sheet(isPresented: $editing) { GatewayFormSheet(existing: model.store.active).withAppModel() }
    }
}

/// The gateway form as the Mac shows it everywhere: a sheet with its own Cancel and Save (the
/// sidebar's gateway, Settings › Gateways, Status › Sign-in, Push setup's "Sign in again"),
/// never pushed beside a toolbar Back.
struct GatewayFormSheet: View {
    var existing: GatewayConnection?
    var body: some View {
        NavigationStack { GatewayFormView(existing: existing) }
            .frame(minWidth: 520, minHeight: 640)
    }
}

/// The lock, over everything, until Touch ID or the password says yes.
private struct MacLockView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.system(size: 34, weight: .medium)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text("Artha is locked").font(.headline)
            if let e = model.lock.lastError { Text(e).font(.footnote).foregroundStyle(.secondary) }
            Button("Unlock with \(model.lock.biometryName)") { Task { await model.lock.unlock() } }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .task { await model.lock.unlock() }
    }
}

// MARK: - Hermes Desktop layout

/// The sidebar, as Hermes Desktop has it: New chat and the pages at the top, then search and the
/// chats (the chat list, unchanged underneath), and the gateway at the foot. One Liquid Glass column.
private struct DesktopSidebar: View {
    @Environment(AppModel.self) private var model
    var tabs: [AppModel.AppTab]
    @Binding var chatPath: NavigationPath

    var body: some View {
        ChatListView(detailPath: $chatPath)
            .environment(\.macPageShown, true)
            .safeAreaInset(edge: .top, spacing: 4) { PageNav(tabs: tabs) }
            .safeAreaInset(edge: .bottom, spacing: 0) { GatewayFooter() }
            .toolbar(removing: .sidebarToggle)
            // A chat picked in the list brings the chats back in front of any page.
            .onChange(of: chatPath) { _, _ in
                PluginHost.shared.selected = nil
                if model.selectedTab != .chats { model.selectedTab = .chats }
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 380)
    }
}

/// New chat and the pages, as rows.
private struct PageNav: View {
    @Environment(AppModel.self) private var model
    @State private var plugins = PluginHost.shared
    var tabs: [AppModel.AppTab]

    var body: some View {
        VStack(spacing: 1) {
            NavRow(symbol: "square.and.pencil", title: "New chat", selected: false, shortcut: nil) {
                // A fresh tab, and the same new chat ⌘N makes, opened in it.
                ChatTabs.shared.newTab()
                plugins.selected = nil
                model.selectedTab = .chats
                model.newChatRequest = UUID()
            }
            ForEach(Array(tabs.filter { $0 != .chats && $0 != .dashboard }.enumerated()), id: \.element) { i, tab in
                NavRow(symbol: tab.symbol, title: tab.title, selected: model.selectedTab == tab && plugins.selected == nil,
                       badge: tab == .approvals ? (model.runtime?.needsAttention.count ?? 0) : 0,
                       shortcut: i < 9 ? Character("\(i + 1)") : nil) {
                    plugins.selected = nil
                    if model.selectedTab == tab { model.tabReselected[tab, default: 0] += 1 } else { model.selectedTab = tab }
                }
            }
            PluginNavSection { page, selected in
                NavRow(symbol: page.symbol, title: page.title, selected: selected, shortcut: nil) {
                    plugins.open(page)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .contextMenu { RailPages() }
    }
}

private struct NavRow: View {
    var symbol: String
    var title: String
    var selected: Bool
    var badge: Int = 0
    var shortcut: Character?
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer(minLength: 4)
                if badge > 0 { CountBadge(badge).scaleEffect(0.8) }
                else if let shortcut, hovering {
                    Text("⌘\(String(shortcut).uppercased())").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.16) : (hovering ? Color.primary.opacity(0.07) : .clear))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .keyboardShortcut(shortcut.map { KeyboardShortcut(KeyEquivalent($0), modifiers: .command) })
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The chats beside the sidebar: the tab strip on top and the open tab's chat below it.
private struct ChatTabsArea: View {
    @Binding var path: NavigationPath
    @State private var tabs = ChatTabs.shared

    var body: some View {
        // The tabs in the title bar, as in Hermes Desktop. Not above the chat in its frame: the
        // thread runs up under the window's toolbar (its glass), and over anything placed there.
        // The start page carries them, and each chat (ChatDetailStack): a pushed view's toolbar
        // takes the place of the stack's.
        ChatDetailStack(path: $path) { StartPage(path: $path).modifier(ChatTabsChrome()) }
            .onChange(of: tabs.selected) { _, _ in
                path = tabs.current?.route?.path ?? NavigationPath()
            }
            #if DEBUG
            // `-vibe-open-chat <stored id>`: opens that chat a few seconds in (the CI screenshots).
            .task {
                let args = ProcessInfo.processInfo.arguments
                guard let i = args.firstIndex(of: "-vibe-open-chat"), args.indices.contains(i + 1) else { return }
                try? await Task.sleep(for: .seconds(4))
                ChatNavigation.select(ChatRoute(storedID: args[i + 1]), in: &path)
            }
            #endif
    }
}

/// An empty tab: a quiet greeting, a few things to ask, and the composer in the middle. Typing
/// there (or a suggestion) starts the chat with that message.
private struct StartPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.macPageShown) private var shown
    @Binding var path: NavigationPath
    @State private var text = ""
    @FocusState private var focused: Bool

    private static let suggestions = ["Check my inbox", "Summarize yesterday", "Plan today"]

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 5 ? "Good night" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 40)
            Text(greeting)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: Color(red: 0.78, green: 0.82, blue: 1).opacity(0.25), radius: 12)
                .accessibilityAddTraits(.isHeader)
            Text("What should Hermes work on?")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
            HStack(spacing: 7) {
                ForEach(Self.suggestions, id: \.self) { s in
                    Button { text = s; focused = true } label: {
                        Text(s).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.58))
                            .padding(.horizontal, 12).frame(height: 26)
                            .background(.white.opacity(0.05), in: .capsule)
                            .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 14)
            composer.padding(.top, 34)
            Spacer(minLength: 80)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            if shown {
                ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) }
                    .sharedBackgroundVisibility(.hidden)
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onAppear { focused = true }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Ask Hermes anything…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit(send)
            HStack(spacing: 6) {
                Text(model.runtime?.profiles.first { $0.name == (model.runtime?.selectedProfile ?? "default") }?.model ?? "Hermes")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.58)).lineLimit(1)
                    .padding(.horizontal, 9).frame(height: 22)
                    .background(.white.opacity(0.06), in: .capsule)
                Spacer()
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color(red: 0.08, green: 0.08, blue: 0.16))
                        .frame(width: 24, height: 24)
                        .background(.white.opacity(text.isEmpty ? 0.35 : 0.85), in: .circle)
                }
                .buttonStyle(.plain)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.leading, 15).padding(.trailing, 10).padding(.top, 12).padding(.bottom, 9)
        .frame(maxWidth: 620)
        .vibeGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 25, y: 18)
    }

    private func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        text = ""
        let profile = model.runtime?.selectedProfile
        ChatNavigation.select(ChatRoute(storedID: nil, title: nil, profile: profile, initialText: t), in: &path)
    }
}
