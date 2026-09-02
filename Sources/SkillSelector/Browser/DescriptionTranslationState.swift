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
    /// Translation session configuration. Kept non-nil with an explicit
    /// en → zh-Hans pairing so `prepareTranslation()` can preload the
    /// models on warm-up and `translate()` never has to auto-detect the
    /// source language (auto-detection is a common failure/stall path).
    /// Call `invalidate()` to re-run the task on the *same* session.
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
