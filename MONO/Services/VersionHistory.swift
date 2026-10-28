import Foundation

/// What changed in each release, newest first. Shown in Settings ▸ Version history and mirrored in CHANGELOG.md.
struct Release: Identifiable, Equatable {
    let version: String
    let date: String
    let title: String
    let notes: [String]
    var id: String { version }
}

enum VersionHistory {
    static let releases: [Release] = [
        Release(version: "1.4", date: "29 Oct 2026", title: "Your theme",
                notes: ["Theme editor in Settings: change the primary, secondary, background, surface, accent and text colours, with a live preview across the whole app.",
                        "Three curated palettes: Sage & Cream, Warm Minimal and Midnight Elegance, each with a light and a dark version.",
                        "Save your own palettes, duplicate or delete them, and switch between System, Light and Dark.",
                        "Liquid Glass intensity slider, from subtle to strong: transparency, blur, reflections and glow.",
                        "A readability check for every colour combination.",
                        "A calmer, more minimal look: softer shading and no decorative graphics."]),
        Release(version: "1.3.1", date: "29 Oct 2026", title: "Import shortcut",
                notes: ["Import from a CSV file is now one tap away on the Transactions screen, and on its empty state."]),
        Release(version: "1.3", date: "29 Oct 2026", title: "Glass",
                notes: ["New glass design in light and dark: frosted surfaces over a soft, muted colour backdrop.",
                        "Overview rebuilt as a bento grid with a budget ring and rounded figures.",
                        "A new app icon, with dark and tinted versions for the iOS home screen.",
                        "Choose your app icon in Settings: three styles in four muted colours.",
                        "Version history in Settings."]),
        Release(version: "1.2", date: "29 Oct 2026", title: "Faster and calmer",
                notes: ["Faster entry: type a description and tap a suggestion to fill its category and amount.",
                        "Swipe right on a transaction to repeat it for today.",
                        "Reminders for planned expenses (the morning before and the day itself) and when a budget reaches 80% or goes over.",
                        "Copy last month’s budget and add whatever was left unspent.",
                        "Card-based redesign."]),
        Release(version: "1.1", date: "29 Oct 2026", title: "Safer and smarter",
                notes: ["Backup reminder, and Back up now saves to Files or iCloud Drive.",
                        "Optional Face ID lock.",
                        "Installation status: shows when this copy of the app needs renewing.",
                        "Recurring monthly transactions, posted automatically.",
                        "CSV import with column matching, a preview and duplicate protection."]),
        Release(version: "1.0", date: "Oct 2026", title: "First release",
                notes: ["Overview, transactions, budgets with category limits, shopping lists, savings goals and trip planning, analytics.",
                        "Works fully offline with no account, no bank connection and no analytics.",
                        "JSON backup and restore, and CSV export.",
                        "App-switcher privacy cover."]),
    ]

    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }
}
