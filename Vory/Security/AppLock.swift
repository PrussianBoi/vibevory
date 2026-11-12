import Foundation
import LocalAuthentication
import Observation
import VoryCore

/// Optional Face ID / passcode lock, evaluated on launch and when returning from the background.
@MainActor
@Observable
final class AppLock {
    static let enabledKey = "appLockEnabled"

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey); if !newValue { isLocked = false } }
    }
    private(set) var isLocked = false
    private(set) var lastError: String?
    private var backgroundedAt: Date?

    init() { isLocked = isEnabled }

    var biometryName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    func didEnterBackground() { backgroundedAt = Date() }

    func willEnterForeground() {
        guard isEnabled else { return }
        if let t = backgroundedAt, Date().timeIntervalSince(t) > 5 { isLocked = true }
        backgroundedAt = nil
    }

    func unlock() async {
        let ctx = LAContext()
        ctx.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            lastError = error?.localizedDescription ?? "Authentication unavailable"
            isLocked = false
            return
        }
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Hermes")
            if ok { isLocked = false; lastError = nil }
        } catch {
            lastError = error.localizedDescription
        }
    }
}
