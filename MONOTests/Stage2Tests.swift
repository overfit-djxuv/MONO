import XCTest
import SwiftData
@testable import MONO

// MARK: - Savings planner: frequencies, start date, monthly equivalent, estimate

final class PlannerStage2Tests: XCTestCase {
    private let today = date(2026, 3, 4)   // a Wednesday
    private func sched(_ f: ContributionFrequency, through: Date?, anchor: Date?, day: Int = 5, limit: Int = 600) -> [Date] {
        SavingsPlanner.schedule(after: today, through: through, frequency: f, day: day, anchor: anchor, limit: limit, calendar: utc)
    }
    private func days(_ ds: [Date]) -> [Int] { ds.map { utc.component(.day, from: $0) } }

    func testWeeklyKeepsTheRhythmOfTheStartDate() {
        XCTAssertEqual(days(sched(.weekly, through: date(2026, 3, 29), anchor: date(2026, 3, 1))), [8, 15, 22, 29])
    }
    func testFortnightlyIsEveryOtherWeek() {
        XCTAssertEqual(days(sched(.biweekly, through: date(2026, 4, 1), anchor: date(2026, 3, 1))), [15, 29])
    }
    func testNothingIsScheduledBeforeAFutureStartDate() {
        XCTAssertEqual(sched(.weekly, through: date(2026, 4, 30), anchor: date(2026, 3, 20)).first, utc.startOfDay(for: date(2026, 3, 20)))
        let monthly = sched(.monthly, through: date(2026, 7, 31), anchor: date(2026, 4, 10))
        XCTAssertEqual(monthly.map { utc.component(.month, from: $0) }, [5, 6, 7], "April 5 is before the April 10 start, so May is first")
    }
    func testMonthlyBehaviourIsUnchanged() {
        let old = SavingsPlanner.contributionDates(after: today, through: date(2026, 6, 30), day: 5, calendar: utc)
        XCTAssertEqual(sched(.monthly, through: date(2026, 6, 30), anchor: nil), old)
        XCTAssertEqual(sched(.monthly, through: date(2026, 6, 30), anchor: date(2026, 1, 1)), old, "a past start date changes nothing")
    }
    func testAnUnboundedScheduleStopsAtTheLimit() {
        XCTAssertEqual(sched(.weekly, through: nil, anchor: date(2026, 3, 1), limit: 5).count, 5)
    }

    private func input(remaining: Int, planned: Int, f: ContributionFrequency = .monthly, deadline: Date? = nil, recent: Int = 0) -> PlanInput {
        PlanInput(target: remaining, saved: 0, plannedMonthly: planned, deadline: deadline, contributionDay: 5,
                  frequency: f, anchor: date(2026, 3, 1), recentNet90Days: recent)
    }
    func testEstimatedCompletionAtThePlan() {
        let p = SavingsPlanner.plan(input(remaining: 100_000, planned: 30_000), today: date(2026, 3, 10), calendar: utc)
        XCTAssertEqual(p.estimateBasis, .plan)
        XCTAssertEqual(p.estimatedCompletion.map { [utc.component(.month, from: $0), utc.component(.day, from: $0)] }, [7, 5], "4 payments: Apr, May, Jun, Jul 5")
        let weekly = SavingsPlanner.plan(input(remaining: 25_000, planned: 10_000, f: .weekly), today: today, calendar: utc)
        XCTAssertEqual(weekly.estimatedCompletion.map { utc.component(.day, from: $0) }, 22, "3 weekly payments: Mar 8, 15, 22")
    }
    func testEstimateFallsBackToTheRecentPaceAndSaysSo() {
        let p = SavingsPlanner.plan(input(remaining: 45_000, planned: 0, recent: 30_000), today: today, calendar: utc)
        XCTAssertEqual(p.estimateBasis, .actualPace)   // 30,000 over 90 days = 10,000 a month → 5 months
        XCTAssertEqual(p.estimatedCompletion.map { utc.component(.month, from: $0) }, 8)
    }
    func testNoPlanAndNoPaceMeansNoEstimateRatherThanAGuess() {
        let p = SavingsPlanner.plan(input(remaining: 45_000, planned: 0), today: today, calendar: utc)
        XCTAssertNil(p.estimatedCompletion); XCTAssertEqual(p.estimateBasis, .none)
        let funded = SavingsPlanner.plan(PlanInput(target: 100, saved: 100, plannedMonthly: 10, deadline: nil, contributionDay: 5), today: today, calendar: utc)
        XCTAssertNil(funded.estimatedCompletion)
    }
    func testMonthlyEquivalentIsRemainingOverWholeMonthsLeft() {
        let six = SavingsPlanner.plan(input(remaining: 120_000, planned: 0, deadline: date(2026, 9, 4)), today: today, calendar: utc)
        XCTAssertEqual(six.requiredMonthlyEquivalent, 20_000)
        let extraDays = SavingsPlanner.plan(input(remaining: 120_000, planned: 0, deadline: date(2026, 9, 10)), today: today, calendar: utc)
        XCTAssertEqual(extraDays.requiredMonthlyEquivalent, 20_000, "a few extra days don't shrink the figure")
        let soon = SavingsPlanner.plan(input(remaining: 50_000, planned: 0, deadline: date(2026, 3, 20)), today: today, calendar: utc)
        XCTAssertEqual(soon.requiredMonthlyEquivalent, 50_000, "under a month counts as one month")
        let funded = SavingsPlanner.plan(PlanInput(target: 100, saved: 100, plannedMonthly: 0, deadline: date(2026, 9, 4), contributionDay: 5), today: today, calendar: utc)
        XCTAssertNil(funded.requiredMonthlyEquivalent)
    }
    func testRequiredPerContributionFollowsTheFrequency() {
        let p = SavingsPlanner.plan(input(remaining: 40_000, planned: 0, f: .weekly, deadline: date(2026, 3, 29)), today: today, calendar: utc)
        XCTAssertEqual(p.contributionsRemaining, 4); XCTAssertEqual(p.requiredMonthly, 10_000, "per weekly contribution")
    }
    func testGoalDefaultsKeepExistingGoalsWorking() {
        let g = SavingsGoal(name: "Old goal", kind: .general, symbol: "target")
        XCTAssertEqual(g.priority, .medium); XCTAssertEqual(g.frequency, .monthly); XCTAssertEqual(g.currencyCode, ""); XCTAssertEqual(g.details, "")
        XCTAssertEqual(g.currency, Money.reporting); XCTAssertEqual(g.scheduleStart, g.createdAt)
    }
}

// MARK: - Goal movements in other currencies

@MainActor
final class GoalCurrencyTests: XCTestCase {
    func testAccountDeltaFollowsTheAccountAmountWhenCurrenciesDiffer() {
        let same = GoalEntry(goalID: UUID(), amountCents: 1_000, date: .now)
        XCTAssertEqual(same.accountDelta, 1_000)
        let into = GoalEntry(goalID: UUID(), amountCents: 100_000, date: .now); into.accountAmountCents = 3_000   // ¥1,000 for RM 30.00
        XCTAssertEqual(into.accountDelta, 3_000)
        let out = GoalEntry(goalID: UUID(), amountCents: -100_000, date: .now); out.accountAmountCents = 3_000
        XCTAssertEqual(out.accountDelta, -3_000, "a withdrawal returns money to the account")
    }
    func testTheAccountLosesWhatItPaidNotWhatTheGoalReceived() {
        let main = Account(name: "Main", kind: .bank, currencyCode: "MYR", openingCents: 100_000, sortOrder: 0)
        let e = GoalEntry(goalID: UUID(), amountCents: 100_000, date: .now); e.accountID = main.id; e.accountAmountCents = 3_000
        let o = AccountEngine.overview(accounts: [main], transactions: [], entries: [e], converter: CurrencyConverter(reporting: myrC, rates: []))
        XCTAssertEqual(o.balances[main.id], 97_000)
    }
    private var myrC: Currency { Currency.find("MYR") }

    func testSavedTotalConvertsEachGoalWithYourRateAndNamesAnyWithout() {
        let yen = SavingsGoal(name: "Japan fund", kind: .general, symbol: "target"); yen.currencyCode = "JPY"
        let eur = SavingsGoal(name: "Paris", kind: .general, symbol: "target"); eur.currencyCode = "EUR"
        let local = SavingsGoal(name: "Laptop", kind: .general, symbol: "target")
        let entries = [GoalEntry(goalID: yen.id, amountCents: 100_000, date: .now),   // ¥100,000
                       GoalEntry(goalID: eur.id, amountCents: 5_000, date: .now),
                       GoalEntry(goalID: local.id, amountCents: 20_000, date: .now)]
        let books = Books(accounts: [], rates: [ExchangeRate(fromCode: "JPY", toCode: "MYR", rateMicros: 29_500)], transactions: [], entries: [])
        let saved = books.savedTotal(goals: [yen, eur, local], entries: entries)
        XCTAssertEqual(saved.total, 295_000 + 20_000, "¥100,000 × 0.0295 = RM 2,950.00, plus the ringgit goal")
        XCTAssertEqual(saved.unconverted, ["Paris"])
        XCTAssertEqual(books.reportableEntries(goals: [yen, eur, local], entries: entries).count, 2, "the euro goal's entry is skipped, not guessed")
    }
    func testGoalAmountsUseTheGoalsOwnCurrency() {
        let yen = SavingsGoal(name: "Japan", kind: .general, symbol: "target"); yen.currencyCode = "JPY"
        XCTAssertEqual(yen.money(150_000), "¥ 150,000")
        XCTAssertEqual(SavingsGoal(name: "L", kind: .general, symbol: "target").money(150_000), Money.format(150_000))
    }
}

// MARK: - Safe to spend

final class SafeToSpendTests: XCTestCase {
    private let now = date(2026, 3, 10)   // 22 days left in March including today
    private let acct = SafeToSpend.AccountMoney(id: UUID(), name: "Main", reportingCents: 200_000)
    private func bill(_ cents: Int, due: Int = 20, cat: String = "Bills", title: String = "Bill") -> SafeToSpend.Commitment {
        .init(title: title, amountCents: cents, dueDate: date(2026, 3, due), category: cat, source: .planned)
    }
    private func calc(_ cfg: SafeToSpend.Config = .init(), accounts: [SafeToSpend.AccountMoney]? = nil, bills: [SafeToSpend.Commitment] = [],
                      goals: [SafeToSpend.GoalPlan] = [], essentials: [SafeToSpend.EssentialBudget] = [], reserved: [(name: String, cents: Int)] = []) -> SafeToSpend.Result {
        SafeToSpend.calculate(now: now, config: cfg, accounts: accounts ?? [acct], commitments: bills, goals: goals, essentials: essentials, reserved: reserved, calendar: utc)
    }

    func testTheExampleFromTheBrief() {
        // Balance 2,000, bills 300, planned savings 400, essentials 500 → 800 to spend.
        let r = calc(bills: [bill(30_000)],
                     goals: [.init(name: "Trip", plannedPerContribution: 40_000, remaining: 100_000, dates: [date(2026, 3, 25)])],
                     essentials: [.init(category: "Groceries", limit: 90_000, spent: 40_000)])
        XCTAssertEqual(r.accountMoney, 200_000); XCTAssertEqual(r.billsTotal, 30_000)
        XCTAssertEqual(r.savingsTotal, 40_000); XCTAssertEqual(r.essentialsTotal, 50_000)
        XCTAssertEqual(r.flexible, 80_000)
    }
    func testNothingCommittedMeansEverythingIsFlexible() {
        let r = calc(); XCTAssertEqual(r.flexible, 200_000); XCTAssertEqual(r.perDay, 200_000 / r.horizonDays)
    }
    func testHorizonDefaultsToEndOfMonthAndCountsDaysInclusively() {
        let r = calc(); XCTAssertEqual(utc.component(.day, from: r.horizonEnd), 31); XCTAssertEqual(r.horizonDays, 22)
        let week = calc(.init(horizon: .days(7))); XCTAssertEqual(week.horizonDays, 7); XCTAssertEqual(utc.component(.day, from: week.horizonEnd), 16)
    }
    func testBillsAfterTheHorizonAreIgnoredAndOverdueBillsStillCount() {
        let r = calc(.init(horizon: .days(7)), bills: [bill(10_000, due: 14), bill(99_000, due: 28), bill(5_000, due: 2, title: "Late")])
        XCTAssertEqual(r.billsTotal, 15_000)
        XCTAssertTrue(r.bills.contains { $0.detail.hasPrefix("Overdue") })
    }
    func testSavingsCountOnlyContributionsStillToComeAndNeverMoreThanTheGoalNeeds() {
        let dates = [date(2026, 3, 5), date(2026, 3, 15), date(2026, 3, 25), date(2026, 4, 5)]   // first is past, last is beyond March
        let r = calc(goals: [.init(name: "Trip", plannedPerContribution: 40_000, remaining: 1_000_000, dates: dates)])
        XCTAssertEqual(r.savingsTotal, 80_000, "only Mar 15 and Mar 25")
        let capped = calc(goals: [.init(name: "Almost", plannedPerContribution: 40_000, remaining: 50_000, dates: [date(2026, 3, 15), date(2026, 3, 25)])])
        XCTAssertEqual(capped.savingsTotal, 50_000)
        let done = calc(goals: [.init(name: "Done", plannedPerContribution: 40_000, remaining: 0, dates: [date(2026, 3, 15)])])
        XCTAssertEqual(done.savingsTotal, 0)
    }
    func testABillIsNotHeldBackTwiceWhenItsCategoryIsAlsoEssential() {
        let r = calc(bills: [bill(20_000, cat: "Bills")], essentials: [.init(category: "Bills", limit: 60_000, spent: 10_000)])
        XCTAssertEqual(r.billsTotal, 20_000)
        XCTAssertEqual(r.essentialsTotal, 30_000, "50,000 budget left − the 20,000 bill already counted")
        XCTAssertEqual(r.flexible, 200_000 - 20_000 - 30_000)
        let covered = calc(bills: [bill(80_000, cat: "Bills")], essentials: [.init(category: "Bills", limit: 60_000, spent: 10_000)])
        XCTAssertEqual(covered.essentialsTotal, 0, "never negative")
    }
    func testEssentialsAreScaledToAShorterHorizon() {
        // 22 days left in the month; a 11-day horizon holds back half of what's left.
        let r = calc(.init(horizon: .days(11)), essentials: [.init(category: "Groceries", limit: 100_000, spent: 0)])
        XCTAssertEqual(r.essentialsTotal, 50_000)
    }
    func testReservedFundsAreSubtractedAndOverspentEssentialsCountAsZero() {
        let r = calc(essentials: [.init(category: "Food", limit: 10_000, spent: 25_000)], reserved: [("Emergency", 50_000), ("Gift", 0)])
        XCTAssertEqual(r.reservedTotal, 50_000); XCTAssertEqual(r.essentialsTotal, 0); XCTAssertEqual(r.reserved.count, 1)
    }
    func testEachCommitmentCanBeSwitchedOff() {
        let args: (bills: [SafeToSpend.Commitment], goals: [SafeToSpend.GoalPlan], ess: [SafeToSpend.EssentialBudget], res: [(name: String, cents: Int)]) =
            ([bill(30_000)], [.init(name: "T", plannedPerContribution: 40_000, remaining: 90_000, dates: [date(2026, 3, 25)])],
             [.init(category: "G", limit: 90_000, spent: 40_000)], [("R", 10_000)])
        func run(_ c: SafeToSpend.Config) -> Int { calc(c, bills: args.bills, goals: args.goals, essentials: args.ess, reserved: args.res).flexible }
        XCTAssertEqual(run(.init()), 200_000 - 30_000 - 40_000 - 50_000 - 10_000)
        var c = SafeToSpend.Config(); c.includeBills = false; XCTAssertEqual(run(c), 200_000 - 40_000 - 50_000 - 10_000)
        c = .init(); c.includeSavings = false; XCTAssertEqual(run(c), 200_000 - 30_000 - 50_000 - 10_000)
        c = .init(); c.includeEssentials = false; XCTAssertEqual(run(c), 200_000 - 30_000 - 40_000 - 10_000)
        c = .init(); c.includeReserved = false; XCTAssertEqual(run(c), 200_000 - 30_000 - 40_000 - 50_000)
        c.includeBills = false; c.includeSavings = false; c.includeEssentials = false; XCTAssertEqual(run(c), 200_000)
    }
    func testExcludedAndUnconvertedAccounts() {
        let savings = SafeToSpend.AccountMoney(id: UUID(), name: "Savings", reportingCents: 500_000)
        let euro = SafeToSpend.AccountMoney(id: UUID(), name: "Euro", reportingCents: nil)
        var cfg = SafeToSpend.Config(); cfg.excludedAccountIDs = [savings.id]
        let r = calc(cfg, accounts: [acct, savings, euro])
        XCTAssertEqual(r.accountMoney, 200_000, "savings excluded by choice, euro excluded because it has no rate")
        XCTAssertEqual(r.unconvertedAccounts, ["Euro"])
    }
    func testAShortfallIsReportedNotHidden() {
        let r = calc(bills: [bill(250_000)])
        XCTAssertEqual(r.flexible, -50_000); XCTAssertTrue(r.isShortfall); XCTAssertNil(r.perDay)
    }
    func testConfigSurvivesSavingAndLoading() {
        let d = UserDefaults(suiteName: "mono-sts-\(UUID().uuidString)")!
        var c = SafeToSpend.Config(); c.horizon = .days(14); c.includeReserved = false; c.excludedAccountIDs = [UUID()]
        c.save(d)
        XCTAssertEqual(SafeToSpend.Config.load(d), c)
        XCTAssertEqual(SafeToSpend.Config.load(UserDefaults(suiteName: "mono-sts-\(UUID().uuidString)")!), SafeToSpend.Config())
    }
}

@MainActor
final class SafeToSpendAssemblyTests: XCTestCase {
    func testBuildsFromStoredDataWithoutDoubleCounting() throws {
        let (_, ctx) = try makeContext()
        let now = date(2026, 3, 10)
        let main = Account(name: "Main", kind: .bank, currencyCode: "MYR", openingCents: 500_000, sortOrder: 0); ctx.insert(main)
        let paid = PlannedExpense(title: "Paid already", amountCents: 70_000, dueDate: date(2026, 3, 12), category: "Bills"); paid.isPaid = true
        let due = PlannedExpense(title: "Insurance", amountCents: 30_000, dueDate: date(2026, 3, 20), category: "Bills")
        let rule = RecurringRule(title: "Gym", amountCents: 8_000, kind: .expense, category: "Health", dayOfMonth: 25, nextMonthKey: "2026-03")
        let posted = RecurringRule(title: "Posted", amountCents: 9_000, kind: .expense, category: "Health", dayOfMonth: 3, nextMonthKey: "2026-04")
        let salary = RecurringRule(title: "Salary", amountCents: 400_000, kind: .income, category: "Salary", dayOfMonth: 28, nextMonthKey: "2026-03")
        let goal = SavingsGoal(name: "Laptop", kind: .general, symbol: "laptopcomputer"); goal.targetCents = 100_000; goal.plannedMonthlyCents = 20_000
        goal.contributionDay = 15; goal.deadline = date(2026, 9, 1); goal.startDate = date(2026, 1, 1)
        let done = SavingsGoal(name: "Funded", kind: .general, symbol: "target"); done.targetCents = 1_000; done.plannedMonthlyCents = 500
        ctx.insert(goal); ctx.insert(done)
        ctx.insert(GoalEntry(goalID: done.id, amountCents: 1_000, date: date(2026, 1, 1), affectsCash: false))
        let fund = ReservedFund(name: "Buffer", amountCents: 100_000)
        let groceries = MoneyCategory(name: "Groceries", symbol: "cart", kind: .expense); groceries.isEssential = true
        let limit = BudgetLimit(monthKey: "2026-03", category: "Groceries", limitCents: 60_000)
        let spent = TransactionRecord(amountCents: 15_000, kind: .expense, category: "Groceries", date: date(2026, 3, 3), title: "", accountID: main.id)
        ctx.insert(spent)
        let books = Books(accounts: [main], rates: [], transactions: [spent], entries: [])
        var cfg = SafeToSpend.Config(); cfg.horizon = .endOfMonth
        let r = SafeToSpend.make(now: now, config: cfg, books: books, planned: [paid, due], rules: [rule, posted, salary], goals: [goal, done],
                                 costs: [], entries: [], categories: [groceries], limits: [limit], monthBudgets: [], reserved: [fund], calendar: utc)
        XCTAssertEqual(r.accountMoney, 485_000, "opening 5,000 − the 150 already spent")
        XCTAssertEqual(r.billsTotal, 30_000 + 8_000, "the paid bill, the already-posted rule and the income rule are all excluded")
        XCTAssertEqual(r.savingsTotal, 20_000, "one contribution on Mar 15; the funded goal adds nothing")
        XCTAssertEqual(r.essentialsTotal, 45_000, "Groceries: 600 limit − 150 spent")
        XCTAssertEqual(r.reservedTotal, 100_000)
        XCTAssertEqual(r.flexible, 485_000 - 38_000 - 20_000 - 45_000 - 100_000)
    }
}

// MARK: - Backup format 3

@MainActor
final class BackupV3Tests: XCTestCase {
    func testGoalFieldsEssentialFlagReservedFundsAndForeignContributionsRoundTrip() throws {
        let (_, src) = try makeContext()
        let goal = SavingsGoal(name: "Japan", kind: .general, symbol: "target")
        goal.targetCents = 500_000; goal.details = "Spring trip"; goal.priority = .high; goal.currencyCode = "JPY"
        goal.frequency = .weekly; goal.startDate = date(2026, 3, 1)
        src.insert(goal)
        let e = GoalEntry(goalID: goal.id, amountCents: 100_000, date: date(2026, 3, 2)); e.accountAmountCents = 3_000; src.insert(e)
        let c = MoneyCategory(name: "Rent", symbol: "house", kind: .expense, sortOrder: 1); c.isEssential = true; src.insert(c)
        src.insert(ReservedFund(name: "Buffer", amountCents: 100_000, isActive: false))
        try src.save()
        let file = try BackupService.decode(try BackupService.encode(try BackupService.snapshot(context: src, openingBalanceCents: 0, currencySymbol: "RM")))
        XCTAssertEqual(file.version, 3)
        let (_, dst) = try makeContext()
        try BackupService.replaceAll(with: file, in: dst)
        let g = try XCTUnwrap(try dst.fetch(FetchDescriptor<SavingsGoal>()).first)
        XCTAssertEqual(g.details, "Spring trip"); XCTAssertEqual(g.priority, .high); XCTAssertEqual(g.currencyCode, "JPY")
        XCTAssertEqual(g.frequency, .weekly); XCTAssertEqual(g.startDate, date(2026, 3, 1))
        XCTAssertEqual(try dst.fetch(FetchDescriptor<GoalEntry>()).first?.accountAmountCents, 3_000)
        XCTAssertTrue(try dst.fetch(FetchDescriptor<MoneyCategory>()).first { $0.name == "Rent" }?.isEssential ?? false)
        let fund = try XCTUnwrap(try dst.fetch(FetchDescriptor<ReservedFund>()).first)
        XCTAssertEqual(fund.amountCents, 100_000); XCTAssertFalse(fund.isActive)
        try? FileManager.default.removeItem(at: AccountMigration.safetyDirectory)
    }
    func testAFormat2BackupStillRestoresWithSensibleDefaults() throws {
        var f = BackupFile(); f.version = 2
        let id = UUID()
        f.goals = [.init(id: id, name: "Old", kind: "general", symbol: "target", targetCents: 1_000, deadline: nil, destination: "",
                         bufferCents: 0, plannedMonthlyCents: 100, contributionDay: 3, createdAt: date(2026, 1, 1))]
        let data = try BackupService.encode(f)
        let (_, ctx) = try makeContext()
        try BackupService.replaceAll(with: try BackupService.decode(data), in: ctx)
        let g = try XCTUnwrap(try ctx.fetch(FetchDescriptor<SavingsGoal>()).first)
        XCTAssertEqual(g.priority, .medium); XCTAssertEqual(g.frequency, .monthly); XCTAssertEqual(g.currencyCode, ""); XCTAssertNil(g.startDate)
        try? FileManager.default.removeItem(at: AccountMigration.safetyDirectory)
    }
    func testValidationRejectsBadGoalFields() throws {
        func goal(_ tweak: (inout BackupFile.GoalDTO) -> Void) -> BackupFile {
            var g = BackupFile.GoalDTO(id: UUID(), name: "G", kind: "general", symbol: "x", targetCents: 1, deadline: nil, destination: "",
                                       bufferCents: 0, plannedMonthlyCents: 0, contributionDay: 1, createdAt: .now)
            tweak(&g); var f = BackupFile(); f.goals = [g]; return f
        }
        XCTAssertNoThrow(try BackupService.validate(goal { _ in }))
        XCTAssertThrowsError(try BackupService.validate(goal { $0.currencyCode = "YENS" }))
        XCTAssertThrowsError(try BackupService.validate(goal { $0.priority = 9 }))
        XCTAssertThrowsError(try BackupService.validate(goal { $0.frequency = "daily" }))
    }
}

@MainActor
final class EssentialSeedingTests: XCTestCase {
    func testMarksOnlyTheUsualDefaultsOnceAndLeavesYourCategoriesAlone() throws {
        let (_, ctx) = try makeContext()
        let d = UserDefaults(suiteName: "mono-ess-\(UUID().uuidString)")!
        let groceries = MoneyCategory(name: "Groceries", symbol: "cart", kind: .expense, isDefault: true)
        let fun = MoneyCategory(name: "Entertainment", symbol: "film", kind: .expense, isDefault: true)
        let mine = MoneyCategory(name: "Bills", symbol: "doc", kind: .expense, isDefault: false)   // same name, but yours
        let salary = MoneyCategory(name: "Salary", symbol: "banknote", kind: .income, isDefault: true)
        [groceries, fun, mine, salary].forEach(ctx.insert); try ctx.save()
        DefaultCategories.seedEssentialsIfNeeded(ctx, defaults: d)
        XCTAssertTrue(groceries.isEssential); XCTAssertFalse(fun.isEssential); XCTAssertFalse(mine.isEssential); XCTAssertFalse(salary.isEssential)
        groceries.isEssential = false   // the user turns it off
        DefaultCategories.seedEssentialsIfNeeded(ctx, defaults: d)
        XCTAssertFalse(groceries.isEssential, "seeding runs once and never overrides a choice")
    }
    func testWaitsUntilCategoriesExist() throws {
        let (_, ctx) = try makeContext()
        let d = UserDefaults(suiteName: "mono-ess-\(UUID().uuidString)")!
        DefaultCategories.seedEssentialsIfNeeded(ctx, defaults: d)
        XCTAssertFalse(d.bool(forKey: DefaultCategories.essentialSeededKey), "nothing to mark yet, so it will try again later")
    }
}

final class HideAmountsTests: XCTestCase {
    override func tearDown() { PrivacyStore.shared.setHidden(false) }

    func testMoneyIsMaskedButTheSymbolAndSignRemain() {
        PrivacyStore.shared.setHidden(true)
        XCTAssertEqual(Money.format(123_456), "RM ••••")
        XCTAssertEqual(Money.format(-500), "−RM ••••")
        XCTAssertEqual(Money.format(500, signed: true), "+RM ••••", "income still reads as income")
        XCTAssertEqual(Money.format(500, signed: false), "RM ••••")
        XCTAssertEqual(Money.format(100_000, currency: Currency.find("JPY")), "¥ ••••")
        XCTAssertEqual(Money.formatWhole(123_456), "RM ••••"); XCTAssertEqual(Money.compact(5_000), "•••")
        XCTAssertFalse(Money.format(987_654_321).contains("9"), "no digit of the real amount leaks")
    }
    func testNumbersComeBackWhenShown() {
        PrivacyStore.shared.setHidden(true); PrivacyStore.shared.setHidden(false)
        XCTAssertEqual(Money.format(123_456), "RM 1,234.56")
    }
    func testHidingDoesNotChangeAnyCalculation() {
        let tx = [TransactionRecord(amountCents: 5_000, kind: .income, category: "Salary", date: date(2026, 3, 1), title: ""),
                  TransactionRecord(amountCents: 1_200, kind: .expense, category: "Food", date: date(2026, 3, 2), title: "")]
        let before = FinanceEngine.totals(tx, in: MonthKey(year: 2026, month: 3), calendar: utc)
        PrivacyStore.shared.setHidden(true)
        let after = FinanceEngine.totals(tx, in: MonthKey(year: 2026, month: 3), calendar: utc)
        XCTAssertEqual(before.income, after.income); XCTAssertEqual(before.expense, after.expense)
        XCTAssertEqual(Money.parse("12.50"), 1_250, "typing amounts still works while hidden")
        XCTAssertEqual(Money.editable(1_250), "12.50", "and editing shows the real number in the field you are typing in")
    }
    func testRememberedAcrossLaunchesUnlessHideOnLaunchIsOn() {
        let name = "mono-priv-\(UUID().uuidString)"
        let a = PrivacyStore(defaults: UserDefaults(suiteName: name)!)
        a.setHidden(true)
        XCTAssertTrue(PrivacyStore(defaults: UserDefaults(suiteName: name)!).hidden, "remembers how you left it")
        a.setHidden(false); a.setHideOnLaunch(true)
        XCTAssertTrue(PrivacyStore(defaults: UserDefaults(suiteName: name)!).hidden, "hide-on-launch overrides")
        a.setHideOnLaunch(false)
        XCTAssertFalse(PrivacyStore(defaults: UserDefaults(suiteName: name)!).hidden)
    }
}
