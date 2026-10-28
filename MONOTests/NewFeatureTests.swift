import XCTest
import SwiftData
@testable import MONO

@MainActor
final class RecurringTests: XCTestCase {
    var container: ModelContainer!
    var context: ModelContext!

    override func setUpWithError() throws { (container, context) = try makeContext() }

    private func rule(day: Int, next: String, active: Bool = true, kind: TxKind = .expense) -> RecurringRule {
        let r = RecurringRule(title: "Rent", amountCents: 80_000, kind: kind, category: "Bills", dayOfMonth: day, nextMonthKey: next, isActive: active)
        context.insert(r)
        return r
    }
    private func all() throws -> [TransactionRecord] { try context.fetch(FetchDescriptor<TransactionRecord>(sortBy: [SortDescriptor(\.date)])) }

    func testFirstDueMonthNeverBackdates() {
        let now = date(2026, 10, 10)
        XCTAssertEqual(Ledger.firstDueMonth(day: 10, now: now, calendar: utc).string, "2026-10")
        XCTAssertEqual(Ledger.firstDueMonth(day: 25, now: now, calendar: utc).string, "2026-10")
        XCTAssertEqual(Ledger.firstDueMonth(day: 5, now: now, calendar: utc).string, "2026-11")
        XCTAssertEqual(Ledger.firstDueMonth(day: 5, now: date(2026, 12, 20), calendar: utc).string, "2027-01")
    }

    func testPostsNothingBeforeDay() throws {
        let r = rule(day: 25, next: "2026-10")
        XCTAssertEqual(try Ledger.postDueRecurring([r], in: context, now: date(2026, 10, 10), calendar: utc), 0)
        XCTAssertEqual(r.nextMonthKey, "2026-10")
        XCTAssertTrue(try all().isEmpty)
    }

    func testPostsOnTheDayAndAdvances() throws {
        let r = rule(day: 10, next: "2026-10")
        XCTAssertEqual(try Ledger.postDueRecurring([r], in: context, now: date(2026, 10, 10, hour: 8), calendar: utc), 1)
        let tx = try XCTUnwrap(all().first)
        XCTAssertEqual(tx.amountCents, 80_000)
        XCTAssertEqual(tx.category, "Bills")
        XCTAssertEqual(tx.kind, .expense)
        XCTAssertEqual(r.nextMonthKey, "2026-11")
    }

    func testRunningTwiceDoesNotDuplicate() throws {
        let r = rule(day: 1, next: "2026-10")
        let now = date(2026, 10, 15)
        try Ledger.postDueRecurring([r], in: context, now: now, calendar: utc)
        try Ledger.postDueRecurring([r], in: context, now: now, calendar: utc)
        XCTAssertEqual(try all().count, 1)
    }

    func testCatchesUpMissedMonths() throws {
        let r = rule(day: 5, next: "2026-08")
        XCTAssertEqual(try Ledger.postDueRecurring([r], in: context, now: date(2026, 11, 7), calendar: utc), 4)
        XCTAssertEqual(try all().map { utc.component(.month, from: $0.date) }, [8, 9, 10, 11])
        XCTAssertEqual(r.nextMonthKey, "2026-12")
    }

    func testDeletingPostedTransactionDoesNotRepost() throws {
        let r = rule(day: 1, next: "2026-10")
        let now = date(2026, 10, 15)
        try Ledger.postDueRecurring([r], in: context, now: now, calendar: utc)
        for t in try all() { context.delete(t) }
        try context.save()
        try Ledger.postDueRecurring([r], in: context, now: now, calendar: utc)
        XCTAssertTrue(try all().isEmpty)
    }

    func testPausedRuleDoesNotPost() throws {
        let r = rule(day: 1, next: "2026-10", active: false)
        XCTAssertEqual(try Ledger.postDueRecurring([r], in: context, now: date(2026, 10, 15), calendar: utc), 0)
        XCTAssertEqual(r.nextMonthKey, "2026-10")
    }

    func testIncomeRulePostsAsIncome() throws {
        let r = rule(day: 1, next: "2026-10", kind: .income)
        try Ledger.postDueRecurring([r], in: context, now: date(2026, 10, 2), calendar: utc)
        XCTAssertEqual(try all().first?.kind, .income)
    }

    func testCatchUpIsCapped() throws {
        let r = rule(day: 1, next: "2020-01")
        XCTAssertEqual(try Ledger.postDueRecurring([r], in: context, now: date(2026, 10, 15), calendar: utc),
                       Ledger.maxRecurringCatchUpMonths)
    }

    func testBackupRoundTripKeepsRules() throws {
        _ = rule(day: 7, next: "2026-11")
        try context.save()
        let snap = try BackupService.snapshot(context: context, openingBalanceCents: 0, currencySymbol: "RM")
        let decoded = try BackupService.decode(try BackupService.encode(snap))
        XCTAssertEqual(decoded.recurringRules?.count, 1)
        let (_, other) = try makeContext()
        try BackupService.replaceAll(with: decoded, in: other)
        let restored = try other.fetch(FetchDescriptor<RecurringRule>())
        XCTAssertEqual(restored.first?.dayOfMonth, 7)
        XCTAssertEqual(restored.first?.nextMonthKey, "2026-11")
    }

    func testOldBackupWithoutRulesStillDecodes() throws {
        var f = BackupFile()
        f.recurringRules = nil
        let data = try BackupService.encode(f)
        XCTAssertNil(try BackupService.decode(data).recurringRules)
    }

    func testInvalidRuleIsRejected() throws {
        var f = BackupFile()
        f.recurringRules = [.init(id: UUID(), title: "x", amountCents: 100, kind: "expense", category: "Bills",
                                  dayOfMonth: 31, nextMonthKey: "2026-10", isActive: true)]
        XCTAssertThrowsError(try BackupService.validate(f))
    }
}

final class BackupFreshnessTests: XCTestCase {
    func testNoDataNeverStale() {
        XCTAssertFalse(BackupService.isBackupStale(lastBackup: nil, hasData: false, calendar: utc))
    }
    func testNeverBackedUpWithDataIsStale() {
        XCTAssertTrue(BackupService.isBackupStale(lastBackup: nil, hasData: true, calendar: utc))
    }
    func testSevenDayThreshold() {
        let now = date(2026, 10, 29)
        XCTAssertFalse(BackupService.isBackupStale(lastBackup: date(2026, 10, 23), hasData: true, now: now, calendar: utc))
        XCTAssertTrue(BackupService.isBackupStale(lastBackup: date(2026, 10, 22), hasData: true, now: now, calendar: utc))
    }
}

final class ProfileInfoTests: XCTestCase {
    func testReadsExpiryFromSignedEnvelope() throws {
        let expiry = Date(timeIntervalSince1970: 1_793_000_000)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["ExpirationDate": expiry, "Name": "x"], format: .xml, options: 0)
        var blob = Data([0x30, 0x82, 0x01, 0xFF])   // junk CMS header
        blob.append(plist)
        blob.append(Data([0x00, 0x01, 0x02]))        // junk signature
        XCTAssertEqual(ProfileInfo.expiry(fromProfile: blob), expiry)
    }
    func testGarbageGivesNil() {
        XCTAssertNil(ProfileInfo.expiry(fromProfile: Data([1, 2, 3])))
    }
    func testStatusBands() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(ProfileInfo.status(expiry: now.addingTimeInterval(-1), now: now), .expired)
        XCTAssertEqual(ProfileInfo.status(expiry: now.addingTimeInterval(3_600), now: now), .soon(daysLeft: 0))
        XCTAssertEqual(ProfileInfo.status(expiry: now.addingTimeInterval(6.5 * 86_400), now: now), .ok(daysLeft: 6))
    }
}

@MainActor
final class CSVImportTests: XCTestCase {
    func records(_ text: String) throws -> [[String]] { try CSVImport.parse(text) }
    let cats = [MoneyCategory(name: "Food", symbol: "x", kind: .expense), MoneyCategory(name: "Salary", symbol: "x", kind: .income)]

    func plan(_ text: String, tweak: (inout CSVImport.Mapping) -> Void = { _ in }, existing: [TransactionRecord] = [],
              create: Bool = false) throws -> CSVImport.Plan {
        let r = try records(text)
        var m = CSVImport.autoMapping(r, calendar: utc)
        tweak(&m)
        return CSVImport.plan(records: r, mapping: m, existing: existing, categories: cats, createMissingCategories: create, calendar: utc)
    }

    // MARK: parser

    func testQuotesCommasAndNewlinesInsideFields() throws {
        let r = try records("a,b\r\n\"x, y\",\"say \"\"hi\"\"\"\r\n\"line1\nline2\",z\r\n")
        XCTAssertEqual(r, [["a", "b"], ["x, y", "say \"hi\""], ["line1\nline2", "z"]])
    }
    func testSemicolonAndBOM() throws {
        let text = try CSVImport.decode(Data("\u{FEFF}date;amount\n2026-01-02;5,50\n".utf8))
        XCTAssertEqual(try records(text), [["date", "amount"], ["2026-01-02", "5,50"]])
    }
    func testBlankLinesDroppedAndEmptyFileRejected() throws {
        XCTAssertEqual(try records("a\n\n\nb\n").count, 2)
        XCTAssertThrowsError(try records(""))
    }

    // MARK: amounts and dates

    func testAmountFormats() {
        XCTAssertEqual(CSVImport.parseAmount("1,234.50"), 123_450)
        XCTAssertEqual(CSVImport.parseAmount("-12.00"), -1_200)
        XCTAssertEqual(CSVImport.parseAmount("(12.00)"), -1_200)
        XCTAssertEqual(CSVImport.parseAmount("RM 40"), 4_000)
        XCTAssertEqual(CSVImport.parseAmount("1.234,50"), 123_450)
        XCTAssertEqual(CSVImport.parseAmount("12,50"), 1_250)
        XCTAssertEqual(CSVImport.parseAmount("1,234"), 123_400)
        XCTAssertEqual(CSVImport.parseAmount("1.234.567"), 123_456_700)
        XCTAssertNil(CSVImport.parseAmount("abc"))
        XCTAssertNil(CSVImport.parseAmount(""))
        XCTAssertNil(CSVImport.parseAmount("12.345"))
    }
    func testDateFormatsAndDetection() {
        XCTAssertNotNil(CSVImport.parseDate("2026-03-31", format: .iso, calendar: utc))
        XCTAssertNotNil(CSVImport.parseDate("31/03/2026", format: .dmy, calendar: utc))
        XCTAssertNil(CSVImport.parseDate("31/03/2026", format: .mdy, calendar: utc))
        XCTAssertNotNil(CSVImport.parseDate("31 Mar 2026", format: .dMonY, calendar: utc))
        XCTAssertNotNil(CSVImport.parseDate("2026-03-31T14:00:00", format: .iso, calendar: utc))
        XCTAssertNil(CSVImport.parseDate("2026-02-31", format: .iso, calendar: utc))
        XCTAssertEqual(CSVImport.detectDateFormat(["31/03/2026", "01/04/2026"], calendar: utc), .dmy)
        XCTAssertEqual(CSVImport.detectDateFormat(["03/31/2026", "04/01/2026"], calendar: utc), .mdy)
        XCTAssertEqual(CSVImport.detectDateFormat(["05/03/2026"], calendar: utc), .dmy, "ambiguous defaults to day-first")
    }

    // MARK: planning

    func testSignedAmountsBecomeIncomeAndExpense() throws {
        let p = try plan("Date,Description,Amount\n2026-03-01,Salary,5000.00\n2026-03-02,Lunch,-12.50\n")
        XCTAssertEqual(p.rows.map(\.kind), [.income, .expense])
        XCTAssertEqual(p.rows.map(\.cents), [500_000, 1_250])
        XCTAssertEqual(p.rows.map(\.title), ["Salary", "Lunch"])
    }
    func testInvertSigns() throws {
        let p = try plan("Date,Description,Amount\n2026-03-02,Shop,25.00\n", tweak: { $0.invertSigns = true })
        XCTAssertEqual(p.rows.first?.kind, .expense)
    }
    func testDebitCreditColumns() throws {
        let p = try plan("Date,Details,Debit,Credit\n2026-03-01,Rent,800.00,\n2026-03-02,Refund,,20.00\n2026-03-03,Odd,5.00,5.00\n2026-03-04,Empty,,\n")
        XCTAssertEqual(p.rows.map(\.kind), [.expense, .income])
        XCTAssertEqual(p.skipped.map(\.line), [4, 5])
    }
    func testMONOsOwnExportRoundTrips() throws {
        let tx = [TransactionRecord(amountCents: 1_250, kind: .expense, category: "Food", date: date(2026, 3, 2), title: "=SUM(A1)", notes: "n,1"),
                  TransactionRecord(amountCents: 500_000, kind: .income, category: "Salary", date: date(2026, 3, 1), title: "Pay")]
        let p = try plan(BackupService.csv(transactions: tx))
        XCTAssertEqual(p.rows.count, 2)
        XCTAssertEqual(p.rows.map(\.kind), [.income, .expense])
        XCTAssertEqual(p.rows.map(\.category), ["Salary", "Food"])
        XCTAssertEqual(p.rows[1].title, "=SUM(A1)", "export's formula guard apostrophe is removed")
        XCTAssertEqual(p.rows[1].notes, "n,1")
    }
    func testUnknownCategoryFallsBackOrIsCreated() throws {
        let text = "Date,Description,Amount,Category\n2026-03-02,Taxi,-9.00,Transport\n2026-03-03,Bonus,50.00,Transport\n"
        let plain = try plan(text)
        XCTAssertEqual(plain.rows.map(\.category), ["Other", "Other Income"])
        let made = try plan(text, create: true)
        XCTAssertEqual(made.rows.map(\.category), ["Transport", "Transport"])
        XCTAssertEqual(made.newCategories.count, 2, "one per type")
    }
    func testBadRowsAreSkippedWithReasons() throws {
        let p = try plan("Date,Description,Amount\nnot a date,A,5\n2026-03-02,B,xyz\n2026-03-02,C,0\n2026-03-02,D,3.00\n")
        XCTAssertEqual(p.rows.count, 1)
        XCTAssertEqual(p.skipped.map(\.line), [2, 3, 4])
    }
    func testDuplicatesAgainstExistingAreSkippedOncePerRecord() throws {
        let have = [TransactionRecord(amountCents: 1_250, kind: .expense, category: "Food", date: date(2026, 3, 2), title: "Lunch")]
        let p = try plan("Date,Description,Amount\n2026-03-02,lunch,-12.50\n2026-03-02,Lunch,-12.50\n", existing: have)
        XCTAssertEqual(p.duplicates, 1)
        XCTAssertEqual(p.rows.count, 1, "a second identical purchase on the same day is still genuine")
    }
    func testApplyAddsRecordsAndReimportAddsNothing() throws {
        let (_, ctx) = try makeContext()
        let r = try records("Date,Description,Amount,Category\n2026-03-02,Taxi,-9.00,Transport\n")
        var m = CSVImport.autoMapping(r, calendar: utc)
        m.dateFormat = .iso
        let p = CSVImport.plan(records: r, mapping: m, existing: [], categories: [], createMissingCategories: true, calendar: utc)
        try CSVImport.apply(p, categories: [], in: ctx)
        let stored = try ctx.fetch(FetchDescriptor<TransactionRecord>())
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MoneyCategory>()).map(\.name), ["Transport"])
        let again = CSVImport.plan(records: r, mapping: m, existing: stored, categories: [], createMissingCategories: true, calendar: utc)
        XCTAssertEqual(again.rows.count, 0)
        XCTAssertEqual(again.duplicates, 1)
    }
    func testHeaderlessFileUsesPositions() throws {
        let p = try plan("2026-03-01,Coffee,-3.00\n2026-03-02,Pay,100.00\n")
        XCTAssertEqual(p.rows.count, 2)
    }
}

@MainActor
final class QuickEntryAndReminderTests: XCTestCase {
    func tx(_ title: String, _ cents: Int, _ cat: String, _ d: Date, kind: TxKind = .expense) -> TransactionRecord {
        TransactionRecord(amountCents: cents, kind: kind, category: cat, date: d, title: title)
    }

    func testSuggestionsUseMostRecentAndRankPrefixFirst() {
        let h = [tx("Grab", 1_500, "Transportation", date(2026, 3, 1)), tx("Grab", 2_240, "Transportation", date(2026, 3, 9)),
                 tx("Grabbing coffee", 900, "Food", date(2026, 3, 5)), tx("Lunch grab bag", 700, "Food", date(2026, 3, 8))]
        let s = QuickEntry.suggestions(matching: "grab", in: h)
        XCTAssertEqual(s.map(\.title), ["Grab", "Grabbing coffee", "Lunch grab bag"])
        XCTAssertEqual(s.first?.amountCents, 2_240, "uses the latest amount")
    }
    func testEmptyTextShowsRecentDistinctAndSkipsLinkedAndBlank() {
        let linked = tx("Eggs", 500, "Groceries", date(2026, 3, 9)); linked.sourceID = UUID()
        let h = [tx("A", 100, "Food", date(2026, 3, 1)), tx("", 100, "Food", date(2026, 3, 2)), linked, tx("a", 200, "Food", date(2026, 3, 3))]
        XCTAssertEqual(QuickEntry.suggestions(matching: "", in: h).map(\.title), ["a"])
    }
    func testRepeatCopiesToTodayWithoutLinks() throws {
        let (_, ctx) = try makeContext()
        let t = tx("Rent", 80_000, "Bills", date(2026, 1, 1)); t.sourceID = UUID(); t.notes = "n"
        ctx.insert(t)
        let c = try Ledger.repeatTransaction(t, in: ctx, now: date(2026, 3, 9))
        XCTAssertEqual(c.amountCents, 80_000); XCTAssertEqual(c.notes, "n"); XCTAssertNil(c.sourceID)
        XCTAssertEqual(c.date, date(2026, 3, 9)); XCTAssertNotEqual(c.id, t.id)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<TransactionRecord>()), 2)
    }

    func planned(_ title: String, due: Date, paid: Bool = false) -> PlannedExpense {
        let p = PlannedExpense(title: title, amountCents: 98_000, dueDate: due, category: "Bills"); p.isPaid = paid; return p
    }
    func testPlannedRemindersEveAndDayOnlyForFuture() {
        let now = date(2026, 3, 9, hour: 10)
        let r = Reminders.plannedReminders([planned("Insurance", due: date(2026, 3, 12)),
                                            planned("Tomorrow", due: date(2026, 3, 10)),
                                            planned("Today", due: date(2026, 3, 9)),
                                            planned("Paid", due: date(2026, 3, 20), paid: true),
                                            planned("Late", due: date(2026, 3, 1))], now: now, calendar: utc)
        XCTAssertEqual(Set(r.map(\.body)).count, 2)
        let byTitle = Dictionary(grouping: r, by: \.title)
        XCTAssertEqual(byTitle["Insurance"]?.count, 2)
        XCTAssertEqual(byTitle["Tomorrow"]?.count, 1, "9:00 the day before is already past; only the day-of remains")
        XCTAssertNil(byTitle["Today"], "09:00 today has passed")
        XCTAssertNil(byTitle["Paid"]); XCTAssertNil(byTitle["Late"])
    }
    func testBudgetAlertLevels() {
        XCTAssertEqual(Reminders.budgetLevel(fraction: nil), 0)
        XCTAssertEqual(Reminders.budgetLevel(fraction: 0.79), 0)
        XCTAssertEqual(Reminders.budgetLevel(fraction: 0.8), 1)
        XCTAssertEqual(Reminders.budgetLevel(fraction: 1.0), 1)
        XCTAssertEqual(Reminders.budgetLevel(fraction: 1.01), 2)
    }
    func testBudgetAlertFiresOncePerLevelAndRearmsWhenSpendingDrops() {
        let d = UserDefaults(suiteName: "mono-test-\(UUID().uuidString)")!
        let month = MonthKey(year: 2026, month: 3)
        func summary(spent: Int) -> BudgetSummary {
            BudgetSummary(month: month, total: 100_000, spent: spent, lines: [], unbudgetedSpent: 0, daysLeft: 10)
        }
        XCTAssertNil(Reminders.checkBudget(summary(spent: 50_000), defaults: d))
        XCTAssertNotNil(Reminders.checkBudget(summary(spent: 85_000), defaults: d))
        XCTAssertNil(Reminders.checkBudget(summary(spent: 90_000), defaults: d), "same level, no repeat")
        XCTAssertNotNil(Reminders.checkBudget(summary(spent: 110_000), defaults: d), "over is a new level")
        XCTAssertNil(Reminders.checkBudget(summary(spent: 40_000), defaults: d))
        XCTAssertNotNil(Reminders.checkBudget(summary(spent: 85_000), defaults: d), "re-arms after dropping")
    }

    func testRolloverCarriesUnspentButNotOverspend() {
        let prev = MonthKey(year: 2026, month: 2)
        let limits = [BudgetLimit(monthKey: "2026-02", category: "Food", limitCents: 60_000),
                      BudgetLimit(monthKey: "2026-02", category: "Fun", limitCents: 20_000)]
        let txs = [expense(45_000, date(2026, 2, 5), cat: "Food"), expense(25_000, date(2026, 2, 6), cat: "Fun")]
        let r = FinanceEngine.rollover(from: prev, totalLimit: 100_000, limits: limits, transactions: txs, calendar: utc)
        XCTAssertEqual(r.limits.first { $0.category == "Food" }?.cents, 75_000, "60k + 15k unspent")
        XCTAssertEqual(r.limits.first { $0.category == "Fun" }?.cents, 20_000, "overspend isn't carried")
        XCTAssertEqual(r.totalCents, 130_000, "100k + 30k left of the total")
    }
    func testRolloverWithoutExplicitTotalHasNoTotal() {
        let r = FinanceEngine.rollover(from: MonthKey(year: 2026, month: 2), totalLimit: nil,
                                       limits: [BudgetLimit(monthKey: "2026-02", category: "Food", limitCents: 10_000)],
                                       transactions: [], calendar: utc)
        XCTAssertNil(r.totalCents)
        XCTAssertEqual(r.limits.first?.cents, 20_000)
    }
}

final class IconAndHistoryTests: XCTestCase {
    func testDefaultIconIsThePrimaryIcon() {
        XCTAssertNil(AppIconChoice.default.alternateName)
        XCTAssertEqual(AppIconChoice(alternateName: nil), .default)
    }
    func testEveryChoiceRoundTripsThroughItsAlternateName() {
        for s in IconStyle.allCases { for c in IconColor.allCases {
            let choice = AppIconChoice(style: s, color: c)
            XCTAssertEqual(AppIconChoice(alternateName: choice.alternateName), choice)
        } }
        XCTAssertEqual(AppIconChoice.allAlternateNames.count, IconStyle.allCases.count * IconColor.allCases.count - 1)
        XCTAssertEqual(Set(AppIconChoice.allAlternateNames).count, AppIconChoice.allAlternateNames.count)
    }
    func testUnknownAlternateNameFallsBackToDefault() {
        XCTAssertEqual(AppIconChoice(alternateName: "icon-neon-pink"), .default)
        XCTAssertEqual(AppIconChoice(alternateName: "garbage"), .default)
    }
    func testIconArtworkShipsInTheBundleForEveryChoice() {
        for s in IconStyle.allCases { for c in IconColor.allCases {
            XCTAssertNotNil(UIImage(named: AppIconChoice(style: s, color: c).previewName, in: Bundle.main, with: nil),
                            "missing preview for \(s.rawValue)-\(c.rawValue)")
        } }
    }
    func testAlternateIconsAreDeclaredInTheAppsInfoPlist() throws {
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let alternates = (icons?["CFBundleAlternateIcons"] as? [String: Any]) ?? [:]
        XCTAssertEqual(Set(alternates.keys), Set(AppIconChoice.allAlternateNames))
    }
    func testVersionHistoryIsNewestFirstAndMatchesTheAppVersion() {
        let versions = VersionHistory.releases.map(\.version)
        XCTAssertEqual(versions, versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending })
        XCTAssertEqual(Set(versions).count, versions.count)
        XCTAssertEqual(versions.first, VersionHistory.current, "add a release entry whenever MARKETING_VERSION changes")
        XCTAssertTrue(VersionHistory.releases.allSatisfy { !$0.notes.isEmpty })
    }
}

final class CSVLoadTests: XCTestCase {
    private func tmp(_ name: String, _ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)-\(name)")
        try data.write(to: url); return url
    }
    func testLoadReadsAFilePickedFromDisk() throws {
        let url = try tmp("s.csv", Data("\u{FEFF}Date,Description,Amount\n2026-03-02,Taxi,-9.00\n".utf8))
        XCTAssertEqual(try CSVImport.load(from: url), [["Date", "Description", "Amount"], ["2026-03-02", "Taxi", "-9.00"]])
    }
    func testLoadRejectsEmptyAndOversizedFiles() throws {
        XCTAssertThrowsError(try CSVImport.load(from: try tmp("e.csv", Data())))
        XCTAssertThrowsError(try CSVImport.load(from: try tmp("big.csv", Data(count: CSVImport.maxBytes + 1))))
    }
}

final class ThemeTests: XCTestCase {
    private func store() -> ThemeStore { ThemeStore(defaults: UserDefaults(suiteName: "mono-theme-\(UUID().uuidString)")!) }

    // MARK: colour maths
    func testContrastMatchesWCAGReferenceValues() {
        XCTAssertEqual(ColorMath.contrast(0x000000, 0xFFFFFF), 21, accuracy: 0.01)
        XCTAssertEqual(ColorMath.contrast(0x777777, 0xFFFFFF), 4.48, accuracy: 0.02)
        XCTAssertEqual(ColorMath.contrast(0x336699, 0x336699), 1, accuracy: 0.001)
    }
    func testMixAndOnColor() {
        XCTAssertEqual(ColorMath.mix(0x000000, 0xFFFFFF, 0.5), 0x808080)
        XCTAssertEqual(ColorMath.mix(0x102030, 0xFFFFFF, 0), 0x102030)
        XCTAssertEqual(ColorMath.onColor(for: 0x101010), 0xFFFFFF)
        XCTAssertEqual(ColorMath.onColor(for: 0xF0F0F0), 0x1A1A1A)
    }

    // MARK: the three curated palettes are readable in both modes
    func testEveryPresetMeetsContrastTargetsInLightAndDark() {
        XCTAssertEqual(ThemePalette.presets.map(\.name), ["Sage & Cream", "Warm Minimal", "Midnight Elegance"])
        for p in ThemePalette.presets {
            for (mode, c) in [("light", p.light), ("dark", p.dark)] {
                let tag = "\(p.name) \(mode)"
                XCTAssertGreaterThanOrEqual(ColorMath.contrast(c.text, c.background), 4.5, "\(tag) text/background")
                XCTAssertGreaterThanOrEqual(ColorMath.contrast(c.text, c.surface), 4.5, "\(tag) text/surface")
                XCTAssertGreaterThanOrEqual(ColorMath.contrast(c.textSecondary, c.background), 4.5, "\(tag) secondary text")
                XCTAssertGreaterThanOrEqual(ColorMath.contrast(c.textSecondary, c.surface), 4.5, "\(tag) secondary text on cards")
                XCTAssertGreaterThanOrEqual(ColorMath.contrast(c.textTertiary, c.background), 3.0, "\(tag) tertiary text")
                XCTAssertGreaterThanOrEqual(ColorMath.contrast(c.accent, c.surface), 3.0, "\(tag) accent")
                XCTAssertGreaterThanOrEqual(ColorMath.contrast(c.onPrimary, c.primary), 4.5, "\(tag) text on primary")
                XCTAssertNotEqual(c.surface, c.background, "\(tag) cards must be distinguishable")
            }
        }
    }
    func testNoPresetColourIsNeonOrOverSaturated() {
        // Chroma (max channel − min channel) measures colourfulness without HSV's exaggeration of dark tones.
        // Neon green 39FF14 scores 0.89 and pure red 1.0; these palettes sit well under 0.30.
        func chroma(_ hex: UInt32) -> Double { let c = ColorMath.components(hex); return max(c.r, c.g, c.b) - min(c.r, c.g, c.b) }
        XCTAssertGreaterThan(chroma(0x39FF14), 0.8, "the yardstick does flag neon")
        for p in ThemePalette.presets { for c in [p.light, p.dark] {
            for hex in [c.primary, c.secondary, c.background, c.surface, c.accent, c.text] {
                XCTAssertLessThan(chroma(hex), 0.30, "\(p.name) has an over-colourful value \(String(hex, radix: 16))")
            }
        } }
    }

    // MARK: store
    func testDefaultsAndSelection() {
        let s = store()
        XCTAssertEqual(s.selected, .sageCream)
        s.select("midnight-elegance")
        XCTAssertEqual(s.active.name, "Midnight Elegance")
        s.select("does-not-exist")
        XCTAssertEqual(s.active.id, "midnight-elegance", "unknown ids are ignored")
    }
    func testEditingAPresetMakesACopyAndNeverChangesThePreset() {
        let s = store()
        s.edit { $0.light.accent = 0x123456 }
        XCTAssertTrue(s.hasDraft)
        XCTAssertEqual(s.active.light.accent, 0x123456)
        XCTAssertTrue(s.active.id.hasPrefix("custom-"))
        XCTAssertEqual(s.active.name, "My palette")
        XCTAssertEqual(ThemePalette.presets.first { $0.id == "sage-cream" }, .sageCream)
        s.discardDraft()
        XCTAssertEqual(s.active, .sageCream, "discarding restores the palette")
    }
    func testSavingKeepsTheCustomPaletteAcrossRelaunch() {
        let suite = "mono-theme-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        let s = ThemeStore(defaults: d)
        s.edit { $0.dark.background = 0x0A0A0A }
        s.saveDraft(name: "  Evening  ")
        s.setGlass(0.2)
        let again = ThemeStore(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(again.selected.name, "Evening")
        XCTAssertEqual(again.selected.dark.background, 0x0A0A0A)
        XCTAssertEqual(again.glass, 0.2, accuracy: 0.0001)
        XCTAssertFalse(again.hasDraft, "an unsaved draft is never persisted")
    }
    func testNamesAreUniqueAndDeleteFallsBackToDefault() {
        let s = store()
        s.edit { $0.light.text = 0x111111 }; s.saveDraft()
        s.select("sage-cream")
        s.edit { $0.light.text = 0x222222 }
        XCTAssertEqual(s.active.name, "My palette 2")
        s.saveDraft()
        let id = s.selected.id
        s.delete(id)
        XCTAssertEqual(s.selected, .sageCream)
        XCTAssertEqual(s.saved.custom.count, 1)
        s.delete("sage-cream")
        XCTAssertEqual(s.palettes.count, 4, "presets can't be deleted")
    }
    func testDuplicateAndReset() {
        let s = store()
        s.duplicate("warm-minimal")
        XCTAssertEqual(s.selected.name, "Warm Minimal copy")
        XCTAssertEqual(s.selected.light, ThemePalette.warmMinimal.light)
        s.setGlass(1)
        s.resetAll()
        XCTAssertEqual(s.selected, .sageCream); XCTAssertTrue(s.saved.custom.isEmpty)
        XCTAssertEqual(s.glass, ThemeStore.defaultGlass, accuracy: 0.0001)
    }
    func testGlassIsClampedAndCodableRoundTrips() throws {
        let s = store()
        s.setGlass(7); XCTAssertEqual(s.glass, 1)
        s.setGlass(-3); XCTAssertEqual(s.glass, 0)
        let data = try JSONEncoder().encode(ThemeStore.Saved(selectedID: "x", custom: [.warmMinimal], glass: 0.4))
        XCTAssertEqual(try JSONDecoder().decode(ThemeStore.Saved.self, from: data).custom, [.warmMinimal])
    }

    // MARK: glass intensity
    func testGlassGetsMoreTransparentAndMoreReflectiveAsIntensityRises() {
        for dark in [false, true] {
            var last = GlassParameters.make(intensity: 0, dark: dark)
            XCTAssertGreaterThanOrEqual(last.solidOpacity, 0.99, "subtle glass is nearly solid")
            for step in stride(from: 0.1, through: 1.0, by: 0.1) {
                let g = GlassParameters.make(intensity: step, dark: dark)
                XCTAssertLessThan(g.solidOpacity, last.solidOpacity)
                XCTAssertGreaterThan(g.materialOpacity, last.materialOpacity)
                XCTAssertGreaterThan(g.sheen, last.sheen)
                XCTAssertGreaterThan(g.edge, last.edge)
                XCTAssertGreaterThanOrEqual(g.materialTier, last.materialTier)
                last = g
            }
            XCTAssertEqual(GlassParameters.make(intensity: 1, dark: dark).materialTier, 2)
        }
    }
}
