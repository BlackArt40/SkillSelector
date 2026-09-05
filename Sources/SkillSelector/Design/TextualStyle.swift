import MarkdownUI
import SwiftUI

/// The MarkdownUI `Theme` bound to the app's `AppTheme` tokens — the same
/// roles the previous Textual style mapped: accent h1 (title scale
/// 1.55/1.35/1.2/1.1/1.0/1.0, semibold), secondary body text, a violet-tinted
/// blockquote with a 3pt leading bar, code inline on the surface tint, and the
/// fenced code panel. Block layout (spacing, list markers, table decoration)
/// follows MarkdownUI's gitHub-like defaults; the base text size is the macOS
/// body size (13) so `.em` heading/code scales match the old fontScale values.
///
/// The theme is MainActor-isolated: `Theme` is not `Sendable`, so a
/// nonisolated global would be rejected in Swift 6 language mode — and every
/// consumer (SwiftUI view bodies) already runs on the main actor.
extension Theme {
    @MainActor
    static let appTheme: Theme = Theme()
        .text {
            FontSize(13)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.85))
            ForegroundColor(AppTheme.codeInline)
            BackgroundColor(AppTheme.surface)
        }
        .strong {
            FontWeight(.semibold)
        }
        .strikethrough {
            StrikethroughStyle(.single)
        }
        .link {
            ForegroundColor(AppTheme.accent)
            UnderlineStyle(.single)
        }
        .heading1 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 18, bottom: 8)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.55))
                    ForegroundColor(AppTheme.accent)
                }
        }
        .heading2 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 18, bottom: 8)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.35))
                    ForegroundColor(AppTheme.foreground)
                }
        }
        .heading3 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 18, bottom: 8)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.2))
                    ForegroundColor(AppTheme.foreground)
                }
        }
        .heading4 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 18, bottom: 8)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.1))
                    ForegroundColor(AppTheme.foreground)
                }
        }
        .heading5 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 18, bottom: 8)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.0))
                    ForegroundColor(AppTheme.foreground)
                }
        }
        .heading6 { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.125))
                .markdownMargin(top: 18, bottom: 8)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.0))
                    ForegroundColor(AppTheme.foreground)
                }
        }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.25))
                .markdownMargin(top: 0, bottom: 12)
                .markdownTextStyle {
                    ForegroundColor(AppTheme.foregroundSecondary)
                }
        }
        .blockquote { configuration in
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(AppTheme.border)
                    .frame(width: 3)
                configuration.label
                    .markdownTextStyle {
                        ForegroundColor(AppTheme.blockquote)
                    }
                    .relativePadding(.horizontal, length: .em(1))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .codeBlock { configuration in
            ScrollView(.horizontal) {
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.2))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.88))
                        ForegroundColor(AppTheme.foreground)
                    }
                    .padding(12)
            }
            .background(AppTheme.codeBlockBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .markdownMargin(top: 0, bottom: 12)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: .em(0.25))
        }
        .table { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownTableBorderStyle(.init(color: AppTheme.border))
                .markdownTableBackgroundStyle(
                    .alternatingRows(AppTheme.background, AppTheme.surface)
                )
                .markdownMargin(top: 0, bottom: 16)
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 {
                        FontWeight(.semibold)
                    }
                    BackgroundColor(nil)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6)
                .padding(.horizontal, 13)
                .relativeLineSpacing(.em(0.25))
        }
        .thematicBreak {
            Divider()
                .relativeFrame(height: .em(0.25))
                .overlay(AppTheme.border)
                .markdownMargin(top: 24, bottom: 24)
        }
}
