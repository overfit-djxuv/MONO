import SwiftUI
import SwiftData

struct ShoppingView: View {
    @Environment(\.modelContext) private var context
    @Environment(ErrorCenter.self) private var errors
    @Query(sort: \ShoppingItem.createdAt) private var allItems: [ShoppingItem]
    @Query private var txs: [TransactionRecord]
    @Query private var entries: [GoalEntry]
    @Query private var monthBudgets: [MonthBudget]
    @Query private var limits: [BudgetLimit]
    @Query(sort: \MoneyCategory.sortOrder) private var categories: [MoneyCategory]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var rates: [ExchangeRate]
    @AppStorage("openingBalanceCents") private var opening = 0

    @State private var list: ListKind = .grocery
    @State private var sheet: ItemTarget?
    @State private var pendingDelete: ShoppingItem?
    @State private var confirmClear = false
    @State private var quick = ""
    @State private var simulate: ShoppingItem?
    @State private var linking: ShoppingItem?
    @FocusState private var quickFocused: Bool

    private var items: [ShoppingItem] {
        allItems.filter { $0.listKind == list }.sorted {
            if $0.isPurchased != $1.isPurchased { return !$0.isPurchased }
            if $0.priorityRaw != $1.priorityRaw { return $0.priorityRaw > $1.priorityRaw }
            return $0.createdAt < $1.createdAt
        }
    }
    private var summary: FinanceEngine.ShoppingSummary { FinanceEngine.shoppingSummary(items) }

    /// What the planned purchases are measured against.
    private var available: (label: String, cents: Int)? {
        let month = MonthKey(.now)
        if list != .grocery {
            let books = Books(accounts: accounts, rates: rates, transactions: txs, entries: entries, legacyOpening: opening)
            return ("Available cash", books.overview.total)
        }
        let b = FinanceEngine.budgetSummary(month: month, totalLimit: monthBudgets.first { $0.monthKey == month.string }?.totalCents,
                                            limits: limits, transactions: Books(accounts: accounts, rates: rates, transactions: txs, entries: []).reported)
        if let l = b.lines.first(where: { $0.category == "Groceries" }) { return ("Groceries budget left", max(l.remaining, 0)) }
        if let r = b.remaining { return ("Monthly budget left", max(r, 0)) }
        return nil
    }
    private var unrecorded: [ShoppingItem] { items.filter { $0.isPurchased && Ledger.canRecord($0, existing: txs) } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    listChips.listRowBackground(Color.clear).listRowSeparator(.hidden).listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    summaryBlock.listRowBackground(Color.clear).listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                    quickAdd.listRowBackground(Color.clear).listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                }
                if items.isEmpty {
                    EmptyState(symbol: list.symbol, title: "\(list.label) is empty",
                               message: list == .grocery ? "Type an item above with a quantity and price, like “milk 2 4.50”, to see the total before you shop."
                                                          : "Keep these separate from everyday groceries, with estimated prices.",
                               actionTitle: "Add with details") { sheet = ItemTarget(item: nil) }
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                } else {
                    Section {
                        ForEach(items) { item in
                            ItemRow(item: item, recorded: item.expenseID != nil, onToggle: { toggle(item) })
                                .contentShape(Rectangle())
                                .onTapGesture { sheet = ItemTarget(item: item) }
                                .contextMenu {
                                    Menu {
                                        ForEach(ListKind.allCases.filter { $0 != item.listKind }) { k in
                                            Button { move(item, to: k) } label: { Label(k.label, systemImage: k.symbol) }
                                        }
                                    } label: { Label("Move to list", systemImage: "arrow.right.circle") }
                                    Button { sheet = ItemTarget(item: item) } label: { Label("Edit", systemImage: "pencil") }
                                    if item.estimatedCents > 0 && !item.isPurchased {
                                        Button { simulate = item } label: { Label("Simulate purchase", systemImage: "wand.and.stars") }
                                    }
                                }
                                .listRowBackground(GlassRowBackground()).listRowSeparatorTint(Theme.line)
                                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                    if item.estimatedCents > 0 && !item.isPurchased {
                                        Button { simulate = item } label: { Label("Simulate", systemImage: "wand.and.stars") }.tint(Theme.inkSecondary)
                                    }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) { pendingDelete = item } label: { Label("Delete", systemImage: "trash") }
                                    if item.isPurchased && Ledger.canRecord(item, existing: txs) {
                                        Button { record(item) } label: { Label("Record", systemImage: "arrow.down.doc") }.tint(Theme.accent)
                                        Button { linking = item } label: { Label("Link", systemImage: "link") }.tint(Theme.inkSecondary)
                                    }
                                }
                        }
                    } header: {
                        Text("\(summary.toBuyCount) to buy · \(summary.purchasedCount) bought").textCase(nil).font(.footnote.weight(.medium))
                    }
                    if !unrecorded.isEmpty || summary.purchasedCount > 0 {
                        Section {
                            if !unrecorded.isEmpty {
                                Button { unrecorded.forEach(record) } label: {
                                    Label("Record \(unrecorded.count) purchased as expenses", systemImage: "arrow.down.doc")
                                }
                            }
                            if summary.purchasedCount > 0 {
                                Button(role: .destructive) { confirmClear = true } label: {
                                    Label("Clear bought items", systemImage: "trash")
                                }
                            }
                        } footer: {
                            Text("Marking an item bought changes nothing in your money. Only Record (or Link) connects it to a real expense.")
                        }
                        .listRowBackground(GlassRowBackground())
                        .font(.subheadline)
                    }
                }
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden).monoScreen()
            .navigationTitle("Shopping")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { sheet = ItemTarget(item: nil) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add item with details")
                }
            }
            .sheet(item: $sheet) { ItemSheet(editing: $0.item, defaultList: list) }
            .sheet(item: $simulate) { item in
                NavigationStack { PurchaseSimulatorView(item: item.name, priceCents: item.estimatedCents * item.quantity, category: item.category)
                    .navigationTitle("Simulate").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { simulate = nil } } } }
            }
            .sheet(item: $linking) { item in LinkExpenseSheet(item: item) }
            .confirmationDialog("Delete this item?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible, presenting: pendingDelete) { item in
                Button("Delete", role: .destructive) {
                    context.delete(item); try? context.save()
                }
            } message: { item in
                Text(item.expenseID != nil ? "The expense already recorded for “\(item.name)” stays in your transactions." : item.name)
            }
            .confirmationDialog("Clear \(summary.purchasedCount) bought \(summary.purchasedCount == 1 ? "item" : "items")?",
                                isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear", role: .destructive) {
                    items.filter(\.isPurchased).forEach { context.delete($0) }
                    try? context.save()
                }
            } message: {
                Text(unrecorded.isEmpty ? "Recorded expenses stay in your transactions."
                                        : "\(unrecorded.count) of them have not been recorded as expenses and will be lost from the list.")
            }
        }
    }

    // MARK: List chips and quick add

    private var listChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ListKind.allCases) { k in
                    let on = k == list
                    Button { withAnimation(Theme.easeOut(0.18)) { list = k } } label: {
                        Text(k.label).font(.subheadline.weight(on ? .semibold : .regular))
                            .foregroundStyle(on ? Theme.accent : Theme.ink)
                            .padding(.horizontal, 14).frame(minHeight: 40)
                            .background(on ? Theme.accentSoft : Color.clear, in: Capsule())
                            .overlay(Capsule().stroke(on ? Theme.accent.opacity(0.5) : Theme.line, lineWidth: 1))
                    }.buttonStyle(PressableStyle())
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var quickAdd: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus").foregroundStyle(Theme.inkSecondary)
            TextField("Add an item, e.g. milk 2 4.50", text: $quick)
                .focused($quickFocused).submitLabel(.done).onSubmit(addQuick)
                .accessibilityIdentifier("quickAddItem")
            if !quick.isEmpty { Button("Add", action: addQuick).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent) }
        }
        .padding(.horizontal, 14).frame(minHeight: 48).surface(padding: 0)
    }

    private func move(_ item: ShoppingItem, to kind: ListKind) {
        item.listKindRaw = kind.rawValue
        do { try context.save(); Haptics.tap() } catch { errors.report(error, doing: "Couldn’t move the item") }
    }

    private func addQuick() {
        guard let p = ShoppingQuickAdd.parse(quick) else { return }
        let cats = categories.filter { $0.kind == .expense }
        let category = cats.contains { $0.name == (list == .grocery ? "Groceries" : "Shopping") } ? (list == .grocery ? "Groceries" : "Shopping") : (cats.first?.name ?? "Groceries")
        context.insert(ShoppingItem(name: p.name, quantity: p.quantity, estimatedCents: p.priceCents, category: category, priority: .medium, listKind: list))
        do { try context.save(); quick = ""; Haptics.tap() } catch { errors.report(error, doing: "Couldn’t add item") }
    }

    // MARK: Summary

    private var summaryBlock: some View {
        let after = available.map { $0.cents - summary.toBuy }
        return VStack(alignment: .leading, spacing: 12) {
            StatStrip(items: [
                .init(label: "Planned", value: Money.format(summary.toBuy)),
                .init(label: "Bought", value: Money.format(summary.purchased), tint: Theme.accent),
                .init(label: after.map { $0 >= 0 ? "Left after plan" : "Over by" } ?? "Budget", value: after.map { Money.format(abs($0)) } ?? "Not set",
                      tint: (after ?? 0) < 0 ? Theme.danger : Theme.ink)
            ])
            if let available, let after {
                Text("Measured against \(available.label.lowercased()): \(Money.format(available.cents)).").font(.caption).foregroundStyle(Theme.inkSecondary)
                if after < 0 {
                    Callout(text: "The items still to buy cost \(Money.format(-after)) more than your \(available.label.lowercased()).", tone: .danger)
                } else if available.cents > 0 && Double(summary.toBuy) / Double(available.cents) >= FinanceEngine.warningThreshold {
                    Callout(text: "This plan uses most of your \(available.label.lowercased()).", tone: .warning)
                }
            } else if list == .grocery {
                Text("Set a Groceries limit or monthly total in Budget to compare this list with what you can spend.")
                    .font(.caption).foregroundStyle(Theme.inkTertiary)
            }
            Text("Planned prices are estimates and don’t change your balances or spending.").font(.caption).foregroundStyle(Theme.inkTertiary)
        }
        .surface()
    }

    // MARK: Actions

    private func toggle(_ item: ShoppingItem) {
        item.isPurchased.toggle()
        item.purchasedAt = item.isPurchased ? .now : nil
        Haptics.tap()
        do { try context.save() } catch { errors.report(error, doing: "Couldn’t update item") }
    }

    private func record(_ item: ShoppingItem) {
        do { try Ledger.recordPurchase(item, existing: txs, in: context); Haptics.success() }
        catch { errors.report(error, doing: "Couldn’t record expense") }
    }
}

struct ItemTarget: Identifiable { let id = UUID(); let item: ShoppingItem? }

struct ItemRow: View {
    let item: ShoppingItem
    let recorded: Bool
    var onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: item.isPurchased ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(item.isPurchased ? Theme.accent : Theme.inkTertiary)
                    .frame(width: 36, height: 44)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(item.isPurchased ? "Mark \(item.name) not purchased" : "Mark \(item.name) purchased")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).font(.body)
                        .foregroundStyle(item.isPurchased ? Theme.inkSecondary : Theme.ink)
                        .strikethrough(item.isPurchased, color: Theme.inkTertiary)
                        .lineLimit(1)
                    if item.priority == .high && !item.isPurchased {
                        Image(systemName: "exclamationmark").font(.caption2.weight(.bold)).foregroundStyle(Theme.warning)
                    }
                }
                HStack(spacing: 6) {
                    Text("\(item.quantity) × \(Money.format(item.actualCents ?? item.estimatedCents))" + (item.isPurchased && item.actualCents != nil && item.actualCents != item.estimatedCents ? " · est. \(Money.format(item.estimatedCents))" : ""))
                        .font(.caption).foregroundStyle(Theme.inkSecondary)
                    if recorded { StatusChip(text: "Linked to expense", tint: Theme.accent) }
                    else if item.isPurchased { StatusChip(text: "Not recorded", tint: Theme.warning) }
                }
            }
            Spacer(minLength: 8)
            Text(Money.format(item.isPurchased ? item.effectiveTotal : item.estimatedTotal))
                .font(.figure(15)).foregroundStyle(item.isPurchased ? Theme.inkSecondary : Theme.ink)
        }
        .padding(.vertical, 2)
        .animation(Theme.easeOut(0.2), value: item.isPurchased)
    }
}

struct ItemSheet: View {
    let editing: ShoppingItem?
    let defaultList: ListKind
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ErrorCenter.self) private var errors
    @Query(sort: \MoneyCategory.sortOrder) private var categories: [MoneyCategory]
    @Query private var txs: [TransactionRecord]

    @State private var name = ""
    @State private var quantity = 1
    @State private var estimate = ""
    @State private var actual = ""
    @State private var category = ""
    @State private var priority: Priority = .medium
    @State private var listKind: ListKind = .grocery
    @State private var purchased = false

    private var expenseCategories: [MoneyCategory] { categories.filter { $0.kind == .expense } }
    private var estimateCents: Int? { estimate.isEmpty ? 0 : Money.parse(estimate) }
    private var actualCents: Int? { actual.isEmpty ? nil : Money.parse(actual) }
    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && estimateCents != nil && (actual.isEmpty || actualCents != nil) && !category.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                Section {
                    TextField("Item", text: $name)
                    Stepper("Quantity: \(quantity)", value: $quantity, in: 1...999)
                    HStack { Text("Estimated price (each)"); AmountField(text: $estimate) }
                    Picker("Category", selection: $category) {
                        ForEach(expenseCategories) { Label($0.name, systemImage: $0.symbol).tag($0.name) }
                    }
                    Picker("Priority", selection: $priority) {
                        ForEach(Priority.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("List", selection: $listKind) {
                        ForEach(ListKind.allCases) { Text($0.label).tag($0) }
                    }
                }
                Section {
                    Toggle("Purchased", isOn: $purchased.animation(Theme.easeOut(0.2)))
                    if purchased {
                        HStack { Text("Actual price (each)"); AmountField(text: $actual, placeholder: estimate.isEmpty ? "0.00" : estimate) }
                    }
                } footer: {
                    if let e = estimateCents, quantity > 0 {
                        Text("Total: \(Money.format(quantity * (actualCents ?? e)))")
                    }
                }
                if let editing, purchased {
                    Section {
                        if editing.expenseID != nil {
                            Label("Recorded as an expense", systemImage: "checkmark.circle").foregroundStyle(Theme.accent)
                        } else if Ledger.canRecord(editing, existing: txs) {
                            Button { saveAndRecord(editing) } label: { Label("Save and record as expense", systemImage: "arrow.down.doc") }
                                .disabled(!valid)
                        }
                    } footer: { Text("Each item can be recorded once, so it can never be counted twice.") }
                }
                }.listRowBackground(GlassRowBackground())
            }
            .scrollContentBackground(.hidden).monoScreen()
            .navigationTitle(editing == nil ? "New item" : "Edit item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { _ = save() }.disabled(!valid) }
            }
            .onAppear(perform: load)
        }
        .presentationDetents([.large])
    }

    private func load() {
        if let e = editing {
            name = e.name; quantity = e.quantity; estimate = Money.editable(e.estimatedCents)
            actual = e.actualCents.map { Money.editable($0) } ?? ""; category = e.category; priority = e.priority
            listKind = e.listKind; purchased = e.isPurchased
        } else {
            listKind = defaultList
            category = (defaultList == .grocery ? "Groceries" : "Shopping")
            if !expenseCategories.contains(where: { $0.name == category }) { category = expenseCategories.first?.name ?? "" }
        }
    }

    @discardableResult
    private func save() -> ShoppingItem? {
        guard valid, let est = estimateCents else { return nil }
        let item = editing ?? ShoppingItem(name: "", quantity: 1, estimatedCents: 0, category: category, priority: priority, listKind: listKind)
        item.name = name.trimmingCharacters(in: .whitespaces)
        item.quantity = quantity; item.estimatedCents = est; item.actualCents = purchased ? actualCents : nil
        item.category = category; item.priority = priority; item.listKindRaw = listKind.rawValue
        if purchased && !item.isPurchased { item.purchasedAt = .now }
        if !purchased { item.purchasedAt = nil }
        item.isPurchased = purchased
        if editing == nil { context.insert(item) }
        else if let id = item.expenseID, let tx = txs.first(where: { $0.id == id }) {
            // keep an already-recorded expense in step with the item rather than leaving a stale amount
            tx.amountCents = item.effectiveTotal; tx.category = item.category
            tx.title = item.quantity > 1 ? "\(item.name) ×\(item.quantity)" : item.name
        }
        do { try context.save(); Haptics.success(); dismiss(); return item }
        catch { errors.report(error, doing: "Couldn’t save item"); return nil }
    }

    private func saveAndRecord(_ item: ShoppingItem) {
        guard save() != nil else { return }
        do { try Ledger.recordPurchase(item, existing: txs, in: context) }
        catch { errors.report(error, doing: "Couldn’t record expense") }
    }
}

/// Connect a bought item to an expense you already entered, so recording it again can't create a second one.
struct LinkExpenseSheet: View {
    let item: ShoppingItem
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ErrorCenter.self) private var errors
    @Query(sort: \TransactionRecord.date, order: .reverse) private var txs: [TransactionRecord]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]

    private var candidates: [TransactionRecord] {
        let total = item.effectiveTotal
        let taken = Set(((try? context.fetch(FetchDescriptor<ShoppingItem>())) ?? []).compactMap(\.expenseID))
        return txs.filter { $0.kind == .expense && !taken.contains($0.id) && $0.sourceID == nil }
            .sorted { ($0.amountCents == total ? 0 : 1, -$0.date.timeIntervalSince1970) < ($1.amountCents == total ? 0 : 1, -$1.date.timeIntervalSince1970) }
            .prefix(15).map { $0 }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(candidates) { t in
                        Button {
                            item.expenseID = t.id
                            do { try context.save(); Haptics.success(); dismiss() } catch { errors.report(error, doing: "Couldn’t link") }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.merchant.isEmpty ? (t.title.isEmpty ? t.category : t.title) : t.merchant).foregroundStyle(Theme.ink)
                                    Text(t.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(Theme.inkSecondary)
                                }
                                Spacer()
                                Text(Money.format(t.amountCents, currency: AccountDirectory(accounts).currency(of: t)))
                                    .font(.figure(15)).foregroundStyle(t.amountCents == item.effectiveTotal ? Theme.accent : Theme.ink)
                            }
                        }
                    }
                } header: { Text("Expenses worth \(Money.format(item.effectiveTotal)) first") }
                footer: { Text("Linking doesn’t change the expense. It only marks “\(item.name)” as already recorded.") }
            }
            .scrollContentBackground(.hidden).monoScreen()
            .navigationTitle("Link to expense").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
