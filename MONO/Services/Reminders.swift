import Foundation
import SwiftData
import UserNotifications

/// Local notifications only: nothing leaves the phone and no push entitlement is needed.
enum Reminders {
    static let enabledKey = "remindersEnabled"
    static let maxPlanned = 15   // iOS keeps at most 64 pending requests; planned expenses use two each, subscriptions up to two occurrences each
    static let maxSubscriptions = 12
    static let hourKey = "reminderHour"

    /// The time of day reminders arrive (default 9:00). You can change it in Settings.
    static var hour: Int { let h = UserDefaults.standard.object(forKey: hourKey) as? Int ?? 9; return min(max(h, 0), 23) }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func isAuthorized() async -> Bool {
        let s = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return s == .authorized || s == .provisional
    }

    // MARK: Planned expenses

    struct Pending: Equatable {
        let id: String
        let title: String
        let body: String
        let fire: DateComponents
    }

    /// One reminder the morning before and one on the day, for unpaid expenses that haven't passed.
    static func plannedReminders(_ planned: [PlannedExpense], now: Date = .now, hour: Int? = nil,
                                 calendar: Calendar = .current) -> [Pending] {
        let hour = hour ?? Self.hour
        let today = calendar.startOfDay(for: now)
        var out: [Pending] = []
        for p in planned.filter({ !$0.isPaid && calendar.startOfDay(for: $0.dueDate) >= today })
            .sorted(by: { $0.dueDate < $1.dueDate }).prefix(maxPlanned) {
            let due = calendar.startOfDay(for: p.dueDate)
            let amount = Money.format(p.amountCents)
            func comps(_ d: Date) -> DateComponents {
                var c = calendar.dateComponents([.year, .month, .day], from: d); c.hour = hour; return c
            }
            if let eve = calendar.date(byAdding: .day, value: -1, to: due), let fire = calendar.date(from: comps(eve)), fire > now {
                out.append(.init(id: "planned-\(p.id.uuidString)-eve", title: p.title.isEmpty ? "Planned expense" : p.title,
                                 body: "\(amount) is due tomorrow.", fire: comps(eve)))
            }
            if let fire = calendar.date(from: comps(due)), fire > now {
                out.append(.init(id: "planned-\(p.id.uuidString)-due", title: p.title.isEmpty ? "Planned expense" : p.title,
                                 body: "\(amount) is due today.", fire: comps(due)))
            }
        }
        return out
    }

    /// Reminders for subscriptions and bills: the next two payments of each active one, `remindDaysBefore` days ahead at the chosen time.
    /// Text follows Hide amounts. Nothing here records or deducts anything.
    static func subscriptionReminders(_ rules: [RecurringRule], now: Date = .now, hour: Int? = nil, defaultCurrency: (RecurringRule) -> Currency = { _ in Money.reporting },
                                      calendar: Calendar = .current) -> [Pending] {
        let hour = hour ?? Self.hour
        var out: [Pending] = []
        for r in rules.filter({ $0.status == .active && $0.kind == .expense }).sorted(by: { $0.dueDate < $1.dueDate }).prefix(maxSubscriptions) {
            var due = calendar.startOfDay(for: r.dueDate)
            var scheduled = 0, guardCount = 0
            while scheduled < 2 && guardCount < 6 {
                guardCount += 1
                let lead = max(r.remindDaysBefore, 0)
                if let day = calendar.date(byAdding: .day, value: -lead, to: due) {
                    var comps = calendar.dateComponents([.year, .month, .day], from: day); comps.hour = hour
                    if let fire = calendar.date(from: comps), fire > now {
                        let when = lead == 0 ? "is due today" : (lead == 1 ? "is due tomorrow" : "is due in \(lead) days")
                        out.append(Pending(id: "sub-\(r.id.uuidString)-\(calendar.component(.year, from: due))\(calendar.component(.month, from: due))\(calendar.component(.day, from: due))",
                                           title: r.title.isEmpty ? "Payment due" : r.title,
                                           body: "\(Money.format(r.amountCents, currency: defaultCurrency(r))) \(when). Open MONO to confirm it when you’ve paid.",
                                           fire: comps))
                        scheduled += 1
                    }
                }
                due = r.following(due, calendar: calendar)
            }
        }
        return out
    }

    /// Replaces every scheduled reminder so edits, payments and deletions are always reflected.
    static func syncPlanned(_ planned: [PlannedExpense], subscriptions: [RecurringRule] = [], accounts: [Account] = []) async {
        let center = UNUserNotificationCenter.current()
        let existing = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("planned-") || $0.hasPrefix("sub-") }
        center.removePendingNotificationRequests(withIdentifiers: existing)
        guard isEnabled, await isAuthorized() else { return }
        let byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let defaultID = AccountEngine.defaultAccount(accounts)?.id
        let all = plannedReminders(planned) + subscriptionReminders(subscriptions) { rule in
            (rule.accountID ?? defaultID).flatMap { byID[$0] }?.currency ?? Money.reporting
        }
        for r in all {
            let content = UNMutableNotificationContent()
            content.title = r.title; content.body = r.body; content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: r.fire, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: r.id, content: content, trigger: trigger))
        }
    }

    static func cancelAll() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
    }

    // MARK: Budget alerts

    /// 0 = fine, 1 = 80% used, 2 = over budget.
    static func budgetLevel(fraction: Double?) -> Int {
        guard let f = fraction else { return 0 }
        return f > 1 ? 2 : f >= 0.8 ? 1 : 0
    }

    static func levelKey(_ month: MonthKey) -> String { "budgetAlertLevel-\(month.string)" }

    /// Marks the current state as already known, so turning reminders on doesn't announce an old overspend.
    static func acknowledgeBudget(_ s: BudgetSummary) {
        UserDefaults.standard.set(budgetLevel(fraction: s.fraction), forKey: levelKey(s.month))
    }

    /// Fires one alert when spending crosses 80% or 100% of the month's budget, never twice for the same level.
    /// If spending falls back below a level (a transaction was deleted), that level can alert again later.
    static func checkBudget(_ s: BudgetSummary, defaults: UserDefaults = .standard) -> String? {
        guard s.total != nil else { return nil }
        let level = budgetLevel(fraction: s.fraction)
        let key = levelKey(s.month)
        let known = defaults.integer(forKey: key)
        defaults.set(level, forKey: key)
        guard level > known else { return nil }
        if level == 2 { return "You’re \(Money.format(s.overBy)) over your \(s.month.shortTitle()) budget." }
        let pct = Int(((s.fraction ?? 0) * 100).rounded())
        return "\(pct)% of your \(s.month.shortTitle()) budget is used"
            + (s.dailyAllowance.map { ". About \(Money.format($0)) a day keeps you within it." } ?? ".")
    }

    static func post(budgetMessage: String) async {
        guard isEnabled, await isAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Budget"; content.body = budgetMessage; content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "budget-\(UUID().uuidString)",
                                                                              content: content, trigger: trigger))
    }
}

/// Lets alerts appear as banners even while MONO is open.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }
}
