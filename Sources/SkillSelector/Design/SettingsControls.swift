import SwiftUI

/// Building blocks behind the Settings panes' `.group` / `.group-row`
/// language (design/screens/settings.html). Shared by SettingsView and
/// the per-pane files so row/group styling lives in exactly one place.

/// `.group` — a surface card whose rows are separated by hairline borders
/// (the design removes the border under the last row). settings.html's
/// cards are square-cornered with the white hairline stroke.
struct SettingsGroup<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        _VariadicView.Tree(SettingsGroupLayout()) {
            content
        }
        .background(AppTheme.surface)
        .overlay {
            Rectangle().stroke(AppTheme.border, lineWidth: 1)
        }
    }
}

private struct SettingsGroupLayout: _VariadicView.MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let views = Array(children)
        VStack(spacing: 0) {
            ForEach(Array(views.enumerated()), id: \.offset) { index, child in
                child
                if index < views.count - 1 {
                    Rectangle()
                        .fill(AppTheme.border)
                        .frame(height: 1)
                }
            }
        }
    }
}

/// `.group-row` — 44 pt min-height row with label, optional sub, and a
/// trailing control. Rows inside a group separate themselves with a
/// hairline border above (the design removes it on the first row).
struct SettingsRow<Content: View>: View {
    let label: String
    var sub: String? = nil
    var subMonospaced = false
    var hint = false
    let trailing: Content

    init(
        label: String,
        sub: String? = nil,
        subMonospaced: Bool = false,
        hint: Bool = false,
        @ViewBuilder trailing: () -> Content = { EmptyView() }
    ) {
        self.label = label
        self.sub = sub
        self.subMonospaced = subMonospaced
        self.hint = hint
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: label)
                    .font(AppTheme.body(13))
                    .foregroundStyle(hint ? AppTheme.muted : AppTheme.foreground)
                if let sub {
                    Text(verbatim: sub)
                        .font(subMonospaced ? AppTheme.mono(11.5) : AppTheme.body(11.5))
                        .foregroundStyle(AppTheme.muted)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if !(trailing is EmptyView) {
                trailing
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .padding(.vertical, 11)
        .background(AppTheme.surface)
    }
}

/// `.radio` — 17 pt circle; on state fills with the accent border.
struct RadioDot: View {
    let isOn: Bool

    var body: some View {
        Circle()
            .strokeBorder(isOn ? AppTheme.accentInk : AppTheme.meta, lineWidth: isOn ? 5.5 : 1.5)
            .frame(width: 17, height: 17)
            .accessibilityHidden(true)
    }
}

/// `.btn` — 32 pt settings button: square, page-tone fill behind a 1 px
/// ink stroke, lifting on hover and sinking on press.
struct SettingsButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTheme.body(12))
            .foregroundStyle(AppTheme.foreground)
            .frame(height: 32)
            .padding(.horizontal, 12)
            .background(AppTheme.background)
            .overlay {
                Rectangle().stroke(AppTheme.ink, lineWidth: 1)
            }
            .contentShape(Rectangle())
            .pressLiftMotion(isPressed: configuration.isPressed)
    }
}

/// settings.html's 移除 button — the destructive action keeps a bordered
/// 32 pt body with the red label and the trash icon the page shows.
struct SettingsDangerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTheme.body(12))
            .foregroundStyle(AppTheme.danger)
            .frame(height: 32)
            .padding(.horizontal, 12)
            .background(AppTheme.background)
            .overlay {
                Rectangle().stroke(AppTheme.ink, lineWidth: 1)
            }
            .contentShape(Rectangle())
            .pressLiftMotion(isPressed: configuration.isPressed)
    }
}

/// The settings section header: `text-base font-bold` plus the optional
/// count chip (`h-6 border border-ring bg-card …`) the directories page
/// hangs off 已授权目录 / 自定义 Agent 目录.
struct SettingsGroupHeading: View {
    let title: String
    var count: Int? = nil
    var spaced = false

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: title)
                .font(AppTheme.body(16, weight: .bold))
                .foregroundStyle(AppTheme.foreground)
            if let count {
                Text(verbatim: "\(count)")
                    .font(AppTheme.body(12, weight: .bold).monospacedDigit())
                    .foregroundStyle(AppTheme.foreground)
                    .padding(.horizontal, 6)
                    .frame(height: 24)
                    .background(AppTheme.surface)
                    .overlay(Rectangle().stroke(AppTheme.ink, lineWidth: 1))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, spaced ? 24 : 0)
        .padding(.bottom, 12)
    }
}

/// A small colored status dot with a caption — authorization state,
/// translation key state, and their kin.
struct SettingsStatusDot: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(verbatim: text)
                .font(AppTheme.body(12))
                .foregroundStyle(AppTheme.muted)
        }
    }
}
