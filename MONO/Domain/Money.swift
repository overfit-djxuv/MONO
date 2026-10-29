import Foundation

/// All amounts in MONO are stored as integer minor units (cents, sen, yen…) so sums are exact.
/// The global helpers below use the reporting currency; pass a `Currency` to format another one.
enum Money {
    static let maxCents = 99_999_999_999 // 999,999,999.99

    static let reportingKey = "reportingCurrency"

    /// The currency totals are reported in (default ringgit). Everything in other currencies is converted into it with an explicit rate.
    static var reporting: Currency { Currency.find(UserDefaults.standard.string(forKey: reportingKey) ?? Currency.default.code) }

    /// A user-typed symbol override for the reporting currency; otherwise the currency's own symbol.
    static var symbol: String {
        let s = (UserDefaults.standard.string(forKey: "currencySymbol") ?? "").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? reporting.symbol : s
    }

    private static let whole: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    /// "RM 1,234.50", negatives as "−RM 1,234.50".
    /// `ignoreHiding` is only for files you explicitly export; on screen, Hide amounts always wins.
    static func format(_ cents: Int, signed: Bool = false, symbol: String? = nil, currency: Currency? = nil, ignoreHiding: Bool = false) -> String {
        let cur = currency ?? reporting
        let sym = symbol ?? (currency == nil ? Self.symbol : cur.symbol)
        let a = abs(cents)
        // Hide amounts: the figure becomes dots but the symbol and the sign stay, so income still reads as income.
        if PrivacyStore.shared.hidden && !ignoreHiding {
            let masked = "\(sym) \(PrivacyStore.mask)"
            if cents < 0 { return "−" + masked }
            return signed && cents > 0 ? "+" + masked : masked
        }
        let w = whole.string(from: NSNumber(value: a / cur.scale)) ?? "\(a / cur.scale)"
        let body = cur.digits == 0 ? "\(sym) \(w)" : "\(sym) \(w).\(String(format: "%0\(cur.digits)d", a % cur.scale))"
        if cents < 0 { return "−" + body }
        return signed && cents > 0 ? "+" + body : body
    }

    /// Whole-unit rendering for tight spaces: "RM 1,235".
    static func formatWhole(_ cents: Int) -> String {
        if PrivacyStore.shared.hidden { return (cents < 0 ? "−" : "") + "\(symbol) \(PrivacyStore.mask)" }
        let rounded = Int((Double(abs(cents)) / Double(reporting.scale)).rounded())
        let w = whole.string(from: NSNumber(value: rounded)) ?? "\(rounded)"
        return (cents < 0 ? "−" : "") + "\(symbol) \(w)"
    }

    /// Chart-axis style: 1.2k, 3.4M.
    static func compact(_ value: Double) -> String {
        if PrivacyStore.shared.hidden { return "•••" }
        let a = abs(value)
        let sign = value < 0 ? "−" : ""
        switch a {
        case 1_000_000...: return "\(sign)\(trim(a / 1_000_000))M"
        case 1_000...: return "\(sign)\(trim(a / 1_000))k"
        default: return "\(sign)\(Int(a.rounded()))"
        }
    }

    private static func trim(_ v: Double) -> String {
        let s = String(format: "%.1f", v)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }

    /// Parses user input such as "12", "12.5", "1,200.00", "RM 40". Returns nil for anything ambiguous,
    /// including more decimal places than the currency has (2 for ringgit, 0 for yen).
    static func parse(_ text: String, currency: Currency? = nil) -> Int? {
        let cur = currency ?? reporting
        let sym = currency == nil ? symbol : cur.symbol
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
        if s.lowercased().hasPrefix(sym.lowercased()) { s = String(s.dropFirst(sym.count)) }
        guard !s.isEmpty else { return nil }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let intPart = String(parts[0])
        let fracPart = parts.count == 2 ? String(parts[1]) : ""
        guard intPart.allSatisfy({ $0.isASCII && $0.isNumber }),
              fracPart.allSatisfy({ $0.isASCII && $0.isNumber }),
              fracPart.count <= cur.digits, intPart.count <= 11,
              !(intPart.isEmpty && fracPart.isEmpty) else { return nil }
        let w = Int(intPart.isEmpty ? "0" : intPart) ?? 0
        let f = cur.digits == 0 ? 0 : (Int((fracPart + String(repeating: "0", count: cur.digits)).prefix(cur.digits)) ?? 0)
        let total = w * cur.scale + f
        return total <= maxCents ? total : nil
    }

    /// Plain editable text for a minor-unit value ("12.50"), used to pre-fill forms.
    static func editable(_ cents: Int, currency: Currency? = nil) -> String {
        let cur = currency ?? reporting
        guard cents != 0 else { return "" }
        return cur.digits == 0 ? "\(cents)" : String(format: "%d.%0\(cur.digits)d", cents / cur.scale, cents % cur.scale)
    }
}

extension Int {
    /// Cents → ringgit as Double, for charts only.
    var rm: Double { Double(self) / Double(Money.reporting.scale) }
}

func ceilDiv(_ a: Int, _ b: Int) -> Int { b <= 0 ? 0 : (a + b - 1) / b }
