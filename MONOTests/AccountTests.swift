import XCTest
import SwiftData
@testable import MONO

private let myr = Currency.find("MYR"), usd = Currency.find("USD"), jpy = Currency.find("JPY"), kwd = Currency.find("KWD")

private func converter(_ rates: [(String, String, Int)] = [("USD", "MYR", 4_472_500)], reporting: Currency = myr) -> CurrencyConverter {
    CurrencyConverter(reporting: reporting, rates: rates.map { (from: $0.0, to: $0.1, micros: $0.2) })
}
private func account(_ name: String, _ cur: String = "MYR", opening: Int = 0, order: Int = 0) -> Account {
    Account(name: name, kind: .bank, currencyCode: cur, openingCents: opening, sortOrder: order)
}

// MARK: - Currency-specific money

final class CurrencyMoneyTests: XCTestCase {
    func testDigitsPerCurrency() {
        XCTAssertEqual(Money.format(123_456, currency: myr), "RM 1,234.56")
        XCTAssertEqual(Money.format(123_456, currency: jpy), "¥ 123,456", "yen has no minor unit")
        XCTAssertEqual(Money.format(1_234, currency: kwd), "KD 1.234", "dinar has three")
        XCTAssertEqual(Money.format(-5, currency: usd), "−$ 0.05")
    }
    func testParseRespectsDecimalPlaces() {
        XCTAssertEqual(Money.parse("12.5", currency: myr), 1_250)
        XCTAssertNil(Money.parse("12.345", currency: myr), "too many decimals is rejected, not rounded")
        XCTAssertEqual(Money.parse("1,500", currency: jpy), 1_500)
        XCTAssertNil(Money.parse("1500.5", currency: jpy))
        XCTAssertEqual(Money.parse("1.234", currency: kwd), 1_234)
        XCTAssertEqual(Money.editable(1_250, currency: myr), "12.50")
        XCTAssertEqual(Money.editable(1_500, currency: jpy), "1500")
    }
}

final class ConverterTests: XCTestCase {
    func testConvertsWithExplicitRateAndRounds() {
        let c = converter()
        XCTAssertEqual(c.convert(10_000, from: usd), 44_725, "100.00 USD at 4.4725 = RM 447.25")
        XCTAssertEqual(c.convert(1, from: usd), 4, "$0.01 → RM 0.044725 → 0.04")
        XCTAssertEqual(c.convert(3_000, from: myr), 3_000, "reporting currency is unchanged")
        XCTAssertEqual(c.convert(-10_000, from: usd), -44_725)
    }
    func testDifferentMinorUnitsConvertCorrectly() {
        let c = converter([("JPY", "MYR", 29_500), ("KWD", "MYR", 14_500_000)])
        XCTAssertEqual(c.convert(1_000, from: jpy), 2_950, "¥1,000 at 0.0295 = RM 29.50")
        XCTAssertEqual(c.convert(1_234, from: kwd), 1_789, "1.234 KWD at 14.5 = RM 17.893 → 17.89")
        let toYen = CurrencyConverter(reporting: jpy, rates: [(from: "MYR", to: "JPY", micros: 33_900_000)])
        XCTAssertEqual(toYen.convert(10_000, from: myr), 3_390, "RM 100.00 at 33.9 yen = ¥3,390")
    }
    func testMissingRateIsNilNeverGuessed() {
        let c = converter()
        XCTAssertNil(c.convert(100, from: Currency.find("EUR")))
        XCTAssertFalse(c.hasRate(for: Currency.find("EUR")))
        XCTAssertTrue(c.hasRate(for: usd)); XCTAssertTrue(c.hasRate(for: myr))
    }
    func testInverseRateIsUsedWhenOnlyTheOtherDirectionWasEntered() {
        let c = CurrencyConverter(reporting: myr, rates: [(from: "MYR", to: "USD", micros: 223_600)])   // 1 RM = 0.2236 USD
        let micros = c.micros(for: usd)!
        XCTAssertEqual(Double(micros) / 1e6, 4.4723, accuracy: 0.0002)
    }
    func testImpliedRateOfATransferAndRateText() {
        XCTAssertEqual(CurrencyConverter.impliedMicros(fromMinor: 10_000, from: usd, toMinor: 44_725, to: myr), 4_472_500)
        XCTAssertNil(CurrencyConverter.impliedMicros(fromMinor: 0, from: usd, toMinor: 1, to: myr))
        XCTAssertEqual(CurrencyConverter.parseRate("4.4725"), 4_472_500)
        XCTAssertEqual(CurrencyConverter.parseRate("4,47"), 4_470_000)
        XCTAssertNil(CurrencyConverter.parseRate("0")); XCTAssertNil(CurrencyConverter.parseRate("abc"))
        XCTAssertEqual(CurrencyConverter.formatRate(4_472_500), "4.4725")
    }
}

// MARK: - Balances and transfers

@MainActor
final class AccountBalanceTests: XCTestCase {
    var ctx: ModelContext!
    override func setUpWithError() throws { (_, ctx) = try makeContext() }

    private func tx(_ kind: TxKind, _ cents: Int, _ acct: Account?, day: Int = 5) -> TransactionRecord {
        let t = TransactionRecord(amountCents: cents, kind: kind, category: kind == .transfer ? "" : "Food",
                                  date: date(2026, 3, day), title: "", accountID: acct?.id)
        ctx.insert(t); return t
    }

    func testSingleAccountMatchesTheOldAvailableCashFormula() throws {
        let main = account("Main", opening: 100_000); ctx.insert(main)
        let txs = [tx(.income, 500_000, main), tx(.expense, 12_345, main), tx(.expense, 700, main)]
        let e = GoalEntry(goalID: UUID(), amountCents: 50_000, date: date(2026, 3, 6)); e.accountID = main.id; ctx.insert(e)
        let new = AccountEngine.overview(accounts: [main], transactions: txs, entries: [e], converter: converter())
        let old = FinanceEngine.availableCash(opening: 100_000, transactions: txs, entries: [e])
        XCTAssertEqual(new.total, old)
        XCTAssertEqual(new.total, 100_000 + 500_000 - 12_345 - 700 - 50_000)
    }
    func testTransferMovesMoneyWithoutCreatingIncomeOrSpending() throws {
        let bank = account("Bank", opening: 200_000, order: 0), cash = account("Cash", opening: 10_000, order: 1)
        [bank, cash].forEach(ctx.insert)
        let t = try Ledger.createTransfer(from: bank, to: cash, sentCents: 50_000, receivedCents: 50_000, date: date(2026, 3, 5), in: ctx)
        let all = [t]
        let o = AccountEngine.overview(accounts: [bank, cash], transactions: all, entries: [], converter: converter())
        XCTAssertEqual(o.balances[bank.id], 150_000); XCTAssertEqual(o.balances[cash.id], 60_000)
        XCTAssertEqual(o.total, 210_000, "total money is unchanged")
        let month = MonthKey(year: 2026, month: 3)
        XCTAssertEqual(FinanceEngine.totals(all, in: month, calendar: utc).income, 0)
        XCTAssertEqual(FinanceEngine.totals(all, in: month, calendar: utc).expense, 0)
        let s = FinanceEngine.monthlySummaries(all, range: [month], calendar: utc)[0]
        XCTAssertEqual(s.income, 0); XCTAssertEqual(s.expense, 0); XCTAssertEqual(s.recordCount, 0)
        XCTAssertEqual(FinanceEngine.availableCash(opening: 0, transactions: all, entries: []), 0)
        XCTAssertEqual(FinanceEngine.expensesByCategory(all, in: month...month, calendar: utc).count, 0)
        XCTAssertTrue(Reporting.reportable(all, accounts: [bank, cash], converter: converter()).records.isEmpty)
    }
    func testCrossCurrencyTransferKeepsTotalWorthUnderTheEnteredRate() throws {
        let bank = account("Bank", opening: 500_000), wallet = account("USD wallet", "USD", order: 1)
        [bank, wallet].forEach(ctx.insert)
        let t = try Ledger.createTransfer(from: bank, to: wallet, sentCents: 44_725, receivedCents: 10_000, date: date(2026, 3, 5), in: ctx)
        let o = AccountEngine.overview(accounts: [bank, wallet], transactions: [t], entries: [], converter: converter())
        XCTAssertEqual(o.balances[bank.id], 455_275); XCTAssertEqual(o.balances[wallet.id], 10_000)
        XCTAssertEqual(o.total, 500_000, "RM 447.25 became $100.00, worth RM 447.25 at the same rate")
    }
    func testAccountWithoutARateIsExcludedAndFlaggedNeverGuessed() throws {
        let bank = account("Bank", opening: 100_000), eur = account("Euro", "EUR", opening: 50_000, order: 1)
        let o = AccountEngine.overview(accounts: [bank, eur], transactions: [], entries: [], converter: converter())
        XCTAssertEqual(o.total, 100_000)
        XCTAssertEqual(o.unconverted, [eur.id])
        XCTAssertEqual(o.balances[eur.id], 50_000, "its own balance is still shown, in its own currency")
    }
    func testRecordsWithoutAnAccountBelongToTheDefaultAccount() {
        let a = account("A", opening: 0, order: 0), b = account("B", opening: 0, order: 1)
        let income = TransactionRecord(amountCents: 1_000, kind: .income, category: "Salary", date: date(2026, 3, 1), title: "")
        let o = AccountEngine.overview(accounts: [b, a], transactions: [income], entries: [], converter: converter())
        XCTAssertEqual(o.balances[a.id], 1_000); XCTAssertEqual(o.balances[b.id], 0)
        XCTAssertEqual(AccountEngine.defaultAccount([b, a])?.id, a.id)
    }
    func testWithNoAccountsTheOldFormulaKeepsTheFigureCorrect() {
        let income = TransactionRecord(amountCents: 10_000, kind: .income, category: "Salary", date: date(2026, 3, 1), title: "")
        let o = AccountEngine.overview(accounts: [], transactions: [income], entries: [], converter: converter(), legacyOpening: 5_000)
        XCTAssertEqual(o.total, 15_000)
    }
    func testGoalContributionsLeaveTheChosenAccountOnly() {
        let a = account("A", opening: 100_000, order: 0), b = account("B", opening: 100_000, order: 1)
        let e = GoalEntry(goalID: UUID(), amountCents: 30_000, date: date(2026, 3, 1)); e.accountID = b.id
        let o = AccountEngine.overview(accounts: [a, b], transactions: [], entries: [e], converter: converter())
        XCTAssertEqual(o.balances[a.id], 100_000); XCTAssertEqual(o.balances[b.id], 70_000)
        let notFromCash = GoalEntry(goalID: UUID(), amountCents: 30_000, date: date(2026, 3, 1), affectsCash: false)
        XCTAssertEqual(AccountEngine.overview(accounts: [a], transactions: [], entries: [notFromCash], converter: converter()).total, 100_000)
    }
    func testArchivedAccountsStillCountSoMoneyNeverVanishes() {
        let a = account("A", opening: 100_000, order: 0), old = account("Old", opening: 40_000, order: 1); old.isArchived = true
        XCTAssertEqual(AccountEngine.overview(accounts: [a, old], transactions: [], entries: [], converter: converter()).total, 140_000)
    }

    // MARK: validation
    func testTransferRules() throws {
        let a = account("A", opening: 100_000), b = account("B", order: 1), usdW = account("W", "USD", order: 2)
        [a, b, usdW].forEach(ctx.insert)
        XCTAssertThrowsError(try Ledger.createTransfer(from: a, to: a, sentCents: 100, receivedCents: 100, date: .now, in: ctx)) {
            XCTAssertEqual($0 as? Ledger.LedgerError, .sameAccount) }
        XCTAssertThrowsError(try Ledger.createTransfer(from: a, to: b, sentCents: 0, receivedCents: 0, date: .now, in: ctx)) {
            XCTAssertEqual($0 as? Ledger.LedgerError, .invalidAmount) }
        XCTAssertThrowsError(try Ledger.createTransfer(from: a, to: b, sentCents: 100, receivedCents: 99, date: .now, in: ctx)) {
            XCTAssertEqual($0 as? Ledger.LedgerError, .transferAmountMismatch) }
        b.isArchived = true
        XCTAssertThrowsError(try Ledger.createTransfer(from: a, to: b, sentCents: 100, receivedCents: 100, date: .now, in: ctx)) {
            XCTAssertEqual($0 as? Ledger.LedgerError, .archivedAccount) }
        XCTAssertNoThrow(try Ledger.createTransfer(from: a, to: usdW, sentCents: 4_472, receivedCents: 1_000, date: .now, in: ctx))
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<TransactionRecord>()), 1, "failed transfers leave nothing behind")
    }
    func testDuplicateWarning() {
        let main = account("Main"), other = account("Other", order: 1)
        let existing = TransactionRecord(amountCents: 1_250, kind: .expense, category: "Food", date: date(2026, 3, 5, hour: 9), title: "Lunch", accountID: main.id)
        func dupe(_ cents: Int = 1_250, day: Int = 5, title: String = "lunch", acct: UUID? = nil, id: UUID? = nil) -> Bool {
            Ledger.possibleDuplicate(kind: .expense, cents: cents, date: date(2026, 3, day, hour: 20), title: title, accountID: acct ?? main.id,
                                     defaultAccountID: main.id, excluding: id, in: [existing], calendar: utc) != nil
        }
        XCTAssertTrue(dupe())
        XCTAssertFalse(dupe(1_251)); XCTAssertFalse(dupe(day: 6)); XCTAssertFalse(dupe(title: "Dinner")); XCTAssertFalse(dupe(acct: other.id))
        XCTAssertFalse(dupe(id: existing.id), "editing a record doesn't flag itself")
    }
    func testTags() {
        XCTAssertEqual(Tags.normalize("Coffee, #Work  coffee;TRAVEL"), "coffee,work,travel")
        XCTAssertEqual(Tags.list(from: "  ,, "), [])
        XCTAssertEqual(Tags.list(from: String(repeating: "a", count: 40)).first?.count, Tags.maxLength)
        XCTAssertEqual(Tags.list(from: (1...30).map { "t\($0)" }.joined(separator: ",")).count, Tags.maxTags)
    }
    func testForeignCurrencyRecordsAreConvertedForReportsAndNeverMixedBlindly() {
        let main = account("Main"), usdW = account("USD", "USD", order: 1)
        let spend = TransactionRecord(amountCents: 2_000, kind: .expense, category: "Food", date: date(2026, 3, 5), title: "", accountID: usdW.id)
        let local = TransactionRecord(amountCents: 1_000, kind: .expense, category: "Food", date: date(2026, 3, 5), title: "", accountID: main.id)
        let withRate = Reporting.reportable([spend, local], accounts: [main, usdW], converter: converter())
        XCTAssertEqual(withRate.records.map(\.amountCents).sorted(), [1_000, 8_945], "$20.00 × 4.4725 = RM 89.45")
        XCTAssertEqual(withRate.skipped, 0)
        let noRate = Reporting.reportable([spend, local], accounts: [main, usdW], converter: converter([]))
        XCTAssertEqual(noRate.records.map(\.amountCents), [1_000]); XCTAssertEqual(noRate.skipped, 1)
        XCTAssertEqual(spend.amountCents, 2_000, "the stored record is never altered")
        let same = Reporting.reportable([local], accounts: [main], converter: converter())
        XCTAssertTrue(same.records.first === local, "single-currency users get the original records, no copies")
    }
}

// MARK: - Migration and backup

@MainActor
final class AccountMigrationTests: XCTestCase {
    var ctx: ModelContext!
    var defaults: UserDefaults!
    override func setUpWithError() throws {
        (_, ctx) = try makeContext()
        defaults = UserDefaults(suiteName: "mono-mig-\(UUID().uuidString)")!
        try? FileManager.default.removeItem(at: AccountMigration.safetyDirectory)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: AccountMigration.safetyDirectory) }

    private func seedLegacy() throws -> (txs: [TransactionRecord], entry: GoalEntry) {
        defaults.set(122_000, forKey: "openingBalanceCents")
        let a = TransactionRecord(amountCents: 520_000, kind: .income, category: "Salary", date: date(2026, 3, 1), title: "Pay")
        let b = TransactionRecord(amountCents: 1_850, kind: .expense, category: "Food", date: date(2026, 3, 3), title: "Lunch")
        let goal = SavingsGoal(name: "Trip", kind: .general, symbol: "target"); ctx.insert(goal)
        let e = GoalEntry(goalID: goal.id, amountCents: 100_000, date: date(2026, 3, 4))
        [a, b].forEach(ctx.insert); ctx.insert(e); try ctx.save()
        return ([a, b], e)
    }

    func testLegacyDataGainsAMainAccountAndTheBalanceIsUnchanged() throws {
        let (txs, entry) = try seedLegacy()
        let before = FinanceEngine.availableCash(opening: 122_000, transactions: txs, entries: [entry])
        XCTAssertTrue(try AccountMigration.run(in: ctx, defaults: defaults))
        let accounts = try ctx.fetch(FetchDescriptor<Account>())
        XCTAssertEqual(accounts.count, 1); XCTAssertEqual(accounts[0].name, "Main account")
        XCTAssertEqual(accounts[0].openingCents, 122_000); XCTAssertEqual(accounts[0].currencyCode, "MYR")
        XCTAssertTrue(txs.allSatisfy { $0.accountID == accounts[0].id }); XCTAssertEqual(entry.accountID, accounts[0].id)
        let after = AccountEngine.overview(accounts: accounts, transactions: txs, entries: [entry], converter: converter()).total
        XCTAssertEqual(after, before, "migrating must not move a single sen")
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<TransactionRecord>()), 2, "no records added or lost")
    }
    func testASafetyBackupIsWrittenAndValidatedBeforeAnythingChanges() throws {
        _ = try seedLegacy()
        try AccountMigration.run(in: ctx, defaults: defaults)
        let files = try FileManager.default.contentsOfDirectory(at: AccountMigration.safetyDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let snap = try BackupService.decode(Data(contentsOf: files[0]))
        XCTAssertEqual(snap.transactions.count, 2); XCTAssertEqual(snap.goalEntries.count, 1)
        XCTAssertEqual(snap.openingBalanceCents, 122_000)
        XCTAssertTrue(snap.accounts?.isEmpty ?? true, "it captured the data as it was before accounts existed")
    }
    func testRunningTwiceChangesNothing() throws {
        _ = try seedLegacy()
        XCTAssertTrue(try AccountMigration.run(in: ctx, defaults: defaults))
        XCTAssertFalse(try AccountMigration.run(in: ctx, defaults: defaults))
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Account>()), 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: AccountMigration.safetyDirectory, includingPropertiesForKeys: nil).count, 1)
    }
    func testNewRecordsWithoutAnAccountGetStampedLater() throws {
        _ = try seedLegacy(); try AccountMigration.run(in: ctx, defaults: defaults)
        let late = TransactionRecord(amountCents: 100, kind: .expense, category: "Food", date: .now, title: ""); ctx.insert(late)
        XCTAssertTrue(try AccountMigration.run(in: ctx, defaults: defaults))
        XCTAssertNotNil(late.accountID)
    }
    func testAnEmptyAppGetsAMainAccountWithoutASnapshot() throws {
        XCTAssertTrue(try AccountMigration.run(in: ctx, defaults: defaults))
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<Account>()), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AccountMigration.safetyDirectory.path))
    }
}

@MainActor
final class BackupV2Tests: XCTestCase {
    func testAccountsTransfersRatesAndNewFieldsRoundTrip() throws {
        let (_, src) = try makeContext()
        let bank = account("Bank", opening: 100_000), usdW = account("Wallet", "USD", opening: 5_000, order: 1)
        [bank, usdW].forEach(src.insert)
        let t = try Ledger.createTransfer(from: bank, to: usdW, sentCents: 44_725, receivedCents: 10_000, date: date(2026, 3, 5), title: "Top up", in: src)
        let e = TransactionRecord(amountCents: 900, kind: .expense, category: "Food", date: date(2026, 3, 6), title: "Latte",
                                  accountID: bank.id, merchant: "Kopi", tags: "coffee,work")
        src.insert(e)
        let g = GoalEntry(goalID: UUID(), amountCents: 100, date: date(2026, 3, 7)); g.accountID = bank.id; src.insert(g)
        src.insert(ExchangeRate(fromCode: "USD", toCode: "MYR", rateMicros: 4_472_500))
        let goal = SavingsGoal(name: "G", kind: .general, symbol: "target"); goal.id = g.goalID; src.insert(goal)
        try src.save()

        let data = try BackupService.encode(try BackupService.snapshot(context: src, openingBalanceCents: 0, currencySymbol: "RM"))
        let file = try BackupService.decode(data)
        XCTAssertEqual(file.version, 2); XCTAssertEqual(file.accounts?.count, 2); XCTAssertEqual(file.exchangeRates?.count, 1)

        let (_, dst) = try makeContext()
        try BackupService.replaceAll(with: file, in: dst)
        let accounts = try dst.fetch(FetchDescriptor<Account>(sortBy: [SortDescriptor(\.sortOrder)]))
        XCTAssertEqual(accounts.map(\.name), ["Bank", "Wallet"]); XCTAssertEqual(accounts.map(\.currencyCode), ["MYR", "USD"])
        let txs = try dst.fetch(FetchDescriptor<TransactionRecord>())
        let transfer = try XCTUnwrap(txs.first { $0.kind == .transfer })
        XCTAssertEqual(transfer.id, t.id); XCTAssertEqual(transfer.toAmountCents, 10_000); XCTAssertEqual(transfer.toAccountID, usdW.id)
        let latte = try XCTUnwrap(txs.first { $0.title == "Latte" })
        XCTAssertEqual(latte.merchant, "Kopi"); XCTAssertEqual(latte.tags, "coffee,work"); XCTAssertEqual(latte.accountID, bank.id)
        XCTAssertEqual(try dst.fetch(FetchDescriptor<GoalEntry>()).first?.accountID, bank.id)
        XCTAssertEqual(try dst.fetch(FetchDescriptor<ExchangeRate>()).first?.rateMicros, 4_472_500)
    }
    func testAVersion1BackupStillRestoresAndGetsAMainAccount() throws {
        var f = BackupFile(); f.version = 1; f.openingBalanceCents = 122_000
        f.transactions = [.init(id: UUID(), amountCents: 500, kind: "expense", category: "Food", date: date(2026, 3, 1), title: "x", notes: "", sourceID: nil)]
        let data = try BackupService.encode(f)
        let restored = try BackupService.decode(data)
        XCTAssertNil(restored.accounts)
        let (_, ctx) = try makeContext()
        try BackupService.replaceAll(with: restored, in: ctx)
        let acct = try XCTUnwrap(try ctx.fetch(FetchDescriptor<Account>()).first)
        XCTAssertEqual(acct.openingCents, 122_000)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<TransactionRecord>()).first?.accountID, acct.id)
        try? FileManager.default.removeItem(at: AccountMigration.safetyDirectory)
    }
    func testValidationRejectsBrokenAccountReferencesAndTransfers() throws {
        let main = BackupFile.AccountDTO(id: UUID(), name: "Main", kind: "bank", currencyCode: "MYR", openingCents: 0, sortOrder: 0, isArchived: false, createdAt: .now)
        let other = BackupFile.AccountDTO(id: UUID(), name: "B", kind: "cash", currencyCode: "MYR", openingCents: 0, sortOrder: 1, isArchived: false, createdAt: .now)
        func file(_ t: BackupFile.TransactionDTO) -> BackupFile { var f = BackupFile(); f.accounts = [main, other]; f.transactions = [t]; return f }
        func dto(kind: String = "expense", acct: UUID?, to: UUID? = nil, toAmt: Int? = nil) -> BackupFile.TransactionDTO {
            .init(id: UUID(), amountCents: 100, kind: kind, category: "", date: .now, title: "", notes: "", sourceID: nil, accountID: acct, toAccountID: to, toAmountCents: toAmt)
        }
        XCTAssertNoThrow(try BackupService.validate(file(dto(acct: main.id))))
        XCTAssertNoThrow(try BackupService.validate(file(dto(kind: "transfer", acct: main.id, to: other.id, toAmt: 100))))
        XCTAssertThrowsError(try BackupService.validate(file(dto(acct: UUID()))), "unknown account")
        XCTAssertThrowsError(try BackupService.validate(file(dto(kind: "transfer", acct: main.id, to: main.id, toAmt: 100))), "same account")
        XCTAssertThrowsError(try BackupService.validate(file(dto(kind: "transfer", acct: main.id, to: other.id, toAmt: 0))), "no amount received")
        XCTAssertThrowsError(try BackupService.validate(file(dto(kind: "transfer", acct: main.id, to: nil, toAmt: 100))), "no destination")
        var bad = file(dto(acct: main.id)); bad.exchangeRates = [.init(fromCode: "USD", toCode: "USD", rateMicros: 1, updatedAt: .now)]
        XCTAssertThrowsError(try BackupService.validate(bad), "a rate from a currency to itself")
    }
}
