import SwiftUI
import SwiftData

/// Subscriptions, bills and other repeating payments. A schedule here is a plan, not a transaction:
/// nothing is deducted until you tap Mark paid.
struct SubscriptionsView: View {
    @Environment(\.modelContext) private var context
    @Environment(ErrorCenter.self) private var errors
    @Query(sort: \RecurringRule.title) private var rules: [RecurringRule]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var rates: [ExchangeRate]
    @Query(sort: \MoneyCategory.sortOrder) private var categories: [MoneyCategory]

    @State private var editing: SubTarget?
    @State private var paying: RecurringRule?

    private var books: Books { Books(accounts: accounts, rates: rates, transactions: [], entries: []) }
    private var today: Date { Calendar.current.startOfDay(for: .now) }
    private var active: [RecurringRule] { rules.filter { $0.status == .active }.sorted { $0.dueDate < $1.dueDate } }
    private var dueNow: [RecurringRule] { active.filter { Calendar.current.startOfDay(for: $0.dueDate) <= today } }
    private var upcoming: [RecurringRule] { active.filter { Calendar.current.startOfDay(for: $0.dueDate) > today } }
    private var paused: [RecurringRule] { rules.filter { $0.status == .paused } }
    private var cancelled: [RecurringRule] { rules.filter { $0.status == .cancelled } }

    var body: some View {
        let books = self.books
        ScrollView {
            VStack(spacing: 16) {
                if rules.isEmpty {
                    EmptyState(symbol: "arrow.triangle.2.circlepath", title: "No subscriptions yet",
                               message: "Add streaming, phone, rent or any payment that repeats. MONO reminds you and helps you record it, but never deducts anything on its own.",
                               actionTitle: "Add a payment") { editing = SubTarget(rule: nil) }
                        .padding(.top, 40)
                } else {
                    summary(books)
                    if !dueNow.isEmpty { dueCard(books) }
                    if !upcoming.isEmpty { listCard("Coming up", upcoming, books) }
                    if !paused.isEmpty { collapsed("Paused", paused, books) }
                    if !cancelled.isEmpty { collapsed("Cancelled", cancelled, books) }
                }
            }
            .padding(.horizontal, Theme.gutter).padding(.vertical, 8).padding(.bottom, 28)
        }
        .monoScreen()
        .navigationTitle("Subscriptions & bills")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = SubTarget(rule: nil) } label: { Image(systemName: "plus") }.accessibilityLabel("Add a payment")
            }
        }
        .sheet(item: $editing) { SubscriptionForm(editing: $0.rule) }
        .sheet(item: $paying) { MarkPaidSheet(rule: $0) }
    }

    // MARK: Summary (an estimate)

    private func summary(_ books: Books) -> some View {
        let costs = active.filter { $0.kind == .expense }
        var monthly = 0, annual = 0, missing: [String] = []
        for r in costs {
            let cur = books.account(r.accountID)?.currency ?? Money.reporting
            if let m = books.converter.convert(r.monthlyCostEstimate, from: cur), let a = books.converter.convert(r.annualCostEstimate, from: cur) {
                monthly += m; annual += a
            } else { missing.append(r.title) }
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "What they cost")
                Spacer()
                Text("Estimate").font(.caption2.weight(.semibold)).foregroundStyle(Theme.inkSecondary)
                    .padding(.vertical, 2).padding(.horizontal, 8).background(Theme.accentSoft, in: Capsule())
            }
            HStack(alignment: .top, spacing: 16) {
                Metric(label: "Per month", value: Money.format(monthly), footnote: "\(costs.count) active")
                Metric(label: "Per year", value: Money.format(annual))
            }
            Text("Spread evenly from each payment’s amount and schedule. Paused and cancelled ones aren’t included.")
                .font(.caption).foregroundStyle(Theme.inkSecondary)
            if !missing.isEmpty {
                Text("\(missing.joined(separator: ", ")) isn’t included: no exchange rate for its currency.").font(.caption).foregroundStyle(Theme.warning)
            }
        }
        .glass(padding: 18)
    }

    // MARK: Due now

    private func dueCard(_ books: Books) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "Due now").padding(.bottom, 6)
            ForEach(Array(dueNow.enumerated()), id: \.element.id) { i, r in
                VStack(alignment: .leading, spacing: 10) {
                    Button { editing = SubTarget(rule: r) } label: { row(r, books) }.buttonStyle(PressableStyle())
                    HStack(spacing: 10) {
                        Button { paying = r } label: { Label("Mark paid", systemImage: "checkmark").font(.footnote.weight(.semibold)) }
                            .buttonStyle(.borderedProminent).tint(Theme.primary).foregroundStyle(Theme.onPrimary).controlSize(.small)
                        Button { skip(r) } label: { Text("Skip this one").font(.footnote) }
                            .buttonStyle(.bordered).tint(Theme.inkSecondary).controlSize(.small)
                        Spacer()
                    }
                }
                .padding(.vertical, 8)
                if i < dueNow.count - 1 { Hairline() }
            }
            Text("Nothing is recorded until you tap Mark paid. Skip moves to the next payment without recording one.")
                .font(.caption).foregroundStyle(Theme.inkSecondary).padding(.top, 6)
        }
        .glass(padding: 18)
    }

    private func listCard(_ title: String, _ list: [RecurringRule], _ books: Books) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: title).padding(.bottom, 6)
            ForEach(Array(list.enumerated()), id: \.element.id) { i, r in
                Button { editing = SubTarget(rule: r) } label: { row(r, books).padding(.vertical, 8) }.buttonStyle(PressableStyle())
                if i < list.count - 1 { Hairline() }
            }
        }
        .glass(padding: 18)
    }

    private func collapsed(_ title: String, _ list: [RecurringRule], _ books: Books) -> some View {
        DisclosureGroup {
            VStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, r in
                    Button { editing = SubTarget(rule: r) } label: { row(r, books, dimmed: true).padding(.vertical, 8) }.buttonStyle(PressableStyle())
                    if i < list.count - 1 { Hairline() }
                }
            }
            .padding(.top, 6)
        } label: { SectionHeader(title: "\(title) · \(list.count)") }
        .tint(Theme.inkSecondary)
        .glass(padding: 18)
    }

    private func row(_ r: RecurringRule, _ books: Books, dimmed: Bool = false) -> some View {
        let cur = books.account(r.accountID)?.currency ?? Money.reporting
        let overdue = Calendar.current.startOfDay(for: r.dueDate) < today && r.status == .active
        return HStack(spacing: 12) {
            CategoryGlyph(symbol: categories.symbol(for: r.category), tint: r.kind == .income ? Theme.income : Theme.inkSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title.isEmpty ? r.category : r.title).font(.body).foregroundStyle(Theme.ink).lineLimit(1)
                Text(subtitle(r, overdue: overdue)).font(.caption).foregroundStyle(overdue ? Theme.warning : Theme.inkSecondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(Money.format(r.kind == .income ? r.amountCents : -r.amountCents, signed: true, currency: cur))
                    .font(.figure(16)).foregroundStyle(r.kind == .income ? Theme.income : Theme.ink).lineLimit(1).minimumScaleFactor(0.8)
                if r.unit != .month || r.interval != 1, r.kind == .expense {
                    Text("≈ \(Money.format(r.monthlyCostEstimate, currency: cur))/mo").font(.caption).foregroundStyle(Theme.inkSecondary)
                }
            }
        }
        .opacity(dimmed ? 0.6 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func subtitle(_ r: RecurringRule, overdue: Bool) -> String {
        switch r.status {
        case .cancelled: return "\(r.scheduleText) · cancelled"
        case .paused: return "\(r.scheduleText) · paused"
        case .active:
            let when = r.dueDate.formatted(.dateTime.day().month(.abbreviated))
            if overdue { return "\(r.scheduleText) · was due \(when)" }
            return "\(r.scheduleText) · next \(when)"
        }
    }

    private func skip(_ r: RecurringRule) {
        do { try Ledger.skipPayment(of: r, in: context); Haptics.tap() } catch { errors.report(error, doing: "Couldn’t skip") }
    }
}

struct SubTarget: Identifiable { let id = UUID(); let rule: RecurringRule? }

// MARK: - Mark paid

struct MarkPaidSheet: View {
    let rule: RecurringRule
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ErrorCenter.self) private var errors
    @Query private var txs: [TransactionRecord]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]

    @State private var amountText = ""
    @State private var paidOn = Date.now
    @State private var accountID: UUID?

    private var books: Books { Books(accounts: accounts, rates: [], transactions: [], entries: []) }
    private var account: Account? { books.account(accountID ?? rule.accountID) }
    private var currency: Currency { account?.currency ?? Money.reporting }
    private var cents: Int? { Money.parse(amountText, currency: currency).flatMap { $0 > 0 ? $0 : nil } }
    private var nextDate: Date { rule.following(rule.dueDate) }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                Section {
                    HStack { Text("Amount"); AmountField(text: $amountText, currency: currency) }
                    DatePicker("Paid on", selection: $paidOn, in: ...Date.now, displayedComponents: .date)
                    if books.active.count > 1 {
                        Picker("From", selection: Binding(get: { account?.id }, set: { accountID = $0 })) {
                            ForEach(books.active) { Label("\($0.name) · \($0.currencyCode)", systemImage: $0.kind.symbol).tag(Optional($0.id)) }
                        }
                    }
                } footer: {
                    Text("This records \(rule.kind == .income ? "an income" : "an expense") for the payment due \(rule.dueDate.formatted(.dateTime.day().month(.abbreviated))) and moves the next one to \(nextDate.formatted(.dateTime.day().month(.abbreviated).year())). Change the amount if the bill was different this time.")
                }
                }.listRowBackground(GlassRowBackground())
            }
            .scrollContentBackground(.hidden).monoScreen()
            .navigationTitle(rule.title.isEmpty ? "Mark paid" : rule.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Record payment", action: save).disabled(cents == nil).accessibilityIdentifier("recordPayment") }
            }
            .onAppear { accountID = rule.accountID; amountText = Money.editable(rule.amountCents, currency: currency) }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard let cents else { return }
        do {
            try Ledger.recordPayment(of: rule, paidOn: paidOn, amountCents: cents, accountID: account?.id, existing: txs, in: context)
            Haptics.success(); dismiss()
        } catch { errors.report(error, doing: "Couldn’t record the payment") }
    }
}

// MARK: - Add / edit

struct SubscriptionForm: View {
    let editing: RecurringRule?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ErrorCenter.self) private var errors
    @Query(sort: \MoneyCategory.sortOrder) private var categories: [MoneyCategory]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var rates: [ExchangeRate]

    enum Preset: String, CaseIterable, Identifiable {
        case weekly, biweekly, monthly, quarterly, halfYearly, yearly, custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .weekly: "Weekly"; case .biweekly: "Every 2 weeks"; case .monthly: "Monthly"; case .quarterly: "Every 3 months"
            case .halfYearly: "Every 6 months"; case .yearly: "Yearly"; case .custom: "Custom…"
            }
        }
        var schedule: (RecurrenceUnit, Int)? {
            switch self {
            case .weekly: (.week, 1); case .biweekly: (.week, 2); case .monthly: (.month, 1); case .quarterly: (.month, 3)
            case .halfYearly: (.month, 6); case .yearly: (.year, 1); case .custom: nil
            }
        }
        static func detect(_ unit: RecurrenceUnit, _ interval: Int) -> Preset {
            allCases.first { $0.schedule.map { $0 == (unit, interval) } ?? false } ?? .custom
        }
    }

    @State private var title = ""
    @State private var kind: TxKind = .expense
    @State private var amountText = ""
    @State private var category = ""
    @State private var accountID: UUID?
    @State private var preset: Preset = .monthly
    @State private var unit: RecurrenceUnit = .month
    @State private var interval = 1
    @State private var next = Calendar.current.startOfDay(for: .now)
    @State private var remind = 1
    @State private var notes = ""
    @State private var confirmDelete = false
    @State private var showNewCategory = false

    private var books: Books { Books(accounts: accounts, rates: rates, transactions: [], entries: []) }
    private var account: Account? { books.account(accountID) }
    private var currency: Currency { account?.currency ?? Money.reporting }
    private var cents: Int? { Money.parse(amountText, currency: currency).flatMap { $0 > 0 ? $0 : nil } }
    private var kindCategories: [MoneyCategory] { categories.filter { $0.kind == kind } }
    private var canSave: Bool { cents != nil && !category.isEmpty && !title.trimmingCharacters(in: .whitespaces).isEmpty }
    private var effective: (unit: RecurrenceUnit, interval: Int) { preset.schedule.map { ($0.0, $0.1) } ?? (unit, interval) }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                Section {
                    TextField("Name (for example, Netflix)", text: $title)
                    Picker("Type", selection: $kind) { ForEach(TxKind.categoryKinds) { Text($0 == .expense ? "Payment" : "Income").tag($0) } }
                        .pickerStyle(.segmented)
                    HStack { Text("Amount"); AmountField(text: $amountText, currency: currency) }
                    Picker("Category", selection: $category) { ForEach(kindCategories) { Label($0.name, systemImage: $0.symbol).tag($0.name) } }
                    Button { showNewCategory = true } label: { Label("New category…", systemImage: "plus").font(.subheadline) }
                    if books.active.count > 1 {
                        Picker("Account", selection: Binding(get: { account?.id }, set: { accountID = $0 })) {
                            ForEach(books.active) { Label("\($0.name) · \($0.currencyCode)", systemImage: $0.kind.symbol).tag(Optional($0.id)) }
                        }
                    }
                }
                Section {
                    Picker("Repeats", selection: $preset) { ForEach(Preset.allCases) { Text($0.label).tag($0) } }
                    if preset == .custom {
                        Stepper("Every \(interval)", value: $interval, in: 1...52)
                        Picker("Unit", selection: $unit) { ForEach(RecurrenceUnit.allCases) { Text(interval == 1 ? $0.label : "\($0.label)s").tag($0) } }
                    }
                    DatePicker("Next payment", selection: $next, displayedComponents: .date)
                    Picker("Remind me", selection: $remind) {
                        Text("On the day").tag(0); Text("1 day before").tag(1); Text("3 days before").tag(3); Text("A week before").tag(7)
                    }
                } footer: {
                    if let c = cents, kind == .expense {
                        let e = effective
                        Text("About \(Money.format(SubscriptionSchedule.monthlyCost(c, unit: e.unit, interval: e.interval), currency: currency)) a month, \(Money.format(SubscriptionSchedule.annualCost(c, unit: e.unit, interval: e.interval), currency: currency)) a year (an estimate). Reminders arrive at \(String(format: "%02d:00", Reminders.hour)); change that in Settings ▸ Notifications.")
                    } else { Text("Reminders arrive at \(String(format: "%02d:00", Reminders.hour)); change that in Settings ▸ Notifications.") }
                }
                Section { TextField("Notes (optional)", text: $notes, axis: .vertical).lineLimit(1...4) }
                if let r = editing { statusSection(r) }
                }.listRowBackground(GlassRowBackground())
            }
            .scrollContentBackground(.hidden).monoScreen()
            .navigationTitle(editing == nil ? "New payment" : "Edit payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave).accessibilityIdentifier("saveSubscription") }
            }
            .onChange(of: kind) { _, _ in if !kindCategories.contains(where: { $0.name == category }) { category = kindCategories.first?.name ?? "" } }
            .onAppear(perform: load)
            .sheet(isPresented: $showNewCategory) { NewCategorySheet(kind: kind) { category = $0 } }
            .confirmationDialog("Delete this payment?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let editing { context.delete(editing); try? context.save() }
                    dismiss()
                }
            } message: { Text("Payments you already recorded stay in your transactions.") }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder private func statusSection(_ r: RecurringRule) -> some View {
        Section {
            switch r.status {
            case .active:
                Button("Pause") { run { try Ledger.pause(r, in: context) } }
                Button("Cancel subscription", role: .destructive) { run { try Ledger.cancel(r, in: context) } }
            case .paused:
                Button("Resume") { run { try Ledger.resume(r, in: context) } }
                Button("Cancel subscription", role: .destructive) { run { try Ledger.cancel(r, in: context) } }
            case .cancelled:
                Button("Restart") { run { try Ledger.resume(r, in: context) } }
            }
            Button("Delete", role: .destructive) { confirmDelete = true }
        } footer: {
            Text(r.status == .active ? "Pausing stops reminders and amounts owed. Cancelling keeps it in your list for history."
                                     : "Resuming starts from the next payment on or after today. Nothing missed in between is owed.")
        }
    }

    private func run(_ action: () throws -> Void) {
        do { try action(); Haptics.success(); dismiss() } catch { errors.report(error, doing: "Couldn’t update") }
    }

    private func load() {
        if let r = editing {
            title = r.title; kind = r.kind; category = r.category; accountID = r.accountID; unit = r.unit; interval = r.interval
            preset = Preset.detect(r.unit, r.interval); next = r.dueDate; remind = r.remindDaysBefore; notes = r.notes
            amountText = Money.editable(r.amountCents, currency: currency)
        } else if accountID == nil {
            accountID = books.defaultAccount?.id
        }
        if category.isEmpty || !kindCategories.contains(where: { $0.name == category }) { category = kindCategories.first?.name ?? "" }
    }

    private func save() {
        guard let cents else { return }
        let rule = editing ?? RecurringRule(title: "", amountCents: cents, kind: kind, category: category, dayOfMonth: 1, nextMonthKey: "")
        let e = effective, day = Calendar.current.component(.day, from: next)
        rule.title = title.trimmingCharacters(in: .whitespaces); rule.amountCents = cents; rule.kind = kind; rule.category = category
        rule.unit = e.unit; rule.interval = e.interval; rule.dayOfMonth = day
        rule.nextDueDate = Calendar.current.startOfDay(for: next)
        rule.accountID = account?.id; rule.remindDaysBefore = remind; rule.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        Ledger.syncLegacyFields(rule)
        if editing == nil { context.insert(rule) }
        do { try context.save(); Haptics.success(); dismiss() } catch { errors.report(error, doing: "Couldn’t save") }
    }
}
