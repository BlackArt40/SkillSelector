import AppKit
import SkillSelectorCore
import SwiftUI

/// The 通用 pane: scanning, display language, the translation key group,
/// legacy agents, market sources, and the diagnostics export row. Sheet
/// presentation and the error alert stay in SettingsView — this pane only
/// flips the shared bindings.
struct GeneralSettingsPane: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("SkillSelector.preferredLanguage") private var preferredLanguage: String?
    @Binding var translationAPIKeyInput: String
    @Binding var settingsError: String?
    @Binding var exportStatus: String?
    @Binding var showDiagnosticsViewer: Bool
    @Binding var editingCatalogSource: CustomCatalogSource?
    @Binding var showingAddCatalogSource: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroupHeading(title: L10n.string("Scan"))
            SettingsGroup {
                SettingsRow(
                    label: L10n.string("Auto-scan Home Directory"),
                    sub: L10n.string("Scan agent skill folders in the home directory when the app launches.")
                ) {
                    ThemeSwitch(
                        isOn: Binding(
                            get: { model.autoScanHome },
                            set: { model.autoScanHome = $0 }
                        ),
                        accessibilityLabel: L10n.string("Auto-scan Home Directory")
                    )
                }
            }

            SettingsGroupHeading(title: L10n.string("Display"))
                .padding(.top, 4)
            SettingsGroup {
                languageSegment
            }

            Group {
            SettingsGroupHeading(title: L10n.string("Translation"))
                .padding(.top, 4)
            SettingsGroup {
                translationStatusRow
                translationKeyInputRow
                translationHelpRow
            }
            }

            SettingsGroupHeading(title: L10n.string("Legacy Agents"))
                .padding(.top, 4)
            SettingsGroup {
                ForEach(model.legacyAgentDefinitions) { agent in
                    SettingsRow(label: agent.displayName) {
                        ThemeSwitch(
                            isOn: Binding(
                                get: { model.manuallyEnabledAgentIDs.contains(agent.id) },
                                set: { model.setLegacyAgent(agent.id, enabled: $0) }
                            ),
                            accessibilityLabel: agent.displayName
                        )
                    }
                }
                SettingsRow(
                    label: L10n.string("Legacy Agent Hint"),
                    hint: true
                )
            }

            SettingsGroupHeading(title: L10n.string("Market Sources"))
                .padding(.top, 4)
            SettingsGroup {
                ForEach(model.catalog.sources) { source in
                    catalogSourceRow(source)
                }
                SettingsRow(
                    label: L10n.string("Market Source Hint"),
                    hint: true
                ) {
                    Button(L10n.string("Add…")) {
                        showingAddCatalogSource = true
                    }
                    .buttonStyle(SettingsButtonStyle())
                    .help(L10n.string("Import Source"))
                }
                SettingsRow(
                    label: L10n.string("Restore Built-in Sources"),
                    sub: L10n.string("Restore Built-in Sources Sub")
                ) {
                    Button(L10n.string("Restore")) {
                        model.catalog.restoreAllBuiltInSources()
                        Task { await model.catalog.refresh() }
                    }
                    .buttonStyle(SettingsButtonStyle())
                    .disabled(model.catalog.hiddenBuiltInSourceIDs.isEmpty)
                    .accessibilityLabel(L10n.string("Restore Built-in Sources"))
                }
            }

            Group {
            SettingsGroupHeading(title: L10n.string("Data"))
                .padding(.top, 4)
            SettingsGroup {
                SettingsRow(
                    label: L10n.string("Export Diagnostics Report"),
                    sub: L10n.string("Export Diagnostics Sub")
                ) {
                    HStack(spacing: 10) {
                        Button(L10n.string("View…"), action: { showDiagnosticsViewer = true })
                            .buttonStyle(SettingsButtonStyle())
                            .help(L10n.string("View Redacted Diagnostics"))
                        Button(L10n.string("Export…"), action: exportDiagnostics)
                            .buttonStyle(SettingsButtonStyle())
                            .help(L10n.string("Export Redacted Diagnostics"))
                    }
                }
            }
            exportStatus.map { status in
                Text(verbatim: status)
                    .font(AppTheme.body(12))
                    .foregroundStyle(AppTheme.muted)
                    .padding(.top, 8)
            }
            }
        }
    }

    // MARK: Display

    /// `.seg` — the three-option language segment with radio dots.
    private var languageSegment: some View {
        HStack(spacing: 3) {
            languageOption(L10n.string("Follow System"), value: nil)
            languageOption("简体中文", value: "zh-Hans")
            languageOption("English", value: "en")
        }
        .padding(6)
    }

    private func languageOption(_ title: String, value: String?) -> some View {
        let isSelected = preferredLanguage == value
        return Button {
            preferredLanguage = value
            L10n.setLanguage(value)
        } label: {
            HStack(spacing: 7) {
                RadioDot(isOn: isSelected)
                Text(verbatim: title)
                    .font(AppTheme.body(12.5, weight: .medium))
                    .foregroundStyle(AppTheme.foreground)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 6)
            .padding(.vertical, 7)
            .background(isSelected ? AppTheme.accentTint : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isSelected ? AppTheme.accentTintBorder : AppTheme.borderSoft, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(title)
    }

    // MARK: 翻译一览

    /// Status row: the configured state reads at a glance, with the
    /// removal entry attached only while a key exists.
    private var translationStatusRow: some View {
        SettingsRow(
            label: L10n.string("DeepL API Key"),
            sub: L10n.string(model.isTranslationConfigured
                ? "DeepL API Key Sub"
                : "Translation Missing Sub")
        ) {
            HStack(spacing: 10) {
                SettingsStatusDot(
                    text: L10n.string(model.isTranslationConfigured ? "Configured" : "Not Configured"),
                    color: model.isTranslationConfigured ? AppTheme.success : AppTheme.meta
                )
                if model.isTranslationConfigured {
                    Button(L10n.string("Remove")) {
                        model.removeTranslationAPIKey()
                    }
                    .buttonStyle(SettingsDangerButtonStyle())
                    .accessibilityLabel(L10n.string("Remove Translation API Key"))
                }
            }
        }
    }

    /// Key input row: a full-width secure field with the save button
    /// docked at its trailing edge.
    private var translationKeyInputRow: some View {
        let canSave = !translationAPIKeyInput
            .trimmingCharacters(in: .whitespaces).isEmpty
        return HStack(spacing: 8) {
            SecureField(
                L10n.string(model.isTranslationConfigured
                    ? "API Key Replace Placeholder"
                    : "API Key Placeholder"),
                text: $translationAPIKeyInput
            )
            .textFieldStyle(.roundedBorder)
            .font(AppTheme.body(12.5))
            .onSubmit {
                if canSave { saveTranslationAPIKey() }
            }
            Button(L10n.string("Save")) {
                saveTranslationAPIKey()
            }
            .buttonStyle(SettingsButtonStyle())
            .disabled(!canSave)
            .opacity(canSave ? 1 : 0.5)
            .accessibilityLabel(L10n.string("Save Translation API Key"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(AppTheme.surface)
    }

    /// Help row: signup/management entry points next to the short hint.
    private var translationHelpRow: some View {
        SettingsRow(
            label: L10n.string("Get a Free Key"),
            sub: L10n.string("Get a Free Key Sub")
        ) {
            HStack(spacing: 8) {
                Button(L10n.string("Open DeepL Signup")) {
                    if let url = URL(string: "https://www.deepl.com/pro-api") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(SettingsButtonStyle())
                .help(L10n.string("Open DeepL Signup"))
                Button(L10n.string("Open DeepL API Keys")) {
                    if let url = URL(string: "https://www.deepl.com/account/summary") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(SettingsButtonStyle())
                .help(L10n.string("Open DeepL API Keys"))
            }
        }
    }

    private func saveTranslationAPIKey() {
        let key = translationAPIKeyInput.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        do {
            try model.saveTranslationAPIKey(key)
            translationAPIKeyInput = ""
        } catch {
            settingsError = error.localizedDescription
        }
    }

    // MARK: Market sources

    /// One marketplace source row: display name, owner/repo@branch, and
    /// Edit (改分支重导) / Remove actions. Editing a built-in source
    /// migrates it to a user-managed entry; removing a built-in hides it.
    private func catalogSourceRow(_ source: CatalogSource) -> some View {
        SettingsRow(
            label: source.displayName,
            sub: "\(source.owner)/\(source.repo) @ \(source.branch)",
            subMonospaced: true
        ) {
            HStack(spacing: 10) {
                Button(L10n.string("Edit")) {
                    editingCatalogSource = CustomCatalogSource(
                        owner: source.owner,
                        repo: source.repo,
                        branch: source.branch
                    )
                }
                .buttonStyle(SettingsButtonStyle())
                .accessibilityLabel(L10n.string("Edit Imported Source"))
                Button(L10n.string("Remove")) {
                    model.catalog.removeSource(id: source.id)
                    Task { await model.catalog.refresh() }
                }
                .buttonStyle(SettingsDangerButtonStyle())
                .accessibilityLabel(L10n.string("Remove Imported Source"))
            }
        }
    }

    // MARK: Diagnostics export

    /// `runModal` needs no host window; with `user-selected.read-write`
    /// granted it is all these panels ever needed.
    private func runPanel(_ panel: NSSavePanel) -> URL? {
        panel.runModal() == .OK ? panel.url : nil
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = L10n.string("Export Redacted Diagnostics")
        panel.prompt = L10n.string("Export")
        panel.nameFieldStringValue = "SkillSelector-Diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard let url = runPanel(panel) else { return }
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
