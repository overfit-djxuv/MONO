import Foundation

/// Balances across accounts. Pure functions: every number the app shows for "how much money do I have" comes from here.
enum AccountEngine {
    /// The account used for records created before accounts existed, and the default for new entries.
    static func defaultAccount(_ accounts: [Account]) -> Account? {
        let ordered = accounts.sorted { ($0.sortOrder, $0.createdAt) < ($1.sortOrder, $1.createdAt) }
        return ordered.first { !$0.isArchived } ?? ordered.first
    }

    /// Balance in the account's own currency:
    /// opening + income − expenses − transfers out + transfers in − money moved into goals from this account.
    /// Records with no account belong to the default account.
    static func balance(of account: Account, defaultID: UUID?, transactions: [TransactionRecord], entries: [GoalEntry]) -> Int {
        var b = account.openingCents
        for t in transactions {
            let from = t.accountID ?? defaultID
            switch t.kind {
            case .income: if from == account.id { b += t.amountCents }
            case .expense: if from == account.id { b -= t.amountCents }
            case .transfer:
                if from == account.id { b -= t.amountCents }
                if t.toAccountID == account.id { b += t.toAmountCents }
            }
        }
        for e in entries where e.affectsCash && (e.accountID ?? defaultID) == account.id { b -= e.accountDelta }
        return b
    }

    struct Overview: Equatable {
        /// Each account's balance in its own currency.
        var balances: [UUID: Int]
        /// Sum of every convertible account, in the reporting currency.
        var total: Int
        /// Accounts whose currency has no exchange rate yet. Their money is NOT in `total`.
        var unconverted: [UUID]
    }

    /// With no accounts at all (migration hasn't run, or was stopped because its safety copy failed), fall back to the
    /// original single-balance formula using `legacyOpening`, so the figure on screen is never wrong while accounts are missing.
    static func overview(accounts: [Account], transactions: [TransactionRecord], entries: [GoalEntry],
                         converter: CurrencyConverter, legacyOpening: Int = 0) -> Overview {
        guard !accounts.isEmpty else {
            let total = FinanceEngine.availableCash(opening: legacyOpening, transactions: transactions, entries: entries)
            return Overview(balances: [:], total: total, unconverted: [])
        }
        let defaultID = defaultAccount(accounts)?.id
        var balances: [UUID: Int] = [:], total = 0, missing: [UUID] = []
        for a in accounts {
            let b = balance(of: a, defaultID: defaultID, transactions: transactions, entries: entries)
            balances[a.id] = b
            if let converted = converter.convert(b, from: a.currency) { total += converted } else { missing.append(a.id) }
        }
        return Overview(balances: balances, total: total, unconverted: missing)
    }
}

enum Reporting {
    /// Income and expense records expressed in the reporting currency, ready for the existing analytics.
    /// Transfers are left out on purpose. Records in a currency with no exchange rate are not guessed at; they are counted in `skipped`.
    static func reportable(_ txs: [TransactionRecord], accounts: [Account], converter: CurrencyConverter)
        -> (records: [TransactionRecord], skipped: Int) {
        let real = txs.filter { $0.kind != .transfer }
        let foreign = accounts.contains { $0.currencyCode != converter.reporting.code }
        guard foreign else { return (real, 0) }
        let defaultID = AccountEngine.defaultAccount(accounts)?.id
        let byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        var out: [TransactionRecord] = [], skipped = 0
        for t in real {
            guard let account = (t.accountID ?? defaultID).flatMap({ byID[$0] }) else { out.append(t); continue }
            if account.currencyCode == converter.reporting.code { out.append(t); continue }
            guard let cents = converter.convert(t.amountCents, from: account.currency), cents > 0 else { skipped += 1; continue }
            // A detached copy used only for calculation; it is never inserted into the database.
            out.append(TransactionRecord(amountCents: cents, kind: t.kind, category: t.category, date: t.date, title: t.title,
                                         notes: t.notes, sourceID: t.sourceID, id: t.id, accountID: t.accountID,
                                         merchant: t.merchant, tags: t.tags))
        }
        return (out, skipped)
    }
}

enum Tags {
    static let maxTags = 12, maxLength = 24

    /// "Coffee, #Work  coffee" → "coffee,work". Lower-case, de-duplicated, order kept.
    static func normalize(_ text: String) -> String { list(from: text).joined(separator: ",") }

    static func list(from text: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for raw in text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" || $0 == ";" }) {
            let t = raw.trimmingCharacters(in: CharacterSet(charactersIn: "#")).lowercased()
            guard !t.isEmpty else { continue }
            let tag = String(t.prefix(maxLength))
            if seen.insert(tag).inserted { out.append(tag) }
            if out.count == maxTags { break }
        }
        return out
    }
}
