import Foundation

enum TemplateMatching {
    /// Values bound by the `{name}` templates in `template`, or nil when the
    /// value does not match. A template without a placeholder matches only
    /// itself and binds nothing.
    static func segmentBindings(_ value: String, matches template: String) -> [String: String]? {
        guard let opening = template.firstIndex(of: "{"),
              let closing = template[opening...].firstIndex(of: "}") else {
            return value == template ? [:] : nil
        }
        let prefix = String(template[..<opening])
        let suffix = String(template[template.index(after: closing)...])
        guard value.hasPrefix(prefix),
              value.hasSuffix(suffix),
              value.count > prefix.count + suffix.count else {
            return nil
        }
        let name = String(template[template.index(after: opening)..<closing])
        return [name: String(value.dropFirst(prefix.count).dropLast(suffix.count))]
    }

    static func segment(_ value: String, matches template: String) -> Bool {
        segmentBindings(value, matches: template) != nil
    }

    /// Template bindings for a suffix match, or nil when the path does not
    /// match the pattern, where a `{name}` template segment matches any
    /// non-empty value.
    ///
    /// Single implementation of project-pattern suffix matching shared by the
    /// scanner, the file operator, and the pattern dry run.
    static func suffixBindings(_ path: [String], matches pattern: [String]) -> [String: String]? {
        guard path.count >= pattern.count else { return nil }
        let offset = path.count - pattern.count
        var bindings: [String: String] = [:]
        for (index, template) in pattern.enumerated() {
            guard let segment = segmentBindings(path[offset + index], matches: template) else {
                return nil
            }
            for (name, value) in segment {
                bindings[name] = value
            }
        }
        return bindings
    }

    /// Whether the last `pattern.count` path segments match the pattern, where
    /// a `{name}` template segment matches any non-empty value.
    static func suffix(_ path: [String], matches pattern: [String]) -> Bool {
        suffixBindings(path, matches: pattern) != nil
    }
}
