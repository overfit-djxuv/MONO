import SwiftUI
import UIKit
import AppIntents

/// Things you can start straight from the home-screen icon or the Shortcuts app.
enum QuickAction: String, CaseIterable, Identifiable, Codable {
    case addExpense, addIncome, transfer, safeToSpend
    var id: String { rawValue }

    var title: String {
        switch self {
        case .addExpense: "Add expense"
        case .addIncome: "Add income"
        case .transfer: "Transfer"
        case .safeToSpend: "Safe to spend"
        }
    }
    var symbol: String {
        switch self {
        case .addExpense: "minus.circle"
        case .addIncome: "plus.circle"
        case .transfer: "arrow.left.arrow.right"
        case .safeToSpend: "shield.lefthalf.filled"
        }
    }
    static let shortcutPrefix = "com.example.monoapp.action."
    var shortcutType: String { Self.shortcutPrefix + rawValue }
    init?(shortcutType: String) {
        guard shortcutType.hasPrefix(Self.shortcutPrefix) else { return nil }
        self.init(rawValue: String(shortcutType.dropFirst(Self.shortcutPrefix.count)))
    }
}

/// Which actions are shown on the icon, and in what order. iOS shows at most four.
enum QuickActionSettings {
    static let key = "quickActions.v1"
    static let maxShown = 4

    static func enabled(_ defaults: UserDefaults = .standard) -> [QuickAction] {
        guard let raw = defaults.string(forKey: key) else { return QuickAction.allCases }
        return raw.split(separator: ",").compactMap { QuickAction(rawValue: String($0)) }.removingDuplicates()
    }
    static func save(_ actions: [QuickAction], _ defaults: UserDefaults = .standard) {
        defaults.set(actions.map(\.rawValue).joined(separator: ","), forKey: key)
    }
    static func toggle(_ a: QuickAction, on: Bool, _ defaults: UserDefaults = .standard) {
        var list = enabled(defaults)
        if on { if !list.contains(a) { list.append(a) } } else { list.removeAll { $0 == a } }
        save(list, defaults)
    }
    static func shown(_ defaults: UserDefaults = .standard) -> [QuickAction] { Array(enabled(defaults).prefix(maxShown)) }

    /// Replaces the icon's long-press menu with the chosen actions.
    @MainActor static func publish(_ defaults: UserDefaults = .standard) {
        UIApplication.shared.shortcutItems = shown(defaults).map {
            UIApplicationShortcutItem(type: $0.shortcutType, localizedTitle: $0.title, localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: $0.symbol), userInfo: nil)
        }
    }
}

private extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] { var seen = Set<Element>(); return filter { seen.insert($0).inserted } }
}

/// Holds a requested action until the app is unlocked, so a shortcut can never open a screen with money on it past Face ID.
@MainActor @Observable
final class AppRouter {
    static let shared = AppRouter()
    var pending: QuickAction?
    func request(_ a: QuickAction) { pending = a }
    /// Hands the action over only when nothing is locked.
    func take(isLocked: Bool) -> QuickAction? {
        guard !isLocked, let a = pending else { return nil }
        pending = nil
        return a
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let item = options.shortcutItem, let a = QuickAction(shortcutType: item.type) {
            Task { @MainActor in AppRouter.shared.request(a) }
        }
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem) async -> Bool {
        guard let a = QuickAction(shortcutType: shortcutItem.type) else { return false }
        await MainActor.run { AppRouter.shared.request(a) }
        return true
    }
}

// MARK: - Shortcuts app / Siri

/// These all open the app (never read or speak amounts), so Face ID still guards your data.
struct AddExpenseIntent: AppIntent {
    static let title: LocalizedStringResource = "Add an expense"
    static let description = IntentDescription("Opens MONO ready to record an expense.")
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult { AppRouter.shared.request(.addExpense); return .result() }
}
struct AddIncomeIntent: AppIntent {
    static let title: LocalizedStringResource = "Add income"
    static let description = IntentDescription("Opens MONO ready to record income.")
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult { AppRouter.shared.request(.addIncome); return .result() }
}
struct TransferIntent: AppIntent {
    static let title: LocalizedStringResource = "Transfer between accounts"
    static let description = IntentDescription("Opens MONO ready to move money between your accounts.")
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult { AppRouter.shared.request(.transfer); return .result() }
}
struct SafeToSpendIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Safe to spend"
    static let description = IntentDescription("Opens MONO on your safe-to-spend screen. Amounts stay on screen, behind Face ID if you use it.")
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult { AppRouter.shared.request(.safeToSpend); return .result() }
}

struct MONOShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddExpenseIntent(), phrases: ["Add an expense in \(.applicationName)", "Log spending in \(.applicationName)"],
                    shortTitle: "Add expense", systemImageName: "minus.circle")
        AppShortcut(intent: AddIncomeIntent(), phrases: ["Add income in \(.applicationName)"],
                    shortTitle: "Add income", systemImageName: "plus.circle")
        AppShortcut(intent: TransferIntent(), phrases: ["Transfer money in \(.applicationName)"],
                    shortTitle: "Transfer", systemImageName: "arrow.left.arrow.right")
        AppShortcut(intent: SafeToSpendIntent(), phrases: ["Open safe to spend in \(.applicationName)"],
                    shortTitle: "Safe to spend", systemImageName: "shield.lefthalf.filled")
    }
}
