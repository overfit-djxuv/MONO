import SwiftUI
import SwiftData

/// One month at a glance: browse past months on the timeline, tap any figure to see the transactions behind it, export it.
struct MonthlyReviewView: View {
    @Query private var rawTxs: [TransactionRecord]
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var rates: [ExchangeRate]
    @Query private var entries: [GoalEntry]
    @Query private var goals: [SavingsGoal]
    @Query private var costs: [TripCost]
    @Query private var limits: [BudgetLimit]
    @Query private var monthBudgets: [MonthBudget]
    @Query private var planned: [PlannedExpense]
    @Query private var rules: [RecurringRule]
    @Query(sort: \MoneyCategory.sortOrder) private var categories: [MoneyCategory]

    @State private var month = MonthKey(.now)
    @State private var drill: DrillTarget?
    @State private var share: SharePayload?
    @State private var showHow = false

    struct DrillTarget: Identifiable { let id = UUID(); let title: String; let transactions: [TransactionRecord]; let goalMoves: [GoalEntry] }

    private var books: Books { Books(accounts: accounts, rates: rates, transactions: rawTxs, entries: entries) }

    private func review(_ b: Books) -> MonthlyReview.Review {
        let converted = b.reportableEntries(goals: goals, entries: entries)
        let names = Dictionary(uniqueKeysWithValues: goals.map { ($0.id, $0.name) })
        let monthStart = month.start(), nextStart = month.adding(1).start()
        let moves = converted.filter { $0.affectsCash && $0.date >= monthStart && $0.date < nextStart }.map { (goal: names[$0.goalID] ?? "Goal", cents: $0.amountCents) }
        let progress: [MonthlyReview.GoalProgress] = goals.compactMap { g in
            let mine = converted.filter { $0.goalID == g.id }
            let saved = mine.filter { $0.date < nextStart }.reduce(0) { $0 + $1.amountCents }
            let movedIn = mine.filter { $0.affectsCash && $0.date >= monthStart && $0.date < nextStart }.reduce(0) { $0 + $1.amountCents }
            let plan = SavingsPlanner.plan(for: g, costs: costs, entries: entries)
            guard let target = b.converter.convert(plan.target, from: g.currency), saved != 0 || movedIn != 0 || plan.remaining > 0 else { return nil }
            return .init(name: g.name, movedThisMonth: movedIn, saved: saved, target: target)
        }
        let summary = FinanceEngine.budgetSummary(month: month, totalLimit: monthBudgets.first { $0.monthKey == month.string }?.totalCents,
                                                  limits: limits, transactions: b.reported)
        let active = rules.filter { $0.status == .active && $0.kind == .expense }
        let monthly = active.reduce(0) { acc, r in acc + (b.converter.convert(r.monthlyCostEstimate, from: b.account(r.accountID)?.currency ?? Money.reporting) ?? 0) }
        let paid = b.reported.filter { !$0.occurrenceKey.isEmpty && MonthKey($0.date) == month && $0.kind == .expense }
        let horizon = Calendar.current.date(byAdding: .day, value: 30, to: .now) ?? .now
        var upcoming = planned.filter { !$0.isPaid && $0.dueDate <= horizon }.map { MonthlyReview.Commitment(title: $0.title, date: $0.dueDate, cents: $0.amountCents, isSubscription: false) }
        for r in active {
            let cur = b.account(r.accountID)?.currency ?? Money.reporting
            guard let cents = b.converter.convert(r.amountCents, from: cur) else { continue }
            upcoming += r.dueDates(through: horizon).map { MonthlyReview.Commitment(title: r.title, date: $0, cents: cents, isSubscription: true) }
        }
        return MonthlyReview.make(month: month, now: .now, txs: b.reported, goalMoves: moves, goalProgress: progress,
                                  budget: summary.total == nil ? nil : summary,
                                  recurring: .init(paidCount: paid.count, paidTotal: paid.reduce(0) { $0 + $1.amountCents }, activeCount: active.count, monthlyEstimate: monthly),
                                  upcoming: upcoming.sorted { $0.date < $1.date }, format: { Money.format($0) })
    }

    var body: some View {
        let b = books, r = review(b)
        ScrollView {
            VStack(spacing: 16) {
                timeline(MonthlyReview.months(b.reported, entries: entries, now: .now))
                if r.transactionCount == 0 && r.movedToGoals == 0 {
                    EmptyState(symbol: "doc.text.magnifyingglass", title: "Nothing recorded in \(month.title())",
                               message: "A review appears for any month with records.").padding(.top, 30)
                } else {
                    header(r)
                    if !r.categories.isEmpty { spending(r) }
                    if let bud = r.budget, bud.total != nil { budget(bud) }
                    if let c = r.comparison { compare(c, r) }
                    if !r.largest.isEmpty { largest(r) }
                    if !r.goals.isEmpty { goalsCard(r) }
                    recurring(r)
                    if !r.upcoming.isEmpty { upcoming(r) }
                    if !r.patterns.isEmpty { listCard("Patterns", r.patterns, symbol: "waveform.path.ecg") }
                    if !r.worthALook.isEmpty { listCard("Worth a look", r.worthALook, symbol: "eye", note: "Observations from your own numbers, not advice.") }
                    how
                }
            }
            .padding(.horizontal, Theme.gutter).padding(.vertical, 8).padding(.bottom, 28)
        }
        .monoScreen()
        .navigationTitle("Monthly review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { export(r, kind: .text) } label: { Label("Share summary", systemImage: "text.alignleft") }
                    Button { export(r, kind: .csv) } label: { Label("Export CSV", systemImage: "tablecells") }
                    Button { export(r, kind: .pdf) } label: { Label("Export PDF", systemImage: "doc.richtext") }
                } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Export this review")
            }
        }
        .sheet(item: $drill) { ReviewDrillSheet(target: $0, accounts: accounts, categories: categories) }
        .sheet(item: $share) { ShareSheet(items: $0.items) }
    }

    // MARK: Timeline

    private func timeline(_ months: [MonthKey]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(months) { m in
                        Button { withAnimation(Theme.easeOut(0.2)) { month = m }; Haptics.tap() } label: {
                            VStack(spacing: 1) {
                                Text(m.shortTitle()).font(.footnote.weight(.semibold))
                                Text(String(m.year)).font(.caption2)
                            }
                            .padding(.vertical, 8).padding(.horizontal, 14)
                            .background(m == month ? Theme.accent : Theme.accentSoft, in: Capsule())
                            .foregroundStyle(m == month ? Theme.onPrimary : Theme.accent)
                            .overlay(alignment: .topTrailing) { if m == MonthKey(.now) { Circle().fill(Theme.warning).frame(width: 7, height: 7).offset(x: -2, y: 3) } }
                        }
                        .buttonStyle(PressableStyle()).id(m)
                        .accessibilityLabel("\(m.title())\(m == MonthKey(.now) ? ", in progress" : "")")
                    }
                }
                .padding(.vertical, 2)
            }
            .onAppear { proxy.scrollTo(month, anchor: .trailing) }
        }
    }

    // MARK: Cards

    private func card<C: View>(_ title: String, badge: String? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { SectionHeader(title: title); Spacer()
                if let badge { Text(badge).font(.caption2.weight(.semibold)).foregroundStyle(Theme.inkSecondary).padding(.vertical, 2).padding(.horizontal, 8).background(Theme.accentSoft, in: Capsule()) } }
            content()
        }
        .glass(padding: 18)
    }

    private func tap(_ title: String, _ txs: [TransactionRecord] = [], moves: [GoalEntry] = []) { drill = DrillTarget(title: title, transactions: txs, goalMoves: moves) }

    private func inMonth(_ kind: TxKind? = nil, category: String? = nil) -> [TransactionRecord] {
        rawTxs.filter { MonthKey($0.date) == month && $0.kind != .transfer && (kind == nil || $0.kind == kind) && (category == nil || $0.category == category) }
            .sorted { $0.date > $1.date }
    }

    private func header(_ r: MonthlyReview.Review) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(r.month.title())\(r.isComplete ? "" : " · day \(r.daysCovered)")").font(.footnote.weight(.medium)).foregroundStyle(Theme.onPrimary.opacity(0.74))
                Text(Money.format(r.net, signed: true)).font(.figure(38, weight: .light)).foregroundStyle(Theme.onPrimary).lineLimit(1).minimumScaleFactor(0.6)
                Text("net cash flow").font(.footnote).foregroundStyle(Theme.onPrimary.opacity(0.74))
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading).background(HeroBackground())
            if !r.isComplete { Callout(text: "This month isn’t over. Figures cover the first \(r.daysCovered) days.", tone: .info, symbol: "hourglass") }
            VStack(spacing: 0) {
                figure("Income", Money.format(r.income), tint: Theme.income) { tap("Income · \(r.month.title())", inMonth(.income)) }
                Hairline()
                figure("Expenses", Money.format(r.expense)) { tap("Expenses · \(r.month.title())", inMonth(.expense)) }
                Hairline()
                figure("Moved to goals", Money.format(r.movedToGoals), note: "savings, not an expense") { tap("Goal movements · \(r.month.title())", moves: monthMoves()) }
                Hairline()
                HStack { Text("Savings rate").font(.body).foregroundStyle(Theme.ink); Spacer()
                    Text(r.savingsRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—").font(.figure(16)).foregroundStyle(Theme.ink) }.padding(.vertical, 10)
            }
            .glass(padding: 16)
        }
    }

    private func monthMoves() -> [GoalEntry] {
        let s = month.start(), e = month.adding(1).start()
        return entries.filter { $0.affectsCash && $0.date >= s && $0.date < e }.sorted { $0.date > $1.date }
    }

    private func figure(_ title: String, _ value: String, tint: Color = Theme.ink, note: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body).foregroundStyle(Theme.ink)
                    if let note { Text(note).font(.caption).foregroundStyle(Theme.inkSecondary) }
                }
                Spacer()
                Text(value).font(.figure(16)).foregroundStyle(tint)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.inkTertiary)
            }
            .padding(.vertical, 10).contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private func spending(_ r: MonthlyReview.Review) -> some View {
        card("Where it went", badge: "Actual") {
            ForEach(r.categories) { c in
                Button { tap("\(c.category) · \(r.month.title())", inMonth(.expense, category: c.category)) } label: {
                    VStack(spacing: 5) {
                        HStack { Text(c.category).font(.subheadline).foregroundStyle(Theme.ink); Spacer()
                            Text(Money.format(c.cents)).font(.figure(14)).foregroundStyle(Theme.ink)
                            Text("\(Int((c.share * 100).rounded()))%").font(.caption).foregroundStyle(Theme.inkSecondary).frame(width: 36, alignment: .trailing) }
                        ProgressLine(value: c.share, tint: Theme.accent, height: 4)
                    }
                    .contentShape(Rectangle())
                }.buttonStyle(PressableStyle())
            }
        }
    }

    private func budget(_ b: BudgetSummary) -> some View {
        card("Budget", badge: "Actual") {
            HStack(alignment: .firstTextBaseline) {
                Text(Money.format(b.spent)).font(.figure(22, weight: .light)).foregroundStyle(Theme.ink)
                Text("of \(Money.format(b.total ?? 0))").font(.subheadline).foregroundStyle(Theme.inkSecondary)
            }
            ProgressLine(value: b.fraction ?? 0, tint: b.state == .over ? Theme.danger : (b.state == .warning ? Theme.warning : Theme.accent), height: 6)
            ForEach(b.lines) { l in
                HStack { Text(l.category).font(.subheadline).foregroundStyle(Theme.ink); Spacer()
                    Text(l.spent > l.limit ? "over by \(Money.format(l.spent - l.limit))" : "\(Money.format(l.spent)) of \(Money.format(l.limit))")
                        .font(.footnote).foregroundStyle(l.spent > l.limit ? Theme.danger : Theme.inkSecondary) }
            }
        }
    }

    private func compare(_ c: MonthlyReview.Comparison, _ r: MonthlyReview.Review) -> some View {
        card("Compared with \(c.previous.title())", badge: c.isPartial ? "First \(c.days) days" : "Whole months") {
            diffRow("Income", c.income, c.previousIncome, goodWhenUp: true)
            diffRow("Expenses", c.expense, c.previousExpense, goodWhenUp: false)
            diffRow("Net cash flow", c.net, c.previousNet, goodWhenUp: true)
            ForEach(c.categoryShifts.filter { $0.delta != 0 }.prefix(3)) { s in
                HStack { Text(s.category).font(.caption).foregroundStyle(Theme.inkSecondary); Spacer()
                    Text("\(s.delta > 0 ? "+" : "−")\(Money.format(abs(s.delta)))").font(.figure(13)).foregroundStyle(Theme.inkSecondary) }
            }
        }
    }

    private func diffRow(_ label: String, _ now: Int, _ before: Int, goodWhenUp: Bool) -> some View {
        let d = now - before
        let good = goodWhenUp ? d >= 0 : d <= 0
        return HStack {
            Text(label).font(.subheadline).foregroundStyle(Theme.ink)
            Spacer()
            Text(d == 0 ? "same" : "\(d > 0 ? "+" : "−")\(Money.format(abs(d)))").font(.figure(14, weight: .medium)).foregroundStyle(d == 0 ? Theme.inkSecondary : (good ? Theme.accent : Theme.warning))
            Text("(\(Money.format(before)) before)").font(.caption2).foregroundStyle(Theme.inkTertiary)
        }
    }

    private func largest(_ r: MonthlyReview.Review) -> some View {
        card("Largest expenses", badge: "Actual") {
            ForEach(r.largest, id: \.id) { t in
                HStack { VStack(alignment: .leading, spacing: 1) {
                    Text(t.merchant.isEmpty ? (t.title.isEmpty ? t.category : t.title) : t.merchant).font(.subheadline).foregroundStyle(Theme.ink).lineLimit(1)
                    Text("\(t.category) · \(t.date.short)").font(.caption).foregroundStyle(Theme.inkSecondary) }
                    Spacer(); Text(Money.format(t.amountCents)).font(.figure(15)).foregroundStyle(Theme.ink) }
            }
        }
    }

    private func goalsCard(_ r: MonthlyReview.Review) -> some View {
        card("Savings goals", badge: "Actual") {
            ForEach(r.goals) { g in
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(g.name).font(.subheadline).foregroundStyle(Theme.ink); Spacer()
                        Text("\(Money.format(g.saved)) of \(Money.format(g.target))").font(.figure(13)).foregroundStyle(Theme.inkSecondary) }
                    ProgressLine(value: g.percent, tint: Theme.accent, height: 4)
                    Text(g.movedThisMonth == 0 ? "Nothing moved this month." : "\(g.movedThisMonth > 0 ? "+" : "−")\(Money.format(abs(g.movedThisMonth))) this month")
                        .font(.caption).foregroundStyle(Theme.inkSecondary)
                }
            }
        }
    }

    private func recurring(_ r: MonthlyReview.Review) -> some View {
        card("Subscriptions & bills", badge: "Actual + estimate") {
            HStack { Text("Paid this month").font(.subheadline); Spacer()
                Text("\(r.recurring.paidCount) · \(Money.format(r.recurring.paidTotal))").font(.figure(14)).foregroundStyle(Theme.ink) }
            HStack { Text("Typical month (estimate)").font(.subheadline); Spacer()
                Text(Money.format(r.recurring.monthlyEstimate)).font(.figure(14)).foregroundStyle(Theme.inkSecondary) }
            Text("“Paid” counts payments you confirmed as paid. The typical month is spread evenly from your schedules.").font(.caption).foregroundStyle(Theme.inkSecondary)
        }
    }

    private func upcoming(_ r: MonthlyReview.Review) -> some View {
        card("Coming up in 30 days") {
            ForEach(r.upcoming.prefix(8)) { c in
                HStack { VStack(alignment: .leading, spacing: 1) {
                    Text(c.title.isEmpty ? "Payment" : c.title).font(.subheadline).foregroundStyle(Theme.ink)
                    Text("\(c.date < Calendar.current.startOfDay(for: .now) ? "Overdue" : "Due") \(c.date.short)\(c.isSubscription ? " · subscription" : "")").font(.caption).foregroundStyle(Theme.inkSecondary) }
                    Spacer(); Text(Money.format(c.cents)).font(.figure(14)).foregroundStyle(Theme.ink) }
            }
        }
    }

    private func listCard(_ title: String, _ lines: [String], symbol: String, note: String? = nil) -> some View {
        card(title) {
            ForEach(lines, id: \.self) { l in
                HStack(alignment: .top, spacing: 10) { Image(systemName: symbol).font(.footnote).foregroundStyle(Theme.accent).padding(.top, 2)
                    Text(l).font(.subheadline).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true) }
            }
            if let note { Text(note).font(.caption).foregroundStyle(Theme.inkSecondary) }
        }
    }

    private var how: some View {
        DisclosureGroup(isExpanded: $showHow) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Net cash flow = income − expenses. Transfers between your accounts and money moved into goals are not income or expenses.")
                Text("Savings rate = net cash flow ÷ income.")
                Text("Moved to goals = money put into goals − money taken back out. It stays yours; it just isn’t available cash.")
                Text("Money in other currencies is converted with the exchange rates you entered. A month that isn’t over is compared with the same number of days of the month before.")
                Text("Everything is worked out on this iPhone from your records. “Worth a look” applies simple thresholds to your own numbers; it isn’t financial advice.")
            }.font(.footnote).foregroundStyle(Theme.inkSecondary).padding(.top, 6)
        } label: { SectionHeader(title: "How this is calculated") }
        .tint(Theme.inkSecondary).glass(padding: 18)
    }

    // MARK: Export

    private enum ExportKind { case text, csv, pdf }

    private func export(_ r: MonthlyReview.Review, kind: ExportKind) {
        let real: (Int) -> String = { Money.format($0, ignoreHiding: true) }
        let md = MonthlyReview.markdown(r, format: real)
        let base = "MONO-review-\(r.month.string)"
        do {
            switch kind {
            case .text: share = SharePayload(items: [md])
            case .csv: share = SharePayload(items: [try ReviewExport.file(named: "\(base).csv", data: Data(MonthlyReview.csv(r, format: real).utf8))])
            case .pdf: share = SharePayload(items: [try ReviewExport.file(named: "\(base).pdf", data: ReviewExport.pdf(title: "\(r.month.title()) review", markdown: md))])
            }
            Haptics.success()
        } catch { share = nil }
    }
}

/// The transactions behind a figure.
struct ReviewDrillSheet: View {
    let target: MonthlyReviewView.DrillTarget
    let accounts: [Account]
    let categories: [MoneyCategory]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Group {
                    if target.transactions.isEmpty && target.goalMoves.isEmpty {
                        Text("Nothing here.").foregroundStyle(Theme.inkSecondary)
                    }
                    ForEach(target.transactions) { t in
                        TransactionRow(tx: t, symbol: categories.symbol(for: t.category), directory: AccountDirectory(accounts))
                    }
                    ForEach(target.goalMoves) { e in
                        HStack { Text(e.date.short); Spacer()
                            Text(Money.format(e.amountCents, signed: true)).font(.figure(15)).foregroundStyle(e.amountCents < 0 ? Theme.warning : Theme.ink) }
                    }
                }.listRowBackground(GlassRowBackground())
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden).monoScreen()
            .navigationTitle(target.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
