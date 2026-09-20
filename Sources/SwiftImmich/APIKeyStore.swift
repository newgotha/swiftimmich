import CryptoKit
import Foundation
import IOKit
import Security

/// Keeps the Immich API key in a private file in Application Support, encrypted with a
/// key derived from this Mac, instead of in the login Keychain.
///
/// Why not the Keychain: a Keychain item remembers which builds of an app may read it by
/// a per-build code hash ("partition ID"), which a self-signed app can't make stable — so
/// every rebuild was asked for the login password again, however the app was signed.
/// The file is readable only by your account (mode 0600), and encrypted with a key tied
/// to this Mac's hardware ID, so a copy that ends up in a backup or another machine isn't
/// plain text. It is not as strong as the Keychain: a program running as you could read
/// it the same way this app does.
///
/// A key saved by an older version in the Keychain is moved across the first time it's
/// needed (one last Keychain prompt).
enum APIKeyStore {
    // The Keychain service/account of the original storage, kept for the one-time move.
    private static let legacyService = "dev.local.immichmac"
    private static let legacyAccount = "immich-api-key"

    private static var fileURL: URL { file(named: "api-key.bin") }
    private static var tokenURL: URL { file(named: "session-token.bin") }

    private static func file(named name: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SwiftImmich", isDirectory: true).appendingPathComponent(name)
    }

    static func load() -> String? {
        if let value = read(fileURL) { return value }
        // Not saved here yet: bring across a key from the old Keychain storage.
        if let legacy = loadLegacyFromKeychain() {
            save(legacy)
            return legacy
        }
        return nil
    }

    static func save(_ value: String) { write(value, to: fileURL) }

    /// The Locked Folder sign-in session (never the password itself).
    static func loadSessionToken() -> String? { read(tokenURL) }
    static func saveSessionToken(_ value: String) { write(value, to: tokenURL) }
    static func deleteSessionToken() { try? FileManager.default.removeItem(at: tokenURL) }

    private static func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: symmetricKey)
        else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    private static func write(_ value: String, to url: URL) {
        guard let plain = value.data(using: .utf8),
              let sealed = try? AES.GCM.seal(plain, using: symmetricKey).combined
        else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? sealed.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func delete() {
        try? FileManager.default.removeItem(at: fileURL)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: legacyAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Internals

    private static var symmetricKey: SymmetricKey {
        let material = Data("swiftimmich.api-key.v1|\(hardwareIdentifier)".utf8)
        return SymmetricKey(data: SHA256.hash(data: material))
    }

    /// This Mac's hardware UUID.
    private static var hardwareIdentifier: String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { if service != 0 { IOObjectRelease(service) } }
        if service != 0,
           let value = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String {
            return value
        }
        return "unknown-mac"
    }

    private static func loadLegacyFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: legacyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
