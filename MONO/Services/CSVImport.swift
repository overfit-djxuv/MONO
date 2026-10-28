import Foundation
import SwiftData

/// Reads bank-statement style CSV files into transactions. Everything here is pure logic so it can be tested;
/// `CSVImportView` only drives it. Importing only ever adds records: it never edits or deletes existing ones.
enum CSVImport {
    static let maxRows = 20_000
    static let maxBytes = 5_000_000

    enum ImportError: LocalizedError {
        case unreadable, empty, tooLarge, tooManyRows
        var errorDescription: String? {
            switch self {
            case .unreadable: "The file couldn’t be read as text."
            case .empty: "The file has no rows."
            case .tooLarge: "The file is larger than 5 MB."
            case .tooManyRows: "The file has more than \(CSVImport.maxRows) rows. Split it and import in parts."
            }
        }
    }

    // MARK: Parsing

    /// Decodes UTF-8 (with or without BOM), falling back to Latin-1 for older bank exports.
    static func decode(_ data: Data) throws -> String {
        guard data.count <= maxBytes else { throw ImportError.tooLarge }
        if let s = String(data: data, encoding: .utf8) { return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        throw ImportError.unreadable
    }

    /// Reads a file the user picked: security-scoped access, size limit, decoding and parsing in one step.
    static func load(from url: URL) throws -> [[String]] {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxBytes else { throw ImportError.tooLarge }
        return try parse(try decode(Data(contentsOf: url)))
    }

    static func detectDelimiter(_ text: String) -> Character {
        var counts: [Character: Int] = [",": 0, ";": 0, "\t": 0]
        var inQuotes = false
        for c in text {
            if c == "\"" { inQuotes.toggle() }
            else if !inQuotes {
                if c == "\n" || c == "\r\n" || c == "\r" { break }
                if counts[c] != nil { counts[c]! += 1 }
            }
        }
        let best = counts.max { $0.value < $1.value }
        return (best?.value ?? 0) > 0 ? best!.key : ","
    }

    /// RFC 4180: quoted fields, doubled quotes, newlines inside quotes. Fully blank lines are dropped.
    static func parse(_ text: String, delimiter: Character? = nil) throws -> [[String]] {
        let d = delimiter ?? detectDelimiter(text)
        var rows: [[String]] = [], row: [String] = [], field = ""
        var inQuotes = false, justClosedQuote = false

        func endField() { row.append(field); field = ""; justClosedQuote = false }
        func endRow() {
            endField()
            if !(row.count == 1 && row[0].trimmingCharacters(in: .whitespaces).isEmpty) { rows.append(row) }
            row = []
        }

        for c in text {
            if inQuotes {
                if c == "\"" { inQuotes = false; justClosedQuote = true } else { field.append(c) }
                continue
            }
            switch c {
            case "\"":
                if justClosedQuote { field.append("\""); inQuotes = true; justClosedQuote = false }   // "" → literal quote
                else if field.isEmpty { inQuotes = true }
                else { field.append(c) }
            case d: endField()
            case "\n", "\r\n", "\r":
                endRow()
                if rows.count > maxRows + 1 { throw ImportError.tooManyRows }
            default: field.append(c); justClosedQuote = false
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        guard !rows.isEmpty else { throw ImportError.empty }
        return rows
    }

    // MARK: Amounts

    /// Signed cents from text such as "1,234.50", "-12.00", "(12.00)", "RM 40", "1.234,50". Nil if not a clean amount.
    static func parseAmount(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let negative = t.contains("(") && t.contains(")") || t.hasPrefix("-") || t.hasPrefix("−") || t.hasSuffix("-") || t.hasSuffix("−")
        var s = String(t.filter { $0.isASCII && ($0.isNumber || $0 == "." || $0 == ",") })
        guard s.contains(where: \.isNumber) else { return nil }

        let dots = s.filter { $0 == "." }.count, commas = s.filter { $0 == "," }.count
        if dots > 0 && commas > 0 {
            // The separator that comes last is the decimal point.
            let decimal: Character = s.lastIndex(of: ".")! > s.lastIndex(of: ",")! ? "." : ","
            let thousands: Character = decimal == "." ? "," : "."
            s = s.filter { $0 != thousands }
            if decimal == "," { s = s.replacingOccurrences(of: ",", with: ".") }
        } else if commas > 0 {
            let after = s.split(separator: ",", omittingEmptySubsequences: false).last?.count ?? 0
            if commas == 1 && (1...2).contains(after) { s = s.replacingOccurrences(of: ",", with: ".") }   // "12,50"
            else { s = s.replacingOccurrences(of: ",", with: "") }                                          // "1,234"
        } else if dots > 1 {
            s = s.replacingOccurrences(of: ".", with: "")                                                   // "1.234.567"
        }
        guard let cents = Money.parse(s) else { return nil }
        return negative ? -cents : cents
    }

    // MARK: Dates

    enum DateFormat: String, CaseIterable, Identifiable {
        case iso, dmy, mdy, dMonY
        var id: String { rawValue }
        var label: String {
            switch self { case .iso: "2026-03-31"; case .dmy: "31/03/2026"; case .mdy: "03/31/2026"; case .dMonY: "31 Mar 2026" }
        }
        fileprivate var pattern: String {
            switch self { case .iso: "yyyy-M-d"; case .dmy: "d/M/yyyy"; case .mdy: "M/d/yyyy"; case .dMonY: "d MMM yyyy" }
        }
    }

    static func parseDate(_ text: String, format: DateFormat, calendar: Calendar = .current) -> Date? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        switch format {
        case .iso, .dmy, .mdy:
            if let i = s.firstIndex(where: { $0 == " " || $0 == "T" }) { s = String(s[..<i]) }   // drop a time of day
            s = s.replacingOccurrences(of: ".", with: format == .iso ? "-" : "/")
            s = s.replacingOccurrences(of: "-", with: format == .iso ? "-" : "/")
            if format == .iso { s = s.replacingOccurrences(of: "/", with: "-") }
        case .dMonY:
            s = s.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: ",", with: " ")
            s = s.split(separator: " ").prefix(3).joined(separator: " ")
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = format.pattern
        f.isLenient = false
        guard let day = f.date(from: s) else { return nil }
        let y = calendar.component(.year, from: day)
        guard (1990...2100).contains(y) else { return nil }
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day)
    }

    /// The format that reads the most sample cells. Ties go to day-first, then month-first.
    static func detectDateFormat(_ samples: [String], calendar: Calendar = .current) -> DateFormat {
        let cells = samples.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(200)
        let order: [DateFormat] = [.iso, .dmy, .mdy, .dMonY]
        let scored = order.map { f in (f, cells.filter { parseDate($0, format: f, calendar: calendar) != nil }.count) }
        return scored.max { $0.1 < $1.1 }?.0 ?? .iso
    }

    // MARK: Mapping

    enum AmountMode: String, CaseIterable, Identifiable {
        case signed, debitCredit, typeColumn
        var id: String { rawValue }
        var label: String {
            switch self {
            case .signed: "One amount column (minus = expense)"
            case .debitCredit: "Separate debit and credit columns"
            case .typeColumn: "Amount plus a type column"
            }
        }
    }

    struct Mapping: Equatable {
        var hasHeader = true
        var date: Int?
        var title: Int?
        var amount: Int?
        var debit: Int?
        var credit: Int?
        var type: Int?
        var category: Int?
        var notes: Int?
        var mode: AmountMode = .signed
        var dateFormat: DateFormat = .iso
        /// For statements where charges are positive (some credit-card exports).
        var invertSigns = false
    }

    static func looksLikeHeader(_ row: [String], calendar: Calendar = .current) -> Bool {
        !row.contains { cell in DateFormat.allCases.contains { parseDate(cell, format: $0, calendar: calendar) != nil } }
    }

    static func autoMapping(_ records: [[String]], calendar: Calendar = .current) -> Mapping {
        var m = Mapping()
        guard let first = records.first else { return m }
        m.hasHeader = looksLikeHeader(first, calendar: calendar)
        let names = first.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }

        func find(_ keys: [String], excluding used: Set<Int> = []) -> Int? {
            names.indices.first { i in !used.contains(i) && keys.contains { names[i].contains($0) } }
        }
        if m.hasHeader {
            m.date = find(["date", "posted"])
            m.debit = find(["debit", "withdrawal", "paid out", "money out"])
            m.credit = find(["credit", "deposit", "paid in", "money in"])
            m.type = find(["type"])
            m.amount = find(["amount", "value"], excluding: Set([m.debit, m.credit].compactMap { $0 }))
            m.category = find(["category"])
            m.title = find(["description", "details", "payee", "merchant", "narration", "memo", "title", "name"],
                           excluding: Set([m.date, m.category].compactMap { $0 }))
            m.notes = find(["notes", "note", "reference", "ref"], excluding: Set([m.title].compactMap { $0 }))
            if m.debit != nil && m.credit != nil { m.mode = .debitCredit }
            else if m.type != nil && m.amount != nil { m.mode = .typeColumn }
        } else if first.count >= 3 {
            m.date = 0; m.title = 1; m.amount = 2
        }
        let body = records.dropFirst(m.hasHeader ? 1 : 0)
        if let d = m.date { m.dateFormat = detectDateFormat(body.compactMap { $0.indices.contains(d) ? $0[d] : nil }, calendar: calendar) }
        return m
    }

    // MARK: Planning

    struct Row: Equatable {
        let line: Int
        let kind: TxKind
        let cents: Int
        let date: Date
        let title: String
        let category: String
        let notes: String
    }
    struct Skipped: Equatable { let line: Int; let reason: String }
    struct NewCategory: Equatable { let name: String; let kind: TxKind }

    struct Plan {
        var rows: [Row] = []
        var skipped: [Skipped] = []
        var duplicates = 0
        var newCategories: [NewCategory] = []
        var income: Int { rows.filter { $0.kind == .income }.reduce(0) { $0 + $1.cents } }
        var expense: Int { rows.filter { $0.kind == .expense }.reduce(0) { $0 + $1.cents } }
    }

    private struct Key: Hashable { let day: Date; let kind: TxKind; let cents: Int; let title: String }

    /// Maps rows to transactions without touching the database. Rows that match an existing record
    /// (same day, type, amount and description) are counted as duplicates and left out, once per existing record,
    /// so importing the same file twice adds nothing the second time.
    static func plan(records: [[String]], mapping m: Mapping, existing: [TransactionRecord], categories: [MoneyCategory],
                     createMissingCategories: Bool, calendar: Calendar = .current) -> Plan {
        var plan = Plan()
        var seen: [Key: Int] = [:]
        for t in existing {
            seen[Key(day: calendar.startOfDay(for: t.date), kind: t.kind, cents: t.amountCents,
                     title: t.title.lowercased()), default: 0] += 1
        }
        let known = Dictionary(grouping: categories, by: { $0.kind })
        var added: [String: String] = [:]   // "kind|lowercased" → name, for categories created by this import

        func cell(_ r: [String], _ i: Int?) -> String {
            guard let i, r.indices.contains(i) else { return "" }
            return r[i].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func clean(_ s: String, limit: Int) -> String {
            var v = s
            // Undo the apostrophe MONO's own export adds in front of formula-like text.
            if v.count > 1, v.hasPrefix("'"), "=+-@".contains(v[v.index(after: v.startIndex)]) { v.removeFirst() }
            return String(v.prefix(limit))
        }

        for (offset, r) in records.enumerated().dropFirst(m.hasHeader ? 1 : 0) {
            let line = offset + 1
            if r.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) { continue }
            func skip(_ why: String) { plan.skipped.append(.init(line: line, reason: why)) }

            guard let date = parseDate(cell(r, m.date), format: m.dateFormat, calendar: calendar) else { skip("date not understood"); continue }

            let kind: TxKind, cents: Int
            switch m.mode {
            case .signed:
                guard let v = parseAmount(cell(r, m.amount)) else { skip("amount not understood"); continue }
                guard v != 0 else { skip("amount is zero"); continue }
                kind = (v < 0) != m.invertSigns ? .expense : .income
                cents = abs(v)
            case .debitCredit:
                let d = abs(parseAmount(cell(r, m.debit)) ?? 0), c = abs(parseAmount(cell(r, m.credit)) ?? 0)
                if d > 0 && c > 0 { skip("has both a debit and a credit"); continue }
                guard d > 0 || c > 0 else { skip("no amount"); continue }
                kind = d > 0 ? .expense : .income
                cents = d > 0 ? d : c
            case .typeColumn:
                guard let v = parseAmount(cell(r, m.amount)), v != 0 else { skip("amount not understood"); continue }
                let t = cell(r, m.type).lowercased()
                if ["income", "credit", "deposit", "in", "cr"].contains(t) { kind = .income }
                else if ["expense", "debit", "withdrawal", "out", "dr"].contains(t) { kind = .expense }
                else { skip("type “\(cell(r, m.type))” not understood"); continue }
                cents = abs(v)
            }
            guard cents <= Money.maxCents else { skip("amount too large"); continue }

            let title = clean(cell(r, m.title), limit: 200)
            let wanted = cell(r, m.category)
            var category = ""
            if let hit = known[kind]?.first(where: { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }) {
                category = hit.name
            } else if let made = added["\(kind.rawValue)|\(wanted.lowercased())"] {
                category = made
            } else if createMissingCategories, !wanted.isEmpty {
                category = clean(wanted, limit: 40)
                added["\(kind.rawValue)|\(wanted.lowercased())"] = category
                plan.newCategories.append(.init(name: category, kind: kind))
            } else {
                category = kind == .income ? "Other Income" : "Other"
            }

            let key = Key(day: calendar.startOfDay(for: date), kind: kind, cents: cents, title: title.lowercased())
            if let n = seen[key], n > 0 { seen[key] = n - 1; plan.duplicates += 1; continue }

            plan.rows.append(.init(line: line, kind: kind, cents: cents, date: date, title: title, category: category,
                                   notes: clean(cell(r, m.notes), limit: 500)))
        }
        return plan
    }

    // MARK: Apply

    /// Adds the planned records in one save. Rolls back completely on failure.
    static func apply(_ plan: Plan, categories: [MoneyCategory], in context: ModelContext) throws {
        do {
            var order = (categories.map(\.sortOrder).max() ?? 0) + 1
            for c in plan.newCategories {
                context.insert(MoneyCategory(name: c.name, symbol: "tag", kind: c.kind, sortOrder: order))
                order += 1
            }
            for r in plan.rows {
                context.insert(TransactionRecord(amountCents: r.cents, kind: r.kind, category: r.category,
                                                 date: r.date, title: r.title, notes: r.notes))
            }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}
