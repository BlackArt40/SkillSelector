import Foundation

public struct DescriptionCandidates: Hashable, Sendable {
    public let custom: String?
    public let local: String?
    public let remote: String?
    public let fallback: String

    public init(custom: String?, local: String?, remote: String?, fallback: String) {
        self.custom = custom
        self.local = local
        self.remote = remote
        self.fallback = fallback
    }

    public init(snapshot: SkillSnapshot) {
        self.init(
            custom: snapshot.customDescription,
            local: snapshot.localDescription,
            remote: snapshot.enrichedDescription,
            fallback: snapshot.name
        )
    }
}

public struct EffectiveDescription: Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        case custom
        case local
        case remote
        case fallback
    }

    public let text: String
    public let source: Source

    public init(text: String, source: Source) {
        self.text = text
        self.source = source
    }
}

public enum DescriptionResolver {
    public static func resolve(_ candidates: DescriptionCandidates) -> EffectiveDescription {
        let prioritized: [(String?, EffectiveDescription.Source)] = [
            (candidates.custom, .custom),
            (candidates.local, .local),
            (candidates.remote, .remote),
        ]
        for (candidate, source) in prioritized {
            if let text = trimmedNonempty(candidate) {
                return EffectiveDescription(text: text, source: source)
            }
        }
        return EffectiveDescription(
            text: candidates.fallback.trimmingCharacters(in: .whitespacesAndNewlines),
            source: .fallback
        )
    }

    private static func trimmedNonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
