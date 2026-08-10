import Foundation

enum TemplateMatching {
    static func segment(_ value: String, matches template: String) -> Bool {
        guard let opening = template.firstIndex(of: "{"),
              let closing = template[opening...].firstIndex(of: "}") else {
            return value == template
        }
        let prefix = String(template[..<opening])
        let suffix = String(template[template.index(after: closing)...])
        return value.hasPrefix(prefix)
            && value.hasSuffix(suffix)
            && value.count > prefix.count + suffix.count
    }

    /// Whether the last `pattern.count` path segments match the pattern, where
    /// a `{name}` template segment matches any non-empty value.
    ///
    /// Single implementation of project-pattern suffix matching shared by the
    /// scanner and the file operator.
    static func suffix(_ path: [String], matches pattern: [String]) -> Bool {
        guard path.count >= pattern.count else { return false }
        return zip(path.suffix(pattern.count), pattern).allSatisfy {
            segment($0.0, matches: $0.1)
        }
    }
}
