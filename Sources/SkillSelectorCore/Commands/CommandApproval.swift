import Foundation
import CryptoKit

public enum CommandApprovalState: String, Codable, Hashable, Sendable {
    case approved
    case approvalRequired
}

public struct ApprovedCommand: Codable, Hashable, Sendable {
    public let fingerprint: String
    public let executablePath: String
    public let arguments: [String]
    public let configurationFingerprint: String?

    public init(executablePath: String, arguments: [String], configurationFingerprint: String? = nil) {
        self.executablePath = URL(fileURLWithPath: executablePath).standardizedFileURL.path
        self.arguments = arguments
        self.configurationFingerprint = configurationFingerprint
        self.fingerprint = CommandApproval.fingerprint(
            executablePath: self.executablePath,
            arguments: arguments,
            configurationFingerprint: configurationFingerprint
        )
    }
}

public protocol CommandApprovalStoring: AnyObject {
    func fingerprints() -> Set<String>
    func save(fingerprints: Set<String>)
}

public final class UserDefaultsCommandApprovalStore: CommandApprovalStoring {
    private let defaults: UserDefaults
    private let key: String
    public init(defaults: UserDefaults = .standard, key: String = "SkillSelector.commandApprovals") {
        self.defaults = defaults
        self.key = key
    }
    public func fingerprints() -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }
    public func save(fingerprints: Set<String>) {
        defaults.set(Array(fingerprints).sorted(), forKey: key)
    }
}

public final class CommandApproval: @unchecked Sendable {
    private let store: CommandApprovalStoring
    private let lock = NSLock()

    public init(store: CommandApprovalStoring = UserDefaultsCommandApprovalStore()) {
        self.store = store
    }

    public func state(for command: ApprovedCommand) -> CommandApprovalState {
        lock.lock(); defer { lock.unlock() }
        return store.fingerprints().contains(command.fingerprint) ? .approved : .approvalRequired
    }

    public func state(executableURL: URL, arguments: [String], configurationFingerprint: String? = nil) -> CommandApprovalState {
        state(for: ApprovedCommand(executablePath: executableURL.path, arguments: arguments, configurationFingerprint: configurationFingerprint))
    }

    public func approve(_ command: ApprovedCommand) {
        lock.lock(); defer { lock.unlock() }
        var values = store.fingerprints()
        values.insert(command.fingerprint)
        store.save(fingerprints: values)
    }

    public func revoke(_ command: ApprovedCommand) {
        lock.lock(); defer { lock.unlock() }
        var values = store.fingerprints()
        values.remove(command.fingerprint)
        store.save(fingerprints: values)
    }

    public static func fingerprint(
        executablePath: String,
        arguments: [String],
        configurationFingerprint: String? = nil
    ) -> String {
        var bytes = Data()
        append(executablePath, to: &bytes)
        for argument in arguments { append(argument, to: &bytes) }
        bytes.append(configurationFingerprint == nil ? 0 : 1)
        if let configurationFingerprint {
            append(configurationFingerprint, to: &bytes)
        }
        // Length framing keeps argument boundaries unambiguous. A
        // cryptographic digest makes the persisted approval key stable while
        // avoiding collisions that could authorize a different command.
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func append(_ value: String, to data: inout Data) {
        let encoded = Data(value.utf8)
        var length = UInt64(encoded.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(encoded)
    }
}

public typealias CommandApprovalDecision = CommandApprovalState
