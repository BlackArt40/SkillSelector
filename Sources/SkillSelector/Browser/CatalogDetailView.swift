import AppKit
import SkillSelectorCore
import SwiftUI

/// The right `.detail` column for one remote catalog skill: hero (tile +
/// name + source badge), an action bar limited to browser handoffs
/// (open on GitHub, copy link — no install, no file operations), the
/// fetched SKILL.md rendered read-only, and a metadata grid. Remote
/// content is treated as untrusted text and capped by the fetcher.
struct CatalogDetailView: View {
    @Environment(AppModel.self) private var model
    let skill: CatalogSkill?
    var sourceNamesByID: [String: String] = [:]

    private enum ContentState {
        case loading
        case rendered(AttributedString)
        case raw(String)
        case failed(CatalogLoadFailure)
    }

    @State private var contentState: ContentState = .loading
    @State private var copied: FieldCopy?

    var body: some View {
        if let skill {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    hero(skill)
                    actionBar(skill)
                    contentSection(skill)
                    metadataSection(skill)
                }
                .padding(.horizontal, 32)
                .padding(.top, 32)
                .padding(.bottom, 48)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(AppTheme.background)
            .navigationTitle(skill.name)
            .task(id: skill.id) {
                await load(skill)
            }
        } else {
            emptyState
                .background(AppTheme.background)
        }
    }

    // MARK: Hero

    private func hero(_ skill: CatalogSkill) -> some View {
        HStack(alignment: .top, spacing: 20) {
            SkillTileView(
                title: skill.name.prefix(1).uppercased(),
                size: 72,
                cornerRadius: 18,
                active: false
            )
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: skill.name)
                    .font(AppTheme.display(28, weight: .semibold))
                    .foregroundStyle(AppTheme.foreground)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Text(verbatim: skill.skillPath)
                    .font(AppTheme.mono(12))
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.top, 3)
                HStack(spacing: 8) {
                    PillBadge(
                        text: sourceNamesByID[skill.sourceID] ?? skill.sourceID,
                        style: .link
                    )
                    PillBadge(text: L10n.string("Marketplace Remote Badge"), style: .link)
                }
                .padding(.top, 12)
            }
        }
    }

    // MARK: Action bar

    private func actionBar(_ skill: CatalogSkill) -> some View {
        HStack(spacing: 8) {
            actionButton(
                icon: Image(systemName: "safari"),
                title: L10n.string("Open in GitHub"),
                isActive: copied == .link
            ) {
                NSWorkspace.shared.open(skill.githubURL)
            }
            actionButton(
                icon: nil,
                title: L10n.string("Copy Link"),
                isActive: copied == .link
            ) {
                copy(skill.githubURL.absoluteString, field: .link)
            }
            actionButton(
                icon: Image(systemName: "terminal"),
                title: L10n.string("Copy Install Command"),
                isActive: copied == .installCommand
            ) {
                copy(skill.installCommand, field: .installCommand)
            }
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity)
    }

    private enum FieldCopy {
        case link
        case installCommand
    }

    private func copy(_ value: String, field: FieldCopy) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copied = field
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = nil
        }
    }

    private func actionButton(
        icon: Image?,
        title: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 6) {
                icon?
                    .font(.system(size: 12))
                Text(verbatim: title)
                    .font(AppTheme.body(13, weight: .medium))
                    .foregroundStyle(isActive ? AppTheme.accentActive : AppTheme.foreground)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                isActive ? AppTheme.accentTint : AppTheme.surfaceWarm,
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    // MARK: Content

    @ViewBuilder
    private func contentSection(_ skill: CatalogSkill) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading(L10n.string("Marketplace Document Section"))
            switch contentState {
            case .loading:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(verbatim: L10n.string("Marketplace Document Loading"))
                        .foregroundStyle(AppTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(AppTheme.surfaceWarm, in: RoundedRectangle(cornerRadius: 12))
            case .rendered(let attributed):
                Text(attributed)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(20)
                    .background(AppTheme.surfaceWarm, in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(AppTheme.borderSoft, lineWidth: 1)
                    }
                    .markdownLinkPolicy()
            case .raw(let source):
                Text(verbatim: source)
                    .font(AppTheme.mono(12))
                    .foregroundStyle(AppTheme.foregroundSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(20)
                    .background(AppTheme.surfaceWarm, in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(AppTheme.borderSoft, lineWidth: 1)
                    }
            case .failed(let failure):
                errorShell(
                    title: L10n.string("Marketplace Document Failed"),
                    detail: CatalogFailureMessage.text(for: failure)
                )
                .padding(20)
                .background(AppTheme.surfaceWarm, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: Metadata

    private func metadataSection(_ skill: CatalogSkill) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading(L10n.string("Configuration"))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                keyValue(
                    L10n.string("Source"),
                    value: sourceNamesByID[skill.sourceID] ?? skill.sourceID,
                    monospaced: false
                )
                keyValue(L10n.string("Path"), value: skill.skillPath, monospaced: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func keyValue(_ label: String, value: String, monospaced: Bool) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(verbatim: label)
                .font(AppTheme.body(13))
                .foregroundStyle(AppTheme.muted)
                .frame(width: 108, alignment: .leading)
            Text(verbatim: value)
                .font(monospaced ? AppTheme.mono(12) : AppTheme.body(13))
                .foregroundStyle(AppTheme.foreground)
                .textSelection(.enabled)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(verbatim: title)
            .font(AppTheme.display(14, weight: .semibold))
            .foregroundStyle(AppTheme.foreground)
    }

    private func errorShell(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(verbatim: detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    @MainActor
    private func load(_ skill: CatalogSkill) async {
        contentState = .loading
        do {
            let source = try await model.loadCatalogDocument(skill)
            try Task.checkCancellation()
            let body = MarkdownRenderer.extractBody(source)
            if let attributed = MarkdownRenderer.buildAttributedString(from: body) {
                contentState = .rendered(attributed)
            } else {
                contentState = .raw(source)
            }
        } catch is CancellationError {
            return
        } catch CatalogError.oversized {
            contentState = .failed(.invalidResponse)
        } catch CatalogError.rateLimited {
            contentState = .failed(.rateLimited)
        } catch CatalogError.http(let status) {
            contentState = .failed(.http(status: status))
        } catch CatalogError.invalidResponse {
            contentState = .failed(.invalidResponse)
        } catch is URLError {
            contentState = .failed(.network)
        } catch {
            contentState = .failed(.network)
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            AppIconView(size: 96)
                .opacity(0.9)
            Text(verbatim: L10n.string("Select a Marketplace Skill"))
                .font(AppTheme.display(28, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
            Text(verbatim: L10n.string("Select a Marketplace Skill Description"))
                .font(AppTheme.body(14))
                .foregroundStyle(AppTheme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
