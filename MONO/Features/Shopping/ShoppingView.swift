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
    @AppStorage("openingBalanceCents") private var opening = 0

    @State private var list: ListKind = .grocery
    @State private var sheet: ItemTarget?
    @State private var pendingDelete: ShoppingItem?
    @State private var confirmClear = false

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
        if list == .wishlist {
            return ("Available cash", FinanceEngine.availableCash(opening: opening, transactions: txs, entries: entries))
        }
        let b = FinanceEngine.budgetSummary(month: month, totalLimit: monthBudgets.first { $0.monthKey == month.string }?.totalCents,
                                            limits: limits, transactions: txs)
        if let l = b.lines.first(where: { $0.category == "Groceries" }) { return ("Groceries budget left", max(l.remaining, 0)) }
        if let r = b.remaining { return ("Monthly budget left", max(r, 0)) }
        return nil
    }
    private var unrecorded: [ShoppingItem] { items.filter { $0.isPurchased && Ledger.canRecord($0, existing: txs) } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("List", selection: $list) {
                        ForEach(ListKind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    summaryBlock
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                if items.isEmpty {
                    EmptyState(symbol: list == .grocery ? "cart" : "gift",
                               title: list == .grocery ? "No groceries listed" : "Wishlist is empty",
                               message: list == .grocery ? "Add what you need this week with estimated prices to see the total before you shop."
                                                          : "Keep longer-term purchases here, separate from everyday groceries.",
                               actionTitle: "Add item") { sheet = ItemTarget(item: nil) }
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                } else {
                    Section {
                        ForEach(items) { item in
                            ItemRow(item: item, recorded: item.expenseID != nil, onToggle: { toggle(item) })
                                .contentShape(Rectangle())
                                .onTapGesture { sheet = ItemTarget(item: item) }
                                .listRowBackground(GlassRowBackground()).listRowSeparatorTint(Theme.line)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) { pendingDelete = item } label: { Label("Delete", systemImage: "trash") }
                                    if item.isPurchased && Ledger.canRecord(item, existing: txs) {
                                        Button { record(item) } label: { Label("Record", systemImage: "arrow.down.doc") }.tint(Theme.accent)
                                    }
                                }
                        }
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
                                    Label("Remove purchased items", systemImage: "trash")
                                }
                            }
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
                        .accessibilityLabel("Add item")
                }
            }
            .sheet(item: $sheet) { ItemSheet(editing: $0.item, defaultList: list) }
            .confirmationDialog("Delete this item?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible, presenting: pendingDelete) { item in
                Button("Delete", role: .destructive) {
                    context.delete(item); try? context.save()
                }
            } message: { item in
                Text(item.expenseID != nil ? "The expense already recorded for “\(item.name)” stays in your transactions." : item.name)
            }
            .confirmationDialog("Remove \(summary.purchasedCount) purchased \(summary.purchasedCount == 1 ? "item" : "items")?",
                                isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    items.filter(\.isPurchased).forEach { context.delete($0) }
                    try? context.save()
                }
            } message: {
                Text(unrecorded.isEmpty ? "Recorded expenses stay in your transactions."
                                        : "\(unrecorded.count) of them have not been recorded as expenses and will be lost from the list.")
            }
        }
    }

    // MARK: Summary

    private var summaryBlock: some View {
        let after = available.map { $0.cents - summary.toBuy }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                Metric(label: "To buy · \(summary.toBuyCount)", value: Money.format(summary.toBuy))
                Metric(label: "Bought · \(summary.purchasedCount)", value: Money.format(summary.purchased), tint: Theme.accent)
            }
            if let available, let after {
                Hairline()
                HStack(alignment: .top, spacing: 16) {
                    Metric(label: available.label, value: Money.format(available.cents))
                    Metric(label: after >= 0 ? "Left after plan" : "Over by", value: Money.format(abs(after)),
                           tint: after >= 0 ? Theme.ink : Theme.danger)
                }
                if after < 0 {
                    Callout(text: "The items still to buy cost \(Money.format(-after)) more than your \(available.label.lowercased()).", tone: .danger)
                } else if available.cents > 0 && Double(summary.toBuy) / Double(available.cents) >= FinanceEngine.warningThreshold {
                    Callout(text: "This plan uses most of your \(available.label.lowercased()).", tone: .warning)
                }
            } else if list == .grocery {
                Text("Set a Groceries limit or monthly total in Budget to compare this list with what you can spend.")
                    .font(.caption).foregroundStyle(Theme.inkTertiary)
            }
        }
        .padding(.vertical, 4)
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
                    Text("\(item.quantity) × \(Money.format(item.actualCents ?? item.estimatedCents))")
                        .font(.caption).foregroundStyle(Theme.inkSecondary)
                    if recorded { StatusChip(text: "Recorded", tint: Theme.accent) }
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
