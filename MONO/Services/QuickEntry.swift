import Foundation

/// Learns from past transactions so repeat entries take two taps: type "Grab", get Transportation and the usual amount.
enum QuickEntry {
    struct Suggestion: Identifiable, Equatable {
        let title: String
        let kind: TxKind
        let category: String
        let amountCents: Int
        var id: String { "\(kind.rawValue)|\(title.lowercased())" }
    }

    /// Distinct descriptions from `history` (newest first), filtered by what has been typed.
    /// Each carries the category and amount of its most recent use. Prefix matches rank above substring matches.
    static func suggestions(matching text: String, in history: [TransactionRecord], limit: Int = 6) -> [Suggestion] {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var seen = Set<String>()
        var prefix: [Suggestion] = [], contains: [Suggestion] = []
        for t in history.sorted(by: { $0.date > $1.date }) {
            let title = t.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, t.sourceID == nil, t.kind != .transfer else { continue }
            let s = Suggestion(title: title, kind: t.kind, category: t.category, amountCents: t.amountCents)
            guard seen.insert(s.id).inserted else { continue }
            let lower = title.lowercased()
            if q.isEmpty || lower.hasPrefix(q) { prefix.append(s) }
            else if lower.contains(q) { contains.append(s) }
            if prefix.count >= limit { break }
        }
        return Array((prefix + contains).prefix(limit))
    }
}
