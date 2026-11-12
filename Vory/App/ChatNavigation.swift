import SwiftUI
import VoryCore

/// The chat list beside the open chat (the Mac today; the iPad and the open iPhone Duo in 1.5):
/// what selecting a chat does to the detail column, shared by every root that has one.
///
/// On the phone the list owns a stack and pushes. Beside a detail column, a selection
/// replaces whatever the column shows, the way picking a conversation does in Messages, and
/// a fresh "new chat" is told apart from the last one (two such routes are otherwise equal, and
/// the second would change nothing). No AppKit or UIKit here: it compiles in every target.
enum ChatNavigation {
    /// Shows `route` in the detail column in place of what it shows now.
    /// Told of every selection (the Mac's chat tabs listen): the route, as `Any`.
    nonisolated(unsafe) static var onSelect: ((Any) -> Void)?

    static func select(_ route: some Hashable, in path: inout NavigationPath) {
        if let chat = route as? ChatRoute {
            let t = tokened(chat)
            onSelect?(t as Any)
            path = NavigationPath([t])
        } else {
            onSelect?(route as Any)
            path = NavigationPath([route])
        }
    }

    /// A fresh chat (no stored id) with a token of its own, so it differs from the last fresh
    /// one; a stored chat is itself.
    static func tokened(_ chat: ChatRoute) -> ChatRoute {
        guard chat.storedID == nil else { return chat }
        var fresh = chat
        fresh.token = UUID()
        return fresh
    }

    /// Pushes `route` onto the list's own stack (the phone).
    static func push(_ route: some Hashable, onto path: inout NavigationPath) {
        path.append(route)
    }

    /// The row to highlight for `route`: a stored chat's id, or a group chat's room.
    static func selectionID(of route: some Hashable) -> String? {
        if let chat = route as? ChatRoute { return chat.storedID }
        if let room = route as? RoomRoute { return "room:" + room.room.roomId }
        return nil
    }

    /// The highlight id of a row, to compare with `selectionID(of:)`.
    static func selectionID(ofRoom roomId: String) -> String { "room:" + roomId }
}

/// The detail column's stack: the placeholder until a chat is chosen, and the chat or group
/// chat the list selected. A chat is identified by its route, so choosing another replaces
/// the open one instead of updating it in place; no back chevron, the list beside it is the
/// way between chats.
struct ChatDetailStack<Placeholder: View>: View {
    @Binding var path: NavigationPath
    @ViewBuilder var placeholder: () -> Placeholder

    var body: some View {
        NavigationStack(path: $path) {
            placeholder()
                .navigationDestination(for: ChatRoute.self) { route in
                    ConversationView(route: route).id(route).navigationBarBackButtonHidden(true)
                        #if os(macOS)
                        .modifier(ChatTabsChrome())
                        #endif
                }
                .navigationDestination(for: RoomRoute.self) { r in
                    RoomView(room: r.room, initialText: r.initialText).id(r).navigationBarBackButtonHidden(true)
                        #if os(macOS)
                        .modifier(ChatTabsChrome())
                        #endif
                }
        }
    }
}
