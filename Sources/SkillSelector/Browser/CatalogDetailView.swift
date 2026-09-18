import AppKit
import SkillSelectorCore
import SwiftUI

/// The right `.detail` column for one remote catalog skill: hero (tile +
/// name + source badge), an action bar limited to browser handoffs
/// (open on GitHub, copy link — no install, no file operations), the
/// fetched SKILL.md rendered read-only, and a metadata grid. Remote
/// content is treated as untrusted text and capped by the fetcher.
struct CatalogDetailView: View {
    @EnvironmentObject private var model: AppModel
    let skill: CatalogSkill?
    var sourceNamesByID: [String: String] = [:]
    /// Agent display names for the local-installation section (「对照本地」).
    var agentNamesByID: [String: String] = [:]

    private enum ContentState {
        case loading
        case rendered(String)
        case raw(String)
        case failed(CatalogLoadFailure)
    }

    @State private var contentState: ContentState = .loading
    /// Remote SKILL.md body (frontmatter stripped), kept alongside the
    /// rendered state for the 「对照本地」version-difference comparison.
    @State private var remoteBody: String?
    /// The remote SKILL.md's frontmatter description — the「简介」the
    /// description-translation entry operates on.
    @State private var remoteDescription: String?
    /// Per-skill description-translation driver, shared with the local
    /// detail view (see `DescriptionTranslationController`).
    @StateObject private var translator = DescriptionTranslationController()

    var body: some View {
        if let skill {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hero(skill)
                    badgesRow(skill)
                    actionBar(skill)
                    descriptionSection(skill)
                    repositorySection(skill)
                    localSection(skill)
                    contentSection(skill)
                    metadataSection(skill)
                }
                .padding(24)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(AppTheme.background)
            .navigationTitle(skill.name)
            .task(id: skill.id) {
                // Per-skill translation state resets together with the
                // document reload.
                translator.resetForSkillChange()
                await load(skill)
            }
        } else {
            emptyState
                .background(AppTheme.background)
        }
    }

    // MARK: Description

    /// The remote SKILL.md's frontmatter description with the same
    /// translate/original toggle the local detail view offers. Hidden
    /// entirely when the description is absent — a catalog entry may not
    /// carry one.
    @ViewBuilder
    private func descriptionSection(_ skill: CatalogSkill) -> some View {
        if let description = remoteDescription,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            detailCard(contentSpacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    DetailViewSupport.sectionHeading(L10n.string("Description"))
                    Spacer(minLength: 8)
                    if model.isTranslationConfigured,
                       translator.isTranslatable(description) {
                        DescriptionTranslateButton(controller: translator) {
                            translator.toggle(
                                originalText: description,
                                ownerPath: skill.id,
                                model: model
                            )
                        }
                    }
                }
                Text(verbatim: translator.displayedText(original: description))
                    .font(AppTheme.body(14))
                    .foregroundStyle(AppTheme.foreground)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let descriptionTranslationError = translator.translation.error {
                    DescriptionTranslationErrorRow(message: descriptionTranslationError)
                }
            }
        }
    }

    // MARK: Hero

    private func hero(_ skill: CatalogSkill) -> some View {
        HStack(alignment: .top, spacing: 16) {
            SkillTileView(
                title: skill.name.prefix(1).uppercased(),
                size: 48,
                inkBorder: true
            )
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: skill.name)
                    .font(AppTheme.display(20, weight: .bold))
                    .kerning(-1)
                    .foregroundStyle(AppTheme.foreground)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Text(verbatim: skill.skillPath)
                    .font(AppTheme.mono(12))
                    .foregroundStyle(AppTheme.muted)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.top, 4)
            }
        }
    }

    /// catalog.html's badge row under the hero: source chip on
    /// `bg-sidebar-accent`, the remote chip on `bg-card`.
    private func badgesRow(_ skill: CatalogSkill) -> some View {
        HStack(spacing: 8) {
            InkBadge(text: sourceNamesByID[skill.sourceID] ?? skill.sourceID)
            InkBadge(
                text: L10n.string("Marketplace Remote Badge"),
                backgroundColor: AppTheme.surfaceWarm,
                foregroundColor: AppTheme.foreground
            )
        }
    }

    // MARK: Action bar

    private func actionBar(_ skill: CatalogSkill) -> some View {
        HStack(spacing: 12) {
            Button {
                NSWorkspace.shared.open(skill.githubURL)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 13))
                    Text(verbatim: L10n.string("Open in GitHub"))
                }
            }
            .buttonStyle(InkButtonStyle(height: 40, horizontalPadding: 16))
            .help(L10n.string("Open in GitHub"))
            .accessibilityLabel(L10n.string("Open in GitHub"))
            Button {
                copy(skill.githubURL.absoluteString)
            } label: {
                Text(verbatim: L10n.string("Copy Link"))
            }
            .buttonStyle(InkButtonStyle(height: 40, horizontalPadding: 16))
            .help(L10n.string("Copy Link"))
            .accessibilityLabel(L10n.string("Copy Link"))
            Button {
                copy(skill.installCommand)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "paperplane")
                        .font(.system(size: 13))
                    Text(verbatim: L10n.string("Copy Install Command"))
                }
            }
            .buttonStyle(InkButtonStyle(height: 40, horizontalPadding: 16, isPrimary: true))
            .help(L10n.string("Copy Install Command"))
            .accessibilityLabel(L10n.string("Copy Install Command"))
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    /// catalog.html's detail `article` card — `border-2 border-ring
    /// bg-card p-4 shadow-sm` chrome with a 2 px ink stroke and the hard
    /// offset shadow; every catalog detail section lives in one.
    private func detailCard<Content: View>(
        contentSpacing: CGFloat = 12,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: contentSpacing) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surfaceWarm)
        .overlay {
            Rectangle().stroke(AppTheme.ink, lineWidth: 2)
        }
        .hardShadow(.rest)
    }

    // MARK: Local installation (对照本地)

    /// Connects the market's「发现」with the local index's「管理」, read-only:
    /// whether this remote skill is already installed locally and under
    /// which Agents. Pure name-based matching via `LocalInstallationMatcher`;
    /// the section reads `model.snapshots` directly, so it updates as the
    /// index refreshes.
    private func localSection(_ skill: CatalogSkill) -> some View {
        let matches = LocalInstallationMatcher.localInstallations(
            of: skill,
            in: model.snapshots
        )
        return detailCard {
            DetailViewSupport.sectionHeading(L10n.string("Compare with Local"))
            if matches.isEmpty {
                notInstalledContent
            } else {
                VStack(spacing: 10) {
                    ForEach(matches) { match in
                        localMatchCard(match, remoteBody: remoteBody, sourceID: skill.sourceID)
                    }
                }
            }
            Text(verbatim: L10n.string("Compare with Local Hint"))
                .font(AppTheme.body(12))
                .foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func localMatchCard(
        _ match: SkillSnapshot,
        remoteBody: String?,
        sourceID: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(AppTheme.success)
                Text(verbatim: L10n.string("Installed Locally"))
                    .font(AppTheme.body(14, weight: .bold))
                    .foregroundStyle(AppTheme.foreground)
                Spacer(minLength: 8)
                if match.resolvedTarget != nil {
                    InkBadge(
                        text: L10n.string("Symbolic Link Pill"),
                        backgroundColor: AppTheme.surfaceWarm,
                        foregroundColor: AppTheme.foreground
                    )
                }
            }
            let names = match.agentDisplayNames(by: agentNamesByID)
            if names.isEmpty {
                Text(verbatim: L10n.string("No Associated Agent"))
                    .font(AppTheme.body(12))
                    .foregroundStyle(AppTheme.muted)
            } else {
                FlowChips(names: names)
            }
            Text(verbatim: match.path)
                .font(AppTheme.mono(12))
                .foregroundStyle(AppTheme.muted)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            // Rendered even without a marketplace body: "could not be
            // compared" is one of the three facts, and saying nothing at all
            // is indistinguishable from "identical".
            LocalMatchVersionRow(
                match: match,
                remoteBody: remoteBody,
                sourceID: sourceID
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.sidebarBackground)
    }

    /// The 对照本地 card's not-installed row — catalog.html's
    /// `text-sm font-bold` verdict line with warning icon and muted hint.
    private var notInstalledContent: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 14))
                .foregroundStyle(AppTheme.warn)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: L10n.string("Not Installed Locally"))
                    .font(AppTheme.body(14, weight: .bold))
                    .foregroundStyle(AppTheme.foreground)
                Text(verbatim: L10n.string("Not Installed Locally Hint"))
                    .font(AppTheme.body(12))
                    .foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private func contentSection(_ skill: CatalogSkill) -> some View {
        detailCard {
            DetailViewSupport.sectionHeading(L10n.string("Marketplace Document Section"))
            Group {
                switch contentState {
                case .loading:
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(verbatim: L10n.string("Marketplace Document Loading"))
                            .font(AppTheme.body(12))
                            .foregroundStyle(AppTheme.muted)
                    }
                case .rendered(let text):
                    MarkdownBodyView(text: text)
                case .raw(let source):
                    Text(verbatim: source)
                        .font(AppTheme.mono(12))
                        .foregroundStyle(AppTheme.foreground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                case .failed(let failure):
                    DetailViewSupport.errorShell(
                        title: L10n.string("Marketplace Document Failed"),
                        detail: CatalogFailureMessage.text(for: failure)
                    )
                }
            }
            // The Skill-doc pre block: `bg-sidebar p-4 text-xs
            // leading-relaxed`, flat on the sidebar fill.
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.sidebarBackground)
        }
    }

    // MARK: Metadata

    private func metadataSection(_ skill: CatalogSkill) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailViewSupport.sectionHeading(L10n.string("Configuration"))
            VStack(alignment: .leading, spacing: 10) {
                DetailViewSupport.keyValueRow(
                    L10n.string("Source"),
                    value: sourceNamesByID[skill.sourceID] ?? skill.sourceID,
                    monospaced: false
                )
                DetailViewSupport.keyValueRow(L10n.string("Path"), value: skill.skillPath, monospaced: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Repository metadata

    /// The「仓库信息」section — repo-level numbers shared by every skill
    /// from the same source, prefetched by the catalog model. Empty (hidden)
    /// until the source's metadata lands.
    @ViewBuilder
    private func repositorySection(_ skill: CatalogSkill) -> some View {
        if let repo = model.catalog.repoInfoBySourceID[skill.sourceID] {
            VStack(alignment: .leading, spacing: 12) {
                DetailViewSupport.sectionHeading(L10n.string("Repository"))
                VStack(alignment: .leading, spacing: 10) {
                    DetailViewSupport.keyValueRow(
                        L10n.string("Repository Author"),
                        value: repo.owner,
                        monospaced: false
                    )
                    DetailViewSupport.keyValueRow(L10n.string("Stars"), value: repo.stars.formatted(), monospaced: true)
                    DetailViewSupport.keyValueRow(L10n.string("Forks"), value: repo.forks.formatted(), monospaced: true)
                    DetailViewSupport.keyValueRow(
                        L10n.string("Last Updated"),
                        value: repo.pushedAt?.formatted(date: .abbreviated, time: .omitted)
                            ?? "—",
                        monospaced: false
                    )
                    DetailViewSupport.keyValueRow(
                        L10n.string("License"),
                        value: repo.license ?? "—",
                        monospaced: false
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @MainActor
    private func load(_ skill: CatalogSkill) async {
        contentState = .loading
        remoteDescription = nil
        do {
            let source = try await model.catalog.loadDocument(skill)
            try Task.checkCancellation()
            remoteDescription = FrontmatterParser.parse(source).description
            let body = FrontmatterParser.bodyLines(from: source)
            remoteBody = body.joined(separator: "\n")
            let text = MarkdownBody.hardenedText(from: body)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                contentState = .rendered(text)
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

/// One line inside an installed-local card: how the local copy's content
/// compares with the marketplace's.
///
/// Three facts and no verdict beyond them — the content matches, does not
/// match, or could not be compared. There is deliberately no "out of date":
/// a difference is at least as likely to be a local edit, and the app has no
/// way to tell the two apart, so it states what it knows and stops.
private struct LocalMatchVersionRow: View {
    @EnvironmentObject private var model: AppModel
    let match: SkillSnapshot
    /// The marketplace document, when it was fetched. Absent is itself one of
    /// the three facts rather than a reason to render nothing.
    let remoteBody: String?
    /// The repository being compared against, named so the fact reads as
    /// "content matches <repo>" instead of an unattributed claim.
    let sourceID: String

    private enum Verdict: Equatable {
        case identical
        case differs
        case undecidable(Reason)

        enum Reason: Equatable {
            /// The marketplace document was not fetched.
            case noMarketplaceBody
            /// The local copy carries no fingerprint yet — the backfill has
            /// not reached it.
            case localNotFingerprinted
            /// The local fingerprint predates the body-only scheme, so the
            /// two are not comparable.
            case localFingerprintLegacy
        }
    }

    /// Decided by content fingerprint, never by reading the local file: the
    /// snapshot already carries the fingerprint, so the common case costs
    /// nothing. The line diff runs only when they disagree, to explain what
    /// changed.
    private var verdict: Verdict {
        guard let remoteBody, !remoteBody.isEmpty else {
            return .undecidable(.noMarketplaceBody)
        }
        guard let local = match.contentFingerprint else {
            return .undecidable(.localNotFingerprinted)
        }
        guard SkillContentFingerprint.isCurrentVersion(local) else {
            return .undecidable(.localFingerprintLegacy)
        }
        let remote = SkillContentFingerprint.compute(bodyOfEntryText: remoteBody)
        return local == remote ? .identical : .differs
    }

    @State private var diffSummary: LineDiffSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                switch verdict {
                case .identical:
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.success)
                    Text(verbatim: L10n.string("Marketplace Content Matches %@", sourceID))
                        .font(AppTheme.body(11.5, weight: .medium))
                        .foregroundStyle(AppTheme.success)
                case .differs:
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.warn)
                    Text(verbatim: L10n.string("Marketplace Content Differs %@", sourceID))
                        .font(AppTheme.body(11.5, weight: .medium))
                        .foregroundStyle(AppTheme.warn)
                case .undecidable(let reason):
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.meta)
                    Text(verbatim: "\(L10n.string("Marketplace Content Undecidable")) — \(reasonText(reason))")
                        .font(AppTheme.body(11.5))
                        .foregroundStyle(AppTheme.muted)
                }
            }
            if let diffSummary, !diffSummary.isEmpty {
                Text(verbatim: String.localizedStringWithFormat(
                    L10n.string("Marketplace Version Diff Format"),
                    diffSummary.added, diffSummary.removed
                ))
                .font(AppTheme.body(11))
                .foregroundStyle(AppTheme.muted)
                .padding(.leading, 17)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .help(L10n.string("Marketplace Version Diff Help"))
        .task(id: match.path) {
            // Only a mismatch needs the line diff; the verdict itself came
            // from fingerprints and never touched the local file.
            guard verdict == .differs, let remoteBody else { return }
            diffSummary = await model.comparisons.marketVsLocalBodyDiff(
                marketBody: remoteBody,
                local: match,
                authorizedRoots: model.authorizedRoots
            )
        }
    }

    private func reasonText(_ reason: Verdict.Reason) -> String {
        switch reason {
        case .noMarketplaceBody: return L10n.string("Marketplace Content No Body")
        case .localNotFingerprinted: return L10n.string("Marketplace Content No Local Fingerprint")
        case .localFingerprintLegacy: return L10n.string("Marketplace Content Legacy Local Fingerprint")
        }
    }
}
