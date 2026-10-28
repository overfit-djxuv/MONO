import SwiftUI
import Charts

// Charts use the same palette as the rest of the app. Selecting a bar/point shows a rule + tooltip.

struct ChartTip: View {
    let title: String
    let lines: [(String, String, Color)]
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.ink)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                HStack(spacing: 6) {
                    Circle().fill(l.2).frame(width: 6, height: 6)
                    Text(l.0).font(.caption2).foregroundStyle(Theme.inkSecondary)
                    Spacer(minLength: 8)
                    Text(l.1).font(.figure(11)).foregroundStyle(Theme.ink)
                }
            }
        }
        .padding(8)
        .frame(minWidth: 130)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 0.5))
    }
}

private func axisMoney(_ v: AxisValue) -> String {
    Money.compact(v.as(Double.self) ?? 0)
}

extension View {
    func monoYAxis() -> some View {
        chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Theme.line)
                AxisValueLabel { Text(axisMoney(v)).font(.caption2).foregroundStyle(Theme.inkTertiary) }
            }
        }
    }

    func monoMonthAxis(count: Int) -> some View {
        chartXAxis {
            AxisMarks(values: .stride(by: .month, count: count > 8 ? 2 : 1)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated)).font(.caption2).foregroundStyle(Theme.inkTertiary)
            }
        }
    }
}

// MARK: Income vs expenses

struct IncomeExpenseChart: View {
    let months: [MonthSummary]
    var height: CGFloat = 180
    @State private var selected: Date?

    private var selectedMonth: MonthSummary? {
        guard let selected else { return nil }
        let k = MonthKey(selected)
        return months.first { $0.month == k }
    }

    var body: some View {
        Chart {
            ForEach(months) { m in
                BarMark(x: .value("Month", m.month.start(), unit: .month), y: .value("Amount", m.income.rm), width: .ratio(0.7))
                    .foregroundStyle(by: .value("Type", "Income"))
                    .position(by: .value("Type", "Income"))
                BarMark(x: .value("Month", m.month.start(), unit: .month), y: .value("Amount", m.expense.rm), width: .ratio(0.7))
                    .foregroundStyle(by: .value("Type", "Expenses"))
                    .position(by: .value("Type", "Expenses"))
            }
            if let s = selectedMonth {
                RuleMark(x: .value("Month", s.month.start(), unit: .month))
                    .foregroundStyle(Theme.line)
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartTip(title: s.month.title(), lines: [
                            ("Income", Money.format(s.income), Theme.income),
                            ("Expenses", Money.format(s.expense), Theme.expense),
                            ("Net", Money.format(s.net, signed: true), Theme.inkSecondary),
                        ])
                    }
            }
        }
        .chartForegroundStyleScale(["Income": Theme.income, "Expenses": Theme.expense.opacity(0.7)])
        .chartLegend(position: .bottom, alignment: .leading, spacing: 8)
        .chartXSelection(value: $selected)
        .monoYAxis()
        .monoMonthAxis(count: months.count)
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Income versus expenses by month")
        .accessibilityValue(months.map { "\($0.month.title()): income \(Money.format($0.income)), expenses \(Money.format($0.expense))" }.joined(separator: ". "))
    }
}

// MARK: Category donut

struct CategoryDonut: View {
    let slices: [(category: String, cents: Int)]
    @State private var selectedAngle: Double?

    /// Derived from the active palette so charts always match the theme: no colour here is picked by hand.
    static var palette: [Color] {
        let store = ThemeStore.shared
        func blend(_ a: @escaping (ThemeColors) -> UInt32, _ b: @escaping (ThemeColors) -> UInt32, _ t: Double) -> Color {
            store.token { ColorMath.mix(a($0), b($0), t) }
        }
        return [
            Theme.accent,
            Theme.primary,
            Theme.secondary,
            blend(\.accent, \.text, 0.45),
            blend(\.primary, \.background, 0.45),
            blend(\.secondary, \.text, 0.40),
            blend(\.accent, \.background, 0.50),
            blend(\.text, \.background, 0.55),
        ]
    }

    var total: Int { slices.reduce(0) { $0 + $1.cents } }

    func color(_ i: Int) -> Color { Self.palette[i % Self.palette.count] }

    private var selectedIndex: Int? {
        guard let a = selectedAngle else { return nil }
        var run = 0.0
        for (i, s) in slices.enumerated() {
            run += s.cents.rm
            if a <= run { return i }
        }
        return nil
    }

    var body: some View {
        Chart {
            ForEach(Array(slices.enumerated()), id: \.offset) { i, s in
                SectorMark(angle: .value("Spent", s.cents.rm), innerRadius: .ratio(0.64), angularInset: 1.5)
                    .cornerRadius(2)
                    .foregroundStyle(color(i))
                    .opacity(selectedIndex == nil || selectedIndex == i ? 1 : 0.35)
            }
        }
        .chartAngleSelection(value: $selectedAngle)
        .chartLegend(.hidden)
        .chartBackground { _ in
            VStack(spacing: 2) {
                if let i = selectedIndex {
                    Text(slices[i].category).font(.caption).foregroundStyle(Theme.inkSecondary)
                    Text(Money.formatWhole(slices[i].cents)).font(.figure(16)).foregroundStyle(Theme.ink)
                    Text("\(Int((Double(slices[i].cents) / Double(max(total, 1)) * 100).rounded()))%")
                        .font(.caption2).foregroundStyle(Theme.inkTertiary)
                } else {
                    Text("Spent").font(.caption).foregroundStyle(Theme.inkSecondary)
                    Text(Money.formatWhole(total)).font(.figure(16)).foregroundStyle(Theme.ink)
                }
            }
            .animation(nil, value: selectedAngle)
        }
        .frame(height: 170)
        .accessibilityElement()
        .accessibilityLabel("Spending by category")
        .accessibilityValue(slices.map { "\($0.category) \(Money.format($0.cents))" }.joined(separator: ", "))
    }
}

/// Legend / ranked list that pairs with the donut.
struct CategoryBreakdownList: View {
    let slices: [(category: String, cents: Int)]
    var limit: Int? = nil
    var total: Int { slices.reduce(0) { $0 + $1.cents } }

    var body: some View {
        let shown = limit.map { Array(slices.prefix($0)) } ?? slices
        VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { i, s in
                HStack(spacing: 10) {
                    Circle().fill(CategoryDonut.palette[i % CategoryDonut.palette.count]).frame(width: 8, height: 8)
                    Text(s.category).font(.subheadline).foregroundStyle(Theme.ink)
                    Spacer()
                    Text("\(Int((Double(s.cents) / Double(max(total, 1)) * 100).rounded()))%")
                        .font(.figure(12)).foregroundStyle(Theme.inkTertiary)
                        .frame(width: 40, alignment: .trailing)
                    Text(Money.format(s.cents)).font(.figure(15)).foregroundStyle(Theme.ink)
                        .frame(minWidth: 96, alignment: .trailing)
                }
                .padding(.vertical, 9)
                if i < shown.count - 1 { Hairline() }
            }
        }
    }
}

// MARK: Savings growth

struct SavingsGrowthChart: View {
    let points: [(month: MonthKey, cents: Int)]
    var height: CGFloat = 140
    @State private var selected: Date?

    private var selectedPoint: (month: MonthKey, cents: Int)? {
        guard let selected else { return nil }
        let k = MonthKey(selected)
        return points.first { $0.month == k }
    }

    var body: some View {
        Chart {
            ForEach(points, id: \.month) { p in
                AreaMark(x: .value("Month", p.month.start(), unit: .month), y: .value("Saved", p.cents.rm))
                    .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.18), Theme.accent.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Month", p.month.start(), unit: .month), y: .value("Saved", p.cents.rm))
                    .foregroundStyle(Theme.accent)
                    .lineStyle(StrokeStyle(lineWidth: 1.75, lineCap: .round))
                    .interpolationMethod(.monotone)
                if points.count <= 12 {
                    PointMark(x: .value("Month", p.month.start(), unit: .month), y: .value("Saved", p.cents.rm))
                        .foregroundStyle(Theme.accent).symbolSize(18)
                }
            }
            if let s = selectedPoint {
                RuleMark(x: .value("Month", s.month.start(), unit: .month))
                    .foregroundStyle(Theme.line)
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        ChartTip(title: s.month.title(), lines: [("Saved", Money.format(s.cents), Theme.accent)])
                    }
            }
        }
        .chartXSelection(value: $selected)
        .monoYAxis()
        .monoMonthAxis(count: points.count)
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Savings growth")
        .accessibilityValue(points.map { "\($0.month.title()): \(Money.format($0.cents))" }.joined(separator: ". "))
    }
}
