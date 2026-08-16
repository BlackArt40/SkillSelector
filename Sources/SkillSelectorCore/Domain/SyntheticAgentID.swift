import Foundation

/// Agent-owner IDs recorded for Skills that live outside every registered
/// agent's declared paths: the shared system skills folder and custom-agent
/// roots. They are filter keys for display, not registry agents.
public enum SyntheticAgentID {
    public static let system = "system"
    public static let custom = "custom"

    public static let all: Set<String> = [system, custom]
}
