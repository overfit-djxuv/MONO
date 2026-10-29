import SwiftUI
import SwiftData

struct GoalDetailView: View {
    let goal: SavingsGoal
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ErrorCenter.self) private var errors
    @Query private var allEntries: [GoalEntry]
    @Query private var allCosts: [TripCost]

    @State private var moveSheet: Bool?          // false = add, true = withdraw
    @State private var costSheet: CostTarget?
    @State private var showEdit = false
    @State private var showCompare = false
    @State private var confirmDelete = false
    @State private var pendingEntry: GoalEntry?

    private var entries: [GoalEntry] { allEntries.filter { $0.goalID == goal.id }.sorted { $0.date > $1.date } }
    private var costs: [TripCost] { allCosts.filter { $0.goalID == goal.id } }
    private var plan: SavingsPlan { SavingsPlanner.plan(for: goal, costs: allCosts, entries: allEntries) }

    var body: some View {
        let p = plan
        List {
            VStack(alignment: .leading, spacing: 18) {
                hero(p)
                metrics(p)
                messages(p)
                progressChart
                actions
            }
            .listRowBackground(Color.clear).listRowSeparator(.hidden).listRowInsets(EdgeInsets(top: 8, leading: Theme.gutter, bottom: 8, trailing: Theme.gutter))

            if goal.kind == .trip { costSection }
            historySection
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).monoScreen()
        .navigationTitle(goal.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showEdit = true } label: { Label("Edit plan", systemImage: "pencil") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete goal", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(item: Binding(get: { moveSheet.map { MoveTarget(withdraw: $0) } }, set: { if $0 == nil { moveSheet = nil } })) {
            MoveMoneySheet(goal: goal, withdraw: $0.withdraw)
        }
        .sheet(item: $costSheet) { CostSheet(goal: goal, editing: $0.cost) }
        .sheet(isPresented: $showEdit) { GoalForm(kind: goal.kind, editing: goal) }
        .sheet(isPresented: $showCompare) { ScenarioSheet(goal: goal) }
        .confirmationDialog("Delete “\(goal.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete goal", role: .destructive) {
                do { try Ledger.delete(goal, entries: allEntries, costs: allCosts, in: context); dismiss() }
                catch { errors.report(error, doing: "Couldn’t delete goal") }
            }
        } message: {
            let fromCash = entries.filter(\.affectsCash).reduce(0) { $0 + $1.amountCents }
            Text(fromCash > 0 ? "Its history and costs will be removed, and the \(goal.money(fromCash)) you moved here from cash returns to your available cash."
                              : "Its history and costs will be removed.")
        }
        .confirmationDialog("Delete this entry?", isPresented: Binding(get: { pendingEntry != nil }, set: { if !$0 { pendingEntry = nil } }),
                            titleVisibility: .visible, presenting: pendingEntry) { e in
            Button("Delete", role: .destructive) { context.delete(e); try? context.save() }
        } message: { e in
            Text("\(goal.money(abs(e.amountCents))) \(e.amountCents < 0 ? "withdrawal" : "contribution") on \(e.date.short). Balances will be recalculated.")
        }
    }

    // MARK: Sections

    private func hero(_ p: SavingsPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(goal.kind == .trip ? "Saved for trip" : "Saved").font(.footnote).foregroundStyle(Theme.inkSecondary)
                Spacer()
                StatusChip(text: p.statusText, tint: p.statusTint)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(goal.money(p.saved)).font(.figure(34, weight: .light)).foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                Text("of \(goal.money(p.target))").font(.subheadline).foregroundStyle(Theme.inkSecondary)
            }
            ProgressLine(value: p.percentFunded, tint: p.status == .overdue ? Theme.danger : Theme.accent, height: 6)
            if let d = goal.deadline {
                Text(deadlineText(p, date: d)).font(.footnote).foregroundStyle(Theme.inkSecondary)
            }
            if !goal.details.isEmpty {
                Text(goal.details).font(.subheadline).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Label("\(goal.priority.label) priority", systemImage: goal.priority == .high ? "exclamationmark" : "flag")
                    .font(.caption.weight(.medium)).foregroundStyle(goal.priority == .high ? Theme.warning : Theme.inkSecondary)
                    .padding(.vertical, 3).padding(.horizontal, 8).background(Theme.accentSoft, in: Capsule())
                if goal.currencyCode != "" && goal.currencyCode != Money.reporting.code {
                    Text(goal.currency.code).font(.caption.weight(.medium)).foregroundStyle(Theme.inkSecondary)
                        .padding(.vertical, 3).padding(.horizontal, 8).background(Theme.accentSoft, in: Capsule())
                }
            }
        }
    }

    private func deadlineText(_ p: SavingsPlan, date: Date) -> String {
        let noun = goal.kind == .trip ? "Departure" : "Deadline"
        guard let days = p.daysToDeadline else { return "\(noun) \(date.short)" }
        if p.status == .funded { return "\(noun) \(date.short)" }
        if days < 0 { return "\(noun) was \(date.short) · \(-days) \(-days == 1 ? "day" : "days") ago" }
        if days == 0 { return "\(noun) is today" }
        return "\(noun) \(date.short) · \(days) \(days == 1 ? "day" : "days") to go"
    }

    @State private var showPlanDetails = false

    @ViewBuilder private var progressChart: some View {
        let points = FinanceEngine.savingsGrowth(entries: entries, through: MonthKey(.now))
        if points.count >= 2 {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Progress")
                SavingsGrowthChart(points: points, height: 110).hidesAmounts()
            }.surface()
        }
    }

    private func metrics(_ p: SavingsPlan) -> some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                Metric(label: "Left to save", value: goal.money(p.remaining))
                Metric(label: "Needed each \(goal.frequency.noun)",
                       value: p.status == .funded ? "—" : (p.requiredMonthly.map { goal.money($0) } ?? (p.remaining > 0 ? "Due now" : "—")),
                       footnote: p.status == .funded || p.requiredMonthly == nil ? nil : "to finish by the date")
            }
            if p.status != .funded, p.remaining > 0 {
                HStack(alignment: .top, spacing: 16) {
                    Metric(label: "Estimated completion",
                           value: p.estimatedCompletion?.formatted(.dateTime.day().month(.abbreviated).year()) ?? "—",
                           tint: estimateTint(p), footnote: estimateNote(p))
                    Metric(label: "Funded", value: "\(Int((p.percentFunded * 100).rounded()))%")
                }
            }
            DisclosureGroup(isExpanded: $showPlanDetails) {
                VStack(spacing: 14) {
                    HStack(alignment: .top, spacing: 16) {
                        Metric(label: "Contributions left", value: goal.deadline == nil ? "—" : "\(p.contributionsRemaining)",
                               footnote: goal.plannedMonthlyCents > 0 ? "\(goal.money(goal.plannedMonthlyCents)) each \(goal.frequency.noun)\(goal.frequency == .monthly ? ", day \(goal.contributionDay)" : "")" : "No plan set")
                        if let m = p.requiredMonthlyEquivalent, p.status != .funded {
                            Metric(label: "Monthly equivalent", value: goal.money(m), footnote: "left to save ÷ \(p.monthsRemaining.map { String(format: "%.1f", $0) } ?? "—") months left")
                        } else { Color.clear.frame(maxWidth: .infinity) }
                    }
                    if goal.deadline != nil {
                        HStack(alignment: .top, spacing: 16) {
                            Metric(label: goal.kind == .trip ? "Expected at departure" : "Expected at deadline",
                                   value: goal.money(p.expectedAtDeadline), tint: p.expectedAtDeadline >= p.target ? Theme.accent : Theme.ink)
                            Metric(label: p.shortfall > 0 ? "Shortfall" : "Surplus",
                                   value: goal.money(p.shortfall > 0 ? p.shortfall : p.surplus), tint: p.shortfall > 0 ? Theme.warning : Theme.ink)
                        }
                    }
                }.padding(.top, 10)
            } label: { Text("Plan details").font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink) }
            .tint(Theme.inkSecondary)
        }
        .surface()
    }

    private func estimateTint(_ p: SavingsPlan) -> Color {
        guard let est = p.estimatedCompletion, let d = goal.deadline else { return Theme.ink }
        return est > d ? Theme.warning : Theme.ink
    }

    private func estimateNote(_ p: SavingsPlan) -> String {
        switch p.estimateBasis {
        case .plan: "Estimate at your plan"
        case .actualPace: "Estimate at your recent pace"
        case .none: "Add a plan to see an estimate"
        }
    }

    @ViewBuilder private func messages(_ p: SavingsPlan) -> some View {
        switch p.status {
        case .funded:
            Callout(text: "Fully funded. You’ve saved \(goal.money(p.saved)) of \(goal.money(p.target)).", tone: .info, symbol: "checkmark.circle")
        case .overdue:
            Callout(text: "The date has passed with \(goal.money(p.remaining)) still to save. Move the date or compare plans.", tone: .danger)
        case .behind:
            if p.needsLumpSum {
                Callout(text: "No contribution dates remain before then. \(goal.money(p.remaining)) is still needed — add it now or move the date.", tone: .warning)
            } else {
                Callout(text: "At \(goal.money(goal.plannedMonthlyCents)) each \(goal.frequency.noun) you’ll be \(goal.money(p.shortfall)) short. Contributing \(goal.money(p.requiredMonthly ?? 0)) each \(goal.frequency.noun) closes the gap.", tone: .warning)
            }
        case .onTrack:
            Callout(text: "On track: planned contributions reach \(goal.money(p.expectedAtDeadline)) by the date.", tone: .info, symbol: "checkmark.circle")
        case .open:
            if let m = p.monthsAtPlannedPace {
                Callout(text: "At \(goal.money(goal.plannedMonthlyCents)) each \(goal.frequency.noun), about \(m) \(m == 1 ? "month" : "months") to go.", tone: .info)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button { moveSheet = false } label: { Label("Add money", systemImage: "plus") }
                    .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("addMoney")
                Button { moveSheet = true } label: {
                    Label("Withdraw", systemImage: "arrow.down.left")
                        .font(.body.weight(.medium)).foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line, lineWidth: 1))
                }
                .buttonStyle(PressableStyle())
                .disabled(entries.isEmpty)
            }
            Button { showCompare = true } label: { Label("Compare plans", systemImage: "arrow.left.arrow.right") }
                .font(.subheadline.weight(.medium)).foregroundStyle(Theme.accent)
                .buttonStyle(PressableStyle())
        }
    }

    private var costSection: some View {
        Section {
            ForEach(costs.sorted { $0.categoryRaw < $1.categoryRaw }) { c in
                Button { costSheet = CostTarget(cost: c) } label: {
                    HStack(spacing: 12) {
                        CategoryGlyph(symbol: c.category.symbol, tint: Theme.inkSecondary)
                        Text(c.label.isEmpty ? c.category.label : "\(c.category.label) · \(c.label)").font(.body).foregroundStyle(Theme.ink).lineLimit(1)
                        Spacer()
                        Text(goal.money(c.amountCents)).font(.figure(15)).foregroundStyle(Theme.ink)
                    }
                }
                .buttonStyle(PressableStyle())
                .listRowBackground(GlassRowBackground()).listRowSeparatorTint(Theme.line)
            }
            if goal.bufferCents > 0 {
                HStack {
                    CategoryGlyph(symbol: "shield", tint: Theme.inkSecondary)
                    Text("Emergency buffer").font(.body).foregroundStyle(Theme.ink)
                    Spacer()
                    Text(goal.money(goal.bufferCents)).font(.figure(15)).foregroundStyle(Theme.ink)
                }
                .listRowBackground(GlassRowBackground()).listRowSeparatorTint(Theme.line)
            }
            Button { costSheet = CostTarget(cost: nil) } label: { Label("Add cost", systemImage: "plus").font(.subheadline) }
                .foregroundStyle(Theme.accent).listRowBackground(GlassRowBackground())
        } header: {
            HStack {
                SectionHeader(title: "Estimated costs")
                Text(goal.money(SavingsPlanner.tripTarget(costs: allCosts, goal: goal))).font(.figure(13)).foregroundStyle(Theme.inkSecondary)
            }
            .textCase(nil)
        }
    }

    private var historySection: some View {
        Section {
            if entries.isEmpty {
                Text("No contributions yet. Add money when you set some aside.")
                    .font(.subheadline).foregroundStyle(Theme.inkSecondary)
                    .listRowBackground(GlassRowBackground()).listRowSeparator(.hidden)
            }
            ForEach(entries) { e in
                HStack(spacing: 12) {
                    CategoryGlyph(symbol: e.amountCents < 0 ? "arrow.down.left" : "arrow.up.right",
                                  tint: e.amountCents < 0 ? Theme.warning : Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.note.isEmpty ? (e.amountCents < 0 ? "Withdrawal" : "Contribution") : e.note).font(.body).foregroundStyle(Theme.ink).lineLimit(1)
                        Text(e.date.short + (e.affectsCash ? "" : " · not from cash")).font(.caption).foregroundStyle(Theme.inkSecondary)
                    }
                    Spacer()
                    Text(goal.money(e.amountCents, signed: true)).font(.figure(15)).foregroundStyle(e.amountCents < 0 ? Theme.ink : Theme.accent)
                }
                .listRowBackground(GlassRowBackground()).listRowSeparatorTint(Theme.line)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { pendingEntry = e } label: { Label("Delete", systemImage: "trash") }
                }
            }
        } header: { SectionHeader(title: "History").textCase(nil) }
    }
}

struct CostTarget: Identifiable { let id = UUID(); let cost: TripCost? }
struct MoveTarget: Identifiable { let withdraw: Bool; var id: Bool { withdraw } }
