import AppKit
import SwiftUI

/// Design tokens bound verbatim from `design-redesign/pages/*.html`
/// (brutalist redesign). Every color maps to the `<style id="theme-vars">`
/// `:root` and `.dark` variables of the same role — identical across all
/// eight pages — and adapts automatically to the effective light/dark
/// appearance. Visual language: zero corner radius, `2px 2px 0 0` hard
/// offset shadows, white strokes with black ink details in light mode,
/// monospace type throughout.
enum AppTheme {
    // MARK: Colors

    // Surfaces — --background / --card / --popover.
    nonisolated(unsafe) static let background = adaptive(light: 0xC5C9C9, dark: 0x0A0A0A)
    nonisolated(unsafe) static let surface = adaptive(light: 0xD8DADA, dark: 0x1A1A1A)
    nonisolated(unsafe) static let surfaceWarm = adaptive(light: 0xD8DADA, dark: 0x1A1A1A)

    /// `--muted` as a *surface* (not text): selected rows, banners, chips,
    /// secondary buttons, avatars (`--semantic-surface-muted`).
    nonisolated(unsafe) static let surfaceMuted = adaptive(light: 0xD8DADA, dark: 0x333333)

    // Text — --foreground / --muted-foreground (the design has a single
    // secondary text tone shared by all three legacy roles).
    nonisolated(unsafe) static let foreground = adaptive(light: 0x111111, dark: 0xFFFFFF)
    nonisolated(unsafe) static let foregroundSecondary = adaptive(light: 0x888888, dark: 0xAAAAAA)
    nonisolated(unsafe) static let muted = adaptive(light: 0x888888, dark: 0xAAAAAA)
    nonisolated(unsafe) static let meta = adaptive(light: 0x888888, dark: 0xAAAAAA)

    // Borders — `--border` (white strokes in light mode per the redesign);
    // hairlines share the same tone. `ink` is `--ring`, which the design
    // reuses as the strong-border / focus / ink-detail color
    // (`--semantic-border-strong`, `--semantic-brand-focus`).
    nonisolated(unsafe) static let border = adaptive(light: 0xFFFFFF, dark: 0x333333)
    nonisolated(unsafe) static let borderSoft = adaptive(light: 0xFFFFFF, dark: 0x333333)
    nonisolated(unsafe) static let ink = adaptive(light: 0x000000, dark: 0x333333)

    /// `--semantic-border-interactive` == `--input` — secondary buttons and
    /// search fields stroke this tone (distinct from `--border` in dark).
    nonisolated(unsafe) static let borderInteractive = adaptive(light: 0xFFFFFF, dark: 0x1A1A1A)

    /// `--semantic-input-background` == `--input` — search field fill.
    nonisolated(unsafe) static let inputBackground = adaptive(light: 0xFFFFFF, dark: 0x1A1A1A)

    // Sidebar family — `--sidebar`, `--sidebar-border`, `--sidebar-accent`,
    // `--sidebar-accent-foreground`: the sidebar carries its own surface and
    // accent pair (cooler panel + black/white label) distinct from `--muted`.
    nonisolated(unsafe) static let sidebarBackground = adaptive(light: 0xD8DADA, dark: 0x0A0A0A)
    nonisolated(unsafe) static let sidebarBorder = adaptive(light: 0xFFFFFF, dark: 0x333333)
    nonisolated(unsafe) static let sidebarAccent = adaptive(light: 0xC5C9C9, dark: 0x222222)
    nonisolated(unsafe) static let sidebarAccentForeground = adaptive(light: 0x000000, dark: 0xFFFFFF)

    // Brand — `--accent` (saturated cobalt blue in light; the design keeps
    // dark mode monochrome) and `--primary` (inverted black/white control
    // pair driving active states and primary buttons).
    nonisolated(unsafe) static let accent = adaptive(light: 0x0040FF, dark: 0x222222)
    nonisolated(unsafe) static let accentHover = adaptive(light: 0x111111, dark: 0xFFFFFF)
    nonisolated(unsafe) static let accentActive = adaptive(light: 0x111111, dark: 0xFFFFFF)

    /// Hover/press fill for a button whose *surface* is `accent`. The
    /// design's only hover fill step is onto the muted panel tone
    /// (`hover:bg-sidebar-accent`), which in dark is 0x333333 — stepping to
    /// `accentHover` (white) would bury the white accent-foreground label.
    /// Light keeps the accepted blue→ink step.
    nonisolated(unsafe) static let accentSurfaceHover = adaptive(light: 0x111111, dark: 0x333333)
    nonisolated(unsafe) static let accentSurfaceActive = adaptive(light: 0x111111, dark: 0x333333)

    /// `--secondary` / `--secondary-foreground` — the rules.html chip pair:
    /// near-black fill with a white label in light mode, mid-gray in dark.
    nonisolated(unsafe) static let secondary = adaptive(light: 0x111111, dark: 0x333333)
    nonisolated(unsafe) static let secondaryForeground = adaptive(light: 0xFFFFFF, dark: 0xFFFFFF)

    /// Label on the accent surface (`--accent-foreground`, oklch(1 0 0)):
    /// pure white in both appearances — marketplace selected rows set it.
    nonisolated(unsafe) static let accentForeground = adaptive(light: 0xFFFFFF, dark: 0xFFFFFF)

    // Status — the redesign only defines destructive; success/warn keep the
    // previous palette until a page specifies them (HANDOFF §3.1).
    nonisolated(unsafe) static let success = adaptive(light: 0x12A26D, dark: 0x34D399)
    nonisolated(unsafe) static let warn = adaptive(light: 0xD99A0B, dark: 0xFBBF24)
    nonisolated(unsafe) static let danger = adaptive(light: 0xD73333, dark: 0xEF4444)
    /// `--destructive-foreground` (oklch(1 0 0)): white in both appearances.
    nonisolated(unsafe) static let dangerForeground = adaptive(light: 0xFFFFFF, dark: 0xFFFFFF)
    nonisolated(unsafe) static let dangerHover = adaptive(
        light: blend(0x000000, over: 0xD73333, alpha: 0.15),
        dark: blend(0x000000, over: 0xEF4444, alpha: 0.15)
    )
    nonisolated(unsafe) static let badgeWarnText = adaptive(light: 0x9A6A00, dark: 0xF0A24D)

    /// Selection surfaces: the design marks selection with the muted panel
    /// tone + strong (ink) border + accent inset bar, not an accent wash.
    nonisolated(unsafe) static let accentTint = adaptive(light: 0xD8DADA, dark: 0x333333)

    /// Selected segment / active row border — `--semantic-border-strong`.
    nonisolated(unsafe) static let accentTintBorder = adaptive(light: 0x000000, dark: 0x333333)

    /// Hover surface for accent text buttons — the muted panel tone.
    nonisolated(unsafe) static let accentTintFaint = adaptive(light: 0xD8DADA, dark: 0x333333)

    /// Chip surface on selected rows (muted tone, distinguished by stroke).
    nonisolated(unsafe) static let accentChip = adaptive(light: 0xD8DADA, dark: 0x333333)

    /// Chip label on a muted chip surface.
    nonisolated(unsafe) static let accentChipText = adaptive(light: 0x111111, dark: 0xFFFFFF)

    /// Brand tiles (empty-state art) — flat panels in the redesign.
    nonisolated(unsafe) static let tileTop = adaptive(light: 0xD8DADA, dark: 0x1A1A1A)
    nonisolated(unsafe) static let tileBottom = adaptive(light: 0xC5C9C9, dark: 0x0A0A0A)
    nonisolated(unsafe) static let tileActiveTop = adaptive(light: 0x000000, dark: 0x333333)
    nonisolated(unsafe) static let tileActiveBottom = adaptive(light: 0x0040FF, dark: 0x222222)

    /// Focus ring — `--semantic-brand-focus` (== `--ring`).
    nonisolated(unsafe) static let focusRing = adaptive(light: 0x000000, dark: 0x333333)

    /// Toast pill background (dark in both appearances).
    nonisolated(unsafe) static let toastBackground = Color.black.opacity(0.86)

    /// Hover tint for destructive text buttons.
    nonisolated(unsafe) static let dangerTint = adaptive(
        light: blend(0xD73333, over: 0xC5C9C9, alpha: 0.08),
        dark: blend(0xEF4444, over: 0x0A0A0A, alpha: 0.12)
    )

    /// Pill warning background.
    nonisolated(unsafe) static let warnTint = adaptive(
        light: blend(0xD99A0B, over: 0xC5C9C9, alpha: 0.15),
        dark: blend(0xFBBF24, over: 0x0A0A0A, alpha: 0.15)
    )

    // Markdown element accents — neutral ink on muted code panels.
    nonisolated(unsafe) static let codeInline = adaptive(light: 0x111111, dark: 0xFFFFFF)
    nonisolated(unsafe) static let blockquote = adaptive(light: 0x888888, dark: 0xAAAAAA)
    nonisolated(unsafe) static let codeBlockBackground = adaptive(light: 0xC5C9C9, dark: 0x0A0A0A)

    /// Markdown h1 + link accent. Light takes `--accent` (cobalt); the
    /// design inverts `--accent` to monochrome in dark, where it would
    /// vanish on the card fill, so dark takes `--chart-1` — the design's
    /// only saturated dark family.
    nonisolated(unsafe) static let markdownAccent = adaptive(light: 0x0040FF, dark: 0x60A5FA)

    // Data visualization — `--chart-1`…`--chart-5` (the design's only
    // saturated colors in dark mode; `chart-3` doubles as the positive
    // banner marker, cf. main.html `.banner`).
    nonisolated(unsafe) static let chart1 = adaptive(light: 0x0140FF, dark: 0x60A5FA)
    nonisolated(unsafe) static let chart2 = adaptive(light: 0x386AFF, dark: 0xF472B6)
    nonisolated(unsafe) static let chart3 = adaptive(light: 0x6B90FF, dark: 0x34D399)
    nonisolated(unsafe) static let chart4 = adaptive(light: 0x94AFFF, dark: 0xFBBF24)
    nonisolated(unsafe) static let chart5 = adaptive(light: 0xBDCDFF, dark: 0x818CF8)

    // Primary button pair — `--primary` / `--primary-foreground`.
    nonisolated(unsafe) static let primaryButtonBackground = adaptive(light: 0x111111, dark: 0xFFFFFF)
    nonisolated(unsafe) static let primaryButtonForeground = adaptive(light: 0xFFFFFF, dark: 0x000000)

    /// Hard shadow base color — `--shadow-color` is pure black in both themes.
    nonisolated(unsafe) static let shadowColor = Color.black

    // MARK: Fonts

    /// The redesign sets `--font-sans` and `--font-mono` to Geist Mono;
    /// use the system monospaced design (SF Mono) as the fallback stack.
    static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: Radii

    /// `--radius: 0rem` — the brutalist redesign has zero corner radius.
    static let radiusSmall: CGFloat = 0
    static let radiusMedium: CGFloat = 0
    static let radiusLarge: CGFloat = 0

    // MARK: Hard shadow

    /// Shadow elevation matching `--shadow-2xs` / `--shadow-sm` / `--shadow-md`.
    enum ShadowLevel {
        case flat
        case rest
        case raised
    }

    /// Brutalist hard offset shadow: `2px 2px 0 0` pure black; `rest` and
    /// `raised` add the faint soft secondary shadow from `--shadow-sm` /
    /// `--shadow-md`.
    struct HardShadow: ViewModifier {
        var level: ShadowLevel = .rest

        func body(content: Content) -> some View {
            switch level {
            case .flat:
                content.shadow(color: AppTheme.shadowColor.opacity(0.5), radius: 0, x: 2, y: 2)
            case .rest:
                content
                    .shadow(color: AppTheme.shadowColor, radius: 0, x: 2, y: 2)
                    .shadow(color: AppTheme.shadowColor.opacity(0.55), radius: 2, x: 2, y: 1)
            case .raised:
                content
                    .shadow(color: AppTheme.shadowColor, radius: 0, x: 2, y: 2)
                    .shadow(color: AppTheme.shadowColor.opacity(0.55), radius: 4, x: 2, y: 2)
            }
        }
    }

    // MARK: Helpers

    /// A color that switches between the two RGB values with the effective
    /// light/dark appearance, exactly like the HTML `data-theme` switch.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        func nsColor(_ rgb: UInt32) -> NSColor {
            NSColor(
                srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255.0,
                green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
                blue: CGFloat(rgb & 0xFF) / 255.0,
                alpha: 1.0
            )
        }
        let lightColor = nsColor(light)
        let darkColor = nsColor(dark)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? darkColor
                : lightColor
        })
    }

    /// Straight sRGB alpha compositing used to approximate the design's
    /// `color-mix(in oklab, ...)` tints.
    private static func blend(_ rgb: UInt32, over base: UInt32, alpha: Double) -> UInt32 {
        let a = max(0, min(1, alpha))
        func component(_ value: UInt32, _ shift: Int) -> Double {
            Double((value >> shift) & 0xFF)
        }
        func mixed(_ shift: Int) -> UInt32 {
            UInt32((component(rgb, shift) * a + component(base, shift) * (1 - a)).rounded())
        }
        return (mixed(16) << 16) | (mixed(8) << 8) | mixed(0)
    }
}

extension Color {
    init(hex: UInt32) {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1.0)
    }
}

/// Light/dark appearance persistence shared by the browser toolbar toggle
/// and the settings window. `light`/`dark` override the system; `system`
/// follows the OS — matching the HTML `data-theme` behavior.
enum ThemePreference {
    static let storageKey = "SkillSelector.themeMode"

    @MainActor
    static func effectiveDark(mode: String?) -> Bool {
        guard let mode else { return systemIsDark }
        switch mode {
        case "dark": return true
        case "light": return false
        default: return systemIsDark
        }
    }

    @MainActor
    private static var systemIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

/// Applies the persisted appearance to any window's content.
struct ThemeAppearance: ViewModifier {
    @AppStorage(ThemePreference.storageKey) private var mode = "system"

    func body(content: Content) -> some View {
        content.preferredColorScheme(preferredScheme)
    }

    private var preferredScheme: ColorScheme? {
        switch mode {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}

extension View {
    func themedAppearance() -> some View {
        modifier(ThemeAppearance())
    }

    /// Brutalist hard offset shadow (`2px 2px 0 0` black). See
    /// `AppTheme.HardShadow` for the elevation levels.
    func hardShadow(_ level: AppTheme.ShadowLevel = .rest) -> some View {
        modifier(AppTheme.HardShadow(level: level))
    }

    /// The same shadow, opt-in — for shared components whose design page
    /// only sometimes carries the elevation.
    @ViewBuilder
    func hardShadow(_ level: AppTheme.ShadowLevel, isActive: Bool) -> some View {
        if isActive {
            modifier(AppTheme.HardShadow(level: level))
        } else {
            self
        }
    }
}
