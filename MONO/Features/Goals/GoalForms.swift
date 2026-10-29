import SwiftUI
import SwiftData

/// Create or edit a trip or a general savings goal.
struct GoalForm: View {
    let kind: GoalKind
    let editing: SavingsGoal?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ErrorCenter.self) private var errors

    @State private var name = ""
    @State private var destination = ""
    @State private var symbol = "target"
    @State private var target = ""
    @State private var hasDeadline = true
    @State private var deadline = Calendar.current.date(byAdding: .month, value: 6, to: .now) ?? .now
    @State private var monthly = ""
    @State private var day = 1
    @State private var buffer = ""
    @State private var existing = ""
    @State private var costTexts: [TripCostCategory: String] = [:]
    @State private var details = ""
    @State private var priority: Priority = .medium
    @State private var currencyCode = ""          // empty = the reporting currency
    @State private var frequency: ContributionFrequency = .monthly
    @State private var startDate = Date.now

    private var cur: Currency { currencyCode.isEmpty ? Money.reporting : Currency.find(currencyCode) }

    private var isTrip: Bool { kind == .trip }
    private func amount(_ s: String) -> Int? { s.isEmpty ? 0 : Money.parse(s, currency: cur) }
    private var valid: Bool {
        let n = isTrip ? destination : name
        guard !n.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        guard amount(monthly) != nil, amount(buffer) != nil, amount(existing) != nil else { return false }
        if isTrip { return TripCostCategory.allCases.allSatisfy { amount(costTexts[$0] ?? "") != nil } }
        return (Money.parse(target, currency: cur) ?? 0) > 0
    }
    private var tripTotal: Int {
        TripCostCategory.allCases.reduce(amount(buffer) ?? 0) { $0 + (amount(costTexts[$1] ?? "") ?? 0) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                Section {
                    if isTrip {
                        TextField("Destination", text: $destination).accessibilityIdentifier("goalName")
                        DatePicker("Departure", selection: $deadline, in: Date.now..., displayedComponents: .date)
                    } else {
                        TextField("Goal name", text: $name).accessibilityIdentifier("goalName")
                        HStack { Text("Target"); AmountField(text: $target, currency: cur) }
                        Toggle("Has a deadline", isOn: $hasDeadline)
                        if hasDeadline { DatePicker("Deadline", selection: $deadline, in: Date.now..., displayedComponents: .date) }
                    }
                }
                Section {
                    TextField("Description (optional)", text: $details, axis: .vertical).lineLimit(1...3)
                    Picker("Priority", selection: $priority) { ForEach(Priority.allCases) { Text($0.label).tag($0) } }
                    if editing == nil {
                        Picker("Currency", selection: $currencyCode) {
                            Text("Reporting (\(Money.reporting.code))").tag("")
                            ForEach(Currency.all.filter { $0.code != Money.reporting.code }) { Text("\($0.code) · \($0.name)").tag($0.code) }
                        }
                    } else {
                        HStack { Text("Currency"); Spacer(); Text(cur.code).foregroundStyle(Theme.inkSecondary) }
                    }
                } footer: {
                    Text(editing == nil ? "Amounts for this goal are kept in its own currency. Converting to \(Money.reporting.code) for totals uses the exchange rates you entered."
                                        : "The currency is fixed once a goal exists, because changing it would relabel every amount.")
                }
                if !isTrip {
                    Section("Icon") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                            ForEach(["target", "shield", "laptopcomputer", "graduationcap", "house", "car", "gift", "heart", "camera", "iphone"], id: \.self) { s in
                                Button { symbol = s } label: {
                                    Image(systemName: s).font(.system(size: 18)).frame(width: 44, height: 44)
                                        .foregroundStyle(symbol == s ? Theme.accent : Theme.inkSecondary)
                                        .background(symbol == s ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 10))
                                }.buttonStyle(PressableStyle())
                            }
                        }
                    }
                }
                if isTrip && editing == nil {
                    Section {
                        ForEach(TripCostCategory.allCases) { c in
                            HStack {
                                Label(c.label, systemImage: c.symbol)
                                AmountField(text: Binding(get: { costTexts[c] ?? "" }, set: { costTexts[c] = $0 }), currency: cur)
                            }
                        }
                        HStack { Label("Emergency buffer", systemImage: "shield"); AmountField(text: $buffer, currency: cur) }
                    } header: { Text("Estimated costs") } footer: {
                        Text("Trip target: \(Money.format(tripTotal, currency: cur)). You can refine costs any time.")
                    }
                } else if isTrip {
                    Section {
                        HStack { Label("Emergency buffer", systemImage: "shield"); AmountField(text: $buffer, currency: cur) }
                    } footer: { Text("Costs are edited from the trip screen.") }
                }
                Section {
                    Picker("How often", selection: $frequency) { ForEach(ContributionFrequency.allCases) { Text($0.label).tag($0) } }
                    HStack { Text("Contribution each \(frequency.noun)"); AmountField(text: $monthly, currency: cur) }
                    if frequency == .monthly {
                        Stepper("Contribute on day \(day)", value: $day, in: 1...28)
                    }
                    DatePicker(frequency == .monthly ? "Starts" : "First contribution", selection: $startDate, displayedComponents: .date)
                    if editing == nil {
                        HStack { Text("Already saved"); AmountField(text: $existing, currency: cur) }
                    }
                } header: { Text("Savings plan") } footer: {
                    Text(editing == nil
                         ? "“Already saved” is money you set aside before using MONO. It counts toward the goal but isn’t taken out of your available cash. Nothing is scheduled before the start date."
                         : (frequency == .monthly ? "Planned contributions are counted on this day each month, after today and never before the start date."
                                                  : "Planned contributions repeat every \(frequency == .weekly ? "7" : "14") days from the first contribution."))
                }
                }.listRowBackground(GlassRowBackground())
            }
            .scrollContentBackground(.hidden).monoScreen()
            .navigationTitle(editing == nil ? (isTrip ? "Plan a trip" : "New goal") : "Edit plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!valid).accessibilityIdentifier("saveGoal") }
            }
            .onAppear(perform: load)
        }
        .presentationDetents([.large])
    }

    private func load() {
        guard let g = editing else { return }
        name = g.name; destination = g.destination; symbol = g.symbol
        hasDeadline = g.deadline != nil
        deadline = g.deadline ?? deadline
        details = g.details; priority = g.priority; currencyCode = g.currencyCode; frequency = g.frequency
        startDate = g.scheduleStart
        monthly = Money.editable(g.plannedMonthlyCents, currency: g.currency); day = g.contributionDay
        buffer = Money.editable(g.bufferCents, currency: g.currency)
        target = Money.editable(g.targetCents, currency: g.currency)
    }

    private func save() {
        let g = editing ?? SavingsGoal(name: "", kind: kind, symbol: isTrip ? "airplane" : symbol)
        g.name = (isTrip ? destination : name).trimmingCharacters(in: .whitespaces)
        g.symbol = isTrip ? "airplane" : symbol
        g.destination = isTrip ? g.name : ""
        g.targetCents = isTrip ? 0 : (Money.parse(target, currency: cur) ?? 0)
        g.deadline = isTrip ? deadline : (hasDeadline ? deadline : nil)
        g.bufferCents = amount(buffer) ?? 0
        g.plannedMonthlyCents = amount(monthly) ?? 0
        g.contributionDay = day
        g.details = details.trimmingCharacters(in: .whitespacesAndNewlines)
        g.priority = priority
        g.frequency = frequency
        g.startDate = Calendar.current.startOfDay(for: startDate)
        if editing == nil {
            g.currencyCode = currencyCode
            context.insert(g)
            if isTrip {
                for c in TripCostCategory.allCases {
                    if let v = amount(costTexts[c] ?? ""), v > 0 {
                        context.insert(TripCost(goalID: g.id, category: c, label: "", amountCents: v))
                    }
                }
            }
            if let e = amount(existing), e > 0 {
                context.insert(GoalEntry(goalID: g.id, amountCents: e, date: .now, note: "Already saved before MONO", affectsCash: false))
            }
        }
        do { try context.save(); Haptics.success(); dismiss() } catch { errors.report(error, doing: "Couldn’t save goal") }
    }
}

/// Add money to, or withdraw money from, a goal. If the account is in a different currency from the goal, you enter both amounts,
/// which fixes the rate for this movement. Either way it is a transfer to or from savings, never income or an expense.
struct MoveMoneySheet: View {
    let goal: SavingsGoal
    let withdraw: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ErrorCenter.self) private var errors
    @Query private var entries: [GoalEntry]
    @Query private var txs: [TransactionRecord]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var rates: [ExchangeRate]
    @AppStorage("openingBalanceCents") private var opening = 0

    @State private var accountID: UUID?
    @State private var text = ""
    @State private var accountText = ""
    @State private var date = Date.now
    @State private var note = ""
    @State private var fromExisting = false

    private var gc: Currency { goal.currency }
    private var books: Books { Books(accounts: accounts, rates: rates, transactions: txs, entries: entries, legacyOpening: opening) }
    private var fundingAccounts: [Account] { books.active }
    private var account: Account? { fundingAccounts.first { $0.id == accountID } ?? fundingAccounts.first }
    private var crossCurrency: Bool { account.map { $0.currencyCode != gc.code } ?? false }

    private var cents: Int? { Money.parse(text, currency: gc).flatMap { $0 > 0 ? $0 : nil } }
    /// What the account pays or receives, in its own currency.
    private var accountCents: Int? {
        guard let a = account else { return cents }
        if !crossCurrency { return cents }
        return Money.parse(accountText, currency: a.currency).flatMap { $0 > 0 ? $0 : nil }
    }
    private var impliedRate: String? {
        guard crossCurrency, let a = account, let g = cents, let c = accountCents,
              let m = CurrencyConverter.impliedMicros(fromMinor: g, from: gc, toMinor: c, to: a.currency) else { return nil }
        return "1 \(gc.code) = \(CurrencyConverter.formatRate(m)) \(a.currencyCode)"
    }
    private var balance: Int { FinanceEngine.balance(of: goal.id, entries: entries) }
    private var cash: Int { account.map { books.balance(of: $0) } ?? books.overview.total }
    private var tooMuch: Bool { withdraw && (cents ?? 0) > balance }
    private var cashAfter: Int? {
        guard let c = accountCents, !fromExisting else { return nil }
        return withdraw ? cash + c : cash - c
    }
    private var canSave: Bool { cents != nil && accountCents != nil && !tooMuch }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                Section {
                    HStack { Text(crossCurrency ? (withdraw ? "Goal gives up" : "Goal receives") : "Amount")
                        AmountField(text: $text, currency: gc).accessibilityIdentifier("moveAmount") }
                    if fundingAccounts.count > 1 {
                        Picker(withdraw ? "Return to" : "From", selection: Binding(get: { account?.id }, set: { accountID = $0 })) {
                            ForEach(fundingAccounts) { Label("\($0.name) · \($0.currencyCode)", systemImage: $0.kind.symbol).tag(Optional($0.id)) }
                        }
                    }
                    if crossCurrency, let a = account, !fromExisting {
                        HStack { Text(withdraw ? "Account receives" : "Account pays"); AmountField(text: $accountText, currency: a.currency) }
                        if let impliedRate { Text("Rate used for this movement: \(impliedRate)").font(.footnote).foregroundStyle(Theme.inkSecondary) }
                    }
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    TextField("Note (optional)", text: $note)
                    if !withdraw {
                        Toggle("Already had this saved", isOn: $fromExisting)
                    }
                } footer: {
                    if withdraw {
                        Text("Goal holds \(goal.money(balance)). The money returns to \(account?.name ?? "your available cash"): it isn’t recorded as income.")
                    } else {
                        Text(fromExisting ? "Counts toward the goal without reducing available cash."
                                          : "Moves money from \(account?.name ?? "your account") (\(Money.format(cash, currency: account?.currency))) into this goal. It isn’t recorded as an expense.")
                    }
                }
                if tooMuch { Section { Callout(text: "That’s more than the goal currently holds (\(goal.money(balance))).", tone: .danger) }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                if let after = cashAfter, after < 0, !withdraw {
                    Section { Callout(text: "This takes \(account?.name ?? "your cash") to \(Money.format(after, currency: account?.currency)). Check your account balances in Settings ▸ Accounts if that looks wrong.", tone: .warning) }
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                }.listRowBackground(GlassRowBackground())
            }
            .scrollContentBackground(.hidden).monoScreen()
            .navigationTitle(withdraw ? "Withdraw" : "Add to \(goal.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(withdraw ? "Withdraw" : "Add", action: save).disabled(!canSave).accessibilityIdentifier("saveMove")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        guard let cents else { return }
        do {
            try Ledger.moveMoney(goal: goal, cents: cents, withdraw: withdraw, date: date, note: note,
                                 entries: entries, affectsCash: !fromExisting, accountID: account?.id,
                                 accountAmountCents: crossCurrency && !fromExisting ? (accountCents ?? 0) : 0, in: context)
            Haptics.success(); ToastCenter.shared.show(withdraw ? "Taken out of \(goal.name)" : "Added to \(goal.name)"); dismiss()
        } catch { errors.report(error, doing: "Couldn’t save") }
    }
}

struct CostSheet: View {
    let goal: SavingsGoal
    let editing: TripCost?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ErrorCenter.self) private var errors
    @State private var category: TripCostCategory = .flights
    @State private var label = ""
    @State private var text = ""
    @State private var confirmDelete = false

    private var cents: Int? { Money.parse(text, currency: goal.currency).flatMap { $0 > 0 ? $0 : nil } }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                Section {
                    Picker("Category", selection: $category) {
                        ForEach(TripCostCategory.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                    }
                    TextField("Label (optional)", text: $label)
                    HStack { Text("Estimated cost"); AmountField(text: $text, currency: goal.currency) }
                }
                if editing != nil { Section { Button("Delete cost", role: .destructive) { confirmDelete = true } } }
                }.listRowBackground(GlassRowBackground())
            }
            .scrollContentBackground(.hidden).monoScreen()
            .navigationTitle(editing == nil ? "Add cost" : "Edit cost")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(cents == nil) }
            }
            .onAppear {
                if let e = editing { category = e.category; label = e.label; text = Money.editable(e.amountCents, currency: goal.currency) }
            }
            .confirmationDialog("Delete this cost?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let editing { context.delete(editing); try? context.save() }
                    dismiss()
                }
            } message: { Text("The trip target will go down by this amount.") }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard let cents else { return }
        if let e = editing { e.categoryRaw = category.rawValue; e.label = label; e.amountCents = cents }
        else { context.insert(TripCost(goalID: goal.id, category: category, label: label, amountCents: cents)) }
        do { try context.save(); Haptics.success(); dismiss() } catch { errors.report(error, doing: "Couldn’t save cost") }
    }
}

/// Side-by-side "what if" for contribution size, date and total budget. Nothing is saved until Apply.
struct ScenarioSheet: View {
    let goal: SavingsGoal
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var entries: [GoalEntry]
    @Query private var costs: [TripCost]

    @State private var monthly = ""
    @State private var date = Date.now
    @State private var hasDate = true
    @State private var budget = ""

    private var base: PlanInput { SavingsPlanner.input(for: goal, costs: costs, entries: entries) }
    private var alt: PlanInput {
        var i = base
        i.plannedMonthly = Money.parse(monthly, currency: goal.currency) ?? (monthly.isEmpty ? 0 : base.plannedMonthly)
        i.deadline = hasDate ? date : nil
        if let b = Money.parse(budget, currency: goal.currency), b > 0 { i.target = b }
        return i
    }

    var body: some View {
        let a = SavingsPlanner.plan(base)
        let b = SavingsPlanner.plan(alt)
        NavigationStack {
            Form {
                Group {
                Section("Alternative") {
                    HStack { Text("Contribution each \(goal.frequency.noun)"); AmountField(text: $monthly, currency: goal.currency) }
                    Toggle(goal.kind == .trip ? "Departure date" : "Deadline", isOn: $hasDate)
                    if hasDate { DatePicker("Date", selection: $date, in: Date.now..., displayedComponents: .date) }
                    HStack { Text(goal.kind == .trip ? "Total trip budget" : "Target"); AmountField(text: $budget, placeholder: Money.editable(base.target, currency: goal.currency), currency: goal.currency) }
                }
                Section("Comparison") {
                    HStack {
                        Spacer()
                        Text("Current").frame(minWidth: 84, alignment: .trailing)
                        Text("Alternative").frame(minWidth: 84, alignment: .trailing)
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.inkSecondary)
                    CompareRow(label: "Target", a: goal.money(a.target), b: goal.money(b.target))
                    CompareRow(label: "Remaining to save", a: goal.money(a.remaining), b: goal.money(b.remaining))
                    CompareRow(label: "Contributions left", a: "\(a.contributionsRemaining)", b: "\(b.contributionsRemaining)")
                    CompareRow(label: "Required / month", a: a.requiredMonthly.map { goal.money($0) } ?? "—", b: b.requiredMonthly.map { goal.money($0) } ?? "—")
                    CompareRow(label: "Expected at date", a: a.expectedAtDeadline.formatted_, b: b.expectedAtDeadline.formatted_)
                    CompareRow(label: b.shortfall > 0 || a.shortfall > 0 ? "Shortfall" : "Surplus",
                               a: goal.money(a.shortfall > 0 ? a.shortfall : a.surplus), b: goal.money(b.shortfall > 0 ? b.shortfall : b.surplus))
                    CompareRow(label: "Status", a: a.statusText, b: b.statusText, bTint: b.statusTint)
                }
                Section {
                    Button("Apply monthly amount and date to plan") { apply() }
                } footer: {
                    Text(goal.kind == .trip ? "A different total budget isn’t applied here; change the trip’s costs to alter the target."
                                            : "A different target isn’t applied here; edit the goal to change it.")
                }
                }.listRowBackground(GlassRowBackground())
            }
            .scrollContentBackground(.hidden).monoScreen()
            .navigationTitle("Compare plans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onAppear {
                monthly = Money.editable(goal.plannedMonthlyCents, currency: goal.currency)
                hasDate = goal.deadline != nil
                date = goal.deadline ?? (Calendar.current.date(byAdding: .month, value: 6, to: .now) ?? .now)
            }
        }
        .presentationDetents([.large])
    }

    private func apply() {
        goal.plannedMonthlyCents = Money.parse(monthly, currency: goal.currency) ?? 0
        if goal.kind == .trip { goal.deadline = date } else { goal.deadline = hasDate ? date : nil }
        try? context.save(); Haptics.success(); dismiss()
    }
}

private extension Int { var formatted_: String { Money.format(self) } }

private struct CompareRow: View {
    let label: String, a: String, b: String
    var bTint: Color = Theme.ink
    var body: some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(Theme.inkSecondary)
            Spacer()
            Text(a).font(.figure(14)).foregroundStyle(Theme.ink).frame(minWidth: 84, alignment: .trailing)
            Text(b).font(.figure(14)).foregroundStyle(bTint).frame(minWidth: 84, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
