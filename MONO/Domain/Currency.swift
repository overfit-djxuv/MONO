import Foundation

/// An ISO 4217 currency. Amounts are always stored as whole minor units (cents, sen, yen…), never as floating point.
struct Currency: Identifiable, Hashable {
    let code: String
    let name: String
    let symbol: String
    /// Digits after the decimal point: 2 for most currencies, 0 for yen and won, 3 for dinar currencies.
    let digits: Int

    var id: String { code }
    var scale: Int { Int([1, 10, 100, 1000][min(max(digits, 0), 3)]) }

    static let all: [Currency] = [
        Currency(code: "MYR", name: "Malaysian ringgit", symbol: "RM", digits: 2),
        Currency(code: "SGD", name: "Singapore dollar", symbol: "S$", digits: 2),
        Currency(code: "USD", name: "US dollar", symbol: "$", digits: 2),
        Currency(code: "EUR", name: "Euro", symbol: "€", digits: 2),
        Currency(code: "GBP", name: "British pound", symbol: "£", digits: 2),
        Currency(code: "JPY", name: "Japanese yen", symbol: "¥", digits: 0),
        Currency(code: "AUD", name: "Australian dollar", symbol: "A$", digits: 2),
        Currency(code: "NZD", name: "New Zealand dollar", symbol: "NZ$", digits: 2),
        Currency(code: "CAD", name: "Canadian dollar", symbol: "C$", digits: 2),
        Currency(code: "CHF", name: "Swiss franc", symbol: "CHF", digits: 2),
        Currency(code: "CNY", name: "Chinese yuan", symbol: "CN¥", digits: 2),
        Currency(code: "HKD", name: "Hong Kong dollar", symbol: "HK$", digits: 2),
        Currency(code: "TWD", name: "New Taiwan dollar", symbol: "NT$", digits: 2),
        Currency(code: "KRW", name: "South Korean won", symbol: "₩", digits: 0),
        Currency(code: "THB", name: "Thai baht", symbol: "฿", digits: 2),
        Currency(code: "IDR", name: "Indonesian rupiah", symbol: "Rp", digits: 2),
        Currency(code: "PHP", name: "Philippine peso", symbol: "₱", digits: 2),
        Currency(code: "VND", name: "Vietnamese dong", symbol: "₫", digits: 0),
        Currency(code: "INR", name: "Indian rupee", symbol: "₹", digits: 2),
        Currency(code: "BND", name: "Brunei dollar", symbol: "B$", digits: 2),
        Currency(code: "AED", name: "UAE dirham", symbol: "AED", digits: 2),
        Currency(code: "SAR", name: "Saudi riyal", symbol: "SAR", digits: 2),
        Currency(code: "KWD", name: "Kuwaiti dinar", symbol: "KD", digits: 3),
    ]

    static let `default` = all[0]

    static func find(_ code: String) -> Currency {
        all.first { $0.code == code.uppercased() } ?? Currency(code: code.uppercased(), name: code.uppercased(), symbol: code.uppercased(), digits: 2)
    }
}

/// Converts between currencies using rates the user typed in. It never guesses: a missing rate returns nil.
/// A rate means "1 unit of `from` = `rate` units of `to`", held as an integer of millionths to avoid floating point.
struct CurrencyConverter: Equatable {
    static let rateScale = 1_000_000
    let reporting: Currency
    /// Rate from each currency code into the reporting currency, in millionths.
    private(set) var toReporting: [String: Int]

    init(reporting: Currency, rates: [(from: String, to: String, micros: Int)]) {
        self.reporting = reporting
        var map: [String: Int] = [:]
        for r in rates where r.micros > 0 {
            if r.to == reporting.code { map[r.from] = r.micros }
        }
        // A rate saved the other way round (reporting → X) is inverted, so changing which currency is "reporting" keeps working.
        for r in rates where r.micros > 0 && r.from == reporting.code && map[r.to] == nil {
            let inv = (Decimal(Self.rateScale) * Decimal(Self.rateScale) / Decimal(r.micros))
            map[r.to] = NSDecimalNumber(decimal: inv).rounding(accordingToBehavior: Self.behavior).intValue
        }
        toReporting = map
    }

    private static let behavior = NSDecimalNumberHandler(roundingMode: .plain, scale: 0, raiseOnExactness: false,
                                                         raiseOnOverflow: false, raiseOnUnderflow: false, raiseOnDivideByZero: false)

    func hasRate(for currency: Currency) -> Bool { currency.code == reporting.code || toReporting[currency.code] != nil }

    func micros(for currency: Currency) -> Int? { currency.code == reporting.code ? Self.rateScale : toReporting[currency.code] }

    /// `minor` units of `from`, expressed in the reporting currency's minor units, rounded half away from zero.
    func convert(_ minor: Int, from: Currency) -> Int? {
        if from.code == reporting.code { return minor }
        guard let micros = toReporting[from.code] else { return nil }
        return Self.convert(minor, from: from, to: reporting, micros: micros)
    }

    /// Currency-correct conversion of minor units with an explicit rate (`micros` = rate × 1,000,000).
    static func convert(_ minor: Int, from: Currency, to: Currency, micros: Int) -> Int {
        let major = Decimal(minor) / Decimal(from.scale)
        let target = major * Decimal(micros) / Decimal(rateScale) * Decimal(to.scale)
        return NSDecimalNumber(decimal: target).rounding(accordingToBehavior: behavior).intValue
    }

    /// The implied rate (in millionths) of a transfer where `fromMinor` of one currency became `toMinor` of another.
    static func impliedMicros(fromMinor: Int, from: Currency, toMinor: Int, to: Currency) -> Int? {
        guard fromMinor > 0, toMinor > 0 else { return nil }
        let fromMajor = Decimal(fromMinor) / Decimal(from.scale), toMajor = Decimal(toMinor) / Decimal(to.scale)
        return NSDecimalNumber(decimal: toMajor / fromMajor * Decimal(rateScale)).rounding(accordingToBehavior: behavior).intValue
    }

    static func parseRate(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty, let d = Decimal(string: t), d > 0, d < 1_000_000 else { return nil }
        let micros = NSDecimalNumber(decimal: d * Decimal(rateScale)).rounding(accordingToBehavior: behavior).intValue
        return micros > 0 ? micros : nil
    }

    static func formatRate(_ micros: Int) -> String {
        let d = Decimal(micros) / Decimal(rateScale)
        let f = NumberFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.minimumFractionDigits = 0; f.maximumFractionDigits = 6
        f.usesGroupingSeparator = false
        return f.string(from: NSDecimalNumber(decimal: d)) ?? "\(d)"
    }
}
