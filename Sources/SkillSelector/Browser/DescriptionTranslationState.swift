import NaturalLanguage
import SwiftUI
@preconcurrency import Translation

/// Per-selection description-translation state for `SkillDetailView` —
/// the fields that always travel together, reset together when the
/// selection moves.
struct DescriptionTranslationState {
    /// `true` shows the translated description instead of the original.
    var isTranslated = false
    /// Text queued for translation; nil means "warm-up only, nothing to do".
    var pendingText: String?
    /// Cached translation of the current description text.
    var translatedText: String?
    /// True while a description translation request is in flight.
    var isTranslating = false
    /// Last translation failure, shown under the description so a failed
    /// or stalled translation is never silent.
    var error: String?
    /// Path of the skill that queued the current translation request. The
    /// translation task commits its result to the view only while the
    /// selection still points at this skill — an in-flight translation
    /// must never paint its text onto a different skill's detail view.
    var pendingSkillPath: String?
    /// Translation session configuration. Defaults to en → zh-Hans so
    /// `prepareTranslation()` can preload the models for the common case
    /// on warm-up; when the user actually toggles, the source is re-pinned
    /// from the description's own language (see
    /// `DescriptionTranslationSource.preferredSource`) — the session never
    /// auto-detects (a common failure/stall path). Call `invalidate()` to
    /// re-run the task on the *same* session.
    var configuration = TranslationSession.Configuration(
        source: Locale.Language(identifier: "en"),
        target: Locale.Language(identifier: "zh-Hans")
    )

    /// Per-selection reset. `configuration` (and the shared AppModel
    /// translation cache) are intentionally kept, so the session and its
    /// loaded language models are reused across selections.
    mutating func resetForSkillChange() {
        isTranslated = false
        translatedText = nil
        isTranslating = false
        pendingText = nil
        pendingSkillPath = nil
        error = nil
    }
}

/// Picks the translation session's source language for a description.
/// The target stays fixed (zh-Hans, matching the app's Chinese
/// localization); only the source follows the text.
enum DescriptionTranslationSource {
    /// Returns the language to pin as the session's source, or nil when
    /// there is nothing to translate: the description is already
    /// simplified Chinese, or carries no recognizable language at all
    /// (empty/symbol-only text). The detail view hides the translate
    /// button when this returns nil.
    static func preferredSource(in text: String) -> Locale.Language? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let language = recognizer.dominantLanguage else { return nil }
        // Simplified Chinese is the target already; Traditional Chinese
        // still translates (zh-Hant → zh-Hans is a legitimate pairing).
        if language == .simplifiedChinese { return nil }
        return Locale.Language(identifier: language.rawValue)
    }
}
