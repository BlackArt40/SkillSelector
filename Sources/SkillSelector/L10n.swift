import Foundation
import SkillSelectorCore

enum L10n {
    private static let missingValue = "__SKILLSELECTOR_MISSING_LOCALIZATION__"
    private static let selectedBundle = languageBundle(
        preferredLanguages: Locale.preferredLanguages
    )
    private static let englishBundle = languageBundle(preferredLanguages: ["en"])

    static func string(_ key: String) -> String {
        let selected = selectedBundle.localizedString(
            forKey: key,
            value: missingValue,
            table: nil
        )
        guard selected == missingValue else { return selected }
        let english = englishBundle.localizedString(
            forKey: key,
            value: missingValue,
            table: nil
        )
        return english == missingValue ? key : english
    }

    static func diagnostic(_ diagnostic: StructuredDiagnostic) -> String {
        let format = string(diagnostic.code.localizationKey)
        guard !diagnostic.arguments.isEmpty else { return format }
        return String(
            format: format,
            locale: Locale.current,
            arguments: diagnostic.arguments.map { $0 as any CVarArg }
        )
    }

    private static func languageBundle(preferredLanguages: [String]) -> Bundle {
        let localization = LocalizationSelection.preferredLocalization(
            available: Bundle.module.localizations,
            preferredLanguages: preferredLanguages
        )
        guard let url = Bundle.module.url(
            forResource: localization,
            withExtension: "lproj"
        ), let bundle = Bundle(url: url) else {
            return Bundle.module
        }
        return bundle
    }
}
