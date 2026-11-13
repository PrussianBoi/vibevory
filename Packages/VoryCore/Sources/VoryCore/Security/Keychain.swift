import Foundation
import Security

/// Thin wrapper over the generic-password keychain. Items live in `accessGroup` when one is set,
/// which is how the app, its widgets and the watch app read the same gateways and the same
/// widget snapshot without an App Group.
public enum Keychain {
    /// Keyed on the app's bundle id even inside an extension (the notification service, widgets,
    /// the watch app), so every process reads the same items.
    public static let service = baseBundleID + ".gateways"

    /// The host app's bundle id, with any extension / companion suffix stripped.
    public static var baseBundleID: String {
        var base = Bundle.main.bundleIdentifier ?? "Vory"
        for marker in [".watchkitapp", ".LiveActivity", ".widgets", ".complications", ".notificationcontent", ".notificationservice", ".notifications"] {
            if let r = base.range(of: marker) { base = String(base[..<r.lowerBound]) }
        }
        return base
    }
    /// `TEAMID.com.vorantx.vory.shared` (from `keychain-access-groups`); nil keeps the default group.
    nonisolated(unsafe) public static var accessGroup: String?

    #if DEBUG
    /// The demo copy of the app (its own bundle id, ad-hoc signed) has no Keychain it may use:
    /// items live in memory for the life of the process instead. Never set in a release build.
    nonisolated(unsafe) public static var memoryOnly = false
    nonisolated(unsafe) private static var memory: [String: Data] = [:]
    private static let memoryLock = NSLock()
    /// Reads, writes (a value) or removes (nil) an in-memory item; returns what is there after.
    private static func inMemory(_ key: String, write: Data?? = nil) -> Data? {
        memoryLock.lock(); defer { memoryLock.unlock() }
        if let write { memory[key] = write }
        return memory[key]
    }
    #endif

    private static func base(_ account: String) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        if let g = accessGroup { q[kSecAttrAccessGroup as String] = g }
        return dataProtected(q)
    }

    /// On macOS `SecItem*` defaults to the legacy file keychain, where access groups and the
    /// accessibility class mean nothing; this flag selects the iOS-style keychain instead, so the
    /// Mac app and its extensions share items the same way the iPhone does. A no-op elsewhere.
    private static func dataProtected(_ q: [String: Any]) -> [String: Any] {
        #if os(macOS)
        // An ad-hoc signed build (the CI artifact) has no keychain-access-groups entitlement, and
        // the data-protection keychain refuses it (-34018). With no group, use the login keychain.
        guard accessGroup != nil else { return q }
        var q = q
        q[kSecUseDataProtectionKeychain as String] = true
        return q
        #else
        return q
        #endif
    }

    public static func set(_ data: Data, account: String) throws {
        #if DEBUG
        if memoryOnly { _ = inMemory(account, write: .some(data)); return }
        #endif
        if let vault = FileVault.shared { try vault.write(data, key: account); return }
        let query = base(account)
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            let add = query.merging(attrs) { $1 }
            let s2 = SecItemAdd(add as CFDictionary, nil)
            guard s2 == errSecSuccess else { throw KeychainError(status: s2) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public static func get(account: String) -> Data? {
        #if DEBUG
        if memoryOnly { return inMemory(account) }
        #endif
        if let vault = FileVault.shared { return vault.read(key: account) }
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    public static func delete(account: String) {
        #if DEBUG
        if memoryOnly { _ = inMemory(account, write: .some(nil)); return }
        #endif
        if let vault = FileVault.shared { vault.delete(key: account); return }
        SecItemDelete(base(account) as CFDictionary)
    }

    public static func setCodable<T: Encodable>(_ value: T, account: String) throws {
        try set(try JSONEncoder().encode(value), account: account)
    }

    public static func getCodable<T: Decodable>(_ type: T.Type, account: String) -> T? {
        get(account: account).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    /// Moves items written before `accessGroup` existed into the group so widgets can see them.
    /// Runs in a few milliseconds and is a no-op once everything has moved.
    public static func migrateToAccessGroupIfNeeded() {
        #if DEBUG
        if memoryOnly { return }
        #endif
        guard let group = accessGroup else { return }
        let q: [String: Any] = dataProtected([kSecClass as String: kSecClassGenericPassword,
                                              kSecAttrService as String: service,
                                              kSecReturnAttributes as String: true,
                                              kSecReturnData as String: true,
                                              kSecMatchLimit as String: kSecMatchLimitAll])
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return }
        for item in items where (item[kSecAttrAccessGroup as String] as? String) != group {
            guard let account = item[kSecAttrAccount as String] as? String, let data = item[kSecValueData as String] as? Data else { continue }
            if (try? set(data, account: account)) != nil {
                var old: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
                if let g = item[kSecAttrAccessGroup as String] as? String { old[kSecAttrAccessGroup as String] = g }
                SecItemDelete(dataProtected(old) as CFDictionary)
            }
        }
    }

    // MARK: iCloud Keychain

    /// The synced copies live under their own service, apart from the device-only items above:
    /// the running app, its extensions and the watch keep reading the local items, and nothing
    /// that queries `service` (the migration included) ever sees these.
    public static let cloudService = baseBundleID + ".cloud"

    private static func cloudBase(_ account: String) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: cloudService,
                                kSecAttrAccount as String: account,
                                kSecAttrSynchronizable as String: true]
        if let g = accessGroup { q[kSecAttrAccessGroup as String] = g }
        return dataProtected(q)
    }

    /// Writes an item that iCloud Keychain carries to the person's other devices (end-to-end
    /// encrypted by the system). With iCloud Keychain off it is simply a local item.
    public static func setSynced(_ data: Data, account: String) throws {
        #if DEBUG
        if memoryOnly { _ = inMemory("cloud:" + account, write: .some(data)); return }
        #endif
        if let vault = FileVault.shared { try vault.write(data, key: "cloud:" + account); return }
        let query = cloudBase(account)
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            let s2 = SecItemAdd(query.merging(attrs) { $1 } as CFDictionary, nil)
            guard s2 == errSecSuccess else { throw KeychainError(status: s2) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public static func getSynced(account: String) -> Data? {
        #if DEBUG
        if memoryOnly { return inMemory("cloud:" + account) }
        #endif
        if let vault = FileVault.shared { return vault.read(key: "cloud:" + account) }
        var q = cloudBase(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    public static func deleteSynced(account: String) {
        #if DEBUG
        if memoryOnly { _ = inMemory("cloud:" + account, write: .some(nil)); return }
        #endif
        if let vault = FileVault.shared { vault.delete(key: "cloud:" + account); return }
        SecItemDelete(cloudBase(account) as CFDictionary)
    }

    /// Resolves the shared group from the bundle: `<AppIdentifierPrefix><base bundle id>.shared`,
    /// where the base id strips `.watchkitapp…` / `.LiveActivity` / other extension suffixes.
    public static func sharedGroupFromBundle() -> String? {
        guard let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String, !prefix.isEmpty else { return nil }
        return prefix + baseBundleID + ".shared"
    }
}

public struct KeychainError: LocalizedError {
    public let status: OSStatus
    public init(status: OSStatus) { self.status = status }
    public var errorDescription: String? { "Keychain error \(status)" }
}

/// The Mac build without a keychain-access-groups entitlement (every CI build: no Apple team) keeps
/// its items in files instead of the login keychain. The login keychain ties each item to the build
/// that wrote it, so every update asked for the Mac's password again, item by item. The files sit in
/// Application Support in a folder only this user can open (0700, files 0600), and nothing here ever
/// touches the old keychain items, so they never ask again either.
public final class FileVault: @unchecked Sendable {
    public static let shared: FileVault? = {
        #if os(macOS)
        guard Keychain.accessGroup == nil else { return nil }
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return FileVault(folder: support.appendingPathComponent(Keychain.baseBundleID, isDirectory: true).appendingPathComponent("vault", isDirectory: true))
        #else
        return nil
        #endif
    }()

    let folder: URL
    private let lock = NSLock()

    public init(folder: URL) { self.folder = folder }

    private func file(_ key: String) -> URL {
        let name = Data(key.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "=", with: "")
        return folder.appendingPathComponent(name)
    }

    private static func key(fileName: String) -> String? {
        var b = fileName.replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: "-", with: "+")
        while b.count % 4 != 0 { b += "=" }
        return Data(base64Encoded: b).flatMap { String(data: $0, encoding: .utf8) }
    }

    public func write(_ data: Data, key: String) throws {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let url = file(key)
        try data.write(to: url, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func read(key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return try? Data(contentsOf: file(key))
    }

    @discardableResult public func delete(key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let url = file(key)
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    /// Every key that starts with `prefix`, without it.
    public func keys(prefix: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.compactMap(Self.key(fileName:)).filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
}
