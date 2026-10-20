import Foundation
import Security

/// Stores the app's few secrets (the Local Folder / locked-gallery password
/// hashes and the remote-push API tokens) as small strings under an account
/// name, in a private file: `~/Library/Application Support/Blooming8/secrets.json`,
/// in a folder only this user can open (mode 0700), with the file itself
/// readable only by this user (mode 0600).
///
/// **Why a file and not the Keychain.** Neither product is sandboxed or signed
/// with a paid Developer ID, so every rebuild is a different program as far
/// as macOS is concerned. A Keychain item remembers which builds may read it,
/// and asked for the user's password again after every build — which an open
/// access list can't fix, because a second per-build "partition" check sits
/// behind it. A file has no such check.
///
/// **What that gives up.** The Keychain adds encryption at rest and a per-app
/// check; this file relies on the Mac's own protections (account permissions
/// and FileVault, if it's on). The password values are salted, slow
/// PBKDF2 hashes, not passwords. The remote-push token is the one real
/// secret in here.
///
/// Both the widget and the windowed app use the same file.
///
/// **Migration.** Older builds kept these in the Keychain. If an account isn't
/// in the file, the Keychain is checked once; a secret found there is copied
/// into the file and removed from the Keychain. Looking up an item that
/// isn't there never prompts, so this costs nothing once everything has moved.
enum SecretStore {
    private static let lock = NSLock()

    /// `BLOOMING8_SECRETS_DIR` overrides the folder, for tests only.
    private static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["BLOOMING8_SECRETS_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Blooming8", isDirectory: true)
    }

    private static var fileURL: URL { directory.appendingPathComponent("secrets.json") }

    static func read(account: String) -> String? {
        lock.lock()
        if let value = load()[account] {
            lock.unlock()
            return value
        }
        lock.unlock()

        guard let legacy = LegacyKeychain.read(account: account) else { return nil }
        write(legacy, account: account)
        LegacyKeychain.delete(account: account)
        return legacy
    }

    static func write(_ value: String, account: String) {
        lock.lock()
        defer { lock.unlock() }
        var secrets = load()
        secrets[account] = value
        save(secrets)
    }

    static func delete(account: String) {
        lock.lock()
        var secrets = load()
        if secrets.removeValue(forKey: account) != nil { save(secrets) }
        lock.unlock()
        LegacyKeychain.delete(account: account)
    }

    // MARK: - File

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func save(_ secrets: [String: String]) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let data = try JSONEncoder().encode(secrets)
            try data.write(to: fileURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("SecretStore: couldn't save secrets: %@", error.localizedDescription)
        }
    }
}

/// Read-and-delete access to the Keychain items older builds created, used
/// only to move them into the file.
private enum LegacyKeychain {
    private static let service = "com.pholtom.blooming8"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
