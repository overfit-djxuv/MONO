import SwiftUI
import UIKit

/// Every colour in the app comes from here, and every token is derived from the six colours in the active palette
/// (see ThemeModels.swift). Nothing outside this file picks a colour by hex, so changing the palette restyles every screen.
enum Theme {
    private static var store: ThemeStore { .shared }

    // Editable palette colours.
    static var primary: Color { store.token(\.primary) }
    static var secondary: Color { store.token(\.secondary) }
    static var bg: Color { store.token(\.background) }
    static var surface: Color { store.token(\.surface) }
    static var accent: Color { store.token(\.accent) }
    static var ink: Color { store.token(\.text) }

    // Derived.
    static var inkSecondary: Color { store.token(\.textSecondary) }
    static var inkTertiary: Color { store.token(\.textTertiary) }
    static var line: Color { store.token(\.line) }
    static var cardLine: Color { store.token(\.cardLine) }
    static var accentSoft: Color { store.token(\.accentSoft) }
    static var onPrimary: Color { store.token(\.onPrimary) }
    static var heroTop: Color { store.token(\.primary) }
    static var heroBottom: Color { store.token(\.heroBottom) }
    /// Solid fallback for glass when Reduce Transparency is on.
    static var card: Color { surface }
    static var income: Color { accent }
    static var expense: Color { ink }

    // Status colours stay fixed and muted so a warning always reads as a warning, whatever the palette.
    static let warning = Color(light: 0xA2640F, dark: 0xD9A441)
    static let danger = Color(light: 0xA3402B, dark: 0xE07A63)

    /// Strong ease-out: instant-feeling response that settles gently.
    static func easeOut(_ duration: Double = 0.22) -> Animation { .timingCurve(0.23, 1, 0.32, 1, duration: duration) }
    static let press = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.16)

    static let radius: CGFloat = 12
    static let cardRadius: CGFloat = 24
    static let gutter: CGFloat = 20
}

// MARK: - Typography helpers

extension Font {
    /// Figures use tabular digits so columns of amounts line up.
    static func figure(_ size: CGFloat, weight: Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

// MARK: - Press feedback

/// Every tappable control acknowledges the touch: a slight scale on press, fast ease-out on release.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Theme.press, value: configuration.isPressed)
    }
}

/// Filled primary-colour button.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(Theme.onPrimary)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Theme.primary.opacity(enabled ? 1 : 0.35), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.press, value: configuration.isPressed)
    }
}

// MARK: - Glass

/// A soft colour field behind every screen, tinted by the palette. Frosted surfaces read as glass only when something sits behind them.
struct AmbientBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let g = GlassParameters.make(intensity: ThemeStore.shared.glass, dark: scheme == .dark)
        let k = g.backdrop * (scheme == .dark ? 0.46 : 0.36)
        ZStack {
            Theme.bg
            RadialGradient(colors: [Theme.primary.opacity(0.70 * k), .clear], center: UnitPoint(x: 0.95, y: 0.02),
                           startRadius: 0, endRadius: 440)
            RadialGradient(colors: [Theme.secondary.opacity(0.60 * k), .clear], center: UnitPoint(x: 0.0, y: 0.52),
                           startRadius: 0, endRadius: 410)
            RadialGradient(colors: [Theme.accent.opacity(0.40 * k), .clear], center: UnitPoint(x: 0.9, y: 0.98),
                           startRadius: 0, endRadius: 380)
        }
        .ignoresSafeArea()
    }
}

/// Shared by cards and list rows so both follow the glass intensity setting.
func glassMaterial(tier: Int) -> AnyShapeStyle {
    switch tier {
    case 0: AnyShapeStyle(.ultraThinMaterial)
    case 1: AnyShapeStyle(.thinMaterial)
    default: AnyShapeStyle(.regularMaterial)
    }
}

/// Background for rows inside a Form or List, so every screen (not just custom cards) follows the theme.
struct GlassRowBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let g = GlassParameters.make(intensity: ThemeStore.shared.glass, dark: scheme == .dark)
        if reduceTransparency {
            Theme.card
        } else {
            ZStack {
                Theme.surface.opacity(g.solidOpacity)
                Rectangle().fill(glassMaterial(tier: g.materialTier)).opacity(g.materialOpacity)
                Rectangle().fill(.white.opacity(g.sheen * 0.45))
            }
        }
    }
}

/// Frosted glass. The Liquid Glass intensity setting drives how opaque, how blurred and how reflective it is.
struct GlassStyle: ViewModifier {
    var padding: CGFloat = 16
    var radius: CGFloat = Theme.cardRadius
    var tint: Color? = nil
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let dark = scheme == .dark
        let g = GlassParameters.make(intensity: ThemeStore.shared.glass, dark: dark)
        let padded = content.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
        if reduceTransparency {
            padded.background(Theme.card, in: shape).overlay(shape.strokeBorder(Theme.cardLine, lineWidth: 0.75))
        } else {
            padded
                .background(
                    // Every fill sits behind the content so text stays crisp; only the thin rim is drawn on top.
                    ZStack {
                        shape.fill(Theme.surface.opacity(g.solidOpacity))
                        shape.fill(glassMaterial(tier: g.materialTier)).opacity(g.materialOpacity)
                        shape.fill((tint ?? .clear).opacity(0.10))
                        shape.fill(LinearGradient(colors: [.white.opacity(g.sheen), .white.opacity(g.sheen * 0.12)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                )
                .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(g.edge), .white.opacity(g.edge * 0.15)],
                                                           startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8))
                .overlay(shape.strokeBorder(Theme.cardLine.opacity(1 - 0.6 * ThemeStore.shared.glass), lineWidth: 0.5))
                .shadow(color: .black.opacity(dark ? 0.32 : 0.06), radius: g.shadowRadius, y: g.shadowRadius * 0.5)
        }
    }
}

/// The balance card: the palette's primary colour with a gentle shade and a soft reflection.
struct HeroBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        let g = GlassParameters.make(intensity: ThemeStore.shared.glass, dark: scheme == .dark)
        shape.fill(LinearGradient(colors: [Theme.heroTop, Theme.heroBottom], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(shape.fill(RadialGradient(colors: [.white.opacity(0.06 + 0.12 * ThemeStore.shared.glass), .clear],
                                               center: .topLeading, startRadius: 0, endRadius: 340)))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.15 + 0.30 * ThemeStore.shared.glass), .white.opacity(0.03)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.9))
            .shadow(color: Theme.heroBottom.opacity(0.26), radius: g.shadowRadius + 6, y: 12)
    }
}

/// Circular progress gauge with content in the middle.
struct RingGauge<Center: View>: View {
    var value: Double
    var tint: Color = Theme.accent
    var lineWidth: CGFloat = 10
    @ViewBuilder var center: () -> Center
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var shown: Double = 0

    var body: some View {
        ZStack {
            Circle().stroke(Theme.line, lineWidth: lineWidth)
            Circle().trim(from: 0, to: max(min(shown, 1), shown > 0 ? 0.015 : 0))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            center()
        }
        .onAppear { if reduce { shown = value } else { withAnimation(Theme.easeOut(0.7)) { shown = value } } }
        .onChange(of: value) { _, new in withAnimation(reduce ? nil : Theme.easeOut(0.3)) { shown = new } }
    }
}

/// Small glass tile for the bento grid: icon, label, value, optional footnote.
struct StatTile: View {
    let title: String
    let value: String
    var symbol: String
    var tint: Color = Theme.ink
    var footnote: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(tint.opacity(0.14), in: Circle())
                    .foregroundStyle(tint)
                Text(title).font(.footnote.weight(.medium)).foregroundStyle(Theme.inkSecondary)
            }
            Text(value).font(.figure(21)).foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.65).contentTransition(.numericText())
            if let footnote { Text(footnote).font(.caption).foregroundStyle(Theme.inkTertiary).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glass(radius: 22)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Hide amounts

/// With Hide amounts on, a chart is blurred and can't be touched, because its shape would still give the numbers away.
struct HideAmounts: ViewModifier {
    func body(content: Content) -> some View {
        let hidden = PrivacyStore.shared.hidden
        content
            .blur(radius: hidden ? 14 : 0)
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
            .overlay {
                if hidden {
                    Label("Amounts hidden", systemImage: "eye.slash").font(.footnote.weight(.medium)).foregroundStyle(Theme.inkSecondary)
                        .padding(.vertical, 6).padding(.horizontal, 12).background(.ultraThinMaterial, in: Capsule())
                }
            }
            .animation(Theme.easeOut(0.2), value: hidden)
    }
}

// MARK: - Entrance

/// Short fade + 8pt rise. Used once on first appearance of a screen; skipped for Reduce Motion.
struct Entrance: ViewModifier {
    var index: Int
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown || reduce ? 1 : 0)
            .offset(y: shown || reduce ? 0 : 8)
            .onAppear {
                guard !shown else { return }
                withAnimation(Theme.easeOut(0.3).delay(Double(min(index, 6)) * 0.04)) { shown = true }
            }
    }
}

extension View {
    func entrance(_ index: Int) -> some View { modifier(Entrance(index: index)) }

    func hidesAmounts() -> some View { modifier(HideAmounts()) }

    func glass(padding: CGFloat = 16, radius: CGFloat = Theme.cardRadius, tint: Color? = nil) -> some View {
        modifier(GlassStyle(padding: padding, radius: radius, tint: tint))
    }

    /// Existing call sites keep working: every card is glass.
    func card(padding: CGFloat = 16) -> some View { glass(padding: padding) }

    func monoScreen() -> some View {
        self.background(AmbientBackground())
    }
}

// MARK: - Haptics

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}
