import SwiftUI
import SwiftData

/// Try a purchase on paper first. It never records anything; every result is an estimate.
struct PurchaseSimulatorView: View {
    @Query(sort: \Account.sortOrder) private var accounts: [Account]
    @Query private var rates: [ExchangeRate]
    @Query private var txs: [TransactionRecord]
    @Query private var entries: [GoalEntry]
    @Query private var planned: [PlannedExpense]
    @Query private var rules: [RecurringRule]
    @Query private var goals: [SavingsGoal]
    @Query private var costs: [TripCost]
    @Query(sort: \MoneyCategory.sortOrder) private var categories: [MoneyCategory]
    @Query private var limits: [BudgetLimit]
    @Query private var monthBudgets: [MonthBudget]
    @Query private var reserved: [ReservedFund]
    @AppStorage("openingBalanceCents") private var legacyOpening = 0
    @AppStorage("hourlyIncomeCents") private var hourlyCents = 0

    @State private var item = ""
    @State private var priceText = ""
    @State private var category = ""
    @State private var compare = false
    @State private var altText = ""
    @State private var hourlyText = ""

    /// Opens with an item already filled in (from a shopping list). Nothing is recorded either way.
    init(item: String = "", priceCents: Int? = nil, category: String = "") {
        _item = State(initialValue: item)
        var price = priceCents.map { Money.editable($0) } ?? ""
        #if DEBUG
        if price.isEmpty, let i = CommandLine.arguments.firstIndex(of: "-MONOSimPrice"), i + 1 < CommandLine.arguments.count { price = CommandLine.arguments[i + 1] }
        #endif
        _priceText = State(initialValue: price)
        _category = State(initialValue: category)
    }

    private var price: Int? { Money.parse(priceText).flatMap { $0 > 0 ? $0 : nil } }
    private var altPrice: Int? { compare ? Money.parse(altText).flatMap { $0 > 0 ? $0 : nil } : nil }
    private var expenseCategories: [MoneyCategory] { categories.filter { $0.kind == .expense } }
    private var hourly: Int? { hourlyCents > 0 ? hourlyCents : nil }

    private var context: PurchaseSimulator.Context {
        let books = Books(accounts: accounts, rates: rates, transactions: txs, entries: entries, legacyOpening: legacyOpening)
        return PurchaseSimulator.makeContext(books: books, planned: planned, rules: rules, goals: goals, costs: costs, entries: entries,
                                             categories: categories, limits: limits, monthBudgets: monthBudgets, reserved: reserved,
                                             config: SafeToSpend.Config.load())
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                inputs
                if let price {
                    let c = context
                    let r = PurchaseSimulator.evaluate(price: price, category: category.isEmpty ? nil : category, hourlyRate: hourly, context: c)
                    Callout(text: "Estimates only. Nothing here is recorded or changes your balances.", tone: .info, symbol: "wand.and.stars")
                    verdict(r)
                    money(r)
                    if r.overall != nil || r.category != nil { budget(r) }
                    savings(r)
                    if !r.goalDelays.isEmpty { goalCard(r) }
                    if let h = r.hoursOfWork { work(h) }
                    comparison(price: price, now: r, context: c)
                } else {
                    Text("Enter a price to see what it would do to your money, budget and goals.")
                        .font(.footnote).foregroundStyle(Theme.inkSecondary).padding(.top, 8)
                }
            }
            .padding(.horizontal, Theme.gutter).padding(.vertical, 8).padding(.bottom, 28)
        }
        .monoScreen()
        .navigationTitle("Purchase simulator")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { hourlyText = Money.editable(hourlyCents) }
    }

    // MARK: Inputs

    private var inputs: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("What are you thinking of buying?", text: $item).font(.body)
            Hairline()
            HStack { Text("Price"); AmountField(text: $priceText).accessibilityIdentifier("simPrice") }
            Hairline()
            Picker("Category", selection: $category) {
                Text("None").tag("")
                ForEach(expenseCategories) { Label($0.name, systemImage: $0.symbol).tag($0.name) }
            }
            Hairline()
            Toggle("Compare with a cheaper option", isOn: $compare).tint(Theme.accent)
            if compare { HStack { Text("Cheaper price"); AmountField(text: $altText) } }
            Hairline()
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Hourly income").font(.body)
                    Text("Optional: shows the hours of work it costs.").font(.caption).foregroundStyle(Theme.inkSecondary)
                }
                Spacer(minLength: 4)
                AmountField(text: $hourlyText).frame(maxWidth: 120)
                    .onChange(of: hourlyText) { _, v in hourlyCents = Money.parse(v) ?? 0 }
            }
        }
        .glass(padding: 18)
    }

    // MARK: Results

    private func verdict(_ r: PurchaseSimulator.Result) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.isEmpty ? "This purchase" : item).font(.footnote.weight(.medium)).foregroundStyle(Theme.onPrimary.opacity(0.74))
            Text(Money.format(r.price)).font(.figure(36, weight: .light)).foregroundStyle(Theme.onPrimary)
            Text(r.fitsSafeToSpend ? "Fits within your safe-to-spend money. \(Money.format(r.safeAfter)) would be left."
                                   : "\(Money.format(r.overSafeBy)) more than your safe-to-spend money, so it would eat into bills, savings or essentials.")
                .font(.footnote).foregroundStyle(Theme.onPrimary.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading).background(HeroBackground())
    }

    private func line(_ label: String, _ before: String, _ after: String, warn: Bool = false) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(Theme.inkSecondary)
            Spacer()
            Text(before).font(.figure(14)).foregroundStyle(Theme.inkSecondary)
            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(Theme.inkTertiary)
            Text(after).font(.figure(15, weight: .medium)).foregroundStyle(warn ? Theme.danger : Theme.ink)
        }
    }

    private func card<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { SectionHeader(title: title); content() }.glass(padding: 18)
    }

    private func money(_ r: PurchaseSimulator.Result) -> some View {
        card("Your money") {
            line("Available cash", Money.format(r.cashBefore), Money.format(r.cashAfter), warn: r.cashAfter < 0)
            line("Safe to spend", Money.format(r.safeBefore), Money.format(r.safeAfter), warn: r.safeAfter < 0)
        }
    }

    private func budget(_ r: PurchaseSimulator.Result) -> some View {
        card("This month’s budget") {
            if let o = r.overall {
                line("Overall left", Money.format(o.remainingBefore), Money.format(o.remainingAfter), warn: o.remainingAfter < 0)
                if o.goesOver { Text("This would put you over the monthly budget.").font(.footnote).foregroundStyle(Theme.danger) }
            }
            if let c = r.category {
                line("\(category) left", Money.format(c.remainingBefore), Money.format(c.remainingAfter), warn: c.remainingAfter < 0)
                if c.goesOver { Text("This would put \(category) over its limit.").font(.footnote).foregroundStyle(Theme.danger) }
            } else if !category.isEmpty {
                Text("\(category) has no limit this month, so there’s no category effect.").font(.footnote).foregroundStyle(Theme.inkSecondary)
            }
        }
    }

    private func savings(_ r: PurchaseSimulator.Result) -> some View {
        card("Savings this month") {
            if let b = r.savingsRateBefore, let a = r.savingsRateAfter {
                line("Savings rate", "\(Int((b * 100).rounded()))%", "\(Int((a * 100).rounded()))%", warn: a < 0)
                Text("Income minus spending, as a share of income so far this month.").font(.caption).foregroundStyle(Theme.inkSecondary)
            } else {
                Text("No income recorded this month, so there’s no rate to compare.").font(.footnote).foregroundStyle(Theme.inkSecondary)
            }
        }
    }

    private func goalCard(_ r: PurchaseSimulator.Result) -> some View {
        card("Your goals") {
            ForEach(r.goalDelays) { g in
                HStack(alignment: .firstTextBaseline) {
                    Text(g.name).font(.subheadline).foregroundStyle(Theme.ink)
                    Spacer()
                    if let d = g.delayDays {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(delayText(d)).font(.figure(14, weight: .medium)).foregroundStyle(Theme.warning)
                            if let e = g.newEstimate { Text("now ≈ \(e.formatted(.dateTime.day().month(.abbreviated).year()))").font(.caption).foregroundStyle(Theme.inkSecondary) }
                        }
                    } else { Text("no plan to measure").font(.caption).foregroundStyle(Theme.inkSecondary) }
                }
            }
            Text("If you paid for this out of what each goal would have received. Each goal is measured separately, not all at once.")
                .font(.caption).foregroundStyle(Theme.inkSecondary)
        }
    }

    private func delayText(_ days: Int) -> String {
        if days < 14 { return "about \(days) \(days == 1 ? "day" : "days") later" }
        let months = Double(days) / 30.4369
        return months < 2 ? "about \(Int((Double(days) / 7).rounded())) weeks later" : "about \(String(format: "%.1f", months)) months later"
    }

    private func work(_ hours: Double) -> some View {
        card("Time at work") {
            Text(hours < 1 ? "About \(Int((hours * 60).rounded())) minutes of work" : "About \(String(format: "%.1f", hours)) hours of work")
                .font(.figure(20)).foregroundStyle(Theme.ink)
            if hours >= 8 { Text("That’s about \(String(format: "%.1f", hours / 8)) working days.").font(.footnote).foregroundStyle(Theme.inkSecondary) }
            Text("At your hourly income, before tax.").font(.caption).foregroundStyle(Theme.inkSecondary)
        }
    }

    private func comparison(price: Int, now: PurchaseSimulator.Result, context c: PurchaseSimulator.Context) -> some View {
        let wait = PurchaseSimulator.waiting30Days(price: price, context: c)
        let cheaper = altPrice.map { PurchaseSimulator.evaluate(price: $0, category: category.isEmpty ? nil : category, hourlyRate: hourly, context: c) }
        return card("Compare your options") {
            option("Buy now", icon: "bag", lines: ["Safe to spend after: \(Money.format(now.safeAfter))",
                                                   now.fitsSafeToSpend ? "Fits" : "\(Money.format(now.overSafeBy)) too much"],
                   good: now.fitsSafeToSpend)
            Hairline()
            option("Wait 30 days", icon: "calendar", lines: ["Until \(wait.date.formatted(.dateTime.day().month(.abbreviated))) you’ll have \(Money.format(wait.safeToSpend)) safe to spend, after bills and planned savings due by then.",
                                                           wait.stillAffordable ? "Then \(Money.format(wait.leftAfterBuying)) would be left." : "Still \(Money.format(-wait.leftAfterBuying)) short."],
                   good: wait.stillAffordable)
            if let cheaper {
                Hairline()
                option("Cheaper option (\(Money.format(cheaper.price)))", icon: "arrow.down.circle",
                       lines: ["Safe to spend after: \(Money.format(cheaper.safeAfter))",
                               "You keep \(Money.format(now.price - cheaper.price)) more",
                               cheaper.fitsSafeToSpend ? "Fits" : "\(Money.format(cheaper.overSafeBy)) too much"],
                       good: cheaper.fitsSafeToSpend)
            }
            Text("Waiting doesn’t assume any income; it only counts what is already planned.").font(.caption).foregroundStyle(Theme.inkSecondary)
        }
    }

    private func option(_ title: String, icon: String, lines: [String], good: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(good ? Theme.accent : Theme.warning).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                ForEach(lines, id: \.self) { Text($0).font(.footnote).foregroundStyle(Theme.inkSecondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
        }
    }
}
