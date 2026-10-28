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

    @State private var search = ""
    @State private var kindFilter: TxKind?
    @State private var categoryFilter: String?
    @State private var range: DateRangeFilter = .all
    @State private var showAdd = false
    @State private var showCSV = false
    @State private var editing: TransactionRecord?
    @State private var pendingDelete: TransactionRecord?

    private var filtersActive: Bool { kindFilter != nil || categoryFilter != nil || range != .all }

    private var filtered: [TransactionRecord] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return txs.filter { t in
            (kindFilter == nil || t.kind == kindFilter)
                && (categoryFilter == nil || t.category == categoryFilter)
                && range.contains(t.date)
                && (q.isEmpty || t.title.localizedCaseInsensitiveContains(q)
                    || t.category.localizedCaseInsensitiveContains(q)
                    || t.notes.localizedCaseInsensitiveContains(q))
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
                        kindFilter = nil; categoryFilter = nil; range = .all
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
                Text("\(t.title.isEmpty ? t.category : t.title) · \(Money.format(t.amountCents)). Balances update immediately.")
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
                        Button { editing = t } label: { TransactionRow(tx: t, symbol: categories.symbol(for: t.category)) }
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
        let income = filtered.filter { $0.kind == .income }.reduce(0) { $0 + $1.amountCents }
        let expense = filtered.filter { $0.kind == .expense }.reduce(0) { $0 + $1.amountCents }
        return HStack(spacing: 10) {
            Metric(label: "Income", value: Money.format(income), tint: Theme.income)
            Metric(label: "Expenses", value: Money.format(expense))
            Metric(label: "\(filtered.count) \(filtered.count == 1 ? "item" : "items")", value: Money.format(income - expense, signed: true),
                   tint: Theme.inkSecondary)
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
            if filtersActive {
                Button("Clear filters", role: .destructive) { kindFilter = nil; categoryFilter = nil; range = .all }
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

    var body: some View {
        HStack(spacing: 12) {
            CategoryGlyph(symbol: symbol, tint: tx.kind == .income ? Theme.income : Theme.inkSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(tx.title.isEmpty ? tx.category : tx.title)
                    .font(.body).foregroundStyle(Theme.ink).lineLimit(1)
                Text(tx.title.isEmpty ? tx.date.short : "\(tx.category) · \(tx.date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(Theme.inkSecondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Money.format(tx.kind == .income ? tx.amountCents : -tx.amountCents, signed: true))
                .font(.figure(16))
                .foregroundStyle(tx.kind == .income ? Theme.income : Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
