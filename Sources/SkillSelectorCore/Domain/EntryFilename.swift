import Foundation

public enum EntryFilename {
    /// Whether a string is a safe single-component entry filename:
    /// non-empty, not "." or "..", and containing no path separators.
    ///
    /// Single source of truth for the entry-filename rule; the scanner, the
    /// document reader, and the file operator all delegate here so the rule
    /// cannot drift between them.
    public static func isValid(_ filename: String) -> Bool {
        !filename.isEmpty
            && filename != "."
            && filename != ".."
            && !filename.contains("\0")
            && !filename.contains("/")
            && !filename.contains("\\")
    }
}
