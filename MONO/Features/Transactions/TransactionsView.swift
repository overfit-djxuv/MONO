import SwiftUI
import SwiftData

enum DateRangeFilter: String, CaseIterable, Identifiable {
    case all = "All time", thisMonth = "This month", lastMonth = "Last month", last3 = "Last 3 months", thisYear = "This year", custom = "Custom range"
    var id: String { rawValue }

    func contains(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> Bool {
        let cur = MonthKey(now, calendar: calendar), k = MonthKey(date, calendar: calendar)
        switch self {
        case .all: return true
        case .thisMonth: return k == cur
        case .lastMonth: return k == cur.adding(-1)
        case .last3: return k >= cur.adding(-2) && k <= cur
        case .thisYear: return k.year == cur.year && k <= cur
        case .custom: return true   // bounds live with the screen that picked them
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
    @State private var range: DateRangeFilter = .thisMonth
    @State private var customFrom = Calendar.current.date(byAdding: .month, value: -1, to: .now) ?? .now
    @State private var customTo = Date.now
    @State private var showCustom = false
    @State private var minAmount: Int?
    @State private var maxAmount: Int?
    @State private var showAmount = false
    @State private var detail: TransactionRecord?
    @Query private var receipts: [Receipt]
    @State private var showAdd = false
    @State private var showCSV = false
    @State private var editing: TransactionRecord?
    @State private var pendingDelete: TransactionRecord?

    private var directory: AccountDirectory { AccountDirectory(accounts) }
    private var allTags: [String] { Array(Set(txs.flatMap { Tags.list(from: $0.tags) })).sorted() }
    private var filtersActive: Bool {
        kindFilter != nil || categoryFilter != nil || accountFilter != nil || tagFilter != nil || minAmount != nil || maxAmount != nil || range != .thisMonth
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
                && (minAmount == nil || t.amountCents >= minAmount!) && (maxAmount == nil || t.amountCents <= maxAmount!)
                && (range == .custom ? (Calendar.current.startOfDay(for: customFrom)...Calendar.current.startOfDay(for: customTo).addingTimeInterval(86_399)).contains(t.date) : range.contains(t.date))
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
                               message: range == .all || filtersActive ? "Nothing fits the current search or filters." : "Nothing recorded in \(range.rawValue.lowercased()).",
                               actionTitle: "Show all time") {
                        clearFilters(); range = .all; search = ""
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    list
                }
            }
            .monoScreen()
            .navigationDestination(item: $detail) { t in
                TransactionDetailView(tx: t, directory: directory, symbol: categories.symbol(for: t.category),
                                      isDuplicate: duplicateIDs.contains(t.id), receipt: receipts.first { $0.transactionID == t.id })
            }
            .navigationTitle("Transactions")
            .searchable(text: $search, prompt: "Search transactions")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { filterMenu }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add transaction")
                        .accessibilityIdentifier("addTransaction")
                }
            }
            .sheet(isPresented: $showAdd) { TransactionForm(editing: nil) }
            .sheet(item: $editing) { TransactionForm(editing: $0) }
            .csvImport(isPresented: $showCSV)
            .sheet(isPresented: $showCustom) { customRangeSheet }
            .sheet(isPresented: $showAmount) { amountSheet }
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

    /// Records that look like the same purchase entered twice: same type, amount, day, account and name.
    private var duplicateIDs: Set<UUID> {
        let cal = Calendar.current
        let groups = Dictionary(grouping: txs.filter { $0.kind != .transfer }) { t in
            "\(t.kindRaw)|\(t.amountCents)|\(cal.startOfDay(for: t.date).timeIntervalSince1970)|\(t.accountID?.uuidString ?? "")|\((t.merchant.isEmpty ? t.title : t.merchant).lowercased())"
        }
        return Set(groups.values.filter { $0.count > 1 }.flatMap { $0.map(\.id) })
    }

    private func clearFilters() { kindFilter = nil; categoryFilter = nil; accountFilter = nil; tagFilter = nil; minAmount = nil; maxAmount = nil; range = .thisMonth }

    private var list: some View {
        let dupes = duplicateIDs
        return List {
            VStack(alignment: .leading, spacing: 12) {
                periodPicker
                summaryRow
                activeFilterChips
            }
            .listRowBackground(Color.clear).listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 8, trailing: 4))
            ForEach(grouped, id: \.day) { group in
                Section {
                    ForEach(group.items) { t in
                        Button { detail = t } label: {
                            TransactionRow(tx: t, symbol: categories.symbol(for: t.category), directory: directory, flag: dupes.contains(t.id) ? "Possible duplicate" : nil)
                        }
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
                                Button { editing = t } label: { Label("Edit", systemImage: "pencil") }.tint(Theme.inkSecondary)
                            }
                    }
                } header: {
                    HStack {
                        Text(group.day.dayTitle)
                        Spacer()
                        Text(dayTotal(group.items)).font(.figure(12)).foregroundStyle(Theme.inkSecondary)
                    }
                    .font(.footnote.weight(.medium)).foregroundStyle(Theme.inkSecondary).textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.defaultMinListRowHeight, 52)
        .listSectionSpacing(10)
        .scrollContentBackground(.hidden)
    }

    /// Net of the day in the reporting currency; a day with only transfers says so rather than showing zero.
    private func dayTotal(_ items: [TransactionRecord]) -> String {
        let b = Books(accounts: accounts, rates: rates, transactions: items, entries: [])
        let inc = b.reported.filter { $0.kind == .income }.reduce(0) { $0 + $1.amountCents }
        let exp = b.reported.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amountCents }
        if inc == 0 && exp == 0 { return items.allSatisfy { $0.kind == .transfer } ? "Transfers only" : "" }
        return Money.format(inc - exp, signed: true)
    }

    private var periodPicker: some View {
        HStack(spacing: 0) {
            ForEach([DateRangeFilter.thisMonth, .lastMonth, .all], id: \.self) { r in
                Button { withAnimation(Theme.easeOut(0.18)) { range = r } } label: {
                    Text(r == .all ? "All time" : r.rawValue).font(.subheadline.weight(range == r ? .semibold : .regular))
                        .foregroundStyle(range == r ? Theme.ink : Theme.inkSecondary)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background { if range == r { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface) } }
                }.buttonStyle(.plain)
            }
            Button { showCustom = true } label: {
                Text(range == .custom ? "\(customFrom.formatted(.dateTime.day().month(.abbreviated))) – \(customTo.formatted(.dateTime.day().month(.abbreviated)))" : "Custom")
                    .font(.subheadline.weight(range == .custom ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundStyle(range == .custom ? Theme.ink : Theme.inkSecondary)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background { if range == .custom { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface) } }
            }.buttonStyle(.plain)
        }
        .padding(3).background(Theme.line.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var activeFilterChips: some View {
        let chips: [(String, () -> Void)] = [
            kindFilter.map { k in (k.label, { kindFilter = nil }) },
            categoryFilter.map { c in (c, { categoryFilter = nil }) },
            accountFilter.flatMap { id in accounts.first { $0.id == id } }.map { a in (a.name, { accountFilter = nil }) },
            tagFilter.map { t in ("#\(t)", { tagFilter = nil }) },
            amountLabel.map { l in (l, { minAmount = nil; maxAmount = nil }) },
        ].compactMap { $0 }
        if !chips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(chips.enumerated()), id: \.offset) { _, c in
                        Button { c.1() } label: {
                            HStack(spacing: 6) { Text(c.0); Image(systemName: "xmark").font(.caption2.weight(.bold)) }
                                .font(.footnote.weight(.medium)).foregroundStyle(Theme.accent)
                                .padding(.horizontal, 12).frame(minHeight: 32).background(Theme.accentSoft, in: Capsule())
                        }.buttonStyle(PressableStyle()).accessibilityLabel("Remove filter \(c.0)")
                    }
                }
            }
        }
    }

    private var amountLabel: String? {
        switch (minAmount, maxAmount) {
        case (nil, nil): nil
        case (let a?, nil): "From \(Money.format(a))"
        case (nil, let b?): "Up to \(Money.format(b))"
        case (let a?, let b?): "\(Money.format(a)) to \(Money.format(b))"
        }
    }

    private var amountSheet: some View {
        AmountRangeSheet(minAmount: $minAmount, maxAmount: $maxAmount)
    }

    private var customRangeSheet: some View {
        NavigationStack {
            Form {
                DatePicker("From", selection: $customFrom, in: ...customTo, displayedComponents: .date)
                DatePicker("To", selection: $customTo, in: customFrom..., displayedComponents: .date)
            }
            .navigationTitle("Custom range").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Show") { range = .custom; showCustom = false } } }
        }
        .presentationDetents([.height(280)])
    }

    private var summaryRow: some View {
        // Totals are in the reporting currency; foreign-currency records are converted with your rates, transfers are excluded.
        let b = Books(accounts: accounts, rates: rates, transactions: filtered, entries: [])
        let income = b.reported.filter { $0.kind == .income }.reduce(0) { $0 + $1.amountCents }
        let expense = b.reported.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amountCents }
        return VStack(alignment: .leading, spacing: 6) {
            StatStrip(items: [
                .init(label: "Income", value: Money.format(income), tint: Theme.income),
                .init(label: "Spent", value: Money.format(expense)),
                .init(label: "Net", value: Money.format(income - expense, signed: true))
            ])
            if b.skipped > 0 {
                Text("\(b.skipped) \(b.skipped == 1 ? "record is" : "records are") in a currency with no exchange rate, so \(b.skipped == 1 ? "it isn’t" : "they aren’t") in these totals.")
                    .font(.caption).foregroundStyle(Theme.warning)
            }
        }
        .padding(.horizontal, 4)
    }

    private var filterMenu: some View {
        Menu {
            Picker("Type", selection: $kindFilter) {
                Text("All types").tag(TxKind?.none)
                ForEach(TxKind.allCases) { Text($0.label).tag(TxKind?.some($0)) }
            }
            Picker("Period", selection: $range) {
                ForEach(DateRangeFilter.allCases.filter { $0 != .custom }) { Text($0.rawValue).tag($0) }
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
            Button { showAmount = true } label: { Label(amountLabel ?? "Amount…", systemImage: "banknote") }
            if filtersActive {
                Button("Clear filters", role: .destructive) { clearFilters() }
            }
        } label: {
            Image(systemName: filtersActive ? "line.3.horizontal.decrease.circle.fill" : "ellipsis.circle")
        }
        .accessibilityLabel("Filters and import")
    }
}

struct TransactionRow: View {
    let tx: TransactionRecord
    let symbol: String
    var directory: AccountDirectory? = nil
    var flag: String? = nil

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
                Text(flag ?? subtitle).font(.caption).foregroundStyle(flag == nil ? Theme.inkSecondary : Theme.warning).lineLimit(1)
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
        .padding(.vertical, 0)
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

/// Only show transactions between two amounts. Either end can be left empty.
struct AmountRangeSheet: View {
    @Binding var minAmount: Int?
    @Binding var maxAmount: Int?
    @Environment(\.dismiss) private var dismiss
    @State private var minText = ""
    @State private var maxText = ""

    private var lo: Int? { minText.isEmpty ? nil : Money.parse(minText) }
    private var hi: Int? { maxText.isEmpty ? nil : Money.parse(maxText) }
    private var valid: Bool {
        (minText.isEmpty || lo != nil) && (maxText.isEmpty || hi != nil) && !(lo != nil && hi != nil && lo! > hi!)
    }

    var body: some View {
        NavigationStack {
            Form {
                HStack { Text("From"); AmountField(text: $minText, placeholder: "any") }
                HStack { Text("To"); AmountField(text: $maxText, placeholder: "any") }
                if !valid { Text("The first amount must not be larger than the second.").font(.footnote).foregroundStyle(Theme.danger) }
            }
            .navigationTitle("Amount").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Apply") { minAmount = lo; maxAmount = hi; dismiss() }.disabled(!valid) }
            }
            .onAppear { minText = minAmount.map { Money.editable($0) } ?? ""; maxText = maxAmount.map { Money.editable($0) } ?? "" }
        }
        .presentationDetents([.height(300)])
    }
}
