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
            .background(style == .link ? AppTheme.surface : AppTheme.warnTint, in: Rectangle())
            .overlay {
                if style == .link {
                    Rectangle().stroke(AppTheme.borderSoft, lineWidth: 1)
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
        .background(AppTheme.surface, in: Rectangle())
        .overlay(Rectangle().stroke(AppTheme.borderSoft, lineWidth: 1))
        .lineLimit(1)
    }
}

/// A wrapping row of `.agent-chip-lg` chips (`.chip-row`).
///
/// SwiftUI's `Layout` protocol is macOS 13+, so wrapping uses the
/// macOS 11-compatible alignment-guide technique: chips sit in a top-leading
/// ZStack and are pushed into rows by running x/y accumulators captured in
/// the guide closures; the measured block height is fed back through state
/// so the container stays as compact as the chips.
@MainActor
struct FlowChips: View {
    let names: [String]

    /// Gap between and after chips (the old FlowLayout's `spacing`).
    private let spacing: CGFloat = 6
    @State private var totalHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            wrappedChips(in: geo)
        }
        .frame(height: totalHeight)
    }

    private func wrappedChips(in geo: GeometryProxy) -> some View {
        var x: CGFloat = 0
        var y: CGFloat = 0
        return ZStack(alignment: .topLeading) {
            ForEach(names, id: \.self) { name in
                AgentChipLarge(name: name)
                    .padding(.trailing, spacing)
                    .padding(.bottom, spacing)
                    .alignmentGuide(.leading) { dimension in
                        if abs(x - dimension.width) > geo.size.width {
                            x = 0
                            y -= dimension.height
                        }
                        let result = x
                        if name == names.last {
                            x = 0
                        } else {
                            x -= dimension.width
                        }
                        return result
                    }
                    .alignmentGuide(.top) { _ in
                        let result = y
                        if name == names.last {
                            y = 0
                        }
                        return result
                    }
            }
        }
        .background(
            GeometryReader { proxy -> Color in
                let height = proxy.size.height
                DispatchQueue.main.async {
                    if totalHeight != height {
                        totalHeight = height
                    }
                }
                return Color.clear
            }
        )
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
            .font(AppTheme.body(13, weight: .bold))
            .foregroundStyle(foreground)
            .frame(height: 36)
            .padding(.horizontal, 16)
            .background(
                background(isPressed: configuration.isPressed)
                    .hardShadow(.rest)
            )
            .overlay {
                if role == .secondary {
                    Rectangle().stroke(AppTheme.borderInteractive, lineWidth: 1)
                }
            }
            // `.btn` presses translate toward the shadow (+1,+1) and lift
            // on hover (-1,-1), exactly like the CSS transform rules.
            .offset(
                x: configuration.isPressed ? 1 : (isHovering ? -1 : 0),
                y: configuration.isPressed ? 1 : (isHovering ? -1 : 0)
            )
            .onHover { hovering in
                isHovering = hovering
            }
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch role {
        case .secondary: AppTheme.foreground
        case .primary: AppTheme.accentForeground
        case .destructive: AppTheme.danger
        case .dangerSolid: AppTheme.dangerForeground
        }
    }

    private func background(isPressed: Bool) -> Color {
        if isPressed {
            switch role {
            case .secondary: AppTheme.border
            case .primary: AppTheme.accentSurfaceActive
            case .destructive: AppTheme.dangerTint
            case .dangerSolid: AppTheme.danger.opacity(0.85)
            }
        } else if isHovering {
            switch role {
            case .secondary: AppTheme.borderSoft
            case .primary: AppTheme.accentSurfaceHover
            case .destructive: AppTheme.dangerTint
            case .dangerSolid: AppTheme.dangerHover
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

/// catalog.html's heavy ink button (`h-9`/`h-10 border-2 border-ring …
/// shadow-sm`): 14 pt bold label on a card or primary fill behind a
/// constant 2 px ink stroke. Hover lifts (-1,-1) and grows the shadow to
/// `md`; pressing sinks (+1,+1) and drops the shadow — the CSS `active`
/// rules verbatim.
struct InkButtonStyle: ButtonStyle {
    /// Control height: 36 (`h-9`, toolbar row) or 40 (`h-10`, detail actions).
    var height: CGFloat = 36
    /// Horizontal padding: 12 (`px-3`) in the toolbar, 16 (`px-4`) on detail.
    var horizontalPadding: CGFloat = 12
    /// `bg-primary text-primary-foreground` variant (导入市场/复制安装命令).
    var isPrimary = false
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let base = configuration.label
            .font(AppTheme.body(14, weight: .bold))
            .foregroundStyle(isPrimary ? AppTheme.primaryButtonForeground : AppTheme.foreground)
            .frame(height: height)
            .padding(.horizontal, horizontalPadding)
            .background(isPrimary ? AppTheme.primaryButtonBackground : AppTheme.surface)
            .overlay {
                Rectangle().stroke(AppTheme.ink, lineWidth: 2)
            }
        return Group {
            if configuration.isPressed {
                // `active:shadow-none` — the button sinks flat into the surface.
                base
            } else {
                base.hardShadow(isHovering ? .raised : .rest)
            }
        }
        // `.btn` presses translate toward the shadow (+1,+1) and lift on
        // hover (-1,-1), exactly like the CSS transform rules.
        .offset(
            x: configuration.isPressed ? 1 : (isHovering ? -1 : 0),
            y: configuration.isPressed ? 1 : (isHovering ? -1 : 0)
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .contentShape(Rectangle())
    }
}

/// rules.html's ink chip (`h-6 border border-ring bg-secondary px-2
/// text-xs text-secondary-foreground`): 24 pt tall agent tag, near-black
/// fill with a white label in light mode; the `+N` overflow variant uses
/// the muted fill with a muted label.
struct InkChip: View {
    let text: String
    var muted = false

    var body: some View {
        Text(verbatim: text)
            .font(AppTheme.body(12))
            .foregroundStyle(muted ? AppTheme.muted : AppTheme.secondaryForeground)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(muted ? AppTheme.surfaceMuted : AppTheme.secondary)
            .overlay(Rectangle().stroke(AppTheme.ink, lineWidth: 1))
            .lineLimit(1)
    }
}

/// catalog.html's rectangular badge (`border-2 border-ring
/// bg-sidebar-accent px-1.5 py-0.5 text-[11px] font-bold`): count chips
/// and status badges with heavy ink chrome.
struct InkBadge: View {
    let text: String
    var backgroundColor: Color = AppTheme.sidebarAccent
    var foregroundColor: Color = AppTheme.sidebarAccentForeground

    var body: some View {
        Text(verbatim: text)
            .font(AppTheme.body(11, weight: .bold))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundColor)
            .overlay {
                Rectangle().stroke(AppTheme.ink, lineWidth: 2)
            }
            .lineLimit(1)
    }
}

/// `.switch`: 42×25 pill that fills success green when on. Backed by a
/// real Button so keyboard users (Space/Return once focused) and
/// VoiceOver (action on the element) can operate it — the old
/// `onTapGesture` variant was pointer-only.
struct ThemeSwitch: View {
    @Binding var isOn: Bool
    var accessibilityLabel: String

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.22)) {
                isOn.toggle()
            }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? AppTheme.success : AppTheme.border)
                    .frame(width: 42, height: 25)
                Circle()
                    .fill(AppTheme.accentForeground)
                    .frame(width: 21, height: 21)
                    .shadow(color: AppTheme.shadowColor.opacity(0.22), radius: 2, y: 1)
                    .padding(2)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isOn ? "on" : "off")
    }
}

/// The modal-card footer buttons shared by the diagnostics viewer and the
/// agent editor: 取消/关闭 is a 36 pt bordered tool button on the muted
/// fill; 保存/导出 is the primary ink pair. Both lift on hover and sink
/// on press (`transition-all` rules verbatim).
struct ModalToolButtonStyle: ButtonStyle {
    enum Kind {
        case secondary
        case primary
    }

    let kind: Kind
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTheme.body(13))
            .foregroundStyle(kind == .primary
                ? AppTheme.primaryButtonForeground
                : AppTheme.foreground)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(kind == .primary
                ? AppTheme.primaryButtonBackground
                : AppTheme.surfaceMuted)
            .overlay {
                if kind == .secondary {
                    Rectangle().stroke(AppTheme.ink, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .hardShadow(.rest, isActive: !configuration.isPressed)
            .offset(
                x: configuration.isPressed ? 1 : (isHovering ? -1 : 0),
                y: configuration.isPressed ? 1 : (isHovering ? -1 : 0)
            )
            .onHover { isHovering = $0 }
    }
}

/// Column separator, always visible (same language as the sidebar's trailing
/// divider) so the list column reads against the detail pane in both light
/// and dark appearances; the line brightens on hover to hint at dragging.
struct ColumnResizer: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    /// Marketplace chrome (catalog.html): the list↔detail divider is a
    /// constant full-height 2 px ink rule instead of the hairline track.
    var isHeavyInk = false
    @State private var dragStart: CGFloat?
    @State private var showingHandle = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(width: 6)
            .overlay(alignment: .center) {
                Rectangle()
                    .fill(
                        showingHandle
                            ? AppTheme.border
                            : (isHeavyInk ? AppTheme.ink : AppTheme.borderSoft)
                    )
                    .frame(width: isHeavyInk ? 2 : 1)
                    .padding(.vertical, isHeavyInk ? 0 : 6)
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


/// `.search`: shared in-column search field (marketplace, skills,
/// duplicates, MCP, rules, links) — magnifier, 40 pt flat surface with a
/// hard shadow, plus a clear button once text is present. It owns its own
/// focus so ⌘F (`.focusSearchField`) lands the caret in whichever list
/// column is currently visible.
struct ListSearchBar: View {
    /// Chrome levels, one per design page: `.standard` is main.html's
    /// `.search` — input fill, white hairline stroke, hard shadow, accent
    /// focus ring; `.ink` is catalog.html's field — constant 2 px ink
    /// border on the card fill, no shadow; `.card` is mcp.html's field —
    /// 1 px ink border on the card fill, no shadow; `.inputInk` is
    /// rules.html's field — 2 px ink border on the input fill, no shadow.
    /// All four carry the funnel icon the pages share.
    enum Style {
        case standard
        case ink
        case card
        case inputInk
    }

    let placeholderKey: String
    @Binding var text: String
    var style: Style = .standard
    /// rules.html sets the field `h-9` beside its 2xl heading; every other
    /// page uses 40 pt.
    var height: CGFloat = 40
    /// True while background indexing runs — shows a small accent dot on
    /// the right (spec §5.9 "background indexing" / §06 "body search
    /// ready"), meaning search already works and hit counts will refresh
    /// when the index lands. Optional so non-skill columns omit it.
    var isIndexing: Bool = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: style == .standard ? 12 : 14, weight: .medium))
                    .foregroundStyle(AppTheme.foregroundSecondary)
                TextField(L10n.string(placeholderKey), text: $text)
                    .textFieldStyle(.plain)
                    .font(AppTheme.body(13))
                    .focused($searchFocused)
                    .accessibilityLabel(L10n.string(placeholderKey))
                    // Escape clears the term in every list's search bar (when
                    // the field is focused), matching NSSearchField behavior.
                    .onExitCommand {
                        guard !text.isEmpty else { return }
                        text = ""
                    }
                if isIndexing {
                    // Background index in progress: search already works, hits
                    // will refresh when it lands (spec §5.9 / §06).
                    Circle()
                        .fill(AppTheme.accent)
                        .frame(width: 6, height: 6)
                        .help(L10n.string("Indexing"))
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
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(style == .standard || style == .inputInk ? AppTheme.inputBackground : AppTheme.surface)
            .overlay {
                switch style {
                case .ink:
                    Rectangle().stroke(AppTheme.ink, lineWidth: 2)
                case .inputInk:
                    Rectangle()
                        .stroke(searchFocused ? AppTheme.accent : AppTheme.ink, lineWidth: searchFocused ? 3 : 2)
                case .card:
                    Rectangle()
                        .stroke(searchFocused ? AppTheme.accent : AppTheme.ink, lineWidth: searchFocused ? 2 : 1)
                case .standard:
                    Rectangle()
                        .stroke(searchFocused ? AppTheme.accent : AppTheme.border, lineWidth: searchFocused ? 2 : 1)
                }
            }
        }
        // main.html gives the field `shadow-sm`; mcp/catalog leave it flat.
        .hardShadow(.rest, isActive: style == .standard)
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
                    Rectangle().fill(AppTheme.accentTintFaint)
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
        .onChangeCompat(of: reduceMotion) { reduced in
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
    var width: CGFloat? = nil
    var height: CGFloat = 12

    var body: some View {
        Rectangle()
            .fill(AppTheme.surface)
            .frame(width: width, height: height)
            .overlay(ShimmerHighlight())
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
                    SkeletonBlock(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 7) {
                        SkeletonBlock(width: 150, height: 13)
                        SkeletonBlock(width: 230, height: 11)
                    }
                    Spacer(minLength: 0)
                    SkeletonBlock(width: 64, height: 18)
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
                .font(AppTheme.body(13, weight: .bold))
                .foregroundStyle(tint)
                .lineLimit(1)
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
                        .foregroundStyle(AppTheme.foregroundSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.string("Dismiss"))
                .accessibilityLabel(L10n.string("Dismiss"))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .background(AppTheme.surfaceMuted)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(barColor)
                .frame(width: 3)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.border)
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

    private var barColor: Color {
        switch tone {
        case .warning: AppTheme.warn
        case .info: AppTheme.chart1
        case .success: AppTheme.chart3
        }
    }
}
