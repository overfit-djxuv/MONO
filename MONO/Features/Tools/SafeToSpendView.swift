import SwiftUI
import SwiftData

/// "How much can I spend without touching what I've already committed to?" Every line can be switched off or inspected.
struct SafeToSpendView: View {
    @Environment(\.modelContext) private var context
    @Environment(ErrorCenter.self) private var errors
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var rates: [ExchangeRate]
    @Query private var txs: [TransactionRecord]
    @Query private var entries: [GoalEntry]
    @Query private var planned: [PlannedExpense]
    @Query private var rules: [RecurringRule]
    @Query private var goals: [SavingsGoal]
    @Query private var costs: [TripCost]
    @Query private var categories: [MoneyCategory]
    @Query private var limits: [BudgetLimit]
    @Query private var monthBudgets: [MonthBudget]
    @Query(sort: \ReservedFund.createdAt) private var reserved: [ReservedFund]
    @AppStorage("openingBalanceCents") private var legacyOpening = 0

    @State private var config = SafeToSpend.Config.load()
    @State private var editingFund: FundTarget?
    @State private var showHow = false

    private var result: SafeToSpend.Result {
        let books = Books(accounts: accounts, rates: rates, transactions: txs, entries: entries, legacyOpening: legacyOpening)
        return SafeToSpend.make(config: config, books: books, planned: planned, rules: rules, goals: goals, costs: costs, entries: entries,
                                categories: categories, limits: limits, monthBudgets: monthBudgets, reserved: reserved)
    }

    private var horizonChoice: Binding<Int> {
        Binding(get: { if case .days(let n) = config.horizon { return n }; return 0 },
                set: { config.horizon = $0 == 0 ? .endOfMonth : .days($0) })
    }

    var body: some View {
        let r = result
        ScrollView {
            VStack(spacing: 16) {
                hero(r)
                breakdown(r)
                optionsCard
                reservedCard
                howCard
            }
            .padding(.horizontal, Theme.gutter).padding(.vertical, 8).padding(.bottom, 28)
        }
        .monoScreen()
        .navigationTitle("Safe to spend")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingFund) { FundForm(editing: $0.fund) }
        .onChange(of: config) { _, c in c.save() }
    }

    // MARK: Hero

    private func hero(_ r: SafeToSpend.Result) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(r.isShortfall ? "Short by" : "Safe to spend").font(.footnote.weight(.medium)).foregroundStyle(Theme.onPrimary.opacity(0.74))
            Text(Money.format(abs(r.flexible))).font(.figure(44, weight: .light)).foregroundStyle(Theme.onPrimary)
                .lineLimit(1).minimumScaleFactor(0.6).contentTransition(.numericText())
                .accessibilityIdentifier("safeToSpend")
            Text(heroCaption(r)).font(.footnote).foregroundStyle(Theme.onPrimary.opacity(0.74))
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(HeroBackground())
    }

    private func heroCaption(_ r: SafeToSpend.Result) -> String {
        let until = r.horizonEnd.formatted(.dateTime.day().month(.abbreviated))
        if r.isShortfall { return "Your commitments until \(until) are more than the money you have." }
        if let d = r.perDay { return "Until \(until) · about \(Money.format(d)) a day" }
        return "Until \(until)"
    }

    // MARK: Breakdown

    private func breakdown(_ r: SafeToSpend.Result) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            caption("Actual money")
            row("In your accounts", detail: "\(r.includedAccounts.count) \(r.includedAccounts.count == 1 ? "account" : "accounts")", cents: r.accountMoney, sign: "")
            if !r.unconvertedAccounts.isEmpty {
                Callout(text: "\(r.unconvertedAccounts.joined(separator: ", ")) isn’t counted: it has no exchange rate yet.", tone: .warning, symbol: "arrow.left.arrow.right")
                    .padding(.vertical, 8)
            }
            caption("Already spoken for (planned)").padding(.top, 14)
            group("Upcoming bills", on: $config.includeBills, items: r.bills, total: r.billsTotal, empty: "No unpaid bills before then.")
            group("Planned savings", on: $config.includeSavings, items: r.savings, total: r.savingsTotal, empty: "No goal contributions planned before then.")
            group("Essentials", on: $config.includeEssentials, items: r.essentials, total: r.essentialsTotal,
                  empty: "Mark categories as Essential and give them a budget to hold their remainder back.")
            caption("Set aside by you (reserved)").padding(.top, 14)
            group("Reserved", on: $config.includeReserved, items: r.reserved, total: r.reservedTotal, empty: "None. Add a reserve below.")
            Hairline().padding(.top, 10)
            HStack {
                Text(r.isShortfall ? "Shortfall" : "Safe to spend").font(.body.weight(.semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Text(Money.format(r.flexible)).font(.figure(18, weight: .semibold)).foregroundStyle(r.isShortfall ? Theme.danger : Theme.ink)
            }
            .padding(.top, 12)
            .accessibilityElement(children: .combine)
        }
        .glass(padding: 18)
    }

    private func caption(_ text: String) -> some View {
        Text(text.uppercased()).font(.caption.weight(.semibold)).tracking(0.8).foregroundStyle(Theme.inkSecondary).padding(.bottom, 6)
    }

    private func row(_ title: String, detail: String, cents: Int, sign: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body).foregroundStyle(Theme.ink)
                Text(detail).font(.caption).foregroundStyle(Theme.inkSecondary)
            }
            Spacer()
            Text("\(sign)\(Money.format(cents))").font(.figure(16)).foregroundStyle(Theme.ink)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    /// One commitment: a switch to include it, the total it holds back, and the individual items on tap.
    private func group(_ title: String, on: Binding<Bool>, items: [SafeToSpend.Item], total: Int, empty: String) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if items.isEmpty { Text(empty).font(.footnote).foregroundStyle(Theme.inkSecondary) }
                ForEach(items) { i in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(i.title).font(.subheadline).foregroundStyle(Theme.ink)
                            Text(i.detail).font(.caption).foregroundStyle(Theme.inkSecondary)
                        }
                        Spacer()
                        Text(Money.format(i.amountCents)).font(.figure(14)).foregroundStyle(Theme.inkSecondary)
                    }
                }
            }
            .padding(.top, 6).padding(.bottom, 4)
        } label: {
            HStack(spacing: 10) {
                Toggle(title, isOn: on).labelsHidden().tint(Theme.accent).scaleEffect(0.8).frame(width: 46)
                Text(title).font(.body).foregroundStyle(on.wrappedValue ? Theme.ink : Theme.inkSecondary).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Text(on.wrappedValue ? "−\(Money.format(total))" : "not counted").font(.figure(16))
                    .foregroundStyle(on.wrappedValue ? Theme.ink : Theme.inkTertiary)
            }
        }
        .tint(Theme.inkSecondary)
        .padding(.vertical, 4)
    }

    // MARK: Options

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Look ahead")
            Picker("Until", selection: horizonChoice) {
                Text("Month end").tag(0); Text("7 days").tag(7); Text("14 days").tag(14); Text("30 days").tag(30)
            }
            .pickerStyle(.segmented)
            if accounts.filter({ !$0.isArchived }).count > 1 {
                Hairline()
                SectionHeader(title: "Accounts to include")
                ForEach(accounts.filter { !$0.isArchived }) { a in
                    Toggle(isOn: Binding(get: { !config.excludedAccountIDs.contains(a.id) },
                                         set: { on in
                        config.excludedAccountIDs.removeAll { $0 == a.id }
                        if !on { config.excludedAccountIDs.append(a.id) }
                    })) {
                        Label("\(a.name) · \(a.currencyCode)", systemImage: a.kind.symbol).font(.subheadline)
                    }
                    .tint(Theme.accent)
                }
            }
        }
        .glass(padding: 18)
    }

    private var reservedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { SectionHeader(title: "Reserved funds"); Spacer()
                Button { editingFund = FundTarget(fund: nil) } label: { Image(systemName: "plus") }.buttonStyle(PressableStyle()).foregroundStyle(Theme.accent)
                    .accessibilityLabel("Add a reserved fund") }
            if reserved.isEmpty {
                Text("Money you want left alone even though it sits in an account: an emergency buffer, next month’s rent.")
                    .font(.footnote).foregroundStyle(Theme.inkSecondary)
            }
            ForEach(reserved) { f in
                Button { editingFund = FundTarget(fund: f) } label: {
                    HStack {
                        Text(f.name).foregroundStyle(f.isActive ? Theme.ink : Theme.inkSecondary)
                        Spacer()
                        Text(f.isActive ? Money.format(f.amountCents) : "off").font(.figure(15)).foregroundStyle(Theme.inkSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
            }
        }
        .glass(padding: 18)
    }

    private var howCard: some View {
        DisclosureGroup(isExpanded: $showHow) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Safe to spend = money in your accounts − unpaid bills due before the date − planned goal contributions before the date − what’s left of your essential category budgets − reserved funds.")
                Text("Nothing is counted twice. A bill you’ve paid already lowered your balance, so it isn’t subtracted again. Money moved into goals has already left your accounts. A bill in an essential category is taken out of that category’s remainder before it’s held back. Contributions are capped at what a goal still needs.")
                Text("It uses only money you already have; income you expect to receive isn’t added. It’s an estimate for planning and never changes your records.")
            }
            .font(.footnote).foregroundStyle(Theme.inkSecondary).padding(.top, 8)
        } label: { SectionHeader(title: "How this is calculated") }
        .tint(Theme.inkSecondary)
        .glass(padding: 18)
    }
}

struct FundTarget: Identifiable { let id = UUID(); let fund: ReservedFund? }

struct FundForm: View {
    let editing: ReservedFund?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ErrorCenter.self) private var errors
    @State private var name = ""
    @State private var amount = ""
    @State private var active = true
    @State private var confirmDelete = false

    private var cents: Int? { Money.parse(amount).flatMap { $0 > 0 ? $0 : nil } }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                Section {
                    TextField("Name (for example, Emergency buffer)", text: $name)
                    HStack { Text("Amount"); AmountField(text: $amount) }
                    Toggle("Hold this back", isOn: $active).tint(Theme.accent)
                } footer: { Text("In \(Money.reporting.code). While on, this amount is subtracted from Safe to spend.") }
                if editing != nil { Section { Button("Delete", role: .destructive) { confirmDelete = true } } }
                }.listRowBackground(GlassRowBackground())
            }
            .scrollContentBackground(.hidden).monoScreen()
            .navigationTitle(editing == nil ? "New reserve" : "Edit reserve")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(cents == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { if let e = editing { name = e.name; amount = Money.editable(e.amountCents); active = e.isActive } }
            .confirmationDialog("Delete this reserve?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let editing { context.delete(editing); try? context.save() }
                    dismiss()
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard let cents else { return }
        let n = name.trimmingCharacters(in: .whitespaces)
        if let e = editing { e.name = n; e.amountCents = cents; e.isActive = active }
        else { context.insert(ReservedFund(name: n, amountCents: cents, isActive: active)) }
        do { try context.save(); Haptics.success(); dismiss() } catch { errors.report(error, doing: "Couldn’t save") }
    }
}
