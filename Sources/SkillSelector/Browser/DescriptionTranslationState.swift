import Foundation

/// Per-selection description-translation state for `SkillDetailView` —
/// the fields that always travel together, reset together when the
/// selection moves.
///
/// Cloud-provider edition: the macOS 15-only Translation framework was
/// replaced by an opt-in HTTP backend (DeepL first) so the feature also
/// serves macOS 12–14. No session warm-up, no configuration invalidation —
/// a translation is one request, guarded by the locally stored API key.
struct DescriptionTranslationState {
    /// `true` shows the translated description instead of the original.
    var isTranslated = false
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

    /// Per-selection reset. The shared AppModel translation cache is
    /// intentionally kept, so revisiting a skill shows its translation
    /// instantly instead of re-issuing the request.
    mutating func resetForSkillChange() {
        isTranslated = false
        translatedText = nil
        isTranslating = false
        error = nil
        pendingSkillPath = nil
    }
}
