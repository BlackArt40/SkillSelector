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

/// The settings window from design/screens/settings.html: a tab bar with
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
        VStack(spacing: 0) {
            tabBar
            Rectangle()
                .fill(AppTheme.borderSoft)
                .frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
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
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .padding(.bottom, 48)
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

    private var tabBar: some View {
        HStack(spacing: 2) {
            tabButton(.general, title: L10n.string("General"), icon: "gearshape")
            tabButton(.directories, title: L10n.string("Directory Authorization"), icon: "folder")
            tabButton(.about, title: L10n.string("About"), icon: "info.circle")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(AppTheme.surfaceWarm)
    }

    private func tabButton(_ tab: SettingsTab, title: String, icon: String) -> some View {
        Button {
            activeTab = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 19))
                Text(verbatim: title)
                    .font(AppTheme.body(11))
                    .lineLimit(1)
            }
            .foregroundStyle(activeTab == tab ? AppTheme.accentActive : AppTheme.foregroundSecondary)
            .frame(width: 76)
            .padding(.vertical, 7)
            .background(activeTab == tab ? AppTheme.accentTint : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsTabHoverStyle(isActive: activeTab == tab))
        .accessibilityAddTraits(activeTab == tab ? .isSelected : [])
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

/// `.tab:hover:not(.active)` — soft fill on hover.
private struct SettingsTabHoverStyle: ButtonStyle {
    let isActive: Bool
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if isHovering && !isActive && !configuration.isPressed {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(AppTheme.borderSoft)
                }
            }
            .onHover { hovering in
                isHovering = hovering
            }
    }
}
