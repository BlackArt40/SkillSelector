import AppKit
import SwiftUI

/// Apple design tokens bound verbatim from design/screens/browser.html and
/// design/screens/settings.html. Every color maps to the HTML `:root` and
/// `:root[data-theme="dark"]` variable of the same role, and adapts
/// automatically to the effective light/dark appearance.
enum AppTheme {
    // MARK: Colors

    static let background = adaptive(light: 0xFFFFFF, dark: 0x1E1E1E)
    static let surface = adaptive(light: 0xF5F5F7, dark: 0x272729)
    static let surfaceWarm = adaptive(light: 0xFBFBFD, dark: 0x2A2A2C)
    static let foreground = adaptive(light: 0x1D1D1F, dark: 0xF5F5F7)
    static let foregroundSecondary = adaptive(light: 0x424245, dark: 0xD2D2D7)
    static let muted = adaptive(light: 0x6E6E73, dark: 0xA1A1A6)
    static let meta = adaptive(light: 0x86868B, dark: 0x98989D)
    static let border = adaptive(light: 0xD2D2D7, dark: 0x48484A)
    static let borderSoft = adaptive(light: 0xE8E8ED, dark: 0x3A3A3C)
    static let accent = adaptive(light: 0x0071E3, dark: 0x2997FF)
    static let accentHover = adaptive(light: 0x0077ED, dark: 0x44A5FF)
    static let accentActive = adaptive(light: 0x0066CC, dark: 0x6AB8FF)
    static let success = adaptive(light: 0x16A34A, dark: 0x30D158)
    static let warn = adaptive(light: 0xEAB308, dark: 0xFFD60A)
    static let danger = adaptive(light: 0xDC2626, dark: 0xFF453A)
    static let badgeWarnText = adaptive(light: 0xB45309, dark: 0xF0A24D)

    /// color-mix(in oklab, var(--accent), transparent 88%) — active row /
    /// selected item background.
    static let accentTint = adaptive(
        light: blend(0x0071E3, over: 0xFFFFFF, alpha: 0.12),
        dark: blend(0x2997FF, over: 0x1E1E1E, alpha: 0.12)
    )

    /// color-mix(in oklab, var(--accent), transparent 70%) — active row
    /// border / selected segment border.
    static let accentTintBorder = adaptive(
        light: blend(0x0071E3, over: 0xFFFFFF, alpha: 0.30),
        dark: blend(0x2997FF, over: 0x1E1E1E, alpha: 0.30)
    )

    /// rgba(255,255,255,.7) — agent chip on an active skill row.
    static let accentChip: Color = {
        let lightTint = blend(0x0071E3, over: 0xFFFFFF, alpha: 0.12)
        let darkTint = blend(0x2997FF, over: 0x1E1E1E, alpha: 0.12)
        return adaptive(
            light: blend(0xFFFFFF, over: lightTint, alpha: 0.70),
            dark: blend(0xFFFFFF, over: darkTint, alpha: 0.70)
        )
    }()

    /// Skill tile gradients (160deg) from the design.
    static let tileTop = adaptive(light: 0x424245, dark: 0x424245)
    static let tileBottom = adaptive(light: 0x1D1D1F, dark: 0x1D1D1F)
    static let tileActiveTop = adaptive(light: 0x2997FF, dark: 0x2997FF)
    static let tileActiveBottom = adaptive(light: 0x0071E3, dark: 0x0071E3)

    /// Focus ring: color-mix(in oklab, var(--accent), transparent 65%).
    static let focusRing = adaptive(
        light: blend(0x0071E3, over: 0xFFFFFF, alpha: 0.35),
        dark: blend(0x2997FF, over: 0x1E1E1E, alpha: 0.28)
    )

    /// Toast: rgba(29,29,31,.94) pill with #f5f5f7 text.
    static let toastBackground = Color.black.opacity(0.86)

    /// Hover tint for destructive text buttons:
    /// color-mix(in oklab, var(--danger), transparent 92%).
    static let dangerTint = adaptive(
        light: blend(0xDC2626, over: 0xFFFFFF, alpha: 0.08),
        dark: blend(0xFF453A, over: 0x1E1E1E, alpha: 0.12)
    )

    /// Hover tint for accent text buttons:
    /// color-mix(in oklab, var(--accent), transparent 92%).
    static let accentTintFaint = adaptive(
        light: blend(0x0071E3, over: 0xFFFFFF, alpha: 0.08),
        dark: blend(0x2997FF, over: 0x1E1E1E, alpha: 0.12)
    )

    /// Pill warning background: color-mix(in oklab, var(--warn), transparent 85%).
    static let warnTint = adaptive(
        light: blend(0xEAB308, over: 0xFFFFFF, alpha: 0.15),
        dark: blend(0xFFD60A, over: 0x1E1E1E, alpha: 0.15)
    )

    /// Markdown element accents (amber on light, amber-300 on dark).
    static let codeInline = adaptive(light: 0xB45309, dark: 0xFBBF24)

    /// Markdown blockquote tint (violet-700 / violet-300).
    static let blockquote = adaptive(light: 0x6D28D9, dark: 0xA78BFA)

    /// Fenced code block background — clearly darker/lighter than the warm
    /// card surface so blocks read as distinct panels.
    static let codeBlockBackground = adaptive(light: 0xEBEBED, dark: 0x222224)

    // MARK: Fonts

    static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: Radii

    static let radiusSmall: CGFloat = 8
    static let radiusMedium: CGFloat = 12
    static let radiusLarge: CGFloat = 18

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
/// follows the OS — matching the HTML `ss.theme` behavior.
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
}
