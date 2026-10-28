import Foundation

/// All amounts in MONO are stored as integer cents so sums are exact.
enum Money {
    static let maxCents = 99_999_999_999 // 999,999,999.99

    static var symbol: String {
        let s = (UserDefaults.standard.string(forKey: "currencySymbol") ?? "")
            .trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "RM" : s
    }

    private static let whole: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    /// "RM 1,234.50", negatives as "−RM 1,234.50".
    static func format(_ cents: Int, signed: Bool = false, symbol: String? = nil) -> String {
        let sym = symbol ?? Self.symbol
        let a = abs(cents)
        let w = whole.string(from: NSNumber(value: a / 100)) ?? "\(a / 100)"
        let body = "\(sym) \(w).\(String(format: "%02d", a % 100))"
        if cents < 0 { return "−" + body }
        return signed && cents > 0 ? "+" + body : body
    }

    /// Whole-ringgit rendering for tight spaces: "RM 1,235".
    static func formatWhole(_ cents: Int) -> String {
        let rounded = Int((Double(abs(cents)) / 100).rounded())
        let w = whole.string(from: NSNumber(value: rounded)) ?? "\(rounded)"
        return (cents < 0 ? "−" : "") + "\(symbol) \(w)"
    }

    /// Chart-axis style: 1.2k, 3.4M.
    static func compact(_ value: Double) -> String {
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

    /// Parses user input such as "12", "12.5", "1,200.00", "RM 40". Returns nil for anything ambiguous.
    static func parse(_ text: String) -> Int? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
        if s.lowercased().hasPrefix(symbol.lowercased()) { s = String(s.dropFirst(symbol.count)) }
        guard !s.isEmpty else { return nil }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let intPart = String(parts[0])
        let fracPart = parts.count == 2 ? String(parts[1]) : ""
        guard intPart.allSatisfy({ $0.isASCII && $0.isNumber }),
              fracPart.allSatisfy({ $0.isASCII && $0.isNumber }),
              fracPart.count <= 2, intPart.count <= 11,
              !(intPart.isEmpty && fracPart.isEmpty) else { return nil }
        let w = Int(intPart.isEmpty ? "0" : intPart) ?? 0
        let f = Int((fracPart + "00").prefix(2)) ?? 0
        let total = w * 100 + f
        return total <= maxCents ? total : nil
    }

    /// Plain editable text for a cents value ("12.50"), used to pre-fill forms.
    static func editable(_ cents: Int) -> String {
        cents == 0 ? "" : String(format: "%d.%02d", cents / 100, cents % 100)
    }
}

extension Int {
    /// Cents → ringgit as Double, for charts only.
    var rm: Double { Double(self) / 100 }
}

func ceilDiv(_ a: Int, _ b: Int) -> Int { b <= 0 ? 0 : (a + b - 1) / b }
