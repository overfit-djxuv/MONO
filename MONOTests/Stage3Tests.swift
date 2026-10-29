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
