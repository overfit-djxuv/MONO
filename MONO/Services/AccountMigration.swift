import Foundation
import SwiftData

/// One-time (and idempotent) step that introduces accounts to data created before they existed.
///
/// Safety order, because this touches real financial records:
///  1. If there is existing data and no accounts yet, write a full JSON snapshot and read it back to prove it is valid.
///     If that fails, nothing is changed.
///  2. Create "Main account" holding the old opening balance, in the reporting currency.
///  3. Stamp every record that has no account with the default account, so balances can't shift if accounts are reordered later.
/// The old opening balance preference is left in place. Running it again changes nothing.
enum AccountMigration {
    static let safetyDirectory = Persistence.storeDirectory.appending(path: "Safety", directoryHint: .isDirectory)

    @discardableResult
    static func run(in context: ModelContext, snapshotFirst: Bool = true, defaults: UserDefaults = .standard) throws -> Bool {
        var changed = false
        var accounts = try context.fetch(FetchDescriptor<Account>())

        if accounts.isEmpty {
            let txCount = try context.fetchCount(FetchDescriptor<TransactionRecord>())
            let entryCount = try context.fetchCount(FetchDescriptor<GoalEntry>())
            let hasData = txCount > 0 || entryCount > 0 || defaults.integer(forKey: "openingBalanceCents") != 0
            if snapshotFirst, hasData { try writeSafetySnapshot(context: context, defaults: defaults) }
            let opening = defaults.integer(forKey: "openingBalanceCents")
            let main = Account(name: "Main account", kind: .bank, currencyCode: Money.reporting.code,
                               openingCents: min(max(opening, -Money.maxCents), Money.maxCents), sortOrder: 0)
            context.insert(main)
            accounts = [main]
            changed = true
        }

        if let def = AccountEngine.defaultAccount(accounts) {
            for t in try context.fetch(FetchDescriptor<TransactionRecord>(predicate: #Predicate { $0.accountID == nil })) {
                t.accountID = def.id; changed = true
            }
            for e in try context.fetch(FetchDescriptor<GoalEntry>(predicate: #Predicate { $0.accountID == nil })) {
                e.accountID = def.id; changed = true
            }
        }
        if changed { try context.save() }
        return changed
    }

    /// Writes the pre-migration backup atomically and verifies it decodes and validates before anything is modified.
    static func writeSafetySnapshot(context: ModelContext, defaults: UserDefaults = .standard) throws {
        let file = try BackupService.snapshot(context: context, openingBalanceCents: defaults.integer(forKey: "openingBalanceCents"),
                                              currencySymbol: Money.symbol)
        let data = try BackupService.encode(file)
        _ = try BackupService.decode(data)   // prove it can be restored
        let fm = FileManager.default
        try fm.createDirectory(at: safetyDirectory, withIntermediateDirectories: true,
                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let url = safetyDirectory.appending(path: "before-accounts-\(stamp).json")
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        guard (try? BackupService.decode(Data(contentsOf: url))) != nil else { throw BackupError.invalid("the safety copy could not be read back") }
    }
}
