import SwiftUI
import SwiftData

struct BudgetView: View {
    @Environment(\.modelContext) private var context
    @Environment(ErrorCenter.self) private var errors
    @Query private var txs: [TransactionRecord]
    @Query private var monthBudgets: [MonthBudget]
    @Query private var limits: [BudgetLimit]
    @Query(sort: \PlannedExpense.dueDate) private var planned: [PlannedExpense]
    @Query(sort: \MoneyCategory.sortOrder) private var categories: [MoneyCategory]

    @State private var month = MonthKey(.now)
    @State private var showTotal = false
    @State private var limitSheet: LimitTarget?
    @State private var plannedSheet: PlannedTarget?

    private var current: MonthKey { MonthKey(.now) }
    private var explicitTotal: Int? { monthBudgets.first { $0.monthKey == month.string }?.totalCents }
    private var summary: BudgetSummary {
        FinanceEngine.budgetSummary(month: month, totalLimit: explicitTotal, limits: limits, transactions: txs)
    }
    private var previousHasBudget: Bool {
        let p = month.adding(-1).string
        return monthBudgets.contains { $0.monthKey == p } || limits.contains { $0.monthKey == p }
    }
    private var hasBudget: Bool { summary.total != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    monthSelector
                    if hasBudget { overview.card().entrance(0); limitsSection.card().entrance(1) }
                    else { emptyBudget }
                    plannedSection.card().entrance(2)
                }
                .padding(.horizontal, Theme.gutter).padding(.bottom, 32)
            }
            .monoScreen()
            .navigationTitle("Budget")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showTotal = true } label: { Label("Set monthly total", systemImage: "equal.circle") }
                        Button { limitSheet = LimitTarget(limit: nil) } label: { Label("Add category limit", systemImage: "plus.circle") }
                        if previousHasBudget {
                            Button { copyPrevious() } label: { Label("Copy \(month.adding(-1).shortTitle()) budget", systemImage: "doc.on.doc") }
                            Button { copyPrevious(carryOver: true) } label: {
                                Label("Copy \(month.adding(-1).shortTitle()) + unspent", systemImage: "arrow.uturn.forward.circle")
                            }
                        }
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Budget actions")
                }
            }
            .sheet(isPresented: $showTotal) { BudgetTotalSheet(month: month, current: explicitTotal, derived: summary.lines.reduce(0) { $0 + $1.limit }) }
            .sheet(item: $limitSheet) { LimitSheet(month: month, editing: $0.limit) }
            .sheet(item: $plannedSheet) { PlannedSheet(editing: $0.expense) }
        }
    }

    // MARK: Month selector

    private var monthSelector: some View {
        HStack {
            Button { month = month.adding(-1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 36) }
                .accessibilityLabel("Previous month")
            Spacer()
            VStack(spacing: 1) {
                Text(month.title()).font(.headline).contentTransition(.opacity)
                if month != current {
                    Button("Back to this month") { month = current }
                        .font(.caption).foregroundStyle(Theme.accent)
                }
            }
            Spacer()
            Button { month = month.adding(1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 36) }
                .disabled(month >= current.adding(12))
                .accessibilityLabel("Next month")
        }
        .foregroundStyle(Theme.ink)
        .buttonStyle(PressableStyle())
        .animation(Theme.easeOut(0.18), value: month)
    }

    // MARK: Overview

    private var overview: some View {
        let s = summary
        let tint = color(for: s.state ?? .ok)
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Spent").font(.footnote).foregroundStyle(Theme.inkSecondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Money.format(s.spent)).font(.figure(34, weight: .light)).foregroundStyle(Theme.ink)
                        .contentTransition(.numericText())
                    Text("of \(Money.format(s.total ?? 0))").font(.subheadline).foregroundStyle(Theme.inkSecondary)
                }
            }
            ProgressLine(value: s.fraction ?? 0, tint: tint, height: 6)
            HStack(alignment: .top, spacing: 16) {
                if s.overBy > 0 {
                    Metric(label: "Over budget", value: Money.format(s.overBy), tint: Theme.danger)
                } else {
                    Metric(label: "Remaining", value: Money.format(s.remaining ?? 0))
                }
                Metric(label: "Used", value: "\(Int(((s.fraction ?? 0) * 100).rounded()))%", tint: (s.state == .over || s.state == .warning) ? tint : Theme.ink)
                if let a = s.dailyAllowance {
                    Metric(label: "Daily allowance", value: Money.format(a), footnote: "\(s.daysLeft) \(s.daysLeft == 1 ? "day" : "days") left")
                } else {
                    Metric(label: "Daily allowance", value: "—", footnote: month < current ? "Month ended" : nil)
                }
            }
            if s.state == .over {
                Callout(text: "You’re \(Money.format(s.overBy)) over the \(month.shortTitle()) budget.", tone: .danger)
            } else if s.state == .warning {
                Callout(text: "\(Int(((s.fraction ?? 0) * 100).rounded()))% of the budget is used. About \(Money.format(s.dailyAllowance ?? 0)) a day keeps you within it.", tone: .warning)
            }
            if explicitTotal == nil, !s.lines.isEmpty {
                Text("Total is the sum of your category limits. Set a monthly total to budget beyond them.")
                    .font(.caption).foregroundStyle(Theme.inkTertiary)
            }
        }
    }

    // MARK: Category limits

    private var limitsSection: some View {
        let s = summary
        return VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "Category limits", trailing: "Add") { limitSheet = LimitTarget(limit: nil) }
                .padding(.bottom, 6)
            if s.lines.isEmpty {
                Text("No category limits for this month yet.").font(.subheadline).foregroundStyle(Theme.inkSecondary).padding(.vertical, 8)
            }
            ForEach(Array(s.lines.enumerated()), id: \.element.id) { i, line in
                Button {
                    limitSheet = LimitTarget(limit: limits.first { $0.monthKey == month.string && $0.category == line.category })
                } label: { LimitRow(line: line, symbol: categories.symbol(for: line.category), allowance: s.dailyAllowance(for: line)) }
                    .buttonStyle(PressableStyle())
                if i < s.lines.count - 1 { Hairline() }
            }
            if s.unbudgetedSpent > 0 {
                Text("\(Money.format(s.unbudgetedSpent)) was spent in categories without a limit.")
                    .font(.caption).foregroundStyle(Theme.inkTertiary).padding(.top, 8)
            }
        }
    }

    private var emptyBudget: some View {
        VStack(spacing: 10) {
            EmptyState(symbol: "chart.pie", title: "No budget for \(month.title())",
                       message: "Set a monthly total or limits for categories like Food and Transportation to see what’s left each day.",
                       actionTitle: "Set monthly total") { showTotal = true }
            if previousHasBudget {
                Button("Copy \(month.adding(-1).title()) budget") { copyPrevious() }
                    .font(.subheadline).foregroundStyle(Theme.accent)
                Button("Copy and add what was left unspent") { copyPrevious(carryOver: true) }
                    .font(.subheadline).foregroundStyle(Theme.accent)
            }
        }
    }

    // MARK: Planned expenses

    private var plannedSection: some View {
        let upcoming = FinanceEngine.upcoming(planned)
        return VStack(alignment: .leading, spacing: 4) {
            SectionHeader(title: "Planned expenses", trailing: "Add") { plannedSheet = PlannedTarget(expense: nil) }
                .padding(.bottom, 6)
            if upcoming.isEmpty {
                Text("Bills and purchases you know are coming. Mark one paid to record it as an expense.")
                    .font(.subheadline).foregroundStyle(Theme.inkSecondary).padding(.vertical, 8)
            }
            ForEach(Array(upcoming.enumerated()), id: \.element.id) { i, p in
                PlannedRow(expense: p, symbol: categories.symbol(for: p.category),
                           onEdit: { plannedSheet = PlannedTarget(expense: p) },
                           onPaid: { markPaid(p) })
                if i < upcoming.count - 1 { Hairline() }
            }
        }
    }

    // MARK: Actions

    private func color(for s: BudgetState) -> Color {
        switch s { case .ok: Theme.accent; case .warning: Theme.warning; case .over: Theme.danger }
    }

    /// Copies last month's budget into this month. With `carryOver`, each limit (and an explicit total) also gains
    /// whatever was left unspent under it. Existing limits for this month are never overwritten.
    private func copyPrevious(carryOver: Bool = false) {
        let prevMonth = month.adding(-1)
        let prev = prevMonth.string
        let prevTotal = monthBudgets.first(where: { $0.monthKey == prev })?.totalCents
        let plan = carryOver
            ? FinanceEngine.rollover(from: prevMonth, totalLimit: prevTotal, limits: limits, transactions: txs)
            : FinanceEngine.BudgetRollover(totalCents: prevTotal,
                                           limits: limits.filter { $0.monthKey == prev }.map { ($0.category, $0.limitCents) })
        if let t = plan.totalCents, explicitTotal == nil { context.insert(MonthBudget(monthKey: month.string, totalCents: t)) }
        for l in plan.limits where !limits.contains(where: { $0.monthKey == month.string && $0.category == l.category }) {
            context.insert(BudgetLimit(monthKey: month.string, category: l.category, limitCents: l.cents))
        }
        do { try context.save(); Haptics.success() } catch { errors.report(error, doing: "Couldn’t copy budget") }
    }

    private func markPaid(_ p: PlannedExpense) {
        do { try Ledger.markPaid(p, existing: txs, in: context); Haptics.success() }
        catch { errors.report(error, doing: "Couldn’t record payment") }
    }
}

struct LimitTarget: Identifiable { let id = UUID(); let limit: BudgetLimit? }
struct PlannedTarget: Identifiable { let id = UUID(); let expense: PlannedExpense? }

struct LimitRow: View {
    let line: BudgetLine
    let symbol: String
    let allowance: Int?

    var body: some View {
        let tint: Color = line.state == .over ? Theme.danger : line.state == .warning ? Theme.warning : Theme.accent
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                CategoryGlyph(symbol: symbol, tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.category).font(.body).foregroundStyle(Theme.ink)
                    Text("\(Money.format(line.spent)) of \(Money.format(line.limit))")
                        .font(.caption).foregroundStyle(Theme.inkSecondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if line.overBy > 0 {
                        Text("\(Money.format(line.overBy)) over").font(.figure(14)).foregroundStyle(Theme.danger)
                    } else {
                        Text("\(Money.format(line.remaining)) left").font(.figure(14)).foregroundStyle(Theme.ink)
                    }
                    if let a = allowance, line.overBy == 0 {
                        Text("\(Money.format(a))/day").font(.caption).foregroundStyle(Theme.inkTertiary)
                    }
                }
            }
            ProgressLine(value: line.fraction, tint: tint)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct PlannedRow: View {
    let expense: PlannedExpense
    let symbol: String
    var onEdit: () -> Void
    var onPaid: () -> Void

    var body: some View {
        let overdue = expense.dueDate < Calendar.current.startOfDay(for: .now)
        HStack(spacing: 12) {
            Button(action: onEdit) {
                HStack(spacing: 12) {
                    CategoryGlyph(symbol: symbol, tint: overdue ? Theme.warning : Theme.inkSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(expense.title).font(.body).foregroundStyle(Theme.ink).lineLimit(1)
                        Text(overdue ? "Overdue · \(expense.dueDate.short)" : "Due \(expense.dueDate.short)")
                            .font(.caption).foregroundStyle(overdue ? Theme.warning : Theme.inkSecondary)
                    }
                    Spacer(minLength: 6)
                    Text(Money.format(expense.amountCents)).font(.figure(15)).foregroundStyle(Theme.ink)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            Button(action: onPaid) {
                Image(systemName: "checkmark.circle").font(.system(size: 22, weight: .light))
                    .foregroundStyle(Theme.accent).frame(width: 40, height: 40)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Mark \(expense.title) paid")
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Sheets

struct BudgetTotalSheet: View {
    let month: MonthKey
    let current: Int?
    let derived: Int
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ErrorCenter.self) private var errors
    @Query private var monthBudgets: [MonthBudget]
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Group {
                Section {
                    HStack { Text("Monthly total"); AmountField(text: $text) }
                } footer: {
                    Text(derived > 0 ? "Leave empty to use the sum of your category limits (\(Money.format(derived)))."
                                     : "Total you plan to spend across all categories in \(month.title()).")
                }
                if current != nil {
                    Section { Button("Remove monthly total", role: .destructive) { remove() } }
                }
                }.listRowBackground(GlassRowBackground())
            }
            .scrollContentBackground(.hidden).monoScreen()
            .navigationTitle("\(month.title())")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(!valid) }
            }
            .onAppear { text = Money.editable(current ?? 0) }
        }
        .presentationDetents([.medium])
    }

    private var valid: Bool { text.isEmpty ? true : (Money.parse(text) ?? 0) > 0 }

    private func save() {
        let existing = monthBudgets.first { $0.monthKey == month.string }
        if text.isEmpty { if let existing { context.delete(existing) } }
        else if let cents = Money.parse(text), cents > 0 {
            if let existing { existing.totalCents = cents } else { context.insert(MonthBudget(monthKey: month.string, totalCents: cents)) }
        }
        do { try context.save(); Haptics.success(); dismiss() } catch { errors.report(error, doing: "Couldn’t save budget") }
    }

    private func remove() {
        if let e = monthBudgets.first(where: { $0.monthKey == month.string }) { context.delete(e) }
        try? context.save(); dismiss()
    }
}

struct LimitSheet: View {
    let month: MonthKey
    let editing: BudgetLimit?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ErrorCenter.self) private var errors
    @Query(sort: \MoneyCategory.sortOrder) private var categories: [MoneyCategory]
    @Query private var limits: [BudgetLimit]
    @State private var category = ""
    @State private var text = ""
    @State private var confirmDelete = false

    private var available: [MoneyCategory] {
        categories.filter { c in
            c.kind == .expense && (c.name == editing?.category || !limits.contains { $0.monthKey == month.string && $0.category == c.name })
        }
    }
    private var cents: Int? { Money.parse(text).flatMap { $0 > 0 ? $0 : nil } }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                Section {
                    Picker("Category", selection: $category) {
                        ForEach(available) { Label($0.name, systemImage: $0.symbol).tag($0.name) }
                    }
                    .disabled(editing != nil)
                    HStack { Text("Monthly limit"); AmountField(text: $text) }
                } footer: { Text("For \(month.title()).") }
                if editing != nil {
                    Section { Button("Delete limit", role: .destructive) { confirmDelete = true } }
                }
                }.listRowBackground(GlassRowBackground())
            }
            .scrollContentBackground(.hidden).monoScreen()
            .navigationTitle(editing == nil ? "Category limit" : editing!.category)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).disabled(cents == nil || category.isEmpty) }
            }
            .onAppear {
                category = editing?.category ?? available.first?.name ?? ""
                text = Money.editable(editing?.limitCents ?? 0)
            }
            .confirmationDialog("Delete this limit?", isPresented: $confirmDelete, titleVisibility: .visible) {
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
        if let editing { editing.limitCents = cents }
        else { context.insert(BudgetLimit(monthKey: month.string, category: category, limitCents: cents)) }
        do { try context.save(); Haptics.success(); dismiss() } catch { errors.report(error, doing: "Couldn’t save limit") }
    }
}

struct PlannedSheet: View {
    let editing: PlannedExpense?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ErrorCenter.self) private var errors
    @Query(sort: \MoneyCategory.sortOrder) private var categories: [MoneyCategory]
    @State private var title = ""
    @State private var text = ""
    @State private var due = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
    @State private var category = ""
    @State private var confirmDelete = false

    private var cents: Int? { Money.parse(text).flatMap { $0 > 0 ? $0 : nil } }
    private var expenseCategories: [MoneyCategory] { categories.filter { $0.kind == .expense } }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                Section {
                    TextField("What is it for?", text: $title)
                    HStack { Text("Amount"); AmountField(text: $text) }
                    DatePicker("Due", selection: $due, displayedComponents: .date)
                    Picker("Category", selection: $category) {
                        ForEach(expenseCategories) { Label($0.name, systemImage: $0.symbol).tag($0.name) }
                    }
                }
                if editing != nil { Section { Button("Delete", role: .destructive) { confirmDelete = true } } }
                }.listRowBackground(GlassRowBackground())
            }
            .scrollContentBackground(.hidden).monoScreen()
            .navigationTitle(editing == nil ? "Planned expense" : "Edit planned expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(cents == nil || title.trimmingCharacters(in: .whitespaces).isEmpty || category.isEmpty)
                }
            }
            .onAppear {
                if let e = editing { title = e.title; text = Money.editable(e.amountCents); due = e.dueDate; category = e.category }
                else { category = expenseCategories.first?.name ?? "" }
            }
            .confirmationDialog("Delete this planned expense?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let editing { context.delete(editing); try? context.save() }
                    dismiss()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        guard let cents else { return }
        let t = title.trimmingCharacters(in: .whitespaces)
        if let e = editing { e.title = t; e.amountCents = cents; e.dueDate = due; e.category = category }
        else { context.insert(PlannedExpense(title: t, amountCents: cents, dueDate: due, category: category)) }
        do { try context.save(); Haptics.success(); dismiss() } catch { errors.report(error, doing: "Couldn’t save") }
    }
}
