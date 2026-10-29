import XCTest
import SwiftData
@testable import MONO

// MARK: - Schedules

final class SubscriptionScheduleTests: XCTestCase {
    private func adv(_ d: Date, _ u: RecurrenceUnit, _ n: Int = 1, day: Int) -> Date { SubscriptionSchedule.advance(d, unit: u, interval: n, anchorDay: day, calendar: utc) }
    private func ymd(_ d: Date) -> [Int] { [utc.component(.year, from: d), utc.component(.month, from: d), utc.component(.day, from: d)] }

    func testWeeklyAndFortnightly() {
        XCTAssertEqual(ymd(adv(date(2026, 3, 5), .week, day: 5)), [2026, 3, 12])
        XCTAssertEqual(ymd(adv(date(2026, 3, 5), .week, 2, day: 5)), [2026, 3, 19])
    }
    func testAMonthlyPaymentOnThe31stFollowsShortMonthsAndComesBack() {
        let jan = date(2026, 1, 31)
        let feb = adv(jan, .month, day: 31); XCTAssertEqual(ymd(feb), [2026, 2, 28], "clamped, not skipped")
        let mar = adv(feb, .month, day: 31); XCTAssertEqual(ymd(mar), [2026, 3, 31], "returns to the 31st")
        XCTAssertEqual(ymd(adv(date(2028, 1, 31), .month, day: 31)), [2028, 2, 29], "leap year")
    }
    func testMonthlyCrossesTheYearAndQuarterlyAndHalfYearly() {
        XCTAssertEqual(ymd(adv(date(2026, 12, 5), .month, day: 5)), [2027, 1, 5])
        XCTAssertEqual(ymd(adv(date(2026, 11, 15), .month, 3, day: 15)), [2027, 2, 15])
        XCTAssertEqual(ymd(adv(date(2026, 8, 1), .month, 6, day: 1)), [2027, 2, 1])
    }
    func testYearlyIncludingALeapDayBirthday() {
        XCTAssertEqual(ymd(adv(date(2026, 6, 10), .year, day: 10)), [2027, 6, 10])
        XCTAssertEqual(ymd(adv(date(2028, 2, 29), .year, day: 29)), [2029, 2, 28])
        XCTAssertEqual(ymd(adv(date(2029, 2, 28), .year, day: 29)), [2030, 2, 28])
        XCTAssertEqual(ymd(adv(date(2031, 2, 28), .year, 1, day: 29)), [2032, 2, 29], "back to the 29th in a leap year")
    }
    func testDueDatesIncludeOverdueOnesAndStopAtTheEnd() {
        let ds = SubscriptionSchedule.dueDates(from: date(2026, 1, 5), through: date(2026, 4, 5), unit: .month, interval: 1, anchorDay: 5, calendar: utc)
        XCTAssertEqual(ds.map { utc.component(.month, from: $0) }, [1, 2, 3, 4])
        XCTAssertTrue(SubscriptionSchedule.dueDates(from: date(2026, 6, 1), through: date(2026, 5, 1), unit: .month, interval: 1, anchorDay: 1, calendar: utc).isEmpty)
        let weekly = SubscriptionSchedule.dueDates(from: date(2026, 3, 2), through: date(2026, 3, 31), unit: .week, interval: 1, anchorDay: 2, calendar: utc)
        XCTAssertEqual(weekly.count, 5)
    }
    func testResumingLandsOnTheNextRhythmDateWithoutCatchUp() {
        let d = SubscriptionSchedule.firstOnOrAfter(date(2026, 3, 20), from: date(2026, 1, 5), unit: .month, interval: 1, anchorDay: 5, calendar: utc)
        XCTAssertEqual(ymd(d), [2026, 4, 5])
        XCTAssertEqual(ymd(SubscriptionSchedule.firstOnOrAfter(date(2026, 3, 5), from: date(2026, 3, 5), unit: .month, interval: 1, anchorDay: 5, calendar: utc)), [2026, 3, 5], "due today stays due today")
    }
    func testCostEstimates() {
        XCTAssertEqual(SubscriptionSchedule.monthlyCost(1_599, unit: .month, interval: 1), 1_599)
        XCTAssertEqual(SubscriptionSchedule.annualCost(1_599, unit: .month, interval: 1), 19_188)
        XCTAssertEqual(SubscriptionSchedule.annualCost(10_000, unit: .week, interval: 1), 520_000, "52 weeks")
        XCTAssertEqual(SubscriptionSchedule.monthlyCost(10_000, unit: .week, interval: 1), 43_333, "52 ÷ 12 payments a month")
        XCTAssertEqual(SubscriptionSchedule.monthlyCost(12_000, unit: .year, interval: 1), 1_000)
        XCTAssertEqual(SubscriptionSchedule.annualCost(30_000, unit: .month, interval: 3), 120_000)
        XCTAssertEqual(SubscriptionSchedule.monthlyCost(10_000, unit: .week, interval: 2), 21_667)
        XCTAssertEqual(SubscriptionSchedule.describe(unit: .month, interval: 1), "Monthly")
        XCTAssertEqual(SubscriptionSchedule.describe(unit: .week, interval: 3), "Every 3 weeks")
    }
}

// MARK: - Confirm to record

@MainActor
final class RecordPaymentTests: XCTestCase {
    var ctx: ModelContext!
    override func setUpWithError() throws { (_, ctx) = try makeContext() }

    private func rule(due: Date = date(2026, 3, 5), cents: Int = 1_599, unit: RecurrenceUnit = .month) -> RecurringRule {
        let r = RecurringRule(title: "Netflix", amountCents: cents, kind: .expense, category: "Subscriptions", dayOfMonth: 5, nextMonthKey: "2026-03")
        r.nextDueDate = due; r.unit = unit; ctx.insert(r); return r
    }
    private func all() throws -> [TransactionRecord] { try ctx.fetch(FetchDescriptor<TransactionRecord>()) }

    func testNothingIsRecordedOrDeductedUntilYouConfirm() throws {
        let r = rule()
        XCTAssertEqual(try all().count, 0)
        let main = Account(name: "Main", kind: .bank, currencyCode: "MYR", openingCents: 100_000, sortOrder: 0); ctx.insert(main)
        let o = AccountEngine.overview(accounts: [main], transactions: try all(), entries: [], converter: CurrencyConverter(reporting: Currency.find("MYR"), rates: []))
        XCTAssertEqual(o.total, 100_000, "a due schedule doesn't touch the balance")
        _ = r
    }
    func testConfirmingCreatesOneTransactionAndMovesToTheNextPayment() throws {
        let r = rule()
        let tx = try Ledger.recordPayment(of: r, paidOn: date(2026, 3, 6), existing: try all(), in: ctx, calendar: utc)
        XCTAssertEqual(tx.amountCents, 1_599); XCTAssertEqual(tx.kind, .expense); XCTAssertEqual(tx.category, "Subscriptions"); XCTAssertEqual(tx.title, "Netflix")
        XCTAssertEqual(tx.date, date(2026, 3, 6)); XCTAssertEqual(tx.occurrenceKey, "\(r.id.uuidString)|2026-03-05")
        XCTAssertEqual(utc.component(.month, from: r.dueDate), 4); XCTAssertEqual(r.nextMonthKey, "2026-04")
        XCTAssertEqual(try all().count, 1)
    }
    func testTheSameOccurrenceCanNeverBeRecordedTwice() throws {
        let r = rule()
        _ = try Ledger.recordPayment(of: r, existing: try all(), in: ctx, calendar: utc)
        r.nextDueDate = date(2026, 3, 5)   // pretend the schedule was rewound (an edit, or a restored older copy)
        XCTAssertThrowsError(try Ledger.recordPayment(of: r, existing: try all(), in: ctx, calendar: utc)) {
            XCTAssertEqual($0 as? Ledger.LedgerError, .alreadyRecorded) }
        XCTAssertEqual(try all().count, 1)
    }
    func testTheActualAmountAndAccountCanDifferFromThePlan() throws {
        let r = rule(); let wallet = Account(name: "Card", kind: .bank, currencyCode: "MYR", sortOrder: 1); ctx.insert(wallet)
        let tx = try Ledger.recordPayment(of: r, amountCents: 1_750, accountID: wallet.id, existing: [], in: ctx, calendar: utc)
        XCTAssertEqual(tx.amountCents, 1_750); XCTAssertEqual(tx.accountID, wallet.id); XCTAssertEqual(r.amountCents, 1_599, "the plan keeps its usual amount")
        XCTAssertThrowsError(try Ledger.recordPayment(of: rule(), amountCents: 0, existing: [], in: ctx, calendar: utc))
    }
    func testSkippingMovesOnWithoutRecordingAnything() throws {
        let r = rule()
        try Ledger.skipPayment(of: r, in: ctx, calendar: utc)
        XCTAssertEqual(utc.component(.month, from: r.dueDate), 4); XCTAssertEqual(try all().count, 0)
    }
    func testPausingAndResumingDoesNotOweWhatWasMissed() throws {
        let r = rule(due: date(2026, 1, 5))
        try Ledger.pause(r, in: ctx)
        XCTAssertEqual(r.status, .paused)
        try Ledger.resume(r, today: date(2026, 3, 20), in: ctx, calendar: utc)
        XCTAssertEqual(r.status, .active); XCTAssertEqual(utc.component(.month, from: r.dueDate), 4)
        XCTAssertEqual(try all().count, 0, "nothing was recorded for January to March")
    }
    func testCancelledPaymentsCannotBeRecordedUntilRestarted() throws {
        let r = rule()
        try Ledger.cancel(r, in: ctx)
        XCTAssertEqual(r.status, .cancelled); XCTAssertFalse(r.isActive)
        XCTAssertThrowsError(try Ledger.recordPayment(of: r, existing: [], in: ctx, calendar: utc)) { XCTAssertEqual($0 as? Ledger.LedgerError, .cancelledPayment) }
        XCTAssertThrowsError(try Ledger.skipPayment(of: r, in: ctx, calendar: utc))
        try Ledger.resume(r, today: date(2026, 3, 1), in: ctx, calendar: utc)
        XCTAssertEqual(r.status, .active)
    }
    func testAWeeklyScheduleStepsBySevenDays() throws {
        let r = rule(due: date(2026, 3, 2), unit: .week)
        _ = try Ledger.recordPayment(of: r, existing: [], in: ctx, calendar: utc)
        XCTAssertEqual(utc.component(.day, from: r.dueDate), 9)
    }
    func testRulesSavedBeforeRealDatesGetOneWithoutChangingAnythingElse() throws {
        let old = RecurringRule(title: "Gym", amountCents: 8_000, kind: .expense, category: "Health", dayOfMonth: 25, nextMonthKey: "2026-03")
        ctx.insert(old); XCTAssertNil(old.nextDueDate)
        let acct = Account(name: "Main", kind: .bank, currencyCode: "MYR"); ctx.insert(acct)
        XCTAssertTrue(try Ledger.upgradeLegacyRules([old], defaultAccountID: acct.id, in: ctx))
        XCTAssertEqual(Calendar.current.component(.day, from: old.dueDate), 25, "the day you picked, in your own time zone"); XCTAssertEqual(old.accountID, acct.id)
        XCTAssertEqual(old.amountCents, 8_000); XCTAssertEqual(old.status, .active)
        XCTAssertFalse(try Ledger.upgradeLegacyRules([old], defaultAccountID: acct.id, in: ctx), "idempotent")
    }
    func testStatusesAndDueDateFallbackForLegacyRules() {
        let r = RecurringRule(title: "x", amountCents: 1, kind: .expense, category: "c", dayOfMonth: 31, nextMonthKey: "2026-02")
        XCTAssertEqual(r.status, .active)
        XCTAssertEqual(Calendar.current.component(.day, from: r.dueDate), 28, "day 31 clamps to February's length")
        r.isActive = false; XCTAssertEqual(r.status, .paused); r.isCancelled = true; XCTAssertEqual(r.status, .cancelled)
    }
}

// MARK: - Reminders and safe-to-spend with real schedules

@MainActor
final class SubscriptionIntegrationTests: XCTestCase {
    func testRemindersFollowTheLeadTimeAndTheChosenHour() {
        let r = RecurringRule(title: "Netflix", amountCents: 1_599, kind: .expense, category: "Subscriptions", dayOfMonth: 20, nextMonthKey: "2026-03")
        r.nextDueDate = date(2026, 3, 20); r.remindDaysBefore = 3
        let now = date(2026, 3, 10, hour: 8)
        let out = Reminders.subscriptionReminders([r], now: now, hour: 7, calendar: utc)
        XCTAssertEqual(out.count, 2, "the next two payments")
        XCTAssertEqual(out[0].fire.day, 17); XCTAssertEqual(out[0].fire.month, 3); XCTAssertEqual(out[0].fire.hour, 7)
        XCTAssertEqual(out[1].fire.month, 4); XCTAssertEqual(out[1].fire.day, 17)
        XCTAssertTrue(out[0].body.contains("due in 3 days")); XCTAssertTrue(out[0].id.hasPrefix("sub-"))
        r.remindDaysBefore = 0
        XCTAssertTrue(Reminders.subscriptionReminders([r], now: now, hour: 7, calendar: utc)[0].body.contains("due today"))
    }
    func testNoRemindersForPausedCancelledOrIncomeOrAlreadyPastTimes() {
        func make(_ tweak: (RecurringRule) -> Void) -> [RecurringRule] {
            let r = RecurringRule(title: "x", amountCents: 100, kind: .expense, category: "c", dayOfMonth: 20, nextMonthKey: "2026-03")
            r.nextDueDate = date(2026, 3, 20); tweak(r); return [r]
        }
        let now = date(2026, 3, 10)
        XCTAssertTrue(Reminders.subscriptionReminders(make { $0.isActive = false }, now: now, hour: 9, calendar: utc).isEmpty)
        XCTAssertTrue(Reminders.subscriptionReminders(make { $0.isCancelled = true; $0.isActive = false }, now: now, hour: 9, calendar: utc).isEmpty)
        XCTAssertTrue(Reminders.subscriptionReminders(make { $0.kind = .income }, now: now, hour: 9, calendar: utc).isEmpty)
        let late = Reminders.subscriptionReminders(make { $0.remindDaysBefore = 1 }, now: date(2026, 3, 19, hour: 12), hour: 9, calendar: utc)
        XCTAssertEqual(late.map { $0.fire.month }, [4, 5], "March's 09:00 has already passed, so the next two future reminders are April and May")
    }
    func testSafeToSpendCountsEveryWeeklyPaymentBeforeTheHorizonAndSkipsPausedOnes() throws {
        let (_, ctx) = try makeContext()
        let main = Account(name: "Main", kind: .bank, currencyCode: "MYR", openingCents: 500_000, sortOrder: 0); ctx.insert(main)
        let weekly = RecurringRule(title: "Cleaner", amountCents: 5_000, kind: .expense, category: "Bills", dayOfMonth: 11, nextMonthKey: "2026-03")
        weekly.nextDueDate = date(2026, 3, 11); weekly.unit = .week; weekly.accountID = main.id
        let paused = RecurringRule(title: "Paused", amountCents: 9_999, kind: .expense, category: "Bills", dayOfMonth: 12, nextMonthKey: "2026-03")
        paused.nextDueDate = date(2026, 3, 12); paused.isActive = false
        let late = RecurringRule(title: "Overdue", amountCents: 2_000, kind: .expense, category: "Bills", dayOfMonth: 2, nextMonthKey: "2026-03")
        late.nextDueDate = date(2026, 3, 2)
        let books = Books(accounts: [main], rates: [], transactions: [], entries: [])
        var cfg = SafeToSpend.Config(); cfg.horizon = .endOfMonth
        let r = SafeToSpend.make(now: date(2026, 3, 10), config: cfg, books: books, planned: [], rules: [weekly, paused, late], goals: [], costs: [],
                                 entries: [], categories: [], limits: [], monthBudgets: [], reserved: [], calendar: utc)
        // weekly: Mar 11, 18, 25 = 3 × 50.00; overdue 20.00 still owed; paused owes nothing
        XCTAssertEqual(r.billsTotal, 15_000 + 2_000)
    }
    func testForeignCurrencyPaymentsAreConvertedWithYourRateOrLeftOutNotGuessed() throws {
        let (_, ctx) = try makeContext()
        let usd = Account(name: "USD", kind: .ewallet, currencyCode: "USD", openingCents: 100_000, sortOrder: 0); ctx.insert(usd)
        let sub = RecurringRule(title: "Cloud", amountCents: 1_000, kind: .expense, category: "Bills", dayOfMonth: 15, nextMonthKey: "2026-03")
        sub.nextDueDate = date(2026, 3, 15); sub.accountID = usd.id
        func total(_ rates: [ExchangeRate]) -> Int {
            let books = Books(accounts: [usd], rates: rates, transactions: [], entries: [])
            return SafeToSpend.make(now: date(2026, 3, 10), config: SafeToSpend.Config(), books: books, planned: [], rules: [sub], goals: [], costs: [],
                                    entries: [], categories: [], limits: [], monthBudgets: [], reserved: [], calendar: utc).billsTotal
        }
        XCTAssertEqual(total([ExchangeRate(fromCode: "USD", toCode: "MYR", rateMicros: 4_472_500)]), 4_473, "$10.00 × 4.4725 = RM 44.73")
        XCTAssertEqual(total([]), 0)
    }
    func testFormatFourBackupKeepsEverythingAboutSubscriptions() throws {
        let (_, src) = try makeContext()
        let acct = Account(name: "Main", kind: .bank, currencyCode: "MYR", sortOrder: 0); src.insert(acct)
        let r = RecurringRule(title: "Rent", amountCents: 80_000, kind: .expense, category: "Bills", dayOfMonth: 1, nextMonthKey: "2026-04")
        r.nextDueDate = date(2026, 4, 1); r.unit = .month; r.interval = 3; r.isCancelled = true; r.isActive = false; r.notes = "Quarterly"
        r.accountID = acct.id; r.remindDaysBefore = 7; src.insert(r)
        let paid = TransactionRecord(amountCents: 80_000, kind: .expense, category: "Bills", date: date(2026, 1, 2), title: "Rent", accountID: acct.id)
        paid.occurrenceKey = "\(r.id.uuidString)|2026-01-01"; src.insert(paid)
        try src.save()
        let file = try BackupService.decode(try BackupService.encode(try BackupService.snapshot(context: src, openingBalanceCents: 0, currencySymbol: "RM")))
        XCTAssertEqual(file.version, BackupFile.currentVersion)
        let (_, dst) = try makeContext()
        try BackupService.replaceAll(with: file, in: dst)
        let back = try XCTUnwrap(try dst.fetch(FetchDescriptor<RecurringRule>()).first)
        XCTAssertEqual(back.interval, 3); XCTAssertEqual(back.status, .cancelled); XCTAssertEqual(back.notes, "Quarterly")
        XCTAssertEqual(back.remindDaysBefore, 7); XCTAssertEqual(back.nextDueDate, date(2026, 4, 1)); XCTAssertEqual(back.accountID, acct.id)
        XCTAssertEqual(try dst.fetch(FetchDescriptor<TransactionRecord>()).first?.occurrenceKey, paid.occurrenceKey)
        try? FileManager.default.removeItem(at: AccountMigration.safetyDirectory)
    }
    func testABackupWithTheSamePaymentRecordedTwiceIsRejected() throws {
        var f = BackupFile()
        func tx() -> BackupFile.TransactionDTO { .init(id: UUID(), amountCents: 100, kind: "expense", category: "c", date: .now, title: "", notes: "", sourceID: nil, occurrenceKey: "abc|2026-03-05") }
        f.transactions = [tx(), tx()]
        XCTAssertThrowsError(try BackupService.validate(f))
    }
    func testAFormatThreeBackupWithAnOldStyleRuleStillRestores() throws {
        var f = BackupFile(); f.version = 3
        f.recurringRules = [.init(id: UUID(), title: "Gym", amountCents: 8_000, kind: "expense", category: "Health", dayOfMonth: 25, nextMonthKey: "2026-03", isActive: true)]
        let (_, ctx) = try makeContext()
        try BackupService.replaceAll(with: try BackupService.decode(try BackupService.encode(f)), in: ctx)
        let r = try XCTUnwrap(try ctx.fetch(FetchDescriptor<RecurringRule>()).first)
        XCTAssertEqual(r.unit, .month); XCTAssertEqual(r.interval, 1); XCTAssertEqual(r.status, .active); XCTAssertNil(r.nextDueDate)
        try? FileManager.default.removeItem(at: AccountMigration.safetyDirectory)
    }
}

// MARK: - Insights

final class InsightsTests: XCTestCase {
    private func e(_ cents: Int, _ y: Int, _ m: Int, _ d: Int, _ cat: String = "Food", _ title: String = "") -> TransactionRecord {
        TransactionRecord(amountCents: cents, kind: .expense, category: cat, date: date(y, m, d), title: title)
    }
    private func income(_ cents: Int, _ y: Int, _ m: Int, _ d: Int) -> TransactionRecord {
        TransactionRecord(amountCents: cents, kind: .income, category: "Salary", date: date(y, m, d), title: "")
    }
    private let now = date(2026, 3, 10)

    func testDailyAverageForTheCurrentMonthUsesOnlyDaysThatHaveHappened() {
        let txs = [e(10_000, 2026, 3, 2), e(5_000, 2026, 3, 9), income(999_999, 2026, 3, 1)]
        let a = Insights.dailyAverage(txs, month: MonthKey(year: 2026, month: 3), now: now, calendar: utc)!
        XCTAssertEqual(a.days, 10); XCTAssertTrue(a.isPartialMonth); XCTAssertEqual(a.totalCents, 15_000); XCTAssertEqual(a.averageCents, 1_500)
    }
    func testDailyAverageForAFinishedMonthUsesTheWholeMonthAndFutureMonthsHaveNone() {
        let a = Insights.dailyAverage([e(31_000, 2026, 1, 15)], month: MonthKey(year: 2026, month: 1), now: now, calendar: utc)!
        XCTAssertEqual(a.days, 31); XCTAssertFalse(a.isPartialMonth); XCTAssertEqual(a.averageCents, 1_000)
        XCTAssertNil(Insights.dailyAverage([], month: MonthKey(year: 2026, month: 4), now: now, calendar: utc))
    }
    func testComparisonMatchesEquivalentPeriodsNotAHalfMonthAgainstAWholeOne() {
        let txs = [e(10_000, 2026, 3, 3, "Food"), e(4_000, 2026, 3, 9, "Fun"),                       // this month, days 1–10
                   e(8_000, 2026, 2, 4, "Food"), e(1_000, 2026, 2, 8, "Fun"), e(50_000, 2026, 2, 20, "Rent")]   // last month; day 20 is outside the window
        let c = Insights.monthToDateComparison(txs, now: now, calendar: utc)
        XCTAssertEqual(c.days, 10); XCTAssertEqual(c.current, 14_000); XCTAssertEqual(c.previous, 9_000)
        XCTAssertEqual(c.delta, 5_000); XCTAssertEqual(try XCTUnwrap(c.percent), 5.0 / 9.0, accuracy: 0.0001)
        XCTAssertEqual(c.categories.map(\.category).sorted(), ["Food", "Fun"])
        XCTAssertEqual(c.categories.first { $0.category == "Food" }?.delta, 2_000)
    }
    func testComparisonUsesTheShorterMonthsLengthOnTheThirty1st() {
        let c = Insights.monthToDateComparison([e(100, 2026, 3, 30), e(100, 2026, 2, 27)], now: date(2026, 3, 31), calendar: utc)
        XCTAssertEqual(c.days, 28, "February only has 28 days; both months are compared over their first 28")
        XCTAssertEqual(c.current, 0); XCTAssertEqual(c.previous, 100)
    }
    func testNoPercentageWhenThereIsNothingToCompareAgainst() {
        XCTAssertNil(Insights.monthToDateComparison([e(100, 2026, 3, 2)], now: now, calendar: utc).percent)
    }
    func testWeekdayPatternAveragesOverTheDaysThatExist() {
        // Mondays: 2026-03-02 and 2026-03-09 within history that starts on Mar 2 (a Monday). Window ends Mar 10 (Tuesday).
        let txs = [e(6_000, 2026, 3, 2), e(2_000, 2026, 3, 9), e(3_000, 2026, 3, 3)]
        let p = Insights.weekdayPattern(txs, weeks: 8, now: now, calendar: utc)
        XCTAssertEqual(p.count, 7)
        let monday = try? XCTUnwrap(p.first { $0.weekday == 2 }), tuesday = try? XCTUnwrap(p.first { $0.weekday == 3 })
        XCTAssertEqual(monday?.occurrences, 2); XCTAssertEqual(monday?.averageCents, 4_000, "(6,000 + 2,000) ÷ 2 Mondays")
        XCTAssertEqual(tuesday?.occurrences, 2); XCTAssertEqual(tuesday?.averageCents, 1_500, "3,000 ÷ 2 Tuesdays: Mar 10 is a Tuesday with nothing spent")
        XCTAssertEqual(p.first { $0.weekday == 1 }?.occurrences, 1, "history started Mar 2, so only one Sunday has happened (Mar 8)")
    }
    func testWeekdayPatternWithNoExpensesIsAllZero() {
        XCTAssertTrue(Insights.weekdayPattern([income(100, 2026, 3, 1)], now: now, calendar: utc).allSatisfy { $0.averageCents == 0 })
    }
    func testCategoryTotalsByMonth() {
        let months = [MonthKey(year: 2026, month: 1), MonthKey(year: 2026, month: 2), MonthKey(year: 2026, month: 3)]
        let r = Insights.categoryTotals([e(100, 2026, 1, 5, "Food"), e(250, 2026, 1, 9, "Groceries"), e(999, 2026, 2, 1, "Fun"), e(70, 2026, 3, 1, "Food")],
                                        categories: ["Food", "Groceries"], months: months, calendar: utc)
        XCTAssertEqual(r.map(\.cents), [350, 0, 70])
    }
    func testLargestExpensesAreInRangeAndOrdered() {
        let txs = [e(500, 2026, 3, 1), e(900, 2026, 3, 2), e(700, 2026, 3, 3), e(99_999, 2026, 2, 28), income(50_000, 2026, 3, 1)]
        let top = Insights.largestExpenses(txs, from: date(2026, 3, 1, hour: 0), through: date(2026, 3, 31), limit: 2)
        XCTAssertEqual(top.map(\.amountCents), [900, 700])
    }
    func testHabitChangesNeedBothWindowsOfHistory() {
        XCTAssertNil(Insights.habitChanges([e(100, 2026, 1, 5)], now: now, calendar: utc), "only one month of history")
        // now = Mar 2026: recent window = Dec, Jan, Feb; before = Sep, Oct, Nov
        let txs = [e(1_000, 2025, 9, 5, "Food"), e(1_000, 2025, 10, 5, "Food"), e(1_000, 2025, 11, 5, "Food"),
                   e(2_000, 2025, 12, 5, "Food"), e(2_000, 2026, 1, 5, "Food"), e(2_000, 2026, 2, 5, "Food"),
                   e(300, 2025, 10, 9, "Fun"), e(900, 2026, 1, 9, "Rent"), e(555, 2026, 3, 1, "Food")]
        let c = try? XCTUnwrap(Insights.habitChanges(txs, now: now, calendar: utc))
        XCTAssertEqual(c?.first?.category, "Food"); XCTAssertEqual(c?.first?.delta, 3_000, "6,000 vs 3,000; March is not complete so it's left out")
        XCTAssertEqual(c?.first { $0.category == "Fun" }?.delta, -300)
        XCTAssertEqual(c?.first { $0.category == "Rent" }?.delta, 900)
    }
    func testScheduledPaymentsCountOnlyConfirmedScheduleTransactions() {
        let a = e(1_599, 2026, 2, 5, "Subscriptions"); a.occurrenceKey = "x|2026-02-05"
        let b = e(5_000, 2026, 2, 6, "Food")   // ordinary spending, not a subscription
        let c = e(1_599, 2026, 3, 5, "Subscriptions"); c.occurrenceKey = "x|2026-03-05"
        let r = Insights.scheduledPayments([a, b, c], months: [MonthKey(year: 2026, month: 2), MonthKey(year: 2026, month: 3)], calendar: utc)
        XCTAssertEqual(r.map(\.cents), [1_599, 1_599])
    }
}

// MARK: - Purchase simulator

final class PurchaseSimulatorTests: XCTestCase {
    private func ctx(safe: Int = 80_000, safe30: Int = 30_000, income: Int = 400_000, expense: Int = 150_000) -> PurchaseSimulator.Context {
        .init(availableCash: 200_000, safeToSpendNow: safe, safeToSpend30Days: safe30, thirtyDaysFrom: date(2026, 4, 9),
              monthIncome: income, monthExpense: expense, budgetTotal: 250_000, budgetSpent: 150_000,
              categoryBudgets: ["Shopping": (limit: 20_000, spent: 15_000)],
              goals: [.init(name: "Tokyo", priority: 2, monthlyPace: 60_000, remaining: 600_000, estimatedCompletion: date(2027, 1, 5)),
                      .init(name: "Laptop", priority: 1, monthlyPace: 20_000, remaining: 100_000, estimatedCompletion: date(2026, 9, 1)),
                      .init(name: "No plan", priority: 1, monthlyPace: 0, remaining: 50_000, estimatedCompletion: nil),
                      .init(name: "Done", priority: 3, monthlyPace: 10_000, remaining: 0, estimatedCompletion: nil)])
    }
    private func run(_ price: Int, category: String? = nil, hourly: Int? = nil, _ c: PurchaseSimulator.Context? = nil) -> PurchaseSimulator.Result {
        PurchaseSimulator.evaluate(price: price, category: category, hourlyRate: hourly, now: date(2026, 3, 10), context: c ?? ctx())
    }

    func testAvailableMoneyAndSafeToSpendBeforeAndAfter() {
        let r = run(30_000)
        XCTAssertEqual(r.cashBefore, 200_000); XCTAssertEqual(r.cashAfter, 170_000)
        XCTAssertEqual(r.safeBefore, 80_000); XCTAssertEqual(r.safeAfter, 50_000); XCTAssertTrue(r.fitsSafeToSpend); XCTAssertEqual(r.overSafeBy, 0)
        let big = run(100_000)
        XCTAssertFalse(big.fitsSafeToSpend); XCTAssertEqual(big.overSafeBy, 20_000); XCTAssertEqual(big.safeAfter, -20_000)
    }
    func testBudgetEffectOverallAndByCategory() {
        let r = run(12_000, category: "Shopping")
        XCTAssertEqual(r.overall?.remainingBefore, 100_000); XCTAssertEqual(r.overall?.remainingAfter, 88_000)
        XCTAssertEqual(r.category?.remainingBefore, 5_000); XCTAssertEqual(r.category?.remainingAfter, -7_000)
        XCTAssertTrue(r.category?.goesOver ?? false)
        XCTAssertNil(run(500, category: "Food").category, "a category without a limit has no category effect")
        XCTAssertNil(run(500, category: nil).category)
        var none = ctx(); none.budgetTotal = nil
        XCTAssertNil(run(500, none).overall)
        XCTAssertTrue(run(300_000).overall?.goesOver ?? false)
    }
    func testSavingsRateDropsByThePurchase() {
        let r = run(40_000)
        XCTAssertEqual(try XCTUnwrap(r.savingsRateBefore), 250_000.0 / 400_000.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(r.savingsRateAfter), 210_000.0 / 400_000.0, accuracy: 1e-9)
        XCTAssertNil(run(1, ctx(income: 0)).savingsRateBefore, "no income this month, no rate")
    }
    func testGoalDelayIsThePriceOverTheMonthlyPaceInDays() {
        let r = run(30_000)   // 30,000 ÷ 60,000 a month = half a month ≈ 15 days
        let tokyo = try? XCTUnwrap(r.goalDelays.first { $0.name == "Tokyo" })
        XCTAssertEqual(tokyo?.delayDays, 15)
        XCTAssertEqual(tokyo?.newEstimate, Calendar.current.date(byAdding: .day, value: 15, to: date(2027, 1, 5)))
        XCTAssertEqual(r.goalDelays.first { $0.name == "Laptop" }?.delayDays, 46, "30,000 ÷ 20,000 = 1.5 months")
        XCTAssertNil(r.goalDelays.first { $0.name == "No plan" }?.delayDays, "no plan, no estimate: not guessed")
        XCTAssertFalse(r.goalDelays.contains { $0.name == "Done" }, "funded goals aren't delayed")
        XCTAssertEqual(r.goalDelays.first?.name, "Tokyo", "higher priority first")
    }
    func testHoursOfWork() {
        XCTAssertEqual(try XCTUnwrap(run(30_000, hourly: 2_000).hoursOfWork), 15, accuracy: 1e-9)
        XCTAssertNil(run(30_000, hourly: nil).hoursOfWork); XCTAssertNil(run(30_000, hourly: 0).hoursOfWork)
    }
    func testWaitingThirtyDaysUsesOnlyWhatIsAlreadyCommitted() {
        let w = PurchaseSimulator.waiting30Days(price: 20_000, context: ctx(safe30: 30_000))
        XCTAssertTrue(w.stillAffordable); XCTAssertEqual(w.leftAfterBuying, 10_000); XCTAssertEqual(w.date, date(2026, 4, 9))
        let no = PurchaseSimulator.waiting30Days(price: 50_000, context: ctx(safe30: 30_000))
        XCTAssertFalse(no.stillAffordable); XCTAssertEqual(no.leftAfterBuying, -20_000)
    }
    func testACheaperAlternativeIsJustAnotherEvaluation() {
        let a = run(100_000), b = run(40_000)
        XCTAssertLessThan(b.overSafeBy, a.overSafeBy); XCTAssertTrue(b.fitsSafeToSpend)
        XCTAssertLessThan(b.goalDelays[0].delayDays ?? 0, a.goalDelays[0].delayDays ?? 0)
    }
}

// MARK: - What-if lab

final class WhatIfTests: XCTestCase {
    private func e(_ cents: Int, _ y: Int, _ m: Int, _ d: Int = 5) -> TransactionRecord { TransactionRecord(amountCents: cents, kind: .expense, category: "Food", date: date(y, m, d), title: "") }
    private func i(_ cents: Int, _ y: Int, _ m: Int, _ d: Int = 1) -> TransactionRecord { TransactionRecord(amountCents: cents, kind: .income, category: "Salary", date: date(y, m, d), title: "") }
    private let now = date(2026, 4, 10)
    private var goals: [WhatIf.GoalLine] { [.init(name: "Tokyo", remaining: 600_000, monthlyPace: 50_000), .init(name: "Done", remaining: 0, monthlyPace: 10_000)] }

    private func base(_ txs: [TransactionRecord]? = nil, cash: Int = 300_000) -> WhatIf.Baseline {
        let t = txs ?? [i(500_000, 2026, 1), e(200_000, 2026, 1), i(500_000, 2026, 2), e(250_000, 2026, 2), i(500_000, 2026, 3), e(150_000, 2026, 3)]
        return WhatIf.baseline(t, now: now, startingCash: cash, goals: goals, budgetTotal: 220_000, calendar: utc)
    }

    func testBaselineIsTheAverageOfTheLastThreeCompletedMonths() {
        let b = base()
        XCTAssertEqual(b.monthlyIncome, 500_000); XCTAssertEqual(b.monthlySpending, 200_000, "(200k + 250k + 150k) ÷ 3")
        XCTAssertEqual(b.basisMonths, 3); XCTAssertEqual(b.monthlyGoalSavings, 60_000)
        XCTAssertTrue(b.basis.contains("3 completed months"))
    }
    func testTheCurrentIncompleteMonthIsNotMixedIntoTheAverage() {
        let txs = [i(500_000, 2026, 3), e(100_000, 2026, 3), e(999_999, 2026, 4, 2)]   // April is only 10 days old
        let b = base(txs)
        XCTAssertEqual(b.monthlySpending, 100_000); XCTAssertEqual(b.basisMonths, 1)
    }
    func testWithNoCompletedMonthItSaysItUsesThisMonthSoFar() {
        let b = base([i(300_000, 2026, 4, 2), e(80_000, 2026, 4, 3)])
        XCTAssertEqual(b.monthlyIncome, 300_000); XCTAssertEqual(b.basisMonths, 0); XCTAssertTrue(b.basis.contains("this month so far"))
    }
    func testAnUnchangedScenarioMatchesTheCurrentPlanExactly() {
        let b = base()
        let plan = WhatIf.project(b), same = WhatIf.project(b, scenario: WhatIf.Scenario())
        XCTAssertEqual(plan, same); XCTAssertEqual(plan.balances.count, 13)
        XCTAssertEqual(plan.monthlySurplus, 500_000 - 200_000 - 60_000)
        XCTAssertEqual(plan.endingBalance, 300_000 + 12 * 240_000)
        XCTAssertTrue(WhatIf.Scenario().isUnchanged)
    }
    func testLowerIncome() {
        var s = WhatIf.Scenario(); s.incomeChangePercent = -20
        let p = WhatIf.project(base(), scenario: s)
        XCTAssertEqual(p.monthlyIncome, 400_000); XCTAssertEqual(p.monthlySurplus, 140_000)
        XCTAssertEqual(p.endingBalance, 300_000 + 12 * 140_000)
        var cut = WhatIf.Scenario(); cut.incomeChangeAmount = -600_000
        XCTAssertEqual(WhatIf.project(base(), scenario: cut).monthlyIncome, 0, "income can't go below zero")
    }
    func testANewSubscriptionAndASpendingOverride() {
        var s = WhatIf.Scenario(); s.newMonthlyCost = 5_000
        XCTAssertEqual(WhatIf.project(base(), scenario: s).monthlySpending, 205_000)
        s.spendingOverride = 150_000
        XCTAssertEqual(WhatIf.project(base(), scenario: s).monthlySpending, 155_000, "the override replaces normal spending; the new cost is added on top")
    }
    func testAOneTimeExpenseHitsOnlyItsMonthAndCanMakeTheMoneyRunOut() {
        var s = WhatIf.Scenario(); s.oneTimeExpense = 1_200_000; s.oneTimeMonth = 3
        let p = WhatIf.project(base(), scenario: s)
        XCTAssertEqual(p.balances[2], 300_000 + 2 * 240_000, "nothing changes before month 3")
        XCTAssertEqual(p.balances[3], 300_000 + 3 * 240_000 - 1_200_000, "−180,000")
        XCTAssertGreaterThan(p.balances[4], 0, "it recovers the next month, but it did run out")
        XCTAssertEqual(p.runsOutInMonth, 3); XCTAssertLessThan(p.lowestBalance, 0)
        XCTAssertNil(WhatIf.project(base()).runsOutInMonth)
    }
    func testSavingMoreForAGoalLowersCashAndBringsTheGoalForward() {
        var s = WhatIf.Scenario(); s.extraGoalName = "Tokyo"; s.extraGoalMonthly = 50_000
        let p = WhatIf.project(base(), scenario: s)
        XCTAssertEqual(p.monthlyGoalSavings, 110_000); XCTAssertEqual(p.monthlySurplus, 190_000)
        let o = try? XCTUnwrap(WhatIf.goalOutlook(base(), scenario: s, now: now, calendar: utc).first)
        // 600k ÷ 50k = 12 months; 600k ÷ 100k = 6 months
        XCTAssertEqual(o?.baselineDate.map { utc.component(.year, from: $0) * 12 + utc.component(.month, from: $0) }, 2027 * 12 + 4)
        XCTAssertEqual(o?.scenarioDate.map { utc.component(.year, from: $0) * 12 + utc.component(.month, from: $0) }, 2026 * 12 + 10)
        XCTAssertEqual(WhatIf.goalOutlook(base(), scenario: s, now: now, calendar: utc).count, 1, "funded goals are left out")
    }
    func testScenariosPersistAndAreCappedAtThree() {
        let d = UserDefaults(suiteName: "mono-wi-\(UUID().uuidString)")!
        let store = WhatIfStore(defaults: d)
        var s = WhatIf.Scenario(); s.name = "Pay cut"; s.incomeChangePercent = -10
        store.upsert(s)
        XCTAssertEqual(WhatIfStore(defaults: d).scenarios.first?.name, "Pay cut")
        for n in 1...5 { var x = WhatIf.Scenario(); x.name = "S\(n)"; store.upsert(x) }
        XCTAssertEqual(store.scenarios.count, 3)
        s.name = "Renamed"; store.upsert(s)
        XCTAssertEqual(store.scenarios.first { $0.id == s.id }?.name, "Renamed"); XCTAssertEqual(store.scenarios.count, 3)
        store.delete(s.id); XCTAssertEqual(store.scenarios.count, 2)
    }
    func testRunningAProjectionNeverChangesAnyRecord() throws {
        let txs = [i(500_000, 2026, 3), e(100_000, 2026, 3)]
        let before = txs.map(\.amountCents)
        var s = WhatIf.Scenario(); s.oneTimeExpense = 9_999_999; s.incomeChangePercent = -100
        _ = WhatIf.project(base(txs), scenario: s)
        XCTAssertEqual(txs.map(\.amountCents), before)
    }
}

// MARK: - Monthly review

final class MonthlyReviewTests: XCTestCase {
    private func e(_ cents: Int, _ y: Int, _ m: Int, _ d: Int, _ cat: String = "Food", merchant: String = "") -> TransactionRecord {
        TransactionRecord(amountCents: cents, kind: .expense, category: cat, date: date(y, m, d), title: "", merchant: merchant)
    }
    private func i(_ cents: Int, _ y: Int, _ m: Int, _ d: Int = 1) -> TransactionRecord { TransactionRecord(amountCents: cents, kind: .income, category: "Salary", date: date(y, m, d), title: "") }
    private func tr(_ cents: Int, _ y: Int, _ m: Int, _ d: Int) -> TransactionRecord {
        let t = TransactionRecord(amountCents: cents, kind: .transfer, category: "", date: date(y, m, d), title: ""); return t
    }
    private let noRecurring = MonthlyReview.Recurring(paidCount: 0, paidTotal: 0, activeCount: 0, monthlyEstimate: 0)
    private func fmt(_ c: Int) -> String { "RM \(c / 100).\(String(format: "%02d", c % 100))" }
    private func make(_ month: MonthKey, now: Date, _ txs: [TransactionRecord], moves: [(goal: String, cents: Int)] = [], budget: BudgetSummary? = nil,
                      recurring: MonthlyReview.Recurring? = nil) -> MonthlyReview.Review {
        MonthlyReview.make(month: month, now: now, txs: txs, goalMoves: moves, goalProgress: [], budget: budget, recurring: recurring ?? noRecurring,
                           upcoming: [], format: fmt, calendar: utc)
    }
    private let feb = MonthKey(year: 2026, month: 2), mar = MonthKey(year: 2026, month: 3)

    func testTotalsNetAndSavingsRateIgnoreTransfersAndGoalMoney() {
        let txs = [i(500_000, 2026, 3), e(120_000, 2026, 3, 5), e(30_000, 2026, 3, 9, "Fun"), tr(999_999, 2026, 3, 7), e(77_000, 2026, 2, 5)]
        let r = make(mar, now: date(2026, 4, 2), txs, moves: [("Trip", 50_000), ("Trip", -10_000)])
        XCTAssertEqual(r.income, 500_000); XCTAssertEqual(r.expense, 150_000); XCTAssertEqual(r.net, 350_000)
        XCTAssertEqual(r.movedToGoals, 40_000, "contributions minus withdrawals")
        XCTAssertEqual(try XCTUnwrap(r.savingsRate), 0.7, accuracy: 1e-9)
        XCTAssertEqual(r.transactionCount, 3, "the transfer and last month's expense aren't in March")
        XCTAssertTrue(r.isComplete); XCTAssertEqual(r.daysCovered, 31)
    }
    func testCategoriesSumToTheExpensesAndSharesToOne() {
        let r = make(mar, now: date(2026, 4, 2), [e(60_000, 2026, 3, 2, "Rent"), e(30_000, 2026, 3, 3, "Food"), e(10_000, 2026, 3, 4, "Food"), i(1, 2026, 3)])
        XCTAssertEqual(r.categories.map(\.category), ["Rent", "Food"]); XCTAssertEqual(r.categories.map(\.cents), [60_000, 40_000])
        XCTAssertEqual(r.categories.reduce(0) { $0 + $1.cents }, r.expense); XCTAssertEqual(r.categories.reduce(0.0) { $0 + $1.share }, 1, accuracy: 1e-9)
    }
    func testAMonthInProgressSaysSoAndOnlyCountsItsDays() {
        let r = make(mar, now: date(2026, 3, 12), [e(10_000, 2026, 3, 5)])
        XCTAssertFalse(r.isComplete); XCTAssertEqual(r.daysCovered, 12)
        XCTAssertEqual(make(MonthKey(year: 2026, month: 5), now: date(2026, 3, 12), []).daysCovered, 0, "a future month has covered nothing")
    }
    func testAFinishedMonthIsComparedWholeAgainstWholeAndCategoriesAgreeWithTheTotals() {
        let txs = [e(10_000, 2026, 2, 3, "Food"), e(5_000, 2026, 2, 28, "Food"), i(300_000, 2026, 2),
                   e(20_000, 2026, 3, 3, "Food"), e(7_000, 2026, 3, 30, "Fun"), i(400_000, 2026, 3)]
        let c = try? XCTUnwrap(make(mar, now: date(2026, 4, 2), txs).comparison)
        XCTAssertEqual(c?.isPartial, false); XCTAssertEqual(c?.previous, feb)
        XCTAssertEqual(c?.expense, 27_000); XCTAssertEqual(c?.previousExpense, 15_000); XCTAssertEqual(c?.income, 400_000); XCTAssertEqual(c?.previousIncome, 300_000)
        XCTAssertEqual(c?.categoryShifts.reduce(0) { $0 + $1.current }, c?.expense, "March 30th is included, not cut at February's length")
        XCTAssertEqual(c?.categoryShifts.reduce(0) { $0 + $1.previous }, c?.previousExpense)
    }
    func testAMonthInProgressIsComparedOverTheSameNumberOfDays() {
        let txs = [e(10_000, 2026, 2, 3), e(90_000, 2026, 2, 20), e(20_000, 2026, 3, 3)]
        let c = try? XCTUnwrap(make(mar, now: date(2026, 3, 10), txs).comparison)
        XCTAssertEqual(c?.isPartial, true); XCTAssertEqual(c?.days, 10)
        XCTAssertEqual(c?.previousExpense, 10_000, "February's day 20 is outside the first 10 days"); XCTAssertEqual(c?.expense, 20_000)
    }
    func testNoComparisonWithoutAPreviousMonthOfHistory() {
        XCTAssertNil(make(mar, now: date(2026, 4, 2), [e(100, 2026, 3, 3)]).comparison)
    }
    func testPatternsAreFactsFromTheMonth() {
        let r = make(mar, now: date(2026, 4, 2), [e(5_000, 2026, 3, 7), e(40_000, 2026, 3, 9, "Rent"), e(1_000, 2026, 3, 10), i(1, 2026, 3)])   // Mar 7 is a Saturday
        XCTAssertTrue(r.patterns.contains { $0.contains("highest-spending day") && $0.contains("RM 400.00") })
        XCTAssertTrue(r.patterns.contains { $0.contains("largest single expense was RM 400.00") })
        XCTAssertTrue(r.patterns.contains { $0.contains("3 expenses") })
        XCTAssertTrue(r.patterns.contains { $0.contains("weekends") })
        XCTAssertTrue(r.patterns.contains { $0.contains("Rent was your biggest category") })
        XCTAssertTrue(make(mar, now: date(2026, 4, 2), []).patterns.isEmpty, "no spending, nothing to say")
    }
    func testWorthALookFlagsOnlyRealJumpsAndOverBudgetLines() {
        let txs = [e(10_000, 2026, 2, 3, "Fun"), e(20_000, 2026, 3, 3, "Fun"),         // +100.00 (+100%)
                   e(10_000, 2026, 2, 4, "Food"), e(10_500, 2026, 3, 4, "Food")]         // +5.00: too small
        let r = make(mar, now: date(2026, 4, 2), txs)
        XCTAssertEqual(r.worthALook.filter { $0.contains("is up") }.count, 1)
        XCTAssertTrue(r.worthALook.first?.contains("Fun is up RM 100.00 (100%)") ?? false)
        let line = BudgetLine(category: "Food", limit: 5_000, spent: 12_000)
        let b = BudgetSummary(month: mar, total: 50_000, spent: 12_000, lines: [line], unbudgetedSpent: 0, daysLeft: 0)
        XCTAssertTrue(make(mar, now: date(2026, 4, 2), txs, budget: b).worthALook.contains { $0.contains("Food went RM 70.00 over its budget") })
    }
    func testManySmallPurchasesAreCounted() {
        let small = (1...9).map { e(1_000, 2026, 3, $0) } + [e(30_000, 2026, 3, 20, "Rent")]
        let r = make(mar, now: date(2026, 4, 2), small)
        XCTAssertTrue(r.worthALook.contains { $0.contains("9 small purchases under RM 20.00 added up to RM 90.00") })
    }
    func testSubscriptionSummaryIsLabelledAnEstimate() {
        let r = make(mar, now: date(2026, 4, 2), [e(100, 2026, 3, 1)], recurring: .init(paidCount: 2, paidTotal: 7_080, activeCount: 3, monthlyEstimate: 9_000))
        XCTAssertTrue(r.worthALook.contains { $0.contains("3 active subscriptions") && $0.contains("(an estimate)") })
    }
    func testTheTimelineRunsFromTheFirstRecordToNow() {
        let ms = MonthlyReview.months([e(100, 2025, 11, 5), e(100, 2026, 2, 5)], entries: [], now: date(2026, 3, 10), calendar: utc)
        XCTAssertEqual(ms.map(\.string), ["2025-11", "2025-12", "2026-01", "2026-02", "2026-03"])
        XCTAssertEqual(MonthlyReview.months([], entries: [], now: date(2026, 3, 10), calendar: utc).map(\.string), ["2026-03"])
    }
    func testExportsContainTheRealFiguresAndEscapeCSV() {
        PrivacyStore.shared.setHidden(true); defer { PrivacyStore.shared.setHidden(false) }
        let r = make(mar, now: date(2026, 4, 2), [i(500_000, 2026, 3), e(12_345, 2026, 3, 5, "Food, drinks", merchant: "Café \"Zed\"")])
        let md = MonthlyReview.markdown(r, format: fmt)
        XCTAssertTrue(md.contains("# March 2026 review")); XCTAssertTrue(md.contains("Income: RM 5000.00")); XCTAssertTrue(md.contains("Net cash flow: RM 4876.55"))
        XCTAssertFalse(md.contains("••••"), "an export is the real numbers even with Hide amounts on")
        let csv = MonthlyReview.csv(r, format: fmt)
        XCTAssertTrue(csv.contains("\"Food, drinks\"")); XCTAssertTrue(csv.contains("\"Café \"\"Zed\"\"\""))
        XCTAssertEqual(Money.format(12_345, ignoreHiding: true), "RM 123.45"); XCTAssertEqual(Money.format(12_345), "RM ••••")
    }
}
