import Foundation

/// What changed in each release, newest first. Shown in Settings ▸ Version history and mirrored in CHANGELOG.md.
struct Release: Identifiable, Equatable {
    let version: String
    let date: String
    let title: String
    /// New features.
    let notes: [String]
    var improvements: [String] = []
    var fixes: [String] = []
    var security: [String] = []
    /// True when the release day isn't recorded precisely.
    var approximateDate = false
    var id: String { version }
    var changeCount: Int { notes.count + improvements.count + fixes.count + security.count }
}

enum VersionHistory {
    static let releases: [Release] = [
        Release(version: "1.9", date: "29 Oct 2026", title: "Tools, reviews and safer backups",
                notes: ["Purchase simulator: see what a purchase does to your safe-to-spend, goals and cash before you buy, with a clear verdict.",
                        "What-if lab: change income, spending or a goal and see the next 12 months, kept apart from your real records.",
                        "Monthly review: a timeline of past months with income, spending, savings rate, categories, patterns and things worth a look. Tap any figure to see the transactions behind it, and export as PDF, Markdown or CSV.",
                        "Backup & recovery: manual and automatic backups, a history with sizes and status, retention, and optional passphrase encryption.",
                        "Restore with a preview of what's inside, a test restore, an automatic safety copy and an explicit confirmation.",
                        "Quick actions: touch and hold the MONO icon to add an expense, add income, transfer or open Safe to spend, and use the same actions from the Shortcuts app and Siri. They wait for Face ID first, and choose which ones show in Settings.",
                        "Receipts: scan with the camera or pick a photo. Text is read on your iPhone in English, Spanish or Malay (Burmese keeps the photo and you type the details). Check the shop, date, total and tax, then save as an expense, attach to an existing transaction, or keep the receipt alone. Searchable library, duplicate warnings, and photos can be included in backups.",
                        "Version history: changes grouped into features, improvements, fixes and security, with a rollback explanation."],
                improvements: ["Backups now include settings, themes, What-if scenarios and quick actions (never the Face ID lock).",
                               "The Overview backup reminder now asks for a copy saved outside MONO, because backups kept inside the app are deleted with it.",
                               "Backup format 5, with receipts and optional photos."],
                fixes: [],
                security: ["Backup passphrases are stored in the iPhone Keychain, never inside a backup file.",
                           "Every backup is checksummed, verified after writing and test-restored before it counts as a success."]),
        Release(version: "1.8", date: "29 Oct 2026", title: "Subscriptions, insights and privacy",
                notes: ["Hide amounts: an eye on Overview turns every money figure into dots and blurs charts, like a payment app. It can also hide automatically when the app opens, and reminder text follows it.",
                        "Subscriptions & bills: weekly, fortnightly, monthly, quarterly, yearly or custom schedules, with active, paused and cancelled states, notes, the paying account and your own reminder lead time.",
                        "Payments are now confirmed by you. A due payment shows as Due; tapping Mark paid records the real transaction and moves to the next date. The same payment can never be recorded twice, and nothing is deducted on its own. (Earlier versions recorded monthly payments automatically.)",
                        "Estimated monthly and yearly cost of your subscriptions, clearly marked as an estimate.",
                        "Spending insights: daily average, this month against the same days last month, weekly pattern, food and groceries by month, biggest expenses, what has changed over six months, subscription costs and budget warnings. Each card says whether it shows actual spending or an estimate.",
                        "Choose the time of day reminders arrive. Subscription payments appear in Upcoming on Overview and in Safe to spend, including overdue ones.",
                        "Backup format 4 saves schedules, statuses and which payments have been recorded."]),
        Release(version: "1.7", date: "29 Oct 2026", title: "Goals and Safe to spend",
                notes: ["Safe to spend: how much you can spend without touching unpaid bills, planned savings, essential budgets or reserved funds, with every line switchable and expandable. Nothing is counted twice.",
                        "Goals now have a description, a priority, their own currency, a start date and a weekly, fortnightly or monthly contribution schedule.",
                        "Each goal shows what to save each period, the monthly equivalent (what's left ÷ months left) and an estimated completion date, clearly marked as an estimate.",
                        "Goals in another currency are converted to your reporting currency only with a rate you entered; contributions from an account in a different currency record both amounts.",
                        "A Tools screen, one tap from Overview, for advanced features.",
                        "Mark categories as Essential and set aside reserved funds.",
                        "Backup format 3 saves the new goal fields, essential flags and reserved funds."]),
        Release(version: "1.6", date: "29 Oct 2026", title: "System Theme",
                notes: ["One System Theme screen in Settings: colours, appearance mode, Liquid Glass and the app icon, switched with a single Theme / App icon control.",
                        "Choose secondary text and border colours, or leave them automatic.",
                        "A single Reset to default, with confirmation, for the whole theme and the app icon.",
                        "30 app icon looks: five styles in six colours, including new Minimal and Outline styles and Warm and Midnight colours that match the built-in themes. A Match my theme shortcut picks the matching colour."]),
        Release(version: "1.5", date: "29 Oct 2026", title: "Accounts and currencies",
                notes: ["Accounts: cash, bank accounts and e-wallets, each with its own currency and starting balance. Your existing money moved into a “Main account” with nothing lost.",
                        "Transfers between accounts. They are never counted as income or spending, and a cross-currency transfer records the exact amount sent and received.",
                        "Multiple currencies with a reporting currency. Conversion uses only rates you enter; money without a rate is flagged and left out of totals, never guessed.",
                        "Merchant and tags on transactions, filtering by account and tag, and search across merchant, tags and account names.",
                        "A warning when a new transaction looks like a duplicate of one you already have.",
                        "A validated safety copy of your data is written before accounts are first set up.",
                        "Backup format 2 stores accounts, transfers and exchange rates; older backups still restore."]),
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
                        "Installation status: shows when this copy of the app needs renewing.",
                        "Recurring monthly transactions, posted automatically.",
                        "CSV import with column matching, a preview and duplicate protection."],
                security: ["Optional Face ID lock."]),
        Release(version: "1.0", date: "Oct 2026", title: "First release",
                notes: ["Overview, transactions, budgets with category limits, shopping lists, savings goals and trip planning, analytics.",
                        "Works fully offline with no account, no bank connection and no analytics.",
                        "JSON backup and restore, and CSV export."],
                security: ["App-switcher privacy cover."], approximateDate: true),
    ]

    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }
}
