import SkillSelectorCore
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var destination: BrowserDestination? = .all
    @State private var searchText = ""
    @State private var status: SkillQuery.Status = .all
    @State private var sort: SkillQuery.Sort = .default

    var body: some View {
        @Bindable var model = model
        let currentDestination = destination ?? .all
        let query = SkillQuery(
            scope: currentDestination.queryScope,
            agentID: currentDestination.agentID,
            searchText: searchText,
            status: status,
            sort: sort
        )
        let filteredSkills = query.apply(to: model.snapshots, rootsByID: model.rootsByID)
        let agentNamesByID = Dictionary(
            uniqueKeysWithValues: model.agentDefinitions.map { ($0.id, $0.displayName) }
        )
        let detectedAgentIDs = Set(model.snapshots.flatMap(\.agentIDs))
        let selectedSkill = model.selection.flatMap { selection in
            model.snapshots.first { $0.path == selection.path }
        }

        NavigationSplitView {
            BrowserSidebar(
                destination: $destination,
                roots: model.authorizedRoots,
                definitions: model.agentDefinitions,
                detectedAgentIDs: detectedAgentIDs
            )
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } content: {
            SkillListView(
                selection: $model.selection,
                searchText: $searchText,
                status: $status,
                sort: $sort,
                skills: filteredSkills,
                allSkillCount: model.snapshots.count,
                hasAuthorization: model.hasAuthorization,
                hasActiveFilters: hasActiveFilters,
                refreshState: model.refreshState,
                agentNamesByID: agentNamesByID,
                onRefresh: refresh,
                onClearFilters: clearFilters
            )
            .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 380)
        } detail: {
            SkillDetailView(
                skill: selectedSkill,
                rootsByID: model.rootsByID,
                agentNamesByID: agentNamesByID
            )
            .frame(minWidth: 420)
        }
        .toolbar {
            ToolbarItemGroup {
                RefreshToolbarControl(
                    state: model.refreshState,
                    isDisabled: model.fileOperationCommandsDisabled,
                    onRefresh: refresh
                )

                Menu {
                    Button {
                        guard let selectedSkill else { return }
                        Task { await model.enrich([selectedSkill]) }
                    } label: {
                        Label(
                            L10n.string("Enrich Selected Skill"),
                            systemImage: "doc.text.magnifyingglass"
                        )
                    }
                    .disabled(selectedSkill == nil)

                    Button {
                        Task { await model.enrich(filteredSkills) }
                    } label: {
                        Label(
                            L10n.string("Enrich Visible Skills"),
                            systemImage: "square.stack.3d.up"
                        )
                    }
                    .disabled(filteredSkills.isEmpty)
                } label: {
                    if model.isEnriching {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 18, height: 18)
                    } else {
                        Image(systemName: "text.magnifyingglass")
                            .frame(width: 18, height: 18)
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .disabled(model.enrichmentCommandsDisabled)
                .frame(width: 24, height: 24)
                .help(L10n.string("Trusted Metadata"))
                .accessibilityLabel(L10n.string("Trusted Metadata"))

                SettingsLink {
                    Image(systemName: "gearshape")
                        .frame(width: 18, height: 18)
                }
                .help(L10n.string("Open Settings"))
                .accessibilityLabel(L10n.string("Open Settings"))
            }
        }
        .sheet(item: pendingOperationBinding) { plan in
            OperationConfirmationView(
                plan: plan,
                isOperating: model.isOperating,
                onConflictChange: model.updatePendingConflictPolicy,
                onCancel: model.cancelPendingFileOperation,
                onConfirm: { replacementConfirmed in
                    Task {
                        await model.executePendingFileOperation(
                            replacementConfirmed: replacementConfirmed
                        )
                    }
                }
            )
            .id(plan.id)
        }
        .sheet(item: pendingEnrichmentBinding) { group in
            CandidateSourceView(
                group: group,
                position: model.pendingEnrichmentPosition,
                onCancel: model.cancelPendingEnrichment,
                onSkip: model.skipPendingEnrichmentCandidate,
                onApply: model.applyEnrichmentCandidate
            )
            .id(group.id)
        }
        .sheet(item: pendingUpdateBinding) { proposal in
            UpdateReviewView(
                proposal: proposal,
                isUpdating: model.isUpdating,
                onCancel: model.cancelPendingUpdate,
                onConfirm: { allowLocalChanges in
                    Task {
                        await model.applyPendingUpdate(
                            allowLocalChanges: allowLocalChanges
                        )
                    }
                }
            )
            .id(proposal.id)
        }
        .alert(
            L10n.string("File Operation Failed"),
            isPresented: operationErrorBinding
        ) {
            Button(L10n.string("OK")) { model.operationError = nil }
        } message: {
            Text(verbatim: model.operationError ?? "")
        }
        .alert(
            L10n.string("Metadata Lookup Failed"),
            isPresented: enrichmentErrorBinding
        ) {
            Button(L10n.string("OK")) { model.enrichmentError = nil }
        } message: {
            Text(verbatim: model.enrichmentError ?? "")
        }
        .alert(
            L10n.string("Skill Update Failed"),
            isPresented: updateErrorBinding
        ) {
            Button(L10n.string("OK")) { model.updateError = nil }
        } message: {
            Text(verbatim: model.updateError ?? "")
        }
    }

    private var hasActiveFilters: Bool {
        destination != .all
            || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || status != .all
    }

    private var pendingOperationBinding: Binding<FileOperationPlan?> {
        Binding(
            get: { model.pendingOperationPlan },
            set: { value in
                if value == nil { model.cancelPendingFileOperation() }
            }
        )
    }

    private var operationErrorBinding: Binding<Bool> {
        Binding(
            get: { model.operationError != nil },
            set: { isPresented in
                if !isPresented { model.operationError = nil }
            }
        )
    }

    private var pendingEnrichmentBinding: Binding<EnrichmentCandidateGroup?> {
        Binding(
            get: { model.pendingEnrichmentGroup },
            set: { value in
                if value == nil { model.cancelPendingEnrichment() }
            }
        )
    }

    private var enrichmentErrorBinding: Binding<Bool> {
        Binding(
            get: { model.enrichmentError != nil },
            set: { isPresented in
                if !isPresented { model.enrichmentError = nil }
            }
        )
    }

    private var pendingUpdateBinding: Binding<UpdateProposal?> {
        Binding(
            get: { model.pendingUpdateProposal },
            set: { value in
                if value == nil { model.cancelPendingUpdate() }
            }
        )
    }

    private var updateErrorBinding: Binding<Bool> {
        Binding(
            get: { model.updateError != nil },
            set: { isPresented in
                if !isPresented { model.updateError = nil }
            }
        )
    }

    private func refresh() {
        Task { await model.refresh(.manual) }
    }

    private func clearFilters() {
        destination = .all
        searchText = ""
        status = .all
    }
}

private struct RefreshToolbarControl: View {
    let state: RefreshState
    let isDisabled: Bool
    let onRefresh: () -> Void

    @ViewBuilder
    var body: some View {
        if case .failed(let message) = state {
            Menu {
                Section {
                    Text(verbatim: L10n.string("Refresh Failed"))
                    Text(verbatim: message)
                }
                Button(L10n.string("Retry Refresh"), action: onRefresh)
            } label: {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
                    .frame(width: 18, height: 18)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(isDisabled)
            .frame(width: 24, height: 24)
            .help(L10n.string("Refresh Failed"))
            .accessibilityLabel(L10n.string("Refresh Failed"))
        } else {
            Button(action: onRefresh) {
                Group {
                    if state == .running {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 18, height: 18)
            }
            .disabled(state == .running || isDisabled)
            .frame(width: 24, height: 24)
            .help(state == .running
                ? L10n.string("Refreshing Skills")
                : L10n.string("Refresh Skills"))
            .accessibilityLabel(state == .running
                ? L10n.string("Refreshing Skills")
                : L10n.string("Refresh Skills"))
        }
    }
}
