import AppKit
import SwiftUI

/// Brand components drawn from design/assets/logo.svg and app-icon.svg.
/// The logo glyph is drawn natively so it stays crisp at any size and adapts
/// its wordmark to the appearance (the SVG fixes the wordmark to #1d1d1f,
/// which would vanish on a dark background).
enum Brand {
    static let appIconName = "AppIcon"
}

/// The three stacked skill sheets from design/assets/logo.svg.
/// `size` is the front sheet's edge length (46 in the source SVG).
struct LogoGlyph: View {
    var size: CGFloat = 46

    private var u: CGFloat { size / 46 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            sheet(x: 10, y: 40, color: Color(hex: 0xD2D2D7))
            sheet(x: 25, y: 25, color: Color(hex: 0xAEAEB2))
            RoundedRectangle(cornerRadius: 12 * u)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: 0x2997FF), Color(hex: 0x0071E3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 46 * u, height: 46 * u)
                .offset(x: 40 * u, y: 10 * u)
            checkmark
        }
        .frame(width: 86 * u, height: 86 * u, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private func sheet(x: CGFloat, y: CGFloat, color: Color) -> some View {
        RoundedRectangle(cornerRadius: 12 * u)
            .fill(color)
            .frame(width: 46 * u, height: 46 * u)
            .offset(x: x * u, y: y * u)
    }

    private var checkmark: some View {
        Path { path in
            path.move(to: CGPoint(x: 52 * u, y: 33 * u))
            path.addLine(to: CGPoint(x: 60 * u, y: 41 * u))
            path.addLine(to: CGPoint(x: 74 * u, y: 26 * u))
        }
        .stroke(
            Color.white,
            style: StrokeStyle(lineWidth: 6 * u, lineCap: .round, lineJoin: .round)
        )
    }
}

/// The full wordmark lockup (glyph + "SkillSelector") from logo.svg.
/// `height` is the rendered height of the SVG's 96-unit view box.
struct LogoView: View {
    var height: CGFloat = 40

    private var scale: CGFloat { height / 96 }

    var body: some View {
        HStack(alignment: .center, spacing: 22 * scale) {
            LogoGlyph(size: 46 * scale)
            Text("SkillSelector")
                .font(.system(size: 34 * scale, weight: .semibold))
                .tracking(-0.5 * scale)
                .foregroundStyle(AppTheme.foreground)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("SkillSelector")
    }
}

/// Bundle containing the app's images (AppIcon.png).
///
/// The SwiftPM-generated `Bundle.module` on release builds looks for
/// `SkillSelector_SkillSelector.bundle` at the *app bundle root*, while the
/// packaging script places it under Contents/Resources — so images resolve
/// explicitly first, mirroring L10n's resource lookup, and fall back to
/// `Bundle.module` for tests and `swift run`.
extension Bundle {
    static var appResources: Bundle {
        if let url = Bundle.main.url(
            forResource: "SkillSelector_SkillSelector",
            withExtension: "bundle"
        ), let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }
}

/// The 1024px app icon from design/assets (rendered PNG resource).
struct AppIconView: View {
    var size: CGFloat = 128

    var body: some View {
        Image(Brand.appIconName, bundle: .appResources)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
    }
}

/// Gradient square tile showing the Skill's first letter
/// (`.skill-tile` / `.detail-tile` in the design).
struct SkillTileView: View {
    let title: String
    var size: CGFloat = 34
    var cornerRadius: CGFloat = 9
    var active = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(
                LinearGradient(
                    colors: active
                        ? [AppTheme.tileActiveTop, AppTheme.tileActiveBottom]
                        : [AppTheme.tileTop, AppTheme.tileBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay {
                Text(verbatim: title)
                    .font(AppTheme.display(size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// Monogram chip for an Agent (`.agent-mono` in the design).
struct AgentMonoView: View {
    let name: String
    var size: CGFloat = 18

    var body: some View {
        RoundedRectangle(cornerRadius: size * 5 / 18)
            .fill(AppTheme.foreground)
            .frame(width: size, height: size)
            .overlay {
                Text(verbatim: AgentMonoView.monogram(for: name))
                    .font(.system(size: size * 9.5 / 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.background)
            }
            .accessibilityHidden(true)
    }

    /// First letters of up to two words ("Claude Code" → "CC"), or the
    /// first two letters of a single word ("Codex" → "CO").
    static func monogram(for name: String) -> String {
        let words = name
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        if words.count >= 2 {
            return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }
}

/// Bundled per-Agent brand marks, looked up by agent id in `AgentIcons/`.
/// The SVGs are single-path monochrome (simple-icons, CC0), so their images
/// load as templates and tint with the surrounding foreground style —
/// legible in both light and dark appearances.
enum AgentBrandIcon {
    /// The bundled brand mark for an agent id, if one is shipped.
    static func image(for agentID: String) -> NSImage? {
        guard let url = Bundle.module.url(
            forResource: agentID,
            withExtension: "svg",
            subdirectory: "AgentIcons"
        ), let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }

    /// Whether a brand mark ships for this agent id (test seam).
    static func hasIcon(for agentID: String) -> Bool {
        image(for: agentID) != nil
    }
}

/// Agent avatar in the browser sidebar: the bundled brand mark when one
/// exists, the letter monogram otherwise.
struct AgentIconView: View {
    let agentID: String
    let displayName: String
    var size: CGFloat = 18

    var body: some View {
        if let image = AgentBrandIcon.image(for: agentID) {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            AgentMonoView(name: displayName, size: size)
        }
    }
}

/// Returns the first character of a Skill name, uppercased, for tiles.
func skillTileLetter(for name: String) -> String {
    String(name.first.map(String.init) ?? "?").uppercased()
}
