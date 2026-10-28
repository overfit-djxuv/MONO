import SwiftUI
import SwiftData

struct TransactionForm: View {
    let editing: TransactionRecord?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ErrorCenter.self) private var errors
    @Query(sort: \MoneyCategory.sortOrder) private var categories: [MoneyCategory]
    @Query private var items: [ShoppingItem]
    @Query private var planned: [PlannedExpense]
    @Query(sort: \TransactionRecord.date, order: .reverse) private var history: [TransactionRecord]

    @State private var kind: TxKind
    @State private var amountText: String
    @State private var category: String
    @State private var date: Date
    @State private var title: String
    @State private var notes: String
    @State private var showNewCategory = false
    @State private var confirmDelete = false

    init(editing: TransactionRecord?, kind: TxKind = .expense) {
        self.editing = editing
        _kind = State(initialValue: editing?.kind ?? kind)
        _amountText = State(initialValue: Money.editable(editing?.amountCents ?? 0))
        _category = State(initialValue: editing?.category ?? "")
        _date = State(initialValue: editing?.date ?? .now)
        _title = State(initialValue: editing?.title ?? "")
        _notes = State(initialValue: editing?.notes ?? "")
    }

    private var amount: Int? { Money.parse(amountText).flatMap { $0 > 0 ? $0 : nil } }
    private var kindCategories: [MoneyCategory] { categories.filter { $0.kind == kind } }
    private var canSave: Bool { amount != nil && !category.isEmpty }
    private var suggestions: [QuickEntry.Suggestion] {
        QuickEntry.suggestions(matching: title, in: history, limit: 6).filter { $0.title.caseInsensitiveCompare(title) != .orderedSame }
    }

    /// Fills the type, category and amount from the last time this description was used.
    private func apply(_ s: QuickEntry.Suggestion) {
        title = s.title
        kind = s.kind
        if categories.contains(where: { $0.kind == s.kind && $0.name == s.category }) { category = s.category }
        amountText = Money.editable(s.amountCents)
        Haptics.tap()
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(TxKind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                }
                Section {
                    HStack {
                        Text("Amount")
                        AmountField(text: $amountText).accessibilityIdentifier("amountField")
                    }
                    if !amountText.isEmpty && amount == nil {
                        Text("Enter an amount greater than zero.").font(.footnote).foregroundStyle(Theme.danger)
                    }
                    Picker("Category", selection: $category) {
                        ForEach(kindCategories) { c in Label(c.name, systemImage: c.symbol).tag(c.name) }
                    }
                    Button { showNewCategory = true } label: {
                        Label("New category…", systemImage: "plus").font(.subheadline)
                    }
                    DatePicker("Date", selection: $date)
                }
                Section {
                    TextField("Description", text: $title).accessibilityIdentifier("descriptionField")
                    if editing == nil, !suggestions.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(suggestions) { s in
                                    Button { apply(s) } label: {
                                        HStack(spacing: 6) {
                                            Text(s.title).lineLimit(1)
                                            Text(Money.format(s.amountCents)).foregroundStyle(Theme.inkSecondary)
                                        }
                                        .font(.footnote.weight(.medium))
                                        .padding(.vertical, 7).padding(.horizontal, 12)
                                        .background(Theme.accentSoft, in: Capsule())
                                        .foregroundStyle(Theme.accent)
                                    }
                                    .buttonStyle(PressableStyle())
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 2)
                        }
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    }
                    TextField("Notes (optional)", text: $notes, axis: .vertical).lineLimit(1...5)
                }
                if editing?.sourceID != nil {
                    Section {
                        Callout(text: "This expense was created from your shopping list or planned expenses. Deleting it lets you record that item again.")
                    }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                }
                if editing != nil {
                    Section {
                        Button("Delete transaction", role: .destructive) { confirmDelete = true }
                    }
                }
                }.listRowBackground(GlassRowBackground())
            }
            .scrollContentBackground(.hidden)
            .monoScreen()
            .navigationTitle(editing == nil ? "New transaction" : "Edit transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!canSave).accessibilityIdentifier("saveTransaction")
                }
            }
            .onChange(of: kind) { _, _ in
                if !kindCategories.contains(where: { $0.name == category }) { category = kindCategories.first?.name ?? "" }
            }
            .onAppear {
                if category.isEmpty || !kindCategories.contains(where: { $0.name == category }) && editing == nil {
                    category = kindCategories.first?.name ?? ""
                }
            }
            .sheet(isPresented: $showNewCategory) {
                NewCategorySheet(kind: kind) { category = $0 }
            }
            .confirmationDialog("Delete this transaction?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    guard let editing else { return }
                    do { try Ledger.delete(editing, items: items, planned: planned, in: context); dismiss() }
                    catch { errors.report(error, doing: "Couldn’t delete") }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func save() {
        guard let cents = amount, !category.isEmpty else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let t = editing {
            t.amountCents = cents; t.kind = kind; t.category = category
            t.date = date; t.title = cleanTitle; t.notes = notes
        } else {
            context.insert(TransactionRecord(amountCents: cents, kind: kind, category: category,
                                             date: date, title: cleanTitle, notes: notes))
        }
        do { try context.save(); Haptics.success(); dismiss() }
        catch { errors.report(error, doing: "Couldn’t save") }
    }
}

struct NewCategorySheet: View {
    let kind: TxKind
    var onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query private var categories: [MoneyCategory]
    @State private var name = ""
    @State private var symbol = "tag"

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var duplicate: Bool {
        categories.contains { $0.kind == kind && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                Section {
                    TextField("Name", text: $name)
                    if duplicate { Text("You already have a category with this name.").font(.footnote).foregroundStyle(Theme.danger) }
                }
                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 14) {
                        ForEach(iconChoices, id: \.self) { s in
                            Button { symbol = s } label: {
                                Image(systemName: s).font(.system(size: 18))
                                    .frame(width: 44, height: 44)
                                    .foregroundStyle(symbol == s ? Theme.accent : Theme.inkSecondary)
                                    .background(symbol == s ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                    .padding(.vertical, 4)
                }
                }.listRowBackground(GlassRowBackground())
            }
            .scrollContentBackground(.hidden).monoScreen()
            .navigationTitle("New \(kind == .income ? "income" : "expense") category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let order = (categories.map(\.sortOrder).max() ?? 0) + 1
                        context.insert(MoneyCategory(name: trimmed, symbol: symbol, kind: kind, sortOrder: order))
                        try? context.save()
                        onCreate(trimmed); dismiss()
                    }
                    .disabled(trimmed.isEmpty || duplicate)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
