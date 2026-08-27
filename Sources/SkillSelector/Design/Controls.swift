import AppKit
import SwiftUI

/// Shared controls styled from design/screens/browser.html and settings.html:
/// pill badges, agent chips, action-bar buttons, and a wrapping chip row.

/// `.pill-badge`: 11 pt semibold pill used in the detail hero.
struct PillBadge: View {
    enum Style {
        case link
        case warn
    }

    let text: String
    let style: Style

    var body: some View {
        Text(verbatim: text)
            .font(AppTheme.body(11, weight: .semibold))
            .foregroundStyle(style == .link ? AppTheme.foregroundSecondary : AppTheme.badgeWarnText)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(style == .link ? AppTheme.surface : AppTheme.warnTint, in: Capsule())
            .overlay {
                if style == .link {
                    Capsule().stroke(AppTheme.borderSoft, lineWidth: 1)
                }
            }
            .lineLimit(1)
    }
}

/// `.agent-chip-lg`: avatar + name pill used in the detail's 关联 Agents row.
struct AgentChipLarge: View {
    let name: String

    var body: some View {
        HStack(spacing: 6) {
            AgentMonoView(name: name, size: 20)
            Text(verbatim: name)
                .font(AppTheme.body(12, weight: .medium))
                .foregroundStyle(AppTheme.foreground)
        }
        .padding(.leading, 5)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .background(AppTheme.surface, in: Capsule())
        .overlay(Capsule().stroke(AppTheme.borderSoft, lineWidth: 1))
        .lineLimit(1)
    }
}

/// A wrapping row of `.agent-chip-lg` chips (`.chip-row`).
struct FlowChips: View {
    let names: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(names, id: \.self) { name in
                AgentChipLarge(name: name)
            }
        }
    }
}

/// Left-to-right wrapping layout for chip rows.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Action-bar `.btn` variants with the design's hover/active fills.
enum ActionButtonRole {
    case secondary
    case primary
    case destructive
    case dangerSolid
}

struct ActionButtonStyle: ButtonStyle {
    let role: ActionButtonRole
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTheme.body(13, weight: .medium))
            .foregroundStyle(foreground)
            .frame(height: 32)
            .padding(.horizontal, 14)
            .background(background(isPressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                if role == .secondary {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isHovering ? AppTheme.border : AppTheme.border, lineWidth: 1)
                }
            }
            .onHover { hovering in
                isHovering = hovering
            }
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch role {
        case .secondary, .primary: role == .primary ? .white : AppTheme.foreground
        case .destructive: AppTheme.danger
        case .dangerSolid: .white
        }
    }

    private func background(isPressed: Bool) -> Color {
        if isPressed {
            switch role {
            case .secondary: AppTheme.border
            case .primary: AppTheme.accentActive
            case .destructive: AppTheme.dangerTint
            case .dangerSolid: AppTheme.danger.opacity(0.85)
            }
        } else if isHovering {
            switch role {
            case .secondary: AppTheme.borderSoft
            case .primary: AppTheme.accentHover
            case .destructive: AppTheme.dangerTint
            case .dangerSolid: Color(hex: 0xC81E1E)
            }
        } else {
            switch role {
            case .secondary: AppTheme.surface
            case .primary: AppTheme.accent
            case .destructive: .clear
            case .dangerSolid: AppTheme.danger
            }
        }
    }
}

/// Builds an action-bar button with the given icon and role.
func actionButton(
    icon: Image?,
    title: String,
    role: ActionButtonRole,
    action: @escaping () -> Void
) -> some View {
    Button(action: action) {
        HStack(spacing: 6) {
            if let icon {
                icon
                    .font(.system(size: 13))
            }
            Text(verbatim: title)
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(ActionButtonStyle(role: role))
    .help(title)
    .accessibilityLabel(title)
}

/// `.switch`: 42×25 pill that fills success green when on.
struct ThemeSwitch: View {
    @Binding var isOn: Bool
    var accessibilityLabel: String

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? AppTheme.success : AppTheme.border)
                .frame(width: 42, height: 25)
            Circle()
                .fill(.white)
                .frame(width: 21, height: 21)
                .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
                .padding(2)
        }
        .contentShape(Capsule())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.22)) {
                isOn.toggle()
            }
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// Column separator, always visible (same language as the sidebar's trailing
/// divider) so the list column reads against the detail pane in both light
/// and dark appearances; the line brightens on hover to hint at dragging.
struct ColumnResizer: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    @State private var dragStart: CGFloat?
    @State private var showingHandle = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(width: 6)
            .overlay(alignment: .center) {
                Rectangle()
                    .fill(showingHandle ? AppTheme.border : AppTheme.borderSoft)
                    .frame(width: 1)
                    .padding(.vertical, 6)
            }
            .onHover { hovering in
                guard hovering != showingHandle else { return }
                showingHandle = hovering
                // set() replaces the cursor outright — no push/pop stack, so
                // hover events racing the strip's movement cannot unbalance it.
                (hovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
            }
            .gesture(
                // .global measures the drag translation in window space, not
                // the strip's own (moving) local space — otherwise changing
                // width shifts the strip under the cursor and re-anchors the
                // translation, producing the tell-tale lag/jitter.
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        if dragStart == nil { dragStart = width }
                        guard let start = dragStart else { return }
                        width = min(max(range.lowerBound, start + value.translation.width), range.upperBound)
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }
}
