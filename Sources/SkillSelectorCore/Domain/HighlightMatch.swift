import Foundation

/// Pure, testable hit-range finder for search-result highlighting. Only
/// finds ranges — the caller decides how to render them — so this stays
/// UI-agnostic in Core while the views build `Text` runs from it.
public enum HighlightMatch {
    /// The ranges of `query` within `text` (case- and diacritic-insensitive),
    /// non-overlapping, merged, and in order. The query is matched **term by
    /// term** (whitespace-separated): search matches per term, so a hit
    /// where the full string is absent but a word is present must still
    /// highlight. Empty for a blank query or no hits.
    public static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty, !text.isEmpty else { return [] }
        var found: [Range<String.Index>] = []
        for term in terms {
            var searchStart = text.startIndex
            while searchStart < text.endIndex {
                guard let range = text.range(
                    of: term,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: searchStart..<text.endIndex
                ) else { break }
                found.append(range)
                searchStart = range.upperBound
            }
        }
        // Merge overlapping/adjacent hits so one continuous bar renders
        // (e.g. "pdf" + "file" inside "pdf file").
        let ordered = found.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in ordered {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
