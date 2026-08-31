import AppKit
import SkillSelectorCore
import SwiftUI

/// Shared controls styled from design/screens/browser.html and settings.html:
/// pill badges, agent chips, action-bar buttons, and a wrapping chip row.

/// Search-match text: renders `text` with every hit of `query` emphasized
/// (accent blue + semibold, no background fill). Blank query or no hits
/// falls back to a plain Text. Hit ranges come from Core's pure
/// `HighlightMatch`, so every searchable list highlights consistently.
struct HighlightedText: View {
    let text: String
    var query: String = ""
    var font: Font
    var baseColor: Color
    /// Foreground color for each hit; defaults to the accent blue.
    var matchColor: Color = AppTheme.accentActive

    var body: some View {
        highlightedText
    }

    private var highlightedText: Text {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let ranges = HighlightMatch.ranges(of: trimmed, in: text)
        var attributed = AttributedString(text)
        attributed.font = font
        attributed.foregroundColor = baseColor
        // Locate runs by *character offset* rather than converting
        // String.Index directly: descriptions often contain punctuation,
        // emoji, or combined characters where the direct conversion can
        // land off a character boundary and silently return nil.
        let base = attributed.startIndex
        for range in ranges {
            let lowerOffset = text.distance(from: text.startIndex, to: range.lowerBound)
            let upperOffset = text.distance(from: text.startIndex, to: range.upperBound)
            let lower = attributed.index(base, offsetByCharacters: lowerOffset)
            let upper = attributed.index(base, offsetByCharacters: upperOffset)
            guard lower < upper else { continue }
            attributed[lower..<upper].font = font.weight(.semibold)
            attributed[lower..<upper].foregroundColor = matchColor
        }
        return Text(attributed)
    }
}

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


/// Shared in-column search field (marketplace, skills, duplicates, MCP,
/// rules, links): magnifier, rounded surface field whose placeholder
/// states the search scope, and a clear button once text is present.
/// It owns its own focus so ⌘F (`.focusSearchField`) lands the caret in
/// whichever list column is currently visible.
struct ListSearchBar: View {
    let placeholderKey: String
    @Binding var text: String
    /// True while background indexing runs — shows a small accent dot on
    /// the right (spec §5.9 "background indexing" / §06 "body search
    /// ready"), meaning search already works and hit counts will refresh
    /// when the index lands. Optional so non-skill columns omit it.
    var isIndexing: Bool = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.muted)
            TextField(L10n.string(placeholderKey), text: $text)
                .textFieldStyle(.plain)
                .font(AppTheme.body(13))
                .focused($searchFocused)
                .accessibilityLabel(L10n.string(placeholderKey))
                // Escape clears the term in every list's search bar (when
                // the field is focused), matching NSSearchField behavior.
                .onKeyPress(.escape) {
                    guard !text.isEmpty else { return .ignored }
                    text = ""
                    return .handled
                }
            if isIndexing {
                // Background index in progress: search already works, hits
                // will refresh when it lands (spec §5.9 / §06).
                Circle()
                    .fill(AppTheme.accent)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel(L10n.string("Indexing"))
            }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.muted)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.string("Clear Search"))
            } else if !searchFocused {
                // Empty-and-idle hint for the ⌘F shortcut (HIG: discoverable
                // but unobtrusive); it disappears as soon as the caret lands.
                Text("⌘F")
                    .font(AppTheme.body(11, weight: .medium))
                    .foregroundStyle(AppTheme.meta)
                    .padding(.trailing, 4)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(AppTheme.surfaceWarm, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onReceive(NotificationCenter.default.publisher(for: .focusSearchField)) { _ in
            searchFocused = true
        }
    }
}


/// Shared list-column empty state (`.list-empty`): optional icon, title,
/// message, and an optional text action. Every list column converges on
/// this component so empty screens look and behave identically across
/// All Skills, Duplicates, Symlinks, Rules, MCP, and the Marketplace.
struct EmptyState: View {
    var icon: String? = nil
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 48)
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundStyle(AppTheme.meta)
            }
            Text(verbatim: title)
                .font(AppTheme.display(17, weight: .semibold))
                .foregroundStyle(AppTheme.foreground)
                .lineLimit(1)
            if let message {
                Text(verbatim: message)
                    .font(AppTheme.body(13))
                    .foregroundStyle(AppTheme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
            }
            if let actionTitle, let action {
                Button(action: action) {
                    Text(verbatim: actionTitle)
                        .font(AppTheme.body(13, weight: .medium))
                        .foregroundStyle(AppTheme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(EmptyStateActionStyle())
                .padding(.top, 8)
                .accessibilityLabel(actionTitle)
            }
            Spacer(minLength: 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Faint accent fill on hover, matching the design's text-button behavior.
private struct EmptyStateActionStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if isHovering && !configuration.isPressed {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(AppTheme.accentTintFaint)
                }
            }
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

/// "No matching results" — the search-filtered variant of `EmptyState`,
/// kept as a convenience wrapper for filtered list columns.
struct NoResultsView: View {
    var body: some View {
        EmptyState(
            icon: "magnifyingglass",
            title: L10n.string("No Matching Results")
        )
    }
}

/// The moving highlight band shared by every skeleton block: a soft
/// gradient sweeps left-to-right on a 1.4 s cycle (spec §5.8), then
/// restarts — the classic native-feeling shimmer, no easing bounce.
private struct ShimmerHighlight: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let bandWidth = proxy.size.width * 0.55
            LinearGradient(
                colors: [.clear, AppTheme.borderSoft.opacity(0.55), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: bandWidth)
            .offset(x: -bandWidth + phase * (proxy.size.width + bandWidth))
        }
        .onAppear {
            // Respect "reduce motion": the skeleton shows a static band
            // instead of sweeping, so the loading state stays calm.
            guard !reduceMotion else { return }
            startSweep()
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced {
                withAnimation(.easeOut(duration: 0.15)) { phase = 0 }
            } else {
                startSweep()
            }
        }
    }

    private func startSweep() {
        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
            phase = 1
        }
    }
}

/// One rounded placeholder bar with the shimmer sweep. Sized by the
/// caller; used only inside loading skeletons.
struct SkeletonBlock: View {
    var cornerRadius: CGFloat = 6
    var width: CGFloat? = nil
    var height: CGFloat = 12

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(AppTheme.surface)
            .frame(width: width, height: height)
            .overlay(ShimmerHighlight())
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

/// Marketplace loading placeholder (spec §5.8): three skill-row-shaped
/// skeletons — tile, title bar, description bar, agent badge — with a
/// shared shimmer so the column reads "content is coming" instead of
/// showing a bare spinner. VoiceOver announces the loading state.
struct MarketplaceSkeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 10) {
                    SkeletonBlock(cornerRadius: 9, width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 7) {
                        SkeletonBlock(width: 150, height: 13)
                        SkeletonBlock(width: 230, height: 11)
                    }
                    Spacer(minLength: 0)
                    SkeletonBlock(cornerRadius: 8, width: 64, height: 18)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("Marketplace Loading"))
    }
}

/// Shared top-of-window banner (spec §5.7): icon + message + optional
/// action + optional dismiss. The tint follows the tone — warning (amber)
/// for re-authorization, info (accent) for retryable failures, success
/// (green) for refresh completions. Full-width, hairline bottom border.
enum BannerTone {
    case warning
    case info
    case success
}

struct Banner: View {
    let tone: BannerTone
    let icon: String
    let text: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var actionHelp: String? = nil
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(tint)
            Text(verbatim: text)
                .font(AppTheme.body(13))
                .foregroundStyle(AppTheme.foreground)
            Spacer(minLength: 12)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(SettingsButtonStyle())
                    .help(actionHelp ?? actionTitle)
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.muted)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.string("Dismiss"))
                .accessibilityLabel(L10n.string("Dismiss"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(backgroundTint)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.borderSoft)
                .frame(height: 1)
        }
    }

    private var tint: Color {
        switch tone {
        case .warning: AppTheme.warn
        case .info: AppTheme.accent
        case .success: AppTheme.success
        }
    }

    private var backgroundTint: Color {
        switch tone {
        case .warning: AppTheme.warn.opacity(0.12)
        case .info: AppTheme.accent.opacity(0.10)
        case .success: AppTheme.success.opacity(0.12)
        }
    }
}
