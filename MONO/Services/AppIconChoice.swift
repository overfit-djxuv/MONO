import SwiftUI

/// The app icon is one of 12 built-in looks: 3 styles × 4 colourways. iOS can only switch between icons that ship inside the app,
/// so every combination is pre-rendered (tools/make_icon.swift) rather than recoloured on the fly.
enum IconStyle: String, CaseIterable, Identifiable {
    case glass, orbit, dusk
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var detail: String {
        switch self { case .glass: "Frosted tile"; case .orbit: "Progress ring"; case .dusk: "Soft light" }
    }
}

enum IconColor: String, CaseIterable, Identifiable {
    case forest, slate, bronze, graphite
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var swatch: Color {
        switch self {
        case .forest: Color(light: 0x3F7A62, dark: 0x4F8C73)
        case .slate: Color(light: 0x4A6A8C, dark: 0x5C7C9E)
        case .bronze: Color(light: 0x8A6B3F, dark: 0x9C7C50)
        case .graphite: Color(light: 0x5A5E66, dark: 0x70747C)
        }
    }
}

struct AppIconChoice: Equatable {
    var style: IconStyle
    var color: IconColor

    /// What ships as the primary `AppIcon`.
    static let `default` = AppIconChoice(style: .glass, color: .forest)

    /// The alternate-icon name to pass to iOS; nil means the primary icon.
    var alternateName: String? { self == .default ? nil : "icon-\(style.rawValue)-\(color.rawValue)" }

    /// Artwork in the asset catalog used for in-app previews.
    var previewName: String { "Preview-\(style.rawValue)-\(color.rawValue)" }

    var label: String { "\(style.label) · \(color.label)" }

    init(style: IconStyle, color: IconColor) { self.style = style; self.color = color }

    /// Inverse of `alternateName`; unknown names fall back to the default.
    init(alternateName: String?) {
        guard let name = alternateName else { self = .default; return }
        let parts = name.split(separator: "-")
        if parts.count == 3, parts[0] == "icon", let s = IconStyle(rawValue: String(parts[1])), let c = IconColor(rawValue: String(parts[2])) {
            self.init(style: s, color: c)
        } else { self = .default }
    }

    static var allAlternateNames: [String] {
        IconStyle.allCases.flatMap { s in IconColor.allCases.compactMap { AppIconChoice(style: s, color: $0).alternateName } }
    }
}
