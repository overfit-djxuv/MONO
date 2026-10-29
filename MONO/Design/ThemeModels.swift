import SwiftUI
import UIKit
import Observation

// MARK: - Colour maths

/// Small, dependency-free colour helpers working on 0xRRGGBB values. Used for derived tokens and accessibility checks.
enum ColorMath {
    static func components(_ hex: UInt32) -> (r: Double, g: Double, b: Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    /// WCAG relative luminance.
    static func luminance(_ hex: UInt32) -> Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let c = components(hex)
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    /// WCAG contrast ratio, 1...21.
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `a` moved `t` (0...1) of the way toward `b`.
    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        let x = components(a), y = components(b)
        func ch(_ p: Double, _ q: Double) -> UInt32 { UInt32((min(max(p + (q - p) * t, 0), 1) * 255).rounded()) }
        return ch(x.r, y.r) << 16 | ch(x.g, y.g) << 8 | ch(x.b, y.b)
    }

    /// Text colour (white or near-black) that reads best on `hex`.
    static func onColor(for hex: UInt32) -> UInt32 {
        contrast(hex, 0xFFFFFF) >= contrast(hex, 0x1A1A1A) ? 0xFFFFFF : 0x1A1A1A
    }

    static func hex(from color: Color) -> UInt32 {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        func ch(_ v: CGFloat) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
        return ch(r) << 16 | ch(g) << 8 | ch(b)
    }
}

extension Color {
    init(hex: UInt32) {
        let c = ColorMath.components(hex)
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }

    /// Resolves to `light` or `dark` with the environment's colour scheme.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            let c = ColorMath.components(hex)
            return UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
        })
    }
}

// MARK: - Palettes

/// The six colours a user can edit. Everything else in the interface is derived from these.
struct ThemeColors: Codable, Equatable {
    var primary: UInt32      // hero card, primary buttons
    var secondary: UInt32    // supporting tone: backdrop, charts
    var background: UInt32
    var surface: UInt32      // cards and sheets
    var accent: UInt32       // links, progress, selection, income
    var text: UInt32
    /// Optional overrides. Left nil, these are derived from text and background so they always stay readable.
    var secondaryText: UInt32? = nil
    var border: UInt32? = nil

    // Derived tokens (each guaranteed readable if text/background are).
    var textSecondary: UInt32 { secondaryText ?? ColorMath.mix(text, background, 0.30) }
    var textTertiary: UInt32 { ColorMath.mix(secondaryText ?? text, background, secondaryText == nil ? 0.44 : 0.30) }
    var line: UInt32 { border ?? ColorMath.mix(background, text, 0.12) }
    var cardLine: UInt32 { border ?? ColorMath.mix(surface, text, 0.10) }
    var accentSoft: UInt32 { ColorMath.mix(surface, accent, 0.16) }
    var onPrimary: UInt32 { ColorMath.onColor(for: primary) }
    var heroBottom: UInt32 { ColorMath.mix(primary, text, 0.14) }   // a gentle shade, never a harsh gradient
}

struct ThemePalette: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var light: ThemeColors
    var dark: ThemeColors

    func colors(for scheme: ColorScheme) -> ThemeColors { scheme == .dark ? dark : light }

    static let warmMinimal = ThemePalette(
        id: "warm-minimal", name: "Warm Minimal",
        light: ThemeColors(primary: 0x6B5444, secondary: 0xD9C7AE, background: 0xF7F1E7, surface: 0xFFFBF4, accent: 0x7A5A41, text: 0x2E2823),
        dark: ThemeColors(primary: 0x7A5E48, secondary: 0x4A3F35, background: 0x171310, surface: 0x221D19, accent: 0xCDAE90, text: 0xF1E9DE))

    static let midnightElegance = ThemePalette(
        id: "midnight-elegance", name: "Midnight Elegance",
        light: ThemeColors(primary: 0x3D4A59, secondary: 0xC7CED6, background: 0xF1F3F5, surface: 0xFFFFFF, accent: 0x4A5C70, text: 0x1C2128),
        dark: ThemeColors(primary: 0x4A5A6D, secondary: 0x4B5663, background: 0x111316, surface: 0x1A1E23, accent: 0xB9C2CC, text: 0xE6E9ED))

    static let sageCream = ThemePalette(
        id: "sage-cream", name: "Sage & Cream",
        light: ThemeColors(primary: 0x56705A, secondary: 0x7C7A48, background: 0xF5F0E3, surface: 0xFFFCF4, accent: 0x4C6A52, text: 0x242A23),
        dark: ThemeColors(primary: 0x4D6A53, secondary: 0x8A8758, background: 0x131814, surface: 0x1C231E, accent: 0xA9C2AC, text: 0xEDEFE5))

    static let presets: [ThemePalette] = [.sageCream, .warmMinimal, .midnightElegance]
    static let `default` = ThemePalette.sageCream
}

// MARK: - Store

/// Which palette is active, the user's saved palettes, and how strong the glass is. Persisted in UserDefaults.
/// Observable, so any view that reads a `Theme` token re-renders when it changes: that is what makes the preview live.
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    struct Saved: Codable, Equatable {
        var selectedID: String = ThemePalette.default.id
        var custom: [ThemePalette] = []
        var glass: Double = ThemeStore.defaultGlass
    }

    static let defaultGlass = 0.55
    private static let key = "themeState.v1"

    private(set) var saved: Saved
    /// An unsaved edit. While it exists the whole app previews it.
    private(set) var draft: ThemePalette?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let s = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = s
        } else {
            saved = Saved()
        }
        saved.glass = min(max(saved.glass, 0), 1)
        #if DEBUG
        // `-MONOTheme warm-minimal` and `-MONOGlass 0.2` pick a palette / intensity for simulator screenshots and UI tests.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "-MONOTheme"), i + 1 < args.count { saved.selectedID = args[i + 1] }
        if let i = args.firstIndex(of: "-MONOGlass"), i + 1 < args.count, let g = Double(args[i + 1]) { saved.glass = min(max(g, 0), 1) }
        #endif
    }

    // MARK: Reading

    var palettes: [ThemePalette] { ThemePalette.presets + saved.custom }
    var selected: ThemePalette { palettes.first { $0.id == saved.selectedID } ?? .default }
    /// What the interface renders right now.
    var active: ThemePalette { draft ?? selected }
    var glass: Double { saved.glass }
    var hasDraft: Bool { draft != nil }
    func isPreset(_ id: String) -> Bool { ThemePalette.presets.contains { $0.id == id } }

    /// A token that follows the system light/dark setting with the active palette's two colour sets.
    func token(_ pick: @escaping (ThemeColors) -> UInt32) -> Color {
        let p = active
        return Color(light: pick(p.light), dark: pick(p.dark))
    }

    // MARK: Changing

    func select(_ id: String) {
        guard palettes.contains(where: { $0.id == id }) else { return }
        draft = nil
        saved.selectedID = id
        persist()
    }

    func setGlass(_ value: Double) {
        saved.glass = min(max(value, 0), 1)
        persist()
    }

    /// Starts (or continues) an edit. Presets are never modified: editing one makes a copy.
    func edit(_ change: (inout ThemePalette) -> Void) {
        var d = draft ?? selected
        if draft == nil, isPreset(d.id) {
            d.id = "custom-\(UUID().uuidString)"
            d.name = uniqueName("My palette")
        }
        change(&d)
        draft = d
    }

    func rename(to name: String) { edit { $0.name = name } }

    /// Saves the draft as a custom palette and selects it.
    func saveDraft(name: String? = nil) {
        guard var d = draft else { return }
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { d.name = String(name.prefix(32)) }
        if let i = saved.custom.firstIndex(where: { $0.id == d.id }) { saved.custom[i] = d } else { saved.custom.append(d) }
        saved.selectedID = d.id
        draft = nil
        persist()
    }

    func discardDraft() { draft = nil }

    func delete(_ id: String) {
        guard !isPreset(id) else { return }
        saved.custom.removeAll { $0.id == id }
        if saved.selectedID == id { saved.selectedID = ThemePalette.default.id }
        if draft?.id == id { draft = nil }
        persist()
    }

    func duplicate(_ id: String) {
        guard let p = palettes.first(where: { $0.id == id }) else { return }
        var copy = p
        copy.id = "custom-\(UUID().uuidString)"
        copy.name = uniqueName(p.name + " copy")
        saved.custom.append(copy)
        saved.selectedID = copy.id
        draft = nil
        persist()
    }

    /// Re-reads the saved theme (after a backup restore replaced it).
    func reload() {
        if let data = defaults.data(forKey: Self.key), let s = try? JSONDecoder().decode(Saved.self, from: data) { saved = s } else { saved = Saved() }
        saved.glass = min(max(saved.glass, 0), 1)
        draft = nil
    }

    func resetAll() {
        draft = nil
        saved = Saved()
        persist()
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(palettes.map(\.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: Self.key) }
    }
}

// MARK: - Glass

/// How the glass intensity (0 = subtle, 1 = strong) maps to concrete drawing parameters.
struct GlassParameters: Equatable {
    var solidOpacity: Double      // opaque surface fill showing through
    var materialOpacity: Double   // blur layer
    var materialTier: Int         // 0 ultra-thin, 1 thin, 2 regular
    var sheen: Double             // diagonal reflection across the face
    var edge: Double              // light catching the rim
    var shadowRadius: Double
    var backdrop: Double          // how much colour the backdrop carries (frosted glass needs something behind it)

    static func make(intensity: Double, dark: Bool) -> GlassParameters {
        let g = min(max(intensity, 0), 1)
        return GlassParameters(
            solidOpacity: 1 - 0.80 * g,
            materialOpacity: 0.30 + 0.70 * g,
            materialTier: g < 0.34 ? 0 : (g < 0.67 ? 1 : 2),
            sheen: dark ? 0.02 + 0.15 * g : 0.05 + 0.50 * g,
            edge: dark ? 0.08 + 0.30 * g : 0.25 + 0.70 * g,
            shadowRadius: 8 + 14 * g,
            backdrop: 0.55 + 0.75 * g)
    }
}
