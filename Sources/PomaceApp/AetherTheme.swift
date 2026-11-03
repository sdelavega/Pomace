import SwiftUI
import AppKit

/// Native mapping of Aether7B v1.0, sourced from ../aether7b/tokens/aether7b.tokens.json.
/// Content stays opaque; material is reserved for navigation chrome.
enum Aether {
    static let classic = color(0x7BAFD4)
    static let web = color(0x4B9CD3)
    static let ice = color(0x99C5E3)
    static let navy = color(0x13294B)
    static let accent = adaptive(light: 0x2B72A6, dark: 0x7BAFD4)
    static let canvas = adaptive(light: 0xEDF3F8, dark: 0x0A1320)
    static let card = adaptive(light: 0xFFFFFF, dark: 0x0E1A2B)
    static let well = adaptive(light: 0xE3EEF7, dark: 0x13294B)
    static let text = adaptive(light: 0x13294B, dark: 0xE6F0F8)
    static let muted = adaptive(light: 0x4A6583, dark: 0x8CA7C0)
    static let border = adaptive(light: 0x13294B, dark: 0x7BAFD4, lightAlpha: 0.12, darkAlpha: 0.22)
    static let specular = adaptive(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.95, darkAlpha: 0.16)
    static let metadata = Font.system(size: 12, design: .monospaced)

    private static func color(_ hex: UInt32) -> Color {
        Color(nsColor: nsColor(hex))
    }

    private static func nsColor(_ hex: UInt32, alpha: Double = 1) -> NSColor {
        NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                green: Double((hex >> 8) & 255) / 255,
                blue: Double(hex & 255) / 255, alpha: alpha)
    }

    private static func adaptive(light: UInt32, dark: UInt32,
                                 lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return nsColor(isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

struct AetherCanvas: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Aether.canvas
            .overlay {
                if !reduceTransparency {
                    RadialGradient(colors: [Aether.web.opacity(0.14), .clear],
                                   center: .topTrailing, startRadius: 0, endRadius: 600)
                }
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

private struct AetherSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(Aether.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(contrast == .increased ? Aether.muted : Aether.border, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Aether.specular)
                    .frame(height: 1)
                    .padding(.horizontal, 12)
                    .allowsHitTesting(false)
            }
    }
}

struct AetherChrome: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                Aether.canvas
            } else {
                Rectangle().fill(.ultraThinMaterial)
                    .overlay(Aether.navy.opacity(0.05))
            }
        }
        .accessibilityHidden(true)
    }
}

struct AetherBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Aether.metadata)
            .foregroundStyle(Aether.accent)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Aether.classic.opacity(0.15), in: Capsule())
            .overlay(Capsule().strokeBorder(Aether.accent.opacity(0.3), lineWidth: 1))
    }
}

struct AetherPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .foregroundStyle(Aether.colorForButtonText)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(colors: [Aether.classic, Aether.web],
                                         startPoint: .top, endPoint: .bottom))
            }
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Aether.ice, lineWidth: 1))
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Aether.accent, lineWidth: 2).padding(-3)
                }
            }
            .brightness(configuration.isPressed ? -0.08 : 0)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.14),
                       value: configuration.isPressed)
    }
}

extension Aether {
    static let colorForButtonText = Color(nsColor: NSColor(srgbRed: 10.0 / 255,
                                                          green: 19.0 / 255,
                                                          blue: 32.0 / 255, alpha: 1))
}

extension View {
    func aetherSurface() -> some View { modifier(AetherSurface()) }

    func aetherTheme() -> some View {
        tint(Aether.accent)
            .foregroundStyle(Aether.text, Aether.muted)
            .font(.system(size: 13))
            .background { AetherCanvas() }
    }
}
