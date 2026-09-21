import AppKit
import SkillSelectorCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum SettingsTab: Hashable {
    case general
    case directories
    case about
}

extension Notification.Name {
    /// Posted (with a `SettingsTab` as object) when another scene asks the
    /// settings window to open on a specific pane — e.g. the re-authorization
    /// banner jumping to the directory authorization pane.
    static let openSettingsTab = Notification.Name("SkillSelector.openSettingsTab")
}

/// The settings window from design-redesign/pages/settings.html: a tab bar with
/// 通用 / 目录授权 / 关于 panes built from `.group` cards. The pane bodies
/// live in their own files (`GeneralSettingsPane`,
/// `DirectoriesSettingsPane`, `AboutSettingsPane`); this shell owns the
/// tab state plus every sheet/alert presentation the panes trigger.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var activeTab: SettingsTab = .general
    @State private var settingsError: String?
    @State private var exportStatus: String?
    @State private var customAgentSheetRequest: CustomAgentSheetRequest?
    @State private var showDiagnosticsViewer = false
    @State private var translationAPIKeyInput = ""
    /// Imported marketplace source being edited (改分支重导).
    @State private var editingCatalogSource: CustomCatalogSource?
    @State private var showingAddCatalogSource = false

    init(initialTab: SettingsTab = .general) {
        _activeTab = State(initialValue: initialTab)
    }

    var body: some View {
        // The tab bar stays pinned above the scroll view: panes can grow
        // tall (several authorized-root cards), and the tabs must remain
        // reachable without scrolling back to the top.
        VStack(spacing: 0) {
            tabBar
                .padding(.horizontal, 24)
                .padding(.top, 24)
            ScrollView {
                VStack(spacing: 0) {
                    switch activeTab {
                    case .general:
                        GeneralSettingsPane(
                            translationAPIKeyInput: $translationAPIKeyInput,
                            settingsError: $settingsError,
                            exportStatus: $exportStatus,
                            showDiagnosticsViewer: $showDiagnosticsViewer,
                            editingCatalogSource: $editingCatalogSource,
                            showingAddCatalogSource: $showingAddCatalogSource
                        )
                    case .directories:
                        DirectoriesSettingsPane(
                            settingsError: $settingsError,
                            customAgentSheetRequest: $customAgentSheetRequest
                        )
                    case .about:
                        AboutSettingsPane()
                    }
                }
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 64)
            }
        }
        .frame(width: 720, height: 780)
        .background(AppTheme.background)
        .background(SettingsWindowTitle(title: L10n.string("Settings")))
        .languageReloading()
        .themedAppearance()
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsTab)) { note in
            if let tab = note.object as? SettingsTab {
                activeTab = tab
            }
        }
        .sheet(item: $customAgentSheetRequest) { request in
            CustomAgentSheet(editing: request.agent)
        }
        .sheet(item: $editingCatalogSource) { original in
            EditCatalogSourceSheet(
                original: original,
                onSave: { custom in
                    let originalID = "\(original.owner)/\(original.repo)"
                    let updated = model.catalog.updateSource(custom, originalID: originalID)
                    if updated {
                        editingCatalogSource = nil
                        Task { await model.catalog.refresh() }
                    }
                    return updated
                },
                onCancel: { editingCatalogSource = nil }
            )
        }
        .sheet(isPresented: $showingAddCatalogSource) {
            AddCatalogSourceSheet(
                onImport: { custom in
                    let added = model.catalog.addSource(custom)
                    if added {
                        showingAddCatalogSource = false
                        Task { await model.catalog.refresh() }
                    }
                    return added
                },
                onCancel: { showingAddCatalogSource = false }
            )
        }
        .sheet(isPresented: $showDiagnosticsViewer) {
            DiagnosticsViewerView(
                input: model.redactedDiagnostics(),
                onExport: {
                    showDiagnosticsViewer = false
                    exportDiagnostics()
                }
            )
        }
        .alert(
            L10n.string("Settings Error"),
            isPresented: Binding(
                get: { settingsError != nil },
                set: { if !$0 { settingsError = nil } }
            )
        ) {
            Button(L10n.string("OK")) { settingsError = nil }
        } message: {
            Text(verbatim: settingsError ?? "")
        }
    }

    // MARK: Tab bar

    /// settings.html's `#settings-tabs`: a centered segmented control —
    /// 44 pt tall behind a 2 px ink border, hairline separators between
    /// segments, the active one filled with the primary ink pair.
    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton(.general, title: L10n.string("General"), icon: "person")
            Rectangle()
                .fill(AppTheme.ink)
                .frame(width: 1)
            tabButton(.directories, title: L10n.string("Directory Authorization"), icon: "folder")
            Rectangle()
                .fill(AppTheme.ink)
                .frame(width: 1)
            tabButton(.about, title: L10n.string("About"), icon: "questionmark.circle")
        }
        .overlay(Rectangle().stroke(AppTheme.ink, lineWidth: 2))
        // Fixed height keeps the flexible Rectangle separators from
        // absorbing the VStack's leftover height now that the bar sits
        // outside the scroll view; 640 max width centers it like before.
        .frame(height: 44)
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
    }

    private func tabButton(_ tab: SettingsTab, title: String, icon: String) -> some View {
        let isActive = activeTab == tab
        return Button {
            activeTab = tab
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                Text(verbatim: title)
                    .font(AppTheme.body(13))
                    .lineLimit(1)
            }
            .foregroundStyle(isActive ? AppTheme.primaryButtonForeground : AppTheme.foreground)
            .padding(.horizontal, 20)
            .frame(height: 40)
            .background(isActive ? AppTheme.primaryButtonBackground : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsTabHoverStyle(isActive: isActive))
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityLabel(title)
    }

    // MARK: Diagnostics export

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = L10n.string("Export Redacted Diagnostics")
        panel.prompt = L10n.string("Export")
        panel.nameFieldStringValue = "SkillSelector-Diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await model.exportDiagnostics(to: url)
                exportStatus = L10n.string("Diagnostics Exported")
            } catch {
                settingsError = error.localizedDescription
            }
        }
    }
}

/// `.tab:hover:not(.active)` — the page's hover lift + shadow on the
/// inactive segments.
private struct SettingsTabHoverStyle: ButtonStyle {
    let isActive: Bool
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if isHovering && !isActive && !configuration.isPressed {
                    Rectangle().fill(AppTheme.surfaceMuted)
                }
            }
            .onHover { hovering in
                isHovering = hovering
            }
    }
}
