import Foundation

public enum DiagnosticCode: String, Codable, CaseIterable, Hashable, Sendable {
    case authorizedDirectoryMissing = "diagnostic.authorizedDirectoryMissing"
    case authorizedHomeMissing = "diagnostic.authorizedHomeMissing"
    case authorizedProjectMissing = "diagnostic.authorizedProjectMissing"
    case missingClosingFrontmatterBoundary = "diagnostic.missingClosingFrontmatterBoundary"
    case missingFrontmatterBoundary = "diagnostic.missingFrontmatterBoundary"
    case missingRequiredFrontmatterField = "diagnostic.missingRequiredFrontmatterField"
    case rootUnreadable = "diagnostic.rootUnreadable"
    case scanFailed = "diagnostic.scanFailed"
    case unableToInspectAuthorizedDirectory = "diagnostic.unableToInspectAuthorizedDirectory"
    case unableToReadEntry = "diagnostic.unableToReadEntry"
    case unableToResolveAuthorizedDirectory = "diagnostic.unableToResolveAuthorizedDirectory"
    case unsafeEntryFile = "diagnostic.unsafeEntryFile"
    case yamlParseFailed = "diagnostic.yamlParseFailed"

    public var localizationKey: String { rawValue }

    func fallbackMessage(arguments: [String]) -> String {
        let first = arguments.first ?? ""
        let second = arguments.dropFirst().first ?? ""
        return switch self {
        case .authorizedDirectoryMissing:
            "Authorized directory is missing"
        case .authorizedHomeMissing:
            "Authorized home directory is missing"
        case .authorizedProjectMissing:
            "Authorized project directory is missing"
        case .missingClosingFrontmatterBoundary:
            "Missing closing frontmatter boundary"
        case .missingFrontmatterBoundary:
            "Missing frontmatter boundary"
        case .missingRequiredFrontmatterField:
            "Missing required frontmatter field: \(first)"
        case .rootUnreadable:
            "Root is missing or is not a readable directory"
        case .scanFailed:
            "Unable to scan authorized directory: \(first)"
        case .unableToInspectAuthorizedDirectory:
            "Unable to inspect authorized directory: \(first)"
        case .unableToReadEntry:
            "Unable to read \(first): \(second)"
        case .unableToResolveAuthorizedDirectory:
            "Unable to resolve authorized directory: \(first)"
        case .unsafeEntryFile:
            "Entry file must remain readable within its authorized package and root"
        case .yamlParseFailed:
            "YAML parse failed: \(first)"
        }
    }
}

public struct StructuredDiagnostic: Codable, Hashable, Sendable {
    public let code: DiagnosticCode
    public let arguments: [String]

    public init(code: DiagnosticCode, arguments: [String] = []) {
        self.code = code
        self.arguments = arguments
    }

    public var fallbackMessage: String {
        code.fallbackMessage(arguments: arguments)
    }
}
