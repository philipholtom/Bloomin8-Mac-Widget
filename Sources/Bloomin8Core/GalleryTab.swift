import Foundation
import CryptoKit

/// A named group of galleries, optionally gated behind a password. This is a
/// UI-level deterrent only — the frame's HTTP API has no auth of its own, so
/// anyone on the LAN can still bypass it with a direct request. It just keeps
/// someone casually clicking through the menu bar (a kid, a houseguest) out
/// of galleries you've grouped away.
public struct GalleryTab: Identifiable, Equatable {
    public var id: UUID
    public var name: String
    public var galleryNames: Set<String>
    /// Kept in memory here for convenience, but deliberately NOT part of
    /// this type's JSON representation (see the custom `Codable` below) —
    /// it lives in the secret store (`SecretStore`) instead, keyed by `id`.
    public var passwordHash: String?

    public init(id: UUID = UUID(), name: String, galleryNames: Set<String> = [], passwordHash: String? = nil) {
        self.id = id
        self.name = name
        self.galleryNames = galleryNames
        self.passwordHash = passwordHash
    }

    public var isLocked: Bool { passwordHash != nil }

    static func keychainAccount(for id: UUID) -> String { "tabPasswordHash.\(id.uuidString)" }
}

extension GalleryTab: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, galleryNames
        /// Only ever read, never written — the key this struct used to
        /// store its password hash under directly, before hashes moved to
        /// Keychain. Kept here purely so an existing tab's hash can be
        /// migrated out of it once, on first decode after the upgrade.
        case legacyPasswordHash = "passwordHash"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        galleryNames = try container.decode(Set<String>.self, forKey: .galleryNames)

        let account = Self.keychainAccount(for: id)
        if let fromStore = SecretStore.read(account: account) {
            passwordHash = fromStore
        } else if let legacy = try container.decodeIfPresent(String.self, forKey: .legacyPasswordHash) {
            // One-time migration: this tab's hash was still sitting in the
            // UserDefaults-backed JSON blob from before hashes moved to
            // Keychain. Move it over now so this branch isn't hit again for
            // this tab.
            SecretStore.write(legacy, account: account)
            passwordHash = legacy
        } else {
            passwordHash = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(galleryNames, forKey: .galleryNames)
        // passwordHash is intentionally omitted — AppSettings.tabs writes it
        // to the secret store directly whenever a tab's hash changes.
    }
}

/// Salted, iterated password hashing (PBKDF2-HMAC-SHA256), with transparent
/// verification against the plain, unsalted single-round SHA256 this app
/// used before — `verify` upgrades a matching legacy hash to the new format
/// automatically, so existing passwords keep working without the user
/// having to re-set anything.
public enum PasswordHasher {
    private static let iterations: UInt32 = 150_000
    private static let saltLength = 16
    private static let keyLength = 32
    private static let scheme = "pbkdf2-sha256"

    /// Encodes as "pbkdf2-sha256$<iterations>$<base64 salt>$<base64 key>" —
    /// self-describing so a future scheme change stays both detectable and
    /// migratable, the same way this one migrates away from bare SHA256.
    public static func hash(_ password: String) -> String {
        var salt = [UInt8](repeating: 0, count: saltLength)
        _ = SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt)
        let derived = pbkdf2(password: password, salt: salt, iterations: iterations, keyLength: keyLength)
        return "\(scheme)$\(iterations)$\(Data(salt).base64EncodedString())$\(Data(derived).base64EncodedString())"
    }

    /// Checks `password` against `stored`, which may be in either the
    /// current salted format or the legacy bare-SHA256-hex format. Returns
    /// the match result; if `stored` was in the legacy format and matched,
    /// `upgradedHash` is set to a freshly-salted hash the caller should
    /// persist in place of it — so a correct password upgrades its own
    /// storage on the next successful unlock rather than needing a
    /// separate one-time migration pass.
    public static func verify(_ password: String, against stored: String) -> (matched: Bool, upgradedHash: String?) {
        if stored.hasPrefix("\(scheme)$") {
            let parts = stored.split(separator: "$", omittingEmptySubsequences: false)
            guard parts.count == 4,
                  let iterations = UInt32(parts[1]),
                  let salt = Data(base64Encoded: String(parts[2])),
                  let expected = Data(base64Encoded: String(parts[3]))
            else { return (false, nil) }
            let derived = pbkdf2(password: password, salt: [UInt8](salt), iterations: iterations, keyLength: expected.count)
            return (constantTimeEquals(derived, [UInt8](expected)), nil)
        }

        // Legacy format: a bare 64-character SHA256 hex digest.
        guard legacyHash(password) == stored else { return (false, nil) }
        return (true, hash(password))
    }

    private static func legacyHash(_ password: String) -> String {
        SHA256.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// PBKDF2 (RFC 8018) built on CryptoKit's HMAC rather than CommonCrypto
    /// — CryptoKit is already a dependency here (the legacy SHA256 path
    /// uses it too), so this avoids a second, C-interop crypto API for one
    /// function.
    private static func pbkdf2(password: String, salt: [UInt8], iterations: UInt32, keyLength: Int) -> [UInt8] {
        let key = SymmetricKey(data: Data(password.utf8))
        let hashLength = 32 // SHA256 output size
        let blockCount = Int((Double(keyLength) / Double(hashLength)).rounded(.up))
        var derived: [UInt8] = []
        derived.reserveCapacity(blockCount * hashLength)

        for blockIndex in 1...max(blockCount, 1) {
            var input = salt
            var blockIndexBE = UInt32(blockIndex).bigEndian
            withUnsafeBytes(of: &blockIndexBE) { input.append(contentsOf: $0) }

            var u = Data(HMAC<SHA256>.authenticationCode(for: input, using: key))
            var t = [UInt8](u)
            if iterations > 1 {
                for _ in 1..<iterations {
                    u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
                    for i in 0..<t.count { t[i] ^= u[i] }
                }
            }
            derived.append(contentsOf: t)
        }
        return Array(derived.prefix(keyLength))
    }

    /// Ordinary `==` on the derived bytes would short-circuit on the first
    /// differing byte, leaking (via timing) how many leading bytes matched
    /// — not that anyone's realistically timing attacks against a local
    /// menu bar app, but this costs nothing to do properly.
    private static func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
