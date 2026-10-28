import Foundation
import SwiftData
@testable import MONO

let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
}

func income(_ cents: Int, _ d: Date, cat: String = "Salary") -> TransactionRecord {
    TransactionRecord(amountCents: cents, kind: .income, category: cat, date: d, title: "")
}

func expense(_ cents: Int, _ d: Date, cat: String = "Food") -> TransactionRecord {
    TransactionRecord(amountCents: cents, kind: .expense, category: cat, date: d, title: "")
}

@MainActor
func makeContext() throws -> (ModelContainer, ModelContext) {
    let c = try Persistence.inMemoryContainer()
    return (c, ModelContext(c))
}
