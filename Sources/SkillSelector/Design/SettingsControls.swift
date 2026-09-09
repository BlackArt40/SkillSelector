import SwiftUI

/// Building blocks behind the Settings panes' `.group` / `.group-row`
/// language (design/screens/settings.html). Shared by SettingsView and
/// the per-pane files so row/group styling lives in exactly one place.

/// `.group` — a surface card whose rows are separated by hairline borders
/// (the design removes the border under the last row).
struct SettingsGroup<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        _VariadicView.Tree(SettingsGroupLayout()) {
            content
        }
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppTheme.borderSoft, lineWidth: 1)
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
                        .fill(AppTheme.borderSoft)
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
            .strokeBorder(isOn ? AppTheme.accent : AppTheme.meta, lineWidth: isOn ? 5.5 : 1.5)
            .frame(width: 17, height: 17)
            .accessibilityHidden(true)
    }
}

/// `.btn` — 30 pt settings button with an elevation ring.
struct SettingsButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTheme.body(12.5, weight: .medium))
            .foregroundStyle(AppTheme.foreground)
            .frame(height: 30)
            .padding(.horizontal, 14)
            .background(isHovering && !configuration.isPressed ? AppTheme.borderSoft : AppTheme.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppTheme.border, lineWidth: 1)
            }
            .onHover { hovering in
                isHovering = hovering
            }
            .contentShape(Rectangle())
    }
}

/// `.btn.danger` — bordered-less destructive text button.
struct SettingsDangerButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTheme.body(12.5, weight: .semibold))
            .foregroundStyle(AppTheme.danger)
            .frame(height: 30)
            .padding(.horizontal, 14)
            .background(isHovering && !configuration.isPressed ? AppTheme.dangerTint : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .onHover { hovering in
                isHovering = hovering
            }
            .contentShape(Rectangle())
    }
}

/// The muted section label above a settings group. `spaced` adds the
/// extra breathing room used when a section follows a non-group row.
struct SettingsGroupHeading: View {
    let title: String
    var spaced = false

    var body: some View {
        Text(verbatim: title)
            .font(AppTheme.body(12, weight: .semibold))
            .kerning(0.1)
            .foregroundStyle(AppTheme.muted)
            .padding(.horizontal, 4)
            .padding(.top, spaced ? 24 : 0)
            .padding(.bottom, 8)
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
