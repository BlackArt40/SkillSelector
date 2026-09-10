import CryptoKit
import Foundation
import IOKit

/// Local, device-bound storage for the user's translation API key.
///
/// The key is encrypted with AES-GCM using key material derived from this
/// machine's hardware identifier (`IOPlatformUUID`), so the on-disk blob
/// yields nothing to a reader who copies it elsewhere — the plaintext only
/// decrypts on the device that wrote it. This is convenience storage, not a
/// hardware-level secret vault: the derivation is deterministic, so it
/// protects against casual reading and file exfiltration rather than an
/// attacker who can extract process memory or reverse-engineer the app.
public enum TranslationKeyStore {
    public enum StoreError: Error, Equatable {
        case unreadable
        case cryptographic
        case couldNotDeriveKey
        case io
    }

    private static let service = "com.skillselector.translation"
    private static let account = "deepl-api-key"

    /// Test seam: redirects the on-disk location so unit tests never touch
    /// the real Application Support folder. Product code always writes the
    /// default directory; only tests set this.
    nonisolated(unsafe) static var overrideDirectoryURL: URL?

    /// Encrypted blob location — the app's Application Support directory,
    /// the same folder that already hosts the index database.
    private static var fileURL: URL {
        (overrideDirectoryURL ?? defaultDirectoryURL)
            .appendingPathComponent("translation-key.enc")
    }

    private static var defaultDirectoryURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SkillSelector", isDirectory: true)
    }

    /// Returns the stored key, or nil when absent/unreadable. A missing or
    /// corrupt blob reads as absent rather than crashing the launch path.
    public static func load() -> String? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        guard let keyData = try? decrypt(data) else { return nil }
        return String(data: keyData, encoding: .utf8)
    }

    /// Encrypts and writes the key, overwriting any previous value.
    public static func save(_ key: String) throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw StoreError.io
        }
        let data = try encrypt(Data(key.utf8))
        do {
            try data.write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            throw StoreError.io
        }
    }

    /// Best-effort removal; a missing file counts as removed.
    public static func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: Encryption

    private static func encrypt(_ plaintext: Data) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: try derivedKey())
        guard let combined = sealed.combined else { throw StoreError.cryptographic }
        return combined
    }

    private static func decrypt(_ combined: Data) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: try derivedKey())
        } catch {
            throw StoreError.cryptographic
        }
    }

    /// 32-byte AES key derived from the machine's hardware UUID plus the
    /// service/account salt. Deterministic per device — no key is persisted
    /// in plaintext, and the blob cannot be decrypted on another machine.
    private static func derivedKey() throws -> SymmetricKey {
        guard let uuid = hardwareIdentifier() else { throw StoreError.couldNotDeriveKey }
        var hasher = SHA256()
        hasher.update(data: Data(uuid.utf8))
        hasher.update(data: Data(service.utf8))
        hasher.update(data: Data(account.utf8))
        return SymmetricKey(data: hasher.finalize())
    }

    /// The machine's `IOPlatformUUID` — stable across launches on a given
    /// hardware install, distinct across machines.
    private static func hardwareIdentifier() -> String? {
        guard let matching = IOServiceMatching("IOPlatformExpertDevice") else { return nil }
        // `IOServiceGetMatchingService` consumes the matching dictionary
        // (CF_RELEASES_ARGUMENT), so no manual release is needed.
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(
            service,
            "IOPlatformUUID" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String
        else { return nil }
        return property
    }
}