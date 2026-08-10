import Foundation

public struct DescriptionCandidates: Hashable, Sendable {
    public let custom: String?
    public let local: String?
    public let fallback: String

    public init(custom: String?, local: String?, fallback: String) {
        self.custom = custom
        self.local = local
        self.fallback = fallback
    }

    public init(snapshot: SkillSnapshot) {
        self.init(
            custom: snapshot.customDescription,
            local: snapshot.localDescription,
            fallback: snapshot.name
        )
    }
}

public enum DescriptionResolver {
    public static func resolve(_ candidates: DescriptionCandidates) -> String {
        if let text = trimmedNonempty(candidates.custom) { return text }
        if let text = trimmedNonempty(candidates.local) { return text }
        return candidates.fallback.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimmedNonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
