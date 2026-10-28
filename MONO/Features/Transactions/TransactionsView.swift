import SwiftUI
import SwiftData

enum DateRangeFilter: String, CaseIterable, Identifiable {
    case all = "All time", thisMonth = "This month", lastMonth = "Last month", last3 = "Last 3 months", thisYear = "This year"
    var id: String { rawValue }

    func contains(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> Bool {
        let cur = MonthKey(now, calendar: calendar), k = MonthKey(date, calendar: calendar)
        switch self {
        case .all: return true
        case .thisMonth: return k == cur
        case .lastMonth: return k == cur.adding(-1)
        case .last3: return k >= cur.adding(-2) && k <= cur
        case .thisYear: return k.year == cur.year && k <= cur
        }
    }
}

struct TransactionsView: View {
    @Environment(\.modelContext) private var context
    @Environment(ErrorCenter.self) private var errors
    @Query(sort: \TransactionRecord.date, order: .reverse) private var txs: [TransactionRecord]
    @Query private var items: [ShoppingItem]
    @Query private var planned: [PlannedExpense]
    @Query(sort: \MoneyCategory.sortOrder) private var categories: [MoneyCategory]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var rates: [ExchangeRate]

    @State private var search = ""
    @State private var kindFilter: TxKind?
    @State private var categoryFilter: String?
    @State private var accountFilter: UUID?
    @State private var tagFilter: String?
    @State private var range: DateRangeFilter = .all
    @State private var showAdd = false
    @State private var showCSV = false
    @State private var editing: TransactionRecord?
    @State private var pendingDelete: TransactionRecord?

    private var directory: AccountDirectory { AccountDirectory(accounts) }
    private var allTags: [String] { Array(Set(txs.flatMap { Tags.list(from: $0.tags) })).sorted() }
    private var filtersActive: Bool {
        kindFilter != nil || categoryFilter != nil || accountFilter != nil || tagFilter != nil || range != .all
    }

    private var filtered: [TransactionRecord] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let dir = directory
        return txs.filter { t in
            let from = dir.account(t.accountID), to = t.toAccountID.flatMap { dir.byID[$0] }
            return (kindFilter == nil || t.kind == kindFilter)
                && (categoryFilter == nil || t.category == categoryFilter)
                && (accountFilter == nil || from?.id == accountFilter || to?.id == accountFilter)
                && (tagFilter == nil || Tags.list(from: t.tags).contains(tagFilter!))
                && range.contains(t.date)
                && (q.isEmpty || t.title.localizedCaseInsensitiveContains(q)
                    || t.category.localizedCaseInsensitiveContains(q)
                    || t.merchant.localizedCaseInsensitiveContains(q)
                    || t.tags.localizedCaseInsensitiveContains(q)
                    || t.notes.localizedCaseInsensitiveContains(q)
                    || (from?.name.localizedCaseInsensitiveContains(q) ?? false)
                    || (to?.name.localizedCaseInsensitiveContains(q) ?? false))
        }
    }

    private var grouped: [(day: Date, items: [TransactionRecord])] {
        let cal = Calendar.current
        let d = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.date) }
        return d.keys.sorted(by: >).map { ($0, d[$0]!.sorted { $0.date > $1.date }) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if txs.isEmpty {
                    VStack(spacing: 14) {
                        EmptyState(symbol: "list.bullet.rectangle", title: "No transactions yet",
                                   message: "Add income and expenses as they happen. Everything stays on this iPhone.",
                                   actionTitle: "Add transaction") { showAdd = true }
                        Button("Import from a CSV file") { showCSV = true }
                            .font(.subheadline).foregroundStyle(Theme.accent)
                            .buttonStyle(PressableStyle())
                    }
                    .frame(maxHeight: .infinity)
                } else if filtered.isEmpty {
                    EmptyState(symbol: "magnifyingglass", title: "No matches",
                               message: "Nothing fits the current search or filters.",
                               actionTitle: filtersActive ? "Clear filters" : nil) {
                        kindFilter = nil; categoryFilter = nil; accountFilter = nil; tagFilter = nil; range = .all
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    list
                }
            }
            .monoScreen()
            .navigationTitle("Transactions")
            .searchable(text: $search, prompt: "Search transactions")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { filterMenu }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showCSV = true } label: { Image(systemName: "square.and.arrow.down") }
                        .accessibilityLabel("Import transactions from CSV")
                        .accessibilityIdentifier("importCSV")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add transaction")
                        .accessibilityIdentifier("addTransaction")
                }
            }
            .sheet(isPresented: $showAdd) { TransactionForm(editing: nil) }
            .sheet(item: $editing) { TransactionForm(editing: $0) }
            .csvImport(isPresented: $showCSV)
            .confirmationDialog("Delete this transaction?", isPresented: Binding(get: { pendingDelete != nil },
                                                                                 set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible, presenting: pendingDelete) { t in
                Button("Delete", role: .destructive) {
                    do { try Ledger.delete(t, items: items, planned: planned, in: context); Haptics.tap() }
                    catch { errors.report(error, doing: "Couldn’t delete") }
                }
            } message: { t in
                Text("\(t.title.isEmpty ? (t.kind == .transfer ? "Transfer" : t.category) : t.title) · \(Money.format(t.amountCents, currency: directory.currency(of: t))). Balances update immediately.")
            }
        }
    }

    private var list: some View {
        List {
            summaryRow
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 10, trailing: 6))
            ForEach(grouped, id: \.day) { group in
                Section {
                    ForEach(group.items) { t in
                        Button { editing = t } label: { TransactionRow(tx: t, symbol: categories.symbol(for: t.category), directory: directory) }
                            .buttonStyle(PressableStyle())
                            .listRowBackground(GlassRowBackground())
                            .listRowSeparatorTint(Theme.line)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    do { try Ledger.repeatTransaction(t, in: context); Haptics.success() }
                                    catch { errors.report(error, doing: "Couldn’t repeat") }
                                } label: { Label("Repeat today", systemImage: "arrow.counterclockwise") }
                                    .tint(Theme.accent)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { pendingDelete = t } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                } header: {
                    Text(group.day.dayTitle).font(.footnote.weight(.medium)).foregroundStyle(Theme.inkSecondary)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var summaryRow: some View {
        // Totals are in the reporting currency; foreign-currency records are converted with your rates, transfers are excluded.
        let b = Books(accounts: accounts, rates: rates, transactions: filtered, entries: [])
        let income = b.reported.filter { $0.kind == .income }.reduce(0) { $0 + $1.amountCents }
        let expense = b.reported.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amountCents }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Metric(label: "Income", value: Money.format(income), tint: Theme.income)
                Metric(label: "Expenses", value: Money.format(expense))
                Metric(label: "\(filtered.count) \(filtered.count == 1 ? "item" : "items")", value: Money.format(income - expense, signed: true),
                       tint: Theme.inkSecondary)
            }
            if b.skipped > 0 {
                Text("\(b.skipped) \(b.skipped == 1 ? "record is" : "records are") in a currency with no exchange rate, so \(b.skipped == 1 ? "it isn’t" : "they aren’t") in these totals.")
                    .font(.caption).foregroundStyle(Theme.warning)
            }
        }
        .padding(.vertical, 6)
    }

    private var filterMenu: some View {
        Menu {
            Picker("Type", selection: $kindFilter) {
                Text("All types").tag(TxKind?.none)
                ForEach(TxKind.allCases) { Text($0.label).tag(TxKind?.some($0)) }
            }
            Picker("Period", selection: $range) {
                ForEach(DateRangeFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Category", selection: $categoryFilter) {
                Text("All categories").tag(String?.none)
                ForEach(categories) { Text($0.name).tag(String?.some($0.name)) }
            }
            if directory.showNames {
                Picker("Account", selection: $accountFilter) {
                    Text("All accounts").tag(UUID?.none)
                    ForEach(accounts.filter { !$0.isArchived }) { Text($0.name).tag(UUID?.some($0.id)) }
                }
            }
            if !allTags.isEmpty {
                Picker("Tag", selection: $tagFilter) {
                    Text("All tags").tag(String?.none)
                    ForEach(allTags, id: \.self) { Text("#\($0)").tag(String?.some($0)) }
                }
            }
            if filtersActive {
                Button("Clear filters", role: .destructive) { kindFilter = nil; categoryFilter = nil; accountFilter = nil; tagFilter = nil; range = .all }
            }
        } label: {
            Image(systemName: filtersActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("Filter")
    }
}

struct TransactionRow: View {
    let tx: TransactionRecord
    let symbol: String
    var directory: AccountDirectory? = nil

    private var from: Account? { directory?.account(tx.accountID) }
    private var to: Account? { tx.toAccountID.flatMap { directory?.byID[$0] } }
    private var currency: Currency { from?.currency ?? Money.reporting }
    private var showAccount: Bool { directory?.showNames ?? false }

    private var heading: String {
        if tx.kind == .transfer { return tx.title.isEmpty ? "Transfer" : tx.title }
        if !tx.merchant.isEmpty { return tx.merchant }
        return tx.title.isEmpty ? tx.category : tx.title
    }

    private var subtitle: String {
        let time = tx.date.formatted(date: .omitted, time: .shortened)
        var parts: [String] = []
        if tx.kind == .transfer {
            parts.append("\(from?.name ?? "?") → \(to?.name ?? "?")")
        } else {
            if !tx.merchant.isEmpty, !tx.title.isEmpty { parts.append(tx.title) } else if !tx.title.isEmpty || !tx.merchant.isEmpty { parts.append(tx.category) }
            if showAccount, let from { parts.append(from.name) }
            let tags = Tags.list(from: tx.tags)
            if !tags.isEmpty { parts.append(tags.prefix(3).map { "#\($0)" }.joined(separator: " ")) }
        }
        parts.append(time)
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            CategoryGlyph(symbol: tx.kind == .transfer ? "arrow.left.arrow.right" : symbol,
                          tint: tx.kind == .income ? Theme.income : Theme.inkSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(heading).font(.body).foregroundStyle(Theme.ink).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(Theme.inkSecondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(amountText)
                    .font(.figure(16))
                    .foregroundStyle(tx.kind == .income ? Theme.income : (tx.kind == .transfer ? Theme.inkSecondary : Theme.ink))
                    .lineLimit(1).minimumScaleFactor(0.8)
                if tx.kind == .transfer, let to, to.currencyCode != from?.currencyCode {
                    Text("→ \(Money.format(tx.toAmountCents, currency: to.currency))").font(.caption).foregroundStyle(Theme.inkSecondary)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// Shown in the account's own currency, so a dollar account never looks like ringgit.
    private var amountText: String {
        switch tx.kind {
        case .income: Money.format(tx.amountCents, signed: true, currency: currency)
        case .expense: Money.format(-tx.amountCents, signed: true, currency: currency)
        case .transfer: Money.format(tx.amountCents, currency: currency)
        }
    }
}
