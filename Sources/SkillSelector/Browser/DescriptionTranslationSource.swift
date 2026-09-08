import NaturalLanguage

/// Picks the description's source language for the translation backends.
/// The target stays fixed (zh-Hans, matching the app's Chinese
/// localization); only the source follows the text — a description that
/// is already simplified Chinese has nothing to translate, and the
/// button hides for it.
///
/// NaturalLanguage ships since macOS 10.14, so this layer is unconditional
/// and compiles on every supported system (review decision: the cloud
/// provider path serves macOS 12–14 too, where the Translation framework
/// does not exist).
enum DescriptionTranslationSource {
    /// Returns the language to translate from, or nil when there is
    /// nothing to translate: the description is already simplified
    /// Chinese, or carries no recognizable language at all (empty or
    /// symbol-only text).
    static func preferredSource(in text: String) -> NLLanguage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let language = recognizer.dominantLanguage else { return nil }
        // Simplified Chinese is the target already; Traditional Chinese
        // still translates (zh-Hant → zh-Hans is a legitimate pairing).
        if language == .simplifiedChinese { return nil }
        return language
    }

    /// DeepL's `source_lang` expects uppercase ISO 639-1 codes. NLLanguage
    /// raw values carry subtags ("zh-Hant", "pt-BR") — only the primary
    /// subtag is needed. Languages outside DeepL's set translate with
    /// server-side auto-detection instead (nil source).
    static func deeplSourceCode(for language: NLLanguage) -> String? {
        let primary = language.rawValue
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init)?
            .uppercased() ?? ""
        let supported: Set<String> = [
            "EN", "ZH", "JA", "KO", "FR", "DE", "ES", "PT", "IT", "NL", "PL",
            "RU", "SV", "DA", "NB", "FI", "EL", "HU", "CS", "BG", "RO", "SK",
            "SL", "HR", "LT", "LV", "ET", "TR", "UK", "ID", "VI",
        ]
        return supported.contains(primary) ? primary : nil
    }
}
