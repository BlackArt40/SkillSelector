import Foundation

public enum LocalizationSelection {
    public static func preferredLocalization(
        available: [String],
        preferredLanguages: [String],
        fallback: String = "en"
    ) -> String {
        let fallbackLocalization = available.first {
            $0.caseInsensitiveCompare(fallback) == .orderedSame
        } ?? fallback
        let ordered = [fallbackLocalization] + available.filter {
            $0.caseInsensitiveCompare(fallbackLocalization) != .orderedSame
        }
        return Bundle.preferredLocalizations(
            from: ordered,
            forPreferences: preferredLanguages
        ).first ?? fallbackLocalization
    }
}
