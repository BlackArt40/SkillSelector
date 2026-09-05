import AppKit
import MarkdownUI
import SkillSelectorCore
import SwiftUI

/// MarkdownUI-backed rendering for Skill / rules / marketplace document bodies.
///
/// MarkdownUI wraps the cmark-gfm parser and owns the block layout (headings,
/// lists, tables, code blocks). This
/// type keeps only the two things that remain app concerns: hardening
/// CommonMark soft breaks and the http/https link policy.
enum MarkdownBody {
    /// CommonMark soft line breaks (a single newline inside a paragraph) fold
    /// to spaces in Foundation's parser, jamming "workflow: …\ntopic: …" into
    /// one line. Hardening each single newline with two trailing spaces keeps
    /// the source line structure; fenced code content is left untouched.
    static func hardenedText(from lines: [String]) -> String {
        var result: [String] = []
        var inFence = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                result.append(line)
                continue
            }
            let hasNextContent = index + 1 < lines.count
                && !lines[index + 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !inFence, !line.isEmpty, hasNextContent {
                result.append(line + "  ")
            } else {
                result.append(line)
            }
        }
        return result.joined(separator: "\n")
    }
}

/// The http/https-only link policy shared by every rendered document.
///
/// `file:`, `shortcuts:`, `javascript:` and arbitrary app schemes could hand
/// execution to a process outside the App Sandbox, so those destinations must
/// never reach the system opener — they are discarded at click time.
enum MarkdownLinkPolicy {
    static let allowedSchemes: Set<String> = ["http", "https"]

    /// Whether a resolved URL may be handed to the system opener.
    static func isAllowedLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return allowedSchemes.contains(scheme)
    }
}

extension View {
    /// Enforces the renderer's link policy at click time: only http/https
    /// reaches the system opener; everything else is discarded.
    ///
    /// The URL is opened explicitly via `NSWorkspace` instead of returning
    /// `.systemAction` — Textual invokes this action from its own AppKit
    /// gesture host, and an explicit open is not subject to how the default
    /// action is propagated from that context.
    func markdownLinkPolicy() -> some View {
        environment(
            \.openURL,
            OpenURLAction { url in
                guard MarkdownLinkPolicy.isAllowedLink(url) else { return .discarded }
                NSWorkspace.shared.open(url)
                return .handled
            }
        )
    }
}

/// A self-contained structured-markdown body: AppTheme styling, best-effort
/// text selection, and the http/https link policy.
struct MarkdownBodyView: View {
    let text: String

    var body: some View {
        Markdown(text, baseURL: nil)
            .markdownTheme(.appTheme)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .markdownLinkPolicy()
    }
}
