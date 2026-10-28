import SwiftUI
import SwiftData

struct RecurringView: View {
    @Environment(\.modelContext) private var context
    @Environment(ErrorCenter.self) private var errors
    @Query(sort: \RecurringRule.dayOfMonth) private var rules: [RecurringRule]
    @Query(sort: \MoneyCategory.sortOrder) private var categories: [MoneyCategory]
    @State private var showAdd = false
    @State private var editing: RecurringRule?
    @State private var pendingDelete: RecurringRule?

    var body: some View {
        Group {
            if rules.isEmpty {
                EmptyState(symbol: "arrow.triangle.2.circlepath", title: "Nothing recurring yet",
                           message: "Rent, subscriptions or salary can post themselves every month as normal transactions.",
                           actionTitle: "Add recurring") { showAdd = true }
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(rules) { r in
                        Button { editing = r } label: { row(r) }
                            .buttonStyle(PressableStyle())
                            .listRowBackground(GlassRowBackground())
                            .listRowSeparatorTint(Theme.line)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { pendingDelete = r } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                }
                .listStyle(.insetGrouped).scrollContentBackground(.hidden)
            }
        }
        .monoScreen()
        .navigationTitle("Recurring")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add recurring transaction")
            }
        }
        .sheet(isPresented: $showAdd) { RecurringForm(editing: nil) }
        .sheet(item: $editing) { RecurringForm(editing: $0) }
        .confirmationDialog("Delete this recurring transaction?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { r in
            Button("Delete", role: .destructive) {
                context.delete(r)
                do { try context.save(); Haptics.tap() } catch { errors.report(error, doing: "Couldn’t delete") }
            }
        } message: { _ in Text("Transactions it already posted stay in your records.") }
    }

    private func row(_ r: RecurringRule) -> some View {
        HStack(spacing: 12) {
            CategoryGlyph(symbol: categories.symbol(for: r.category), tint: r.kind == .income ? Theme.income : Theme.inkSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title.isEmpty ? r.category : r.title).font(.body).foregroundStyle(Theme.ink).lineLimit(1)
                Text(subtitle(r)).font(.caption).foregroundStyle(Theme.inkSecondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Money.format(r.kind == .income ? r.amountCents : -r.amountCents, signed: true))
                .font(.figure(16)).foregroundStyle(r.kind == .income ? Theme.income : Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .opacity(r.isActive ? 1 : 0.5)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func subtitle(_ r: RecurringRule) -> String {
        guard r.isActive else { return "Paused · day \(r.dayOfMonth)" }
        guard let m = MonthKey(string: r.nextMonthKey) else { return "Day \(r.dayOfMonth) of each month" }
        return "Day \(r.dayOfMonth) · next \(Ledger.occurrence(of: r, in: m).formatted(.dateTime.day().month(.abbreviated)))"
    }
}

struct RecurringForm: View {
    let editing: RecurringRule?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ErrorCenter.self) private var errors
    @Query(sort: \MoneyCategory.sortOrder) private var categories: [MoneyCategory]

    @State private var kind: TxKind
    @State private var amountText: String
    @State private var category: String
    @State private var title: String
    @State private var day: Int
    @State private var isActive: Bool
    @State private var showNewCategory = false

    init(editing: RecurringRule?) {
        self.editing = editing
        _kind = State(initialValue: editing?.kind ?? .expense)
        _amountText = State(initialValue: Money.editable(editing?.amountCents ?? 0))
        _category = State(initialValue: editing?.category ?? "")
        _title = State(initialValue: editing?.title ?? "")
        _day = State(initialValue: editing?.dayOfMonth ?? min(max(Calendar.current.component(.day, from: .now), 1), 28))
        _isActive = State(initialValue: editing?.isActive ?? true)
    }

    private var amount: Int? { Money.parse(amountText).flatMap { $0 > 0 ? $0 : nil } }
    private var kindCategories: [MoneyCategory] { categories.filter { $0.kind == kind } }
    private var canSave: Bool { amount != nil && !category.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                Section {
                    Picker("Type", selection: $kind) { ForEach(TxKind.categoryKinds) { Text($0.label).tag($0) } }
                        .pickerStyle(.segmented)
                        .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                }
                Section {
                    HStack { Text("Amount"); AmountField(text: $amountText) }
                    if !amountText.isEmpty && amount == nil {
                        Text("Enter an amount greater than zero.").font(.footnote).foregroundStyle(Theme.danger)
                    }
                    Picker("Category", selection: $category) {
                        ForEach(kindCategories) { c in Label(c.name, systemImage: c.symbol).tag(c.name) }
                    }
                    Button { showNewCategory = true } label: { Label("New category…", systemImage: "plus").font(.subheadline) }
                    TextField("Description", text: $title)
                } footer: {
                    Text("Each month on this day, MONO adds a normal transaction. If the app wasn’t opened for a while, missed months are added when you next open it.")
                }
                Section {
                    Stepper("Day of month: \(day)", value: $day, in: 1...28)
                } footer: {
                    Text(editing == nil ? "The first one posts \(firstPostText). Days stop at 28 so every month has one." : "Days stop at 28 so every month has one.")
                }
                if editing != nil {
                    Section { Toggle("Active", isOn: $isActive) } footer: { Text("Pausing stops new transactions. Resuming starts from the next occurrence, with no catch-up.") }
                }
                }.listRowBackground(GlassRowBackground())
            }
            .scrollContentBackground(.hidden).monoScreen()
            .navigationTitle(editing == nil ? "New recurring" : "Edit recurring")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!canSave) }
            }
            .onChange(of: kind) { _, _ in
                if !kindCategories.contains(where: { $0.name == category }) { category = kindCategories.first?.name ?? "" }
            }
            .onAppear {
                if category.isEmpty || !kindCategories.contains(where: { $0.name == category }) && editing == nil {
                    category = kindCategories.first?.name ?? ""
                }
            }
            .sheet(isPresented: $showNewCategory) { NewCategorySheet(kind: kind) { category = $0 } }
        }
        .presentationDetents([.large])
    }

    private var firstPostText: String {
        let m = Ledger.firstDueMonth(day: day)
        let d = Calendar.current.date(from: DateComponents(year: m.year, month: m.month, day: day)) ?? .now
        return Calendar.current.isDateInToday(d) ? "today" : "on \(d.formatted(.dateTime.day().month(.wide)))"
    }

    private func save() {
        guard let cents = amount, !category.isEmpty else { return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = editing {
            let resumed = isActive && !r.isActive
            r.amountCents = cents; r.kind = kind; r.category = category; r.title = clean; r.dayOfMonth = day
            r.isActive = isActive
            // Never back-date: a day that has already passed this month waits for next month.
            let earliest = Ledger.firstDueMonth(day: day)
            if resumed || (MonthKey(string: r.nextMonthKey) ?? earliest) < earliest { r.nextMonthKey = earliest.string }
        } else {
            context.insert(RecurringRule(title: clean, amountCents: cents, kind: kind, category: category, dayOfMonth: day,
                                         nextMonthKey: Ledger.firstDueMonth(day: day).string))
        }
        do {
            try context.save()
            // Post right away if the first occurrence is today.
            let rules = try context.fetch(FetchDescriptor<RecurringRule>())
            try Ledger.postDueRecurring(rules, in: context)
            Haptics.success(); dismiss()
        } catch { errors.report(error, doing: "Couldn’t save") }
    }
}
