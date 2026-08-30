import SwiftUI
import Textual

/// The `StructuredText.Style` bound to the app's `AppTheme` tokens: Textual
/// owns the block layout (headings, paragraphs, quotes, code blocks, lists,
/// tables) and this type only maps the design tokens onto it. Layout
/// (spacing, marker shapes, overflow) follows the GitHub preset; colors come
/// from `AppTheme`.
struct AppMarkdownStyle: StructuredText.Style {
    let inlineStyle: InlineStyle = InlineStyle()
        .code(
            .monospaced,
            .fontScale(0.85),
            .foregroundColor(AppTheme.codeInline),
            .backgroundColor(AppTheme.surface)
        )
        .link(.foregroundColor(AppTheme.accent), .underlineStyle(.single))
        .strong(.fontWeight(.semibold))
        .strikethrough(.strikethroughStyle(.single))

    let headingStyle: AppHeadingStyle = AppHeadingStyle()
    let paragraphStyle: AppParagraphStyle = AppParagraphStyle()
    let blockQuoteStyle: AppBlockQuoteStyle = AppBlockQuoteStyle()
    let codeBlockStyle: AppCodeBlockStyle = AppCodeBlockStyle()
    let listItemStyle: StructuredText.DefaultListItemStyle = .default
    let unorderedListMarker: StructuredText.HierarchicalSymbolListMarker = .hierarchical(
        .disc, .circle, .square
    )
    let orderedListMarker: StructuredText.DecimalListMarker = .decimal
    let tableStyle: StructuredText.GitHubTableStyle = .gitHub
    let tableCellStyle: StructuredText.GitHubTableCellStyle = .gitHub
    let thematicBreakStyle: StructuredText.GitHubThematicBreakStyle = .gitHub
}

/// Heading sizes shrink with level; h1 uses the accent, the rest the neutral
/// foreground, all semibold (the previous renderer's `materializeStyles`).
struct AppHeadingStyle: StructuredText.HeadingStyle {
    private static let fontScales: [CGFloat] = [1.55, 1.35, 1.2, 1.1, 1.0, 1.0]

    func makeBody(configuration: Configuration) -> some View {
        let level = min(configuration.headingLevel, 6)
        configuration.label
            .textual.fontScale(Self.fontScales[level - 1])
            .foregroundStyle(level == 1 ? AppTheme.accent : AppTheme.foreground)
            .fontWeight(.semibold)
            .textual.blockSpacing(.init(top: 18, bottom: 8))
    }
}

/// Body paragraphs use the secondary foreground and tight line spacing.
struct AppParagraphStyle: StructuredText.ParagraphStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(AppTheme.foregroundSecondary)
            .textual.lineSpacing(.fontScaled(0.25))
            .textual.blockSpacing(.init(top: 0, bottom: 12))
    }
}

/// A leading bar + tinted quote text (matches the previous renderer's
/// violet-tinted blockquote).
struct AppBlockQuoteStyle: StructuredText.BlockQuoteStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 4)
                .fill(AppTheme.border)
                .textual.frame(width: .fontScaled(0.2))
            configuration.label
                .foregroundStyle(AppTheme.blockquote)
                .textual.padding(.horizontal, .fontScaled(1))
        }
    }
}

/// Fenced code on the dedicated code-block background, monospaced, rounded —
/// the previous renderer's `codeBlockBackground` panel.
struct AppCodeBlockStyle: StructuredText.CodeBlockStyle {
    func makeBody(configuration: Configuration) -> some View {
        Overflow {
            configuration.label
                .monospaced()
                .textual.fontScale(0.88)
                .textual.lineSpacing(.fontScaled(0.2))
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(AppTheme.foreground)
                .padding(12)
        }
        .background(AppTheme.codeBlockBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .textual.blockSpacing(.init(top: 0, bottom: 12))
    }
}
