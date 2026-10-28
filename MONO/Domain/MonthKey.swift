import Foundation

/// A calendar month, used to bucket records and budgets.
struct MonthKey: Hashable, Comparable, Codable, Identifiable {
    let year: Int
    let month: Int

    var id: String { string }

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month], from: date)
        self.init(year: c.year ?? 1970, month: c.month ?? 1)
    }

    init?(string: String) {
        let p = string.split(separator: "-")
        guard p.count == 2, let y = Int(p[0]), let m = Int(p[1]),
              (1...12).contains(m), (1900...3000).contains(y) else { return nil }
        self.init(year: y, month: m)
    }

    var string: String { String(format: "%04d-%02d", year, month) }

    func start(calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date(timeIntervalSince1970: 0)
    }

    func daysInMonth(calendar: Calendar = .current) -> Int {
        calendar.range(of: .day, in: .month, for: start(calendar: calendar))?.count ?? 30
    }

    func adding(_ n: Int) -> MonthKey {
        let t = year * 12 + (month - 1) + n
        return MonthKey(year: t / 12, month: t % 12 + 1)
    }

    /// All months from `self` through `end`, inclusive. Empty if `end` is earlier.
    func months(through end: MonthKey) -> [MonthKey] {
        guard self <= end else { return [] }
        let count = (end.year * 12 + end.month) - (year * 12 + month)
        return (0...count).map { adding($0) }
    }

    func title(calendar: Calendar = .current) -> String {
        start(calendar: calendar).formatted(.dateTime.month(.wide).year())
    }

    func shortTitle(calendar: Calendar = .current) -> String {
        start(calendar: calendar).formatted(.dateTime.month(.abbreviated))
    }

    static func < (a: MonthKey, b: MonthKey) -> Bool {
        (a.year, a.month) < (b.year, b.month)
    }
}
