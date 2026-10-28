import SwiftUI
import SwiftData

extension SavingsPlan {
    var statusText: String {
        switch status {
        case .funded: "Funded"
        case .onTrack: "On track"
        case .behind: "Behind plan"
        case .overdue: "Overdue"
        case .open: "No deadline"
        }
    }
    var statusTint: Color {
        switch status {
        case .funded, .onTrack: Theme.accent
        case .behind: Theme.warning
        case .overdue: Theme.danger
        case .open: Theme.inkSecondary
        }
    }
}

struct GoalsView: View {
    @Query(sort: \SavingsGoal.createdAt) private var goals: [SavingsGoal]
    @Query private var entries: [GoalEntry]
    @Query private var costs: [TripCost]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var rates: [ExchangeRate]

    @State private var newKind: GoalKind?
    @State private var path: [SavingsGoal] = []

    /// Most important first, then soonest deadline.
    private func ordered(_ list: [SavingsGoal]) -> [SavingsGoal] {
        list.sorted { ($0.priorityRaw, $1.deadline ?? .distantFuture) > ($1.priorityRaw, $0.deadline ?? .distantFuture) }
    }
    private var trips: [SavingsGoal] { ordered(goals.filter { $0.kind == .trip }) }
    private var others: [SavingsGoal] { ordered(goals.filter { $0.kind == .general }) }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if goals.isEmpty {
                        EmptyState(symbol: "flag", title: "No goals yet",
                                   message: "Plan a trip or save for something specific. Money you move into a goal leaves your available cash, so nothing is counted twice.",
                                   actionTitle: "Plan a trip") { newKind = .trip }
                        Button("New savings goal") { newKind = .general }
                            .font(.subheadline).foregroundStyle(Theme.accent).frame(maxWidth: .infinity)
                    } else {
                        header.entrance(0)
                        if !trips.isEmpty { section("Trips", trips).entrance(1) }
                        if !others.isEmpty { section("Savings goals", others).entrance(2) }
                    }
                }
                .padding(.horizontal, Theme.gutter).padding(.bottom, 32)
            }
            .monoScreen()
            .navigationTitle("Goals")
            .navigationDestination(for: SavingsGoal.self) { GoalDetailView(goal: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { newKind = .trip } label: { Label("Plan a trip", systemImage: "airplane") }
                        Button { newKind = .general } label: { Label("New savings goal", systemImage: "target") }
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New goal")
                }
            }
            .sheet(item: $newKind) { GoalForm(kind: $0, editing: nil) }
        }
    }

    private var header: some View {
        let saved = Books(accounts: accounts, rates: rates, transactions: [], entries: []).savedTotal(goals: goals, entries: entries)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Saved across goals").font(.footnote).foregroundStyle(Theme.inkSecondary)
            Text(Money.format(saved.total)).font(.figure(34, weight: .light)).foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
            if !saved.unconverted.isEmpty {
                Text("\(saved.unconverted.joined(separator: ", ")) isn’t included: no exchange rate yet.").font(.caption).foregroundStyle(Theme.warning)
            }
        }
    }

    private func section(_ title: String, _ list: [SavingsGoal]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title)
            ForEach(list) { g in
                NavigationLink(value: g) { GoalRow(goal: g, costs: costs, entries: entries).card() }
                    .buttonStyle(PressableStyle())
            }
        }
    }
}

struct GoalRow: View {
    let goal: SavingsGoal
    let costs: [TripCost]
    let entries: [GoalEntry]

    var body: some View {
        let plan = SavingsPlanner.plan(for: goal, costs: costs, entries: entries)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                CategoryGlyph(symbol: goal.kind == .trip ? "airplane" : goal.symbol)
                VStack(alignment: .leading, spacing: 2) {
                    Text(goal.name).font(.body).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(subtitle(plan)).font(.caption).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                    if !goal.details.isEmpty { Text(goal.details).font(.caption).foregroundStyle(Theme.inkTertiary).lineLimit(1) }
                }
                Spacer(minLength: 6)
                if goal.priority == .high { Image(systemName: "exclamationmark.circle.fill").font(.footnote).foregroundStyle(Theme.warning).accessibilityLabel("High priority") }
                StatusChip(text: plan.statusText, tint: plan.statusTint)
            }
            ProgressLine(value: plan.percentFunded, tint: plan.status == .overdue ? Theme.danger : Theme.accent)
            HStack {
                Text(goal.money(plan.saved)).font(.figure(15)).foregroundStyle(Theme.ink)
                Text("of \(goal.money(plan.target))").font(.footnote).foregroundStyle(Theme.inkSecondary)
                Spacer()
                Text("\(Int((plan.percentFunded * 100).rounded()))%").font(.figure(13)).foregroundStyle(Theme.inkSecondary)
            }
            if let r = plan.requiredMonthly, plan.status != .funded {
                Text("\(goal.money(r)) each \(goal.frequency.noun) needed · \(plan.contributionsRemaining) \(plan.contributionsRemaining == 1 ? "contribution" : "contributions") left")
                    .font(.footnote).foregroundStyle(Theme.inkSecondary)
            }
            if plan.status != .funded, let est = plan.estimatedCompletion {
                Text("Estimated \(est.formatted(.dateTime.day().month(.abbreviated).year())) · \(plan.estimateBasis == .plan ? "at your plan" : "at your recent pace")")
                    .font(.caption).foregroundStyle(Theme.inkSecondary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func subtitle(_ plan: SavingsPlan) -> String {
        var parts: [String] = []
        if let d = goal.deadline { parts.append(goal.kind == .trip ? "Departs \(d.short)" : "By \(d.short)") }
        return parts.isEmpty ? (goal.kind == .trip ? goal.destination : "Open-ended") : parts.joined(separator: " · ")
    }
}
