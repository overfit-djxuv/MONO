#if DEBUG
import Foundation
import SwiftData

/// Debug-only sample data for simulator screenshots and UI tests (launch with `-MONODemo`).
/// Compiled out of Release builds, so the shipped app never contains invented records.
enum DemoData {
    static func loadIfRequested(_ context: ModelContext) {
        guard CommandLine.arguments.contains("-MONODemo") else { return }
        guard ((try? context.fetchCount(FetchDescriptor<TransactionRecord>())) ?? 0) == 0 else { return }
        let cal = Calendar.current
        let now = Date.now
        let thisMonth = MonthKey(now)
        UserDefaults.standard.set(1_250_000, forKey: "openingBalanceCents")

        func day(_ m: MonthKey, _ d: Int) -> Date {
            let dim = m.daysInMonth()
            var date = cal.date(from: DateComponents(year: m.year, month: m.month, day: min(d, dim), hour: 12)) ?? now
            if date > now { date = now.addingTimeInterval(-3600) }
            return date
        }
        let expenses: [(String, String, Int, Int)] = [
            ("Food", "Lunch with team", 1850, 3), ("Groceries", "Weekly groceries", 14230, 4), ("Transportation", "Grab to office", 2240, 6),
            ("Subscriptions", "Spotify", 1590, 7), ("Entertainment", "Cinema", 3800, 9), ("Education", "Swift course", 12900, 11),
            ("Food", "Dinner", 4250, 13), ("Groceries", "Fruit and veg", 6780, 15), ("Shopping", "Shirt", 8900, 18),
        ]
        for back in 0...3 {
            let m = thisMonth.adding(-back)
            context.insert(TransactionRecord(amountCents: 520_000, kind: .income, category: "Salary", date: day(m, 1), title: "Salary"))
            for (i, e) in expenses.enumerated() where !(back == 0 && e.3 > cal.component(.day, from: now)) {
                let scale = 1.0 + Double((i + back) % 3) * 0.12
                context.insert(TransactionRecord(amountCents: Int(Double(e.2) * scale), kind: .expense, category: e.0, date: day(m, e.3), title: e.1))
            }
        }
        context.insert(MonthBudget(monthKey: thisMonth.string, totalCents: 250_000))
        for (c, l) in [("Food", 60_000), ("Groceries", 45_000), ("Transportation", 30_000), ("Entertainment", 15_000), ("Shopping", 20_000)] {
            context.insert(BudgetLimit(monthKey: thisMonth.string, category: c, limitCents: l))
        }
        context.insert(PlannedExpense(title: "Car insurance", amountCents: 98_000,
                                      dueDate: cal.date(byAdding: .day, value: 12, to: now) ?? now, category: "Transportation"))
        context.insert(PlannedExpense(title: "Phone bill", amountCents: 8_900,
                                      dueDate: cal.date(byAdding: .day, value: 4, to: now) ?? now, category: "Bills"))

        let trip = SavingsGoal(name: "Tokyo", kind: .trip, symbol: "airplane")
        trip.destination = "Tokyo"
        trip.deadline = cal.date(byAdding: .month, value: 8, to: now)
        trip.plannedMonthlyCents = 60_000; trip.bufferCents = 50_000; trip.contributionDay = 5
        context.insert(trip)
        for (c, v) in [(TripCostCategory.flights, 220_000), (.accommodation, 260_000), (.food, 120_000), (.transportation, 40_000), (.activities, 60_000)] {
            context.insert(TripCost(goalID: trip.id, category: c, label: "", amountCents: v))
        }
        for back in 0...2 {
            context.insert(GoalEntry(goalID: trip.id, amountCents: 50_000, date: day(thisMonth.adding(-back), 5), note: "Monthly saving"))
        }
        let laptop = SavingsGoal(name: "New laptop", kind: .general, symbol: "laptopcomputer")
        laptop.targetCents = 600_000; laptop.deadline = cal.date(byAdding: .month, value: 10, to: now)
        laptop.plannedMonthlyCents = 50_000
        context.insert(laptop)
        context.insert(GoalEntry(goalID: laptop.id, amountCents: 100_000, date: day(thisMonth.adding(-1), 10), note: ""))

        let items: [(String, Int, Int, ListKind, Priority)] = [
            ("Eggs", 2, 1_200, .grocery, .high), ("Chicken breast", 1, 1_800, .grocery, .medium), ("Rice 5kg", 1, 2_600, .grocery, .low),
            ("Mechanical keyboard", 1, 45_000, .wishlist, .medium), ("Running shoes", 1, 32_000, .wishlist, .low),
        ]
        for it in items {
            context.insert(ShoppingItem(name: it.0, quantity: it.1, estimatedCents: it.2,
                                        category: it.3 == .grocery ? "Groceries" : "Shopping", priority: it.4, listKind: it.3))
        }
        try? context.save()
        if let main = (try? context.fetch(FetchDescriptor<Account>()))?.first { main.openingCents = 1_250_000; try? context.save() }
        if CommandLine.arguments.contains("-MONOMultiAccount") { addMultiAccount(context, now: now) }
    }

    /// Two more accounts (cash, and a dollar e-wallet with an explicit rate), a same-currency transfer, a cross-currency
    /// transfer, and a dollar expense, to exercise the multi-account screens.
    private static func addMultiAccount(_ context: ModelContext, now: Date) {
        _ = try? AccountMigration.run(in: context, snapshotFirst: false)
        guard let main = (try? context.fetch(FetchDescriptor<Account>()))?.first else { return }
        let cash = Account(name: "Cash", kind: .cash, currencyCode: "MYR", openingCents: 15_000, sortOrder: 1)
        let wallet = Account(name: "USD wallet", kind: .ewallet, currencyCode: "USD", openingCents: 20_000, sortOrder: 2)
        context.insert(cash); context.insert(wallet)
        context.insert(ExchangeRate(fromCode: "USD", toCode: "MYR", rateMicros: 4_472_500))
        _ = try? Ledger.createTransfer(from: main, to: cash, sentCents: 30_000, receivedCents: 30_000, date: now.addingTimeInterval(-86_400 * 2),
                                       title: "ATM withdrawal", in: context)
        _ = try? Ledger.createTransfer(from: main, to: wallet, sentCents: 44_725, receivedCents: 10_000, date: now.addingTimeInterval(-86_400),
                                       title: "Top up", in: context)
        context.insert(TransactionRecord(amountCents: 1_250, kind: .expense, category: "Food", date: now.addingTimeInterval(-3_600),
                                         title: "Flat white", accountID: wallet.id, merchant: "Blue Bottle", tags: "coffee,travel"))
        context.insert(TransactionRecord(amountCents: 850, kind: .expense, category: "Food", date: now.addingTimeInterval(-7_200),
                                         title: "Nasi lemak", accountID: cash.id, merchant: "Warung Ali", tags: "breakfast"))
        try? context.save()
    }
}
#endif
