import Foundation

public enum DiagnosticCode: String, Codable, CaseIterable, Hashable, Sendable {
    case authorizedDirectoryMissing = "diagnostic.authorizedDirectoryMissing"
    case authorizedHomeMissing = "diagnostic.authorizedHomeMissing"
    case authorizedProjectMissing = "diagnostic.authorizedProjectMissing"
    case blockValueHasNoContent = "diagnostic.blockValueHasNoContent"
    case blockValueMustBeIndented = "diagnostic.blockValueMustBeIndented"
    case collectionsNotSupported = "diagnostic.collectionsNotSupported"
    case digestUnavailable = "diagnostic.digestUnavailable"
    case expectedKeyValuePair = "diagnostic.expectedKeyValuePair"
    case invalidFrontmatterKey = "diagnostic.invalidFrontmatterKey"
    case missingClosingFrontmatterBoundary = "diagnostic.missingClosingFrontmatterBoundary"
    case missingFrontmatterBoundary = "diagnostic.missingFrontmatterBoundary"
    case missingRequiredFrontmatterField = "diagnostic.missingRequiredFrontmatterField"
    case rootUnreadable = "diagnostic.rootUnreadable"
    case scanFailed = "diagnostic.scanFailed"
    case unableToInspectAuthorizedDirectory = "diagnostic.unableToInspectAuthorizedDirectory"
    case unableToReadEntry = "diagnostic.unableToReadEntry"
    case unableToResolveAuthorizedDirectory = "diagnostic.unableToResolveAuthorizedDirectory"
    case unsafeEntryFile = "diagnostic.unsafeEntryFile"
    case unsupportedEscapeSequence = "diagnostic.unsupportedEscapeSequence"
    case unterminatedEscapeSequence = "diagnostic.unterminatedEscapeSequence"
    case unterminatedQuotedString = "diagnostic.unterminatedQuotedString"
    case yamlTagsAndAliasesNotSupported = "diagnostic.yamlTagsAndAliasesNotSupported"

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
        case .blockValueHasNoContent:
            "Block value has no indented content"
        case .blockValueMustBeIndented:
            "Block value must be indented"
        case .collectionsNotSupported:
            "Collections are not supported in frontmatter"
        case .digestUnavailable:
            "Content digest is unavailable because the Skill package exceeds safety limits"
        case .expectedKeyValuePair:
            "Expected a key-value pair"
        case .invalidFrontmatterKey:
            "Invalid frontmatter key"
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
        case .unsupportedEscapeSequence:
            "Unsupported escape sequence"
        case .unterminatedEscapeSequence:
            "Unterminated escape sequence"
        case .unterminatedQuotedString:
            "Unterminated quoted string"
        case .yamlTagsAndAliasesNotSupported:
            "YAML tags and aliases are not supported"
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
