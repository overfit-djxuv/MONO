import Foundation

struct ReceiptItem: Codable, Equatable, Identifiable {
    var name: String
    var cents: Int
    var id: String { "\(name)|\(cents)" }
}

/// What could be read from a receipt's text. `uncertain` names the fields to double-check; nothing here is trusted blindly.
struct ParsedReceipt: Equatable {
    enum Field: String { case merchant, date, total, tax, currency }
    var merchant = ""
    var date: Date?
    var totalCents: Int?
    var taxCents: Int?
    var currencyCode: String?
    var items: [ReceiptItem] = []
    var uncertain: Set<Field> = []
}

/// Reads receipt text in English, Spanish and Malay (and Indonesian words that overlap with Malay). Pure and deterministic.
enum ReceiptParser {
    // MARK: Normalising

    static func fold(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en")) }

    // MARK: Amounts

    private static let amountRegex = try! NSRegularExpression(
        pattern: #"(?<![\d.,])\d{1,3}(?:[.,]\d{3})+(?:[.,]\d{1,2})?(?!\d)|(?<![\d.,])\d+(?:[.,]\d{1,2})?(?!\d)"#)

    struct Amount: Equatable { let cents: Int; let range: Range<String.Index> }

    /// Turns "1,234.50", "1.234,50", "12,5" or "25.000" into minor units. A separator followed by exactly three digits is a thousands mark.
    static func parseAmount(_ token: String, digits: Int = 2) -> Int? {
        let chars = Array(token)
        guard chars.contains(where: \.isNumber) else { return nil }
        var whole = "", frac = ""
        if let last = chars.lastIndex(where: { $0 == "." || $0 == "," }) {
            let after = chars[(last + 1)...].filter(\.isNumber)
            let before = chars[..<last].filter(\.isNumber)
            if after.count == 3 && digits != 3 { whole = String(before + after) }
            else { whole = String(before); frac = String(after) }
        } else { whole = String(chars.filter(\.isNumber)) }
        guard let w = Int(whole.isEmpty ? "0" : whole), whole.count < 12 else { return nil }
        var f = frac
        while f.count < digits { f += "0" }
        f = String(f.prefix(digits))
        let scale = Int(pow(10, Double(digits)))
        return w * scale + (Int(f) ?? 0)
    }

    /// Amounts on a line, ignoring percentages ("6%") and long digit runs (phone numbers, invoice numbers).
    static func amounts(in line: String, digits: Int = 2) -> [Amount] {
        let ns = line as NSString
        return amountRegex.matches(in: line, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard let r = Range(m.range, in: line) else { return nil }
            let token = String(line[r])
            let after = line[r.upperBound...].drop { $0 == " " }
            if after.first == "%" { return nil }
            if token.count > 10 && !token.contains(where: { $0 == "." || $0 == "," }) { return nil }
            // A bare integer with no decimals is rarely a price on a receipt line (quantities, table numbers, years).
            guard token.contains(where: { $0 == "." || $0 == "," }), let c = parseAmount(token, digits: digits) else { return nil }
            return Amount(cents: c, range: r)
        }
    }

    // MARK: Keywords

    private static let totalKeys = ["grand total", "total amount", "amount due", "balance due", "total due", "total a pagar", "importe total", "a pagar",
                                    "jumlah besar", "jumlah bayaran", "jumlah akhir", "total bayar", "net total", "nett total", "jumlah", "amaun", "total"]
    private static let notTotal = ["subtotal", "sub total", "sub-total", "jumlah kecil", "total item", "total qty", "total discount", "diskaun", "discount",
                                   "descuento", "tax", "cukai", "iva", "impuesto", "sst", "gst", "vat", "ppn", "change", "baki", "cambio", "tunai", "cash", "efectivo",
                                   "rounding", "pembundaran", "redondeo", "points", "mata", "saving"]
    private static let taxKeys = ["sst", "gst", "vat", "tax", "iva", "impuesto", "cukai", "ppn", "pajak"]
    private static let skipItem = ["total", "subtotal", "sub total", "tax", "cukai", "iva", "sst", "gst", "vat", "change", "baki", "cambio", "cash", "tunai",
                                   "efectivo", "rounding", "pembundaran", "redondeo", "discount", "diskaun", "descuento", "amount", "jumlah", "importe",
                                   "visa", "master", "debit", "credit", "card", "tarjeta", "kad", "paid", "bayar", "pagado", "balance", "tel", "invoice",
                                   "receipt", "resit", "recibo", "factura", "date", "tarikh", "fecha"]

    private static func has(_ folded: String, any keys: [String]) -> Bool { keys.contains { folded.contains($0) } }
    private static func hasWord(_ folded: String, any keys: [String]) -> Bool {
        let words = Set(folded.split { !$0.isLetter }.map(String.init))
        return keys.contains { words.contains($0) }
    }

    // MARK: Dates

    private static let months: [String: Int] = {
        var m: [String: Int] = [:]
        let names: [[String]] = [
            ["jan", "january", "ene", "enero", "januari"], ["feb", "february", "febrero", "februari", "pebruari"], ["mar", "march", "marzo", "mac", "maret"],
            ["apr", "april", "abr", "abril"], ["may", "mayo", "mei"], ["jun", "june", "junio", "juni"], ["jul", "july", "julio", "julai", "juli"],
            ["aug", "august", "ago", "agosto", "ogos", "agu", "agustus"], ["sep", "sept", "september", "septiembre", "setiembre"],
            ["oct", "october", "octubre", "oktober", "okt"], ["nov", "november", "noviembre"], ["dec", "december", "dic", "diciembre", "disember", "des", "desember"],
        ]
        for (i, list) in names.enumerated() { for n in list { m[n] = i + 1 } }
        return m
    }()

    private static func make(_ y: Int, _ mo: Int, _ d: Int, now: Date, calendar: Calendar) -> Date? {
        let year = y < 100 ? 2000 + y : y
        guard (2000...3000).contains(year), (1...12).contains(mo), (1...31).contains(d) else { return nil }
        var c = DateComponents(); c.year = year; c.month = mo; c.day = d; c.hour = 12
        guard let date = calendar.date(from: c), calendar.component(.day, from: date) == d, calendar.component(.month, from: date) == mo else { return nil }
        guard date < calendar.date(byAdding: .day, value: 2, to: now) ?? now else { return nil }   // receipts aren't from the future
        return date
    }

    private static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
    private static let isoDate = rx(#"(?<!\d)(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})(?!\d)"#)
    private static let numDate = rx(#"(?<![\d.])(\d{1,2})[-/.](\d{1,2})[-/.](\d{4}|\d{2})(?!\d)"#)
    private static let textDayFirst = rx(#"(?<!\d)(\d{1,2})(?:st|nd|rd|th)?[\s.\-]*(?:de\s+)?([\p{L}]{3,10})\.?,?[\s\-]*(?:de\s+|del\s+)?(\d{4}|\d{2})(?!\d)"#)
    private static let textMonthFirst = rx(#"([\p{L}]{3,10})\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})(?!\d)"#)

    /// First plausible date in the text. Numeric dates are read day-first (as in Malaysia and Spain); when that is a guess, `ambiguous` is true.
    static func findDate(in lines: [String], now: Date = .now, calendar: Calendar = .current) -> (date: Date, ambiguous: Bool)? {
        func groups(_ r: NSRegularExpression, _ s: String) -> [[String]]? {
            let ns = s as NSString
            guard let m = r.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
            return [(1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }]
        }
        for line in lines {
            if let g = groups(isoDate, line)?.first, let y = Int(g[0]), let mo = Int(g[1]), let d = Int(g[2]), let dt = make(y, mo, d, now: now, calendar: calendar) { return (dt, false) }
            if let g = groups(numDate, line)?.first, let a = Int(g[0]), let b = Int(g[1]), let y = Int(g[2]) {
                if let dt = make(y, b, a, now: now, calendar: calendar) { return (dt, a <= 12 && b <= 12 && a != b) }
                if let dt = make(y, a, b, now: now, calendar: calendar) { return (dt, false) }   // second number > 12: must be month-first
            }
            if let g = groups(textDayFirst, line)?.first, let d = Int(g[0]), let mo = months[fold(g[1]).lowercased()], let y = Int(g[2]),
               let dt = make(y, mo, d, now: now, calendar: calendar) { return (dt, false) }
            if let g = groups(textMonthFirst, line)?.first, let mo = months[fold(g[0]).lowercased()], let d = Int(g[1]), let y = Int(g[2]),
               let dt = make(y, mo, d, now: now, calendar: calendar) { return (dt, false) }
        }
        return nil
    }

    // MARK: Currency

    static func findCurrency(in text: String) -> String? {
        let checks: [(String, String)] = [(#"\bRM\s?\d|\bMYR\b"#, "MYR"), (#"S\$\s?\d|\bSGD\b"#, "SGD"), (#"€|\bEUR\b"#, "EUR"), (#"\bRp\.?\s?\d|\bIDR\b"#, "IDR"),
                                          (#"£|\bGBP\b"#, "GBP"), (#"\bUSD\b|US\$"#, "USD"), (#"\bTHB\b|฿"#, "THB")]
        for (p, code) in checks where rx(p).firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil { return code }
        return nil   // a bare "$" could be several currencies: never guessed
    }

    // MARK: Parse

    static func parse(lines rawLines: [String], digits: Int = 2, now: Date = .now, calendar: Calendar = .current) -> ParsedReceipt {
        let lines = rawLines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var out = ParsedReceipt()
        let folded = lines.map(fold)

        // Merchant: the first line near the top that looks like a name.
        let headerSkip = ["tel", "phone", "fax", "date", "time", "receipt", "invoice", "resit", "recibo", "factura", "gst", "sst", "reg", "www", "http", "table", "cashier", "kasir", "tarikh", "fecha", "no.", "order"]
        for (i, line) in lines.prefix(8).enumerated() {
            let f = folded[i]
            let letters = line.filter(\.isLetter).count, digitsN = line.filter(\.isNumber).count
            guard letters >= 3, letters > digitsN * 2, !headerSkip.contains(where: { f.hasPrefix($0) }) else { continue }
            out.merchant = line
            if i > 2 { out.uncertain.insert(.merchant) }
            break
        }
        if out.merchant.isEmpty { out.uncertain.insert(.merchant) }

        // Date.
        if let d = findDate(in: lines, now: now, calendar: calendar) { out.date = d.date; if d.ambiguous { out.uncertain.insert(.date) } } else { out.uncertain.insert(.date) }

        // Currency.
        out.currencyCode = findCurrency(in: lines.joined(separator: "\n"))

        // Total.
        func amountsNear(_ i: Int) -> [Amount] {
            let own = amounts(in: lines[i], digits: digits)
            if !own.isEmpty { return own }
            return i + 1 < lines.count ? amounts(in: lines[i + 1], digits: digits) : []
        }
        var best: (rank: Int, cents: Int)?
        for (i, f) in folded.enumerated() {
            guard !has(f, any: notTotal) || has(f, any: ["grand total", "total amount", "amount due", "balance due", "total due", "jumlah besar", "jumlah bayaran", "importe total", "total a pagar"]) else { continue }
            guard let rank = totalKeys.firstIndex(where: { f.contains($0) }), let amount = amountsNear(i).last else { continue }
            let r = totalKeys.count - rank
            if best == nil || r > best!.rank || (r == best!.rank && amount.cents > best!.cents) { best = (r, amount.cents) }
        }
        if let best { out.totalCents = best.cents }
        else {
            // No "total" line: the biggest amount that isn't tax, change or cash is the likeliest total, but it's only a guess.
            let candidates = lines.indices.filter { !has(folded[$0], any: notTotal) }.flatMap { amounts(in: lines[$0], digits: digits).map(\.cents) }
            out.totalCents = candidates.max()
            out.uncertain.insert(.total)
        }
        if out.totalCents == nil { out.uncertain.insert(.total) }

        // Tax.
        for (i, f) in folded.enumerated() where hasWord(f, any: taxKeys) && !f.contains("subtotal") {
            if let a = amounts(in: lines[i], digits: digits).last, a.cents > 0, a.cents < (out.totalCents ?? Int.max) { out.taxCents = a.cents; break }
        }

        // Possible items: "name ... price" lines that are not totals, tax, payment or header lines.
        for (i, line) in lines.enumerated() {
            let f = folded[i]
            guard out.items.count < 60, !hasWord(f, any: skipItem), !has(f, any: ["sub total", "grand total", "jumlah", "importe"]),
                  let a = amounts(in: line, digits: digits).last, a.cents > 0 else { continue }
            var name = String(line[..<a.range.lowerBound])
            for s in ["RM", "MYR", "€", "$", "Rp", "EUR"] { name = name.replacingOccurrences(of: s, with: "") }
            name = name.replacingOccurrences(of: #"^\s*\d+\s*[xX×]?\s+"#, with: "", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: " .:-*\t"))
            guard name.filter(\.isLetter).count >= 2, a.cents != out.totalCents else { continue }
            out.items.append(ReceiptItem(name: name, cents: a.cents))
        }
        return out
    }
}

/// Finds receipts and transactions that probably describe the same purchase.
enum ReceiptMatcher {
    struct Existing { let id: UUID; let merchant: String; let date: Date; let totalCents: Int; let hash: String }

    static func duplicate(of new: (merchant: String, date: Date, totalCents: Int, hash: String), in existing: [Existing], calendar: Calendar = .current) -> Existing? {
        existing.first { e in
            if !new.hash.isEmpty && e.hash == new.hash { return true }
            guard new.totalCents > 0, e.totalCents == new.totalCents, calendar.isDate(e.date, inSameDayAs: new.date) else { return false }
            let a = ReceiptParser.fold(new.merchant).lowercased(), b = ReceiptParser.fold(e.merchant).lowercased()
            return a.isEmpty || b.isEmpty || a == b
        }
    }

    /// Expenses worth offering when attaching a receipt: same amount first, then the closest dates.
    static func candidates(totalCents: Int, date: Date, transactions: [TransactionRecord], limit: Int = 12, calendar: Calendar = .current) -> [TransactionRecord] {
        func dayGap(_ t: TransactionRecord) -> Int { abs(calendar.dateComponents([.day], from: calendar.startOfDay(for: t.date), to: calendar.startOfDay(for: date)).day ?? 999) }
        let spend = transactions.filter { $0.kind == .expense }
        let ranked = spend.sorted { a, b in
            let ea = a.amountCents == totalCents, eb = b.amountCents == totalCents
            if ea != eb { return ea }
            return dayGap(a) < dayGap(b)
        }
        return Array(ranked.filter { $0.amountCents == totalCents || dayGap($0) <= 7 }.prefix(limit))
    }
}
