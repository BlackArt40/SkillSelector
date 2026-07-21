import Foundation
import SwiftUI
import SkillSelectorCore

enum L10n {
    private static let missingValue = "__SKILLSELECTOR_MISSING_LOCALIZATION__"
    private static let resourceBundle: Bundle = {
        if let url = Bundle.main.url(
            forResource: "SkillSelector_SkillSelector",
            withExtension: "bundle"
        ), let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()
    private static let englishBundle = languageBundle(preferredLanguages: ["en"])

    static var currentLanguage: String? {
        UserDefaults.standard.string(forKey: "SkillSelector.preferredLanguage")
    }

    static let languageDidChangeNotification = Notification.Name("SkillSelectorLanguageDidChange")

    static func setLanguage(_ language: String?) {
        if let language {
            UserDefaults.standard.set(language, forKey: "SkillSelector.preferredLanguage")
        } else {
            UserDefaults.standard.removeObject(forKey: "SkillSelector.preferredLanguage")
        }
        NotificationCenter.default.post(name: languageDidChangeNotification, object: nil)
    }

    static func string(_ key: String) -> String {
        let bundle: Bundle
        if let lang = UserDefaults.standard.string(forKey: "SkillSelector.preferredLanguage") {
            bundle = languageBundle(preferredLanguages: [lang])
        } else {
            bundle = languageBundle(preferredLanguages: Locale.preferredLanguages)
        }
        let selected = bundle.localizedString(
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
            available: resourceBundle.localizations,
            preferredLanguages: preferredLanguages
        )
        guard let url = resourceBundle.url(
            forResource: localization,
            withExtension: "lproj"
        ), let bundle = Bundle(url: url) else {
            return resourceBundle
        }
        return bundle
    }
}


struct LanguageReloading: ViewModifier {
    @AppStorage("SkillSelector.preferredLanguage") private var preferredLanguage: String?
    @State private var languageVersion = 0

    func body(content: Content) -> some View {
        content
            .id(languageVersion)
            .onChange(of: preferredLanguage) { _, _ in
                languageVersion += 1
            }
    }
}

extension View {
    func languageReloading() -> some View {
        modifier(LanguageReloading())
    }
}
