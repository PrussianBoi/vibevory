import AppKit
import UserNotifications

/// AppKit delegate for APNs registration and notification taps: the Mac's `AppDelegate`.
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor static var model: AppModel? { AppModel.shared }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        LocalNotifier.registerCategories()
        HealthReportsListener.shared.start()   // MetricKit's closes and freezes, kept on the device (#668)
        // The daily backup while the app runs (the phone has its background refresh for this).
        Task { @MainActor in BackupScheduler.start() }
        // Continuity Camera only where a photo can go, not in every right-click menu.
        Task { @MainActor in ContinuityMenuFilter.start() }
        // Sleep and wake are the Mac's away and back (the phone's are its scene phase).
        Task { @MainActor in MacSleepAway.shared.start() }
        // The main window, if launch didn't bring it (seen on a fresh Mac: only the menu bar
        // item came up). Window › Vory opens it, so ask for it the same way.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            Self.showMainWindowIfNone()
        }
    }

    static func showMainWindowIfNone() {
        let open = NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue.hasPrefix(MacWindow.main) == true }
        guard !open, let menu = NSApp.windowsMenu,
              let item = menu.items.first(where: { $0.title == "Vory" && $0.action != nil }) else { return }
        menu.performActionForItem(at: menu.index(of: item))
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in Self.model?.push.didRegister(token: deviceToken) }
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in Self.model?.push.didFailToRegister(error) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        // The app is in front: the chat itself shows what arrived, so no banner or sound. The
        // setup wizard's test push is the exception, since seeing it is the point.
        let info = notification.request.content.userInfo
        let kind = (info["hermes"] as? [String: Any])?["kind"] as? String
        return kind == "test" ? [.banner, .sound, .list] : []
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier == UNNotificationDefaultActionIdentifier ? nil : response.actionIdentifier
        let reply = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run { Self.model?.route(from: info, action: action, replyText: reply) }
    }
}
