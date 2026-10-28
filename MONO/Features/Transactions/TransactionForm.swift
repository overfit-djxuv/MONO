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
    @Query(sort: \Account.sortOrder) private var allAccounts: [Account]
    @AppStorage("lastAccountID") private var lastAccountID = ""

    @State private var kind: TxKind
    @State private var amountText: String
    @State private var category: String
    @State private var date: Date
    @State private var title: String
    @State private var notes: String
    @State private var merchant: String
    @State private var tagsText: String
    @State private var accountID: UUID?
    @State private var toAccountID: UUID?
    @State private var receivedText = ""
    @State private var showNewCategory = false
    @State private var confirmDelete = false
    @State private var showDuplicate = false

    init(editing: TransactionRecord?, kind: TxKind = .expense) {
        self.editing = editing
        _kind = State(initialValue: editing?.kind ?? kind)
        _category = State(initialValue: editing?.category ?? "")
        _date = State(initialValue: editing?.date ?? .now)
        _title = State(initialValue: editing?.title ?? "")
        _notes = State(initialValue: editing?.notes ?? "")
        _merchant = State(initialValue: editing?.merchant ?? "")
        _tagsText = State(initialValue: (editing?.tags ?? "").replacingOccurrences(of: ",", with: ", "))
        _accountID = State(initialValue: editing?.accountID)
        _toAccountID = State(initialValue: editing?.toAccountID)
        _amountText = State(initialValue: "")   // filled in onAppear, once the account's currency is known
    }

    private var books: Books { Books(accounts: allAccounts, rates: [], transactions: [], entries: []) }   // directory only: cheap, no balances
    private var pickable: [Account] {
        // Keep an archived account selectable only while editing a record that already uses it.
        books.active + allAccounts.filter { $0.isArchived && ($0.id == editing?.accountID || $0.id == editing?.toAccountID) }
    }
    private var fromAccount: Account? { books.account(accountID) }
    private var toAccount: Account? { toAccountID.flatMap { id in allAccounts.first { $0.id == id } } }
    private var currency: Currency { fromAccount?.currency ?? Money.reporting }
    private var toCurrency: Currency { toAccount?.currency ?? Money.reporting }
    private var isTransfer: Bool { kind == .transfer }
    private var sameCurrency: Bool { fromAccount?.currencyCode == toAccount?.currencyCode }

    private var amount: Int? { Money.parse(amountText, currency: currency).flatMap { $0 > 0 ? $0 : nil } }
    private var received: Int? {
        if sameCurrency { return amount }
        return Money.parse(receivedText, currency: toCurrency).flatMap { $0 > 0 ? $0 : nil }
    }
    private var kindCategories: [MoneyCategory] { categories.filter { $0.kind == kind } }
    private var canSave: Bool {
        if isTransfer { return amount != nil && received != nil && fromAccount != nil && toAccount != nil && fromAccount?.id != toAccount?.id }
        return amount != nil && !category.isEmpty
    }
    private var impliedRate: String? {
        guard isTransfer, !sameCurrency, let a = amount, let r = received,
              let m = CurrencyConverter.impliedMicros(fromMinor: a, from: currency, toMinor: r, to: toCurrency) else { return nil }
        return "1 \(currency.code) = \(CurrencyConverter.formatRate(m)) \(toCurrency.code)"
    }
    private var suggestions: [QuickEntry.Suggestion] {
        guard !isTransfer else { return [] }
        return QuickEntry.suggestions(matching: title, in: history, limit: 6).filter { $0.title.caseInsensitiveCompare(title) != .orderedSame }
    }

    /// Fills the type, category and amount from the last time this description was used.
    private func apply(_ s: QuickEntry.Suggestion) {
        title = s.title
        kind = s.kind
        if categories.contains(where: { $0.kind == s.kind && $0.name == s.category }) { category = s.category }
        amountText = Money.editable(s.amountCents, currency: currency)
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
                if isTransfer { transferSection } else { entrySection }
                Section {
                    TextField(isTransfer ? "Description (optional)" : "Description", text: $title).accessibilityIdentifier("descriptionField")
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
                    if !isTransfer {
                        TextField("Merchant (optional)", text: $merchant)
                        TextField("Tags (optional), e.g. work, trip", text: $tagsText)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    TextField("Notes (optional)", text: $notes, axis: .vertical).lineLimit(1...5)
                }
                if editing?.sourceID != nil {
                    Section {
                        Callout(text: "This expense was created from your shopping list or planned expenses. Deleting it lets you record that item again.")
                    }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                }
                if isTransfer {
                    Section {
                        Callout(text: "A transfer moves money between your own accounts. It isn’t income or spending, so it never changes your totals.")
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
                    Button("Save") { save(confirmedDuplicate: false) }.disabled(!canSave).accessibilityIdentifier("saveTransaction")
                }
            }
            .onChange(of: kind) { _, new in
                if new != .transfer, !kindCategories.contains(where: { $0.name == category }) { category = kindCategories.first?.name ?? "" }
                if new == .transfer, toAccountID == nil || toAccountID == accountID { toAccountID = pickable.first { $0.id != fromAccount?.id }?.id }
            }
            .onChange(of: accountID) { old, new in
                // Re-express the typed amount only if the currency's decimals no longer fit.
                if let o = allAccounts.first(where: { $0.id == old }), let n = allAccounts.first(where: { $0.id == new }), o.currencyCode != n.currencyCode {
                    amountText = AmountField.sanitize(amountText, digits: n.currency.digits)
                }
            }
            .onAppear(perform: prepare)
            .sheet(isPresented: $showNewCategory) {
                NewCategorySheet(kind: kind) { category = $0 }
            }
            .alert("Possible duplicate", isPresented: $showDuplicate) {
                Button("Add anyway") { save(confirmedDuplicate: true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You already have a \(kind.label.lowercased()) of \(Money.format(amount ?? 0, currency: currency)) with this description on the same day. Add it anyway?")
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

    // MARK: Sections

    @ViewBuilder private var entrySection: some View {
        Section {
            HStack {
                Text("Amount")
                AmountField(text: $amountText, currency: currency).accessibilityIdentifier("amountField")
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
            if pickable.count > 1 {
                Picker("Account", selection: Binding(get: { accountID ?? books.defaultAccount?.id }, set: { accountID = $0 })) {
                    ForEach(pickable) { a in Label("\(a.name) · \(a.currencyCode)", systemImage: a.kind.symbol).tag(Optional(a.id)) }
                }
            }
            DatePicker("Date", selection: $date)
        }
    }

    @ViewBuilder private var transferSection: some View {
        Section {
            Picker("From", selection: Binding(get: { accountID ?? books.defaultAccount?.id }, set: { accountID = $0 })) {
                ForEach(pickable) { a in Label("\(a.name) · \(a.currencyCode)", systemImage: a.kind.symbol).tag(Optional(a.id)) }
            }
            Picker("To", selection: $toAccountID) {
                Text("Choose…").tag(UUID?.none)
                ForEach(pickable.filter { $0.id != (accountID ?? books.defaultAccount?.id) }) { a in
                    Label("\(a.name) · \(a.currencyCode)", systemImage: a.kind.symbol).tag(Optional(a.id))
                }
            }
            HStack {
                Text(sameCurrency ? "Amount" : "Sent")
                AmountField(text: $amountText, currency: currency).accessibilityIdentifier("amountField")
            }
            if !sameCurrency, toAccount != nil {
                HStack {
                    Text("Received")
                    AmountField(text: $receivedText, currency: toCurrency)
                }
                if let impliedRate { Text("Rate used for this transfer: \(impliedRate)").font(.footnote).foregroundStyle(Theme.inkSecondary) }
            }
            if pickable.count < 2 {
                Text("Add a second account in Settings ▸ Accounts to make a transfer.").font(.footnote).foregroundStyle(Theme.warning)
            }
            DatePicker("Date", selection: $date)
        }
    }

    // MARK: Actions

    private func prepare() {
        if accountID == nil {
            accountID = allAccounts.first { $0.id.uuidString == lastAccountID && !$0.isArchived }?.id ?? books.defaultAccount?.id
        }
        if let e = editing {
            amountText = Money.editable(e.amountCents, currency: currency)
            if e.kind == .transfer { receivedText = Money.editable(e.toAmountCents, currency: toCurrency) }
        }
        if !isTransfer, category.isEmpty || !kindCategories.contains(where: { $0.name == category }) && editing == nil {
            category = kindCategories.first?.name ?? ""
        }
    }

    private func save(confirmedDuplicate: Bool) {
        guard canSave, let cents = amount else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let from = fromAccount

        if isTransfer {
            guard let from, let to = toAccount, let receivedCents = received else { return }
            do {
                if let t = editing {
                    try Ledger.validateTransfer(from: from, to: to, sentCents: cents, receivedCents: receivedCents, allowArchived: true)
                    t.kind = .transfer; t.category = ""; t.merchant = ""; t.tags = ""
                    t.amountCents = cents; t.toAmountCents = receivedCents; t.accountID = from.id; t.toAccountID = to.id
                    t.date = date; t.title = cleanTitle; t.notes = notes
                    try context.save()
                } else {
                    try Ledger.createTransfer(from: from, to: to, sentCents: cents, receivedCents: receivedCents,
                                              date: date, title: cleanTitle, notes: notes, in: context)
                }
                lastAccountID = from.id.uuidString
                Haptics.success(); dismiss()
            } catch { errors.report(error, doing: "Couldn’t save the transfer") }
            return
        }

        guard !category.isEmpty else { return }
        let cleanMerchant = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        if !confirmedDuplicate,
           Ledger.possibleDuplicate(kind: kind, cents: cents, date: date, title: cleanTitle, merchant: cleanMerchant, accountID: from?.id,
                                    defaultAccountID: books.defaultAccount?.id, excluding: editing?.id, in: history) != nil {
            showDuplicate = true; return
        }
        let tags = Tags.normalize(tagsText)
        if let t = editing {
            t.amountCents = cents; t.kind = kind; t.category = category
            t.date = date; t.title = cleanTitle; t.notes = notes
            t.accountID = from?.id; t.merchant = cleanMerchant; t.tags = tags
            t.toAccountID = nil; t.toAmountCents = 0
        } else {
            context.insert(TransactionRecord(amountCents: cents, kind: kind, category: category, date: date, title: cleanTitle,
                                             notes: notes, accountID: from?.id, merchant: cleanMerchant, tags: tags))
        }
        do { try context.save(); lastAccountID = from?.id.uuidString ?? ""; Haptics.success(); dismiss() }
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
