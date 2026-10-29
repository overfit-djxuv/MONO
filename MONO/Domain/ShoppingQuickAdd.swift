import Foundation

/// Turns one typed line into a shopping item: "milk 2 4.50" is milk, quantity 2, RM 4.50 each.
/// One trailing number is a price ("milk 4.50"); two are quantity then price. Anything else stays in the name.
enum ShoppingQuickAdd {
    struct Parsed: Equatable { var name: String; var quantity: Int; var priceCents: Int }

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
            guard let q = Int(numbers[0]), (1...999).contains(q), let p = Money.parse(numbers[1], currency: currency) else { return nil }
            qty = q; price = p
        } else if let n = numbers.first {
            guard let p = Money.parse(n, currency: currency) else { return nil }
            price = p
        }
        return Parsed(name: name, quantity: qty, priceCents: max(price, 0))
    }
}
