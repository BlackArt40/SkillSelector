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
}
