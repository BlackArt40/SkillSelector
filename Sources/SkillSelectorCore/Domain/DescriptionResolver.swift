import Foundation

public struct DescriptionCandidates: Hashable, Sendable {
    public let local: String?
    public let fallback: String

    public init(local: String?, fallback: String) {
        self.local = local
        self.fallback = fallback
    }

    public init(snapshot: SkillSnapshot) {
        self.init(
            local: snapshot.localDescription,
            fallback: snapshot.name
        )
    }
}

public enum DescriptionResolver {
    public static func resolve(_ candidates: DescriptionCandidates) -> String {
        if let text = trimmedNonempty(candidates.local) { return text }
        return candidates.fallback.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimmedNonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
