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
    private var trips: [SavingsGoal] { ordered(goals.filter { $0.isOngoing && $0.kind == .trip }) }
    private var others: [SavingsGoal] { ordered(goals.filter { $0.isOngoing && $0.kind == .general }) }
    private var finished: [SavingsGoal] { goals.filter { !$0.isOngoing }.sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) } }
    @State private var showFinished = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
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
                        if !finished.isEmpty { finishedSection }
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
        let active = goals.filter(\.isOngoing).filter { SavingsPlanner.plan(for: $0, costs: costs, entries: entries).status != .funded }.count
        return VStack(alignment: .leading, spacing: 4) {
            Text("Set aside across \(active) \(active == 1 ? "goal" : "goals")").font(.footnote).foregroundStyle(Theme.inkSecondary)
            Text(Money.format(saved.total)).font(.figure(34, weight: .semibold)).foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
            Text("An allocation inside MONO. Nothing moves between bank accounts.").font(.caption).foregroundStyle(Theme.inkTertiary)
            if !saved.unconverted.isEmpty {
                Text("\(saved.unconverted.joined(separator: ", ")) isn’t included: no exchange rate yet.").font(.caption).foregroundStyle(Theme.warning)
            }
        }
    }

    private var finishedSection: some View {
        DisclosureGroup(isExpanded: $showFinished) {
            VStack(spacing: 0) {
                ForEach(Array(finished.enumerated()), id: \.element.id) { i, g in
                    NavigationLink(value: g) {
                        HStack(spacing: 12) {
                            CategoryGlyph(symbol: g.kind == .trip ? "airplane" : g.symbol, tint: Theme.inkSecondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(g.name).font(.body).foregroundStyle(Theme.ink).lineLimit(1)
                                Text(g.completedAt.map { "Completed \($0.short)" } ?? "Archived").font(.footnote).foregroundStyle(Theme.inkSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.inkTertiary)
                        }
                        .padding(.vertical, 10).contentShape(Rectangle())
                    }.buttonStyle(PressableStyle())
                    if i < finished.count - 1 { Hairline() }
                }
            }.padding(.top, 6)
        } label: { Text("Completed and archived · \(finished.count)").font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink) }
        .tint(Theme.inkSecondary).surface()
    }

    private func section(_ title: String, _ list: [SavingsGoal]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: title)
            VStack(spacing: 0) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, g in
                    NavigationLink(value: g) { GoalRow(goal: g, costs: costs, entries: entries) }
                        .buttonStyle(PressableStyle())
                    if i < list.count - 1 { Hairline() }
                }
            }
            .padding(.horizontal, 16).surface(padding: 0)
        }
    }
}

struct GoalRow: View {
    let goal: SavingsGoal
    let costs: [TripCost]
    let entries: [GoalEntry]

    var body: some View {
        let plan = SavingsPlanner.plan(for: goal, costs: costs, entries: entries)
        ProgressRow(symbol: goal.kind == .trip ? "airplane" : goal.symbol, title: goal.name,
                    subtitle: "\(goal.money(plan.saved)) of \(goal.money(plan.target))",
                    trailing: "\(Int((plan.percentFunded * 100).rounded()))%", value: plan.percentFunded,
                    tint: plan.status == .overdue ? Theme.danger : plan.status == .behind ? Theme.warning : Theme.accent,
                    note: goal.progressNote(plan), noteTint: plan.status == .behind ? Theme.warning : plan.status == .overdue ? Theme.danger : Theme.inkSecondary)
            .contentShape(Rectangle())
    }
}

extension SavingsGoal {
    /// "Behind plan · RM 750 each month needed · by 29 Jun 2027": status, the ask, and the date, in one line.
    func progressNote(_ plan: SavingsPlan) -> String? {
        var parts: [String] = []
        switch plan.status {
        case .funded: parts.append("Funded")
        case .behind: parts.append("Behind plan")
        case .overdue: parts.append("Past its date")
        case .onTrack: parts.append("On track")
        case .open: break
        }
        if plan.status != .funded, let r = plan.requiredMonthly { parts.append("\(money(r)) each \(frequency.noun) needed") }
        if let d = deadline { parts.append(kind == .trip ? "departs \(d.short)" : "by \(d.short)") }
        return parts.isEmpty ? (details.isEmpty ? nil : details) : parts.joined(separator: " · ")
    }
}
