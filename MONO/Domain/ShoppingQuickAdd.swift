import Foundation

/// Turns one typed line into a shopping item: "milk 2 4.50" is milk, quantity 2, RM 4.50 each.
/// One trailing number is a price ("milk 4.50"); two are quantity then price. Anything else stays in the name.
enum ShoppingQuickAdd {
    struct Parsed: Equatable { var name: String; var quantity: Int; var priceCents: Int }

    /// "1,20" is one ringgit twenty in Spanish and Malay typing; "1,200" is a thousand. A comma followed by one or two digits is a decimal.
    private static func normalised(_ token: String) -> String {
        guard !token.contains("."), let comma = token.lastIndex(of: ","), token.filter({ $0 == "," }).count == 1 else { return token }
        let after = token[token.index(after: comma)...]
        return (1...2).contains(after.count) ? token.replacingOccurrences(of: ",", with: ".") : token
    }

    static func parse(_ text: String, currency: Currency? = nil) -> Parsed? {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var numbers: [String] = []
        while let last = words.last, numbers.count < 2, last.contains(where: \.isNumber), Double(last.replacingOccurrences(of: ",", with: ".")) != nil {
            numbers.insert(words.removeLast(), at: 0)
        }
        let name = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        var qty = 1, price = 0
        if numbers.count == 2 {
            guard let q = Int(numbers[0]), (1...999).contains(q), let p = Money.parse(normalised(numbers[1]), currency: currency) else { return nil }
            qty = q; price = p
        } else if let n = numbers.first {
            guard let p = Money.parse(normalised(n), currency: currency) else { return nil }
            price = p
        }
        return Parsed(name: name, quantity: qty, priceCents: max(price, 0))
    }
}
