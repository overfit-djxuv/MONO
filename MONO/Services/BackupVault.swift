import Foundation
import CryptoKit
import CommonCrypto
import SwiftData

/// MONO's own backups: a checksummed, optionally encrypted file around the same data the JSON backup holds.
///
/// Why it is built this way:
///  • Every file is written to a temporary name and moved into place, so a crash can't leave half a backup.
///  • After writing, the file is read back, its checksum checked, and its contents test-restored into a throwaway database.
///    A backup that can't be restored never gets reported as a success.
///  • Encryption is AES-GCM with a key derived from your passphrase. The passphrase is never written to any backup file.
///  • Backups kept inside the app are deleted if you delete the app. Export a copy to Files or iCloud Drive for real protection.
enum BackupVault {
    static let fileExtension = "monobackup"
    static let defaultIterations = 200_000

    // MARK: Envelope

    struct Summary: Codable, Equatable {
        var transactions = 0, accounts = 0, goals = 0, receipts = 0
    }

    struct Envelope: Codable, Equatable {
        var magic = "MONO-BACKUP"
        var envelopeVersion = 1
        var createdAt: Date
        var appVersion: String
        /// "manual", "auto" or "safety" (made automatically before a restore).
        var kind: String
        var encrypted: Bool
        var salt: Data?
        var iterations: Int?
        var payload: Data
        /// SHA-256 of `payload`, to detect damage before anything is decrypted or decoded.
        var sha256: String
        var summary: Summary
        /// Format of the data inside (BackupFile.version).
        var dataFormat: Int
    }

    enum VaultError: LocalizedError, Equatable {
        case notABackup, passphraseRequired, wrongPassphrase, corrupt(String), newerFormat(Int), writeFailed(String), restoreCheckFailed([String])
        var errorDescription: String? {
            switch self {
            case .notABackup: "This file isn’t a MONO backup."
            case .passphraseRequired: "This backup is encrypted. Enter its passphrase."
            case .wrongPassphrase: "That passphrase doesn’t open this backup."
            case .corrupt(let why): "This backup is damaged and can’t be used: \(why)"
            case .newerFormat(let v): "This backup was made by a newer version of MONO (format \(v)). Update the app first."
            case .writeFailed(let why): "The backup couldn’t be saved: \(why)"
            case .restoreCheckFailed(let m): "The backup didn’t pass its restore test, so it was not kept: \(m.joined(separator: "; "))"
            }
        }
    }

    // MARK: Crypto

    static func deriveKey(passphrase: String, salt: Data, iterations: Int) -> SymmetricKey {
        var key = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltPtr in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passphrase, passphrase.utf8.count,
                                 saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), &key, key.count)
        }
        precondition(status == kCCSuccess, "key derivation failed")
        return SymmetricKey(data: Data(key))
    }

    private static let aad = Data("MONO-BACKUP|1".utf8)

    static func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e
    }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    // MARK: Making a backup

    static func makeEnvelope(file: BackupFile, kind: String, passphrase: String?, now: Date = .now, iterations: Int = defaultIterations) throws -> Envelope {
        let plain = try BackupService.encode(file)
        var payload = plain, salt: Data?, iters: Int?
        if let passphrase, !passphrase.isEmpty {
            var s = Data(count: 16)
            guard s.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }) == errSecSuccess else {
                throw VaultError.writeFailed("couldn’t create a random salt")
            }
            let key = deriveKey(passphrase: passphrase, salt: s, iterations: iterations)
            guard let combined = try AES.GCM.seal(plain, using: key, authenticating: aad).combined else { throw VaultError.writeFailed("encryption failed") }
            payload = combined; salt = s; iters = iterations
        }
        return Envelope(createdAt: now, appVersion: VersionHistory.current, kind: kind, encrypted: salt != nil, salt: salt, iterations: iters, payload: payload,
                        sha256: sha256Hex(payload),
                        summary: .init(transactions: file.transactions.count, accounts: file.accounts?.count ?? 1, goals: file.goals.count, receipts: file.receipts?.count ?? 0),
                        dataFormat: file.version)
    }

    static func encode(_ e: Envelope) throws -> Data { try encoder.encode(e) }

    /// Reads a file's header and checks its checksum. Doesn't decrypt.
    static func readEnvelope(_ data: Data) throws -> Envelope {
        guard let e = try? decoder.decode(Envelope.self, from: data), e.magic == "MONO-BACKUP" else { throw VaultError.notABackup }
        guard sha256Hex(e.payload) == e.sha256 else { throw VaultError.corrupt("its contents don’t match its checksum (the file was changed or cut short)") }
        return e
    }

    /// Opens a backup (decrypting if needed), validates it, and returns the data. Also accepts the plain `.json` backups
    /// made by earlier versions of MONO.
    static func open(_ data: Data, passphrase: String?) throws -> (envelope: Envelope?, file: BackupFile) {
        guard let e = try? decoder.decode(Envelope.self, from: data), e.magic == "MONO-BACKUP" else {
            // Older plain JSON backup.
            do { return (nil, try BackupService.decode(data)) } catch let err as BackupError {
                if err == .unreadable { throw VaultError.notABackup }
                throw err
            }
        }
        _ = try readEnvelope(data)
        var plain = e.payload
        if e.encrypted {
            guard let passphrase, !passphrase.isEmpty else { throw VaultError.passphraseRequired }
            guard let salt = e.salt, let iters = e.iterations, iters > 0, iters <= 5_000_000 else { throw VaultError.corrupt("its encryption details are missing") }
            let key = deriveKey(passphrase: passphrase, salt: salt, iterations: iters)
            do { plain = try AES.GCM.open(AES.GCM.SealedBox(combined: e.payload), using: key, authenticating: aad) }
            catch { throw VaultError.wrongPassphrase }
        }
        do { return (e, try BackupService.decode(plain)) }
        catch BackupError.newerVersion(let v) { throw VaultError.newerFormat(v) }
        catch { throw VaultError.corrupt(error.localizedDescription) }
    }

    // MARK: The restore test

    struct RestoreCheck: Equatable { var mismatches: [String]; var ok: Bool { mismatches.isEmpty } }

    /// Restores `file` into a throwaway in-memory database and compares what comes out with what went in.
    /// Nothing real is touched: not your records, not your settings.
    @MainActor
    static func testRestore(_ file: BackupFile) -> RestoreCheck {
        do {
            let container = try Persistence.inMemoryContainer()
            let ctx = ModelContext(container)
            try BackupService.replaceAll(with: file, in: ctx, applyPreferences: false)
            let back = try BackupService.snapshot(context: ctx, openingBalanceCents: file.openingBalanceCents, currencySymbol: file.currencySymbol)
            var bad: [String] = []
            func same<T: Equatable>(_ name: String, _ a: [T], _ b: [T]) { if a != b { bad.append("\(name) differ") } }
            func ids<T>(_ xs: [T], _ key: (T) -> String) -> [String] { xs.map(key).sorted() }
            same("transactions", ids(file.transactions) { "\($0.id)|\($0.amountCents)|\($0.kind)|\($0.accountID.map(\.uuidString) ?? "")" }.map { $0.split(separator: "|").prefix(3).joined(separator: "|") },
                 ids(back.transactions) { "\($0.id)|\($0.amountCents)|\($0.kind)" })
            same("goals", ids(file.goals) { "\($0.id)|\($0.targetCents)" }, ids(back.goals) { "\($0.id)|\($0.targetCents)" })
            same("goal contributions", ids(file.goalEntries) { "\($0.id)|\($0.amountCents)" }, ids(back.goalEntries) { "\($0.id)|\($0.amountCents)" })
            same("categories", ids(file.categories) { $0.name + $0.kind }, ids(back.categories) { $0.name + $0.kind })
            same("budgets", ids(file.budgetLimits) { "\($0.monthKey)|\($0.category)|\($0.limitCents)" }, ids(back.budgetLimits) { "\($0.monthKey)|\($0.category)|\($0.limitCents)" })
            same("shopping items", ids(file.shoppingItems) { "\($0.id)" }, ids(back.shoppingItems) { "\($0.id)" })
            same("planned expenses", ids(file.plannedExpenses) { "\($0.id)" }, ids(back.plannedExpenses) { "\($0.id)" })
            same("subscriptions", ids(file.recurringRules ?? []) { "\($0.id)|\($0.amountCents)" }, ids(back.recurringRules ?? []) { "\($0.id)|\($0.amountCents)" })
            same("receipts", ids(file.receipts ?? []) { "\($0.id)|\($0.totalCents)" }, ids(back.receipts ?? []) { "\($0.id)|\($0.totalCents)" })
            if let accounts = file.accounts, !accounts.isEmpty {
                same("accounts", ids(accounts) { "\($0.id)|\($0.openingCents)|\($0.currencyCode)" },
                     ids(back.accounts ?? []) { "\($0.id)|\($0.openingCents)|\($0.currencyCode)" })
            }
            return RestoreCheck(mismatches: bad)
        } catch { return RestoreCheck(mismatches: ["the test restore failed: \(error.localizedDescription)"]) }
    }

    // MARK: Storage

    static var directory: URL { Persistence.storeDirectory.appending(path: "Backups", directoryHint: .isDirectory) }

    struct Entry: Identifiable, Equatable {
        var url: URL
        var name: String { url.lastPathComponent }
        var createdAt: Date
        var size: Int
        var kind: String
        var encrypted: Bool
        var summary: Summary
        var appVersion: String
        var intact: Bool
        var id: String { name }
    }

    private static func ensureDirectory(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    }

    private static func fileName(for e: Envelope) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        let prefix = e.kind == "safety" ? "MONO-before-restore" : "MONO-backup"
        return "\(prefix)-\(f.string(from: e.createdAt))\(e.encrypted ? "-locked" : "").\(fileExtension)"
    }

    /// Writes atomically, reads back, and checks. On any problem nothing is left behind.
    @discardableResult
    static func write(_ envelope: Envelope, to dir: URL = directory) throws -> URL {
        try ensureDirectory(dir)
        let data = try encode(envelope)
        let url = dir.appending(path: fileName(for: envelope))
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            let back = try Data(contentsOf: url)
            guard back == data else { throw VaultError.corrupt("what was written doesn’t match what was saved") }
            _ = try readEnvelope(back)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error is VaultError ? error : VaultError.writeFailed(error.localizedDescription)
        }
        return url
    }

    /// Creates a backup of the current data, proves it can be restored, and only then reports success.
    @MainActor
    @discardableResult
    static func create(context: ModelContext, kind: String, passphrase: String?, now: Date = .now, dir: URL = directory,
                       iterations: Int = defaultIterations, includeReceiptPhotos: Bool? = nil) throws -> Entry {
        var file = try BackupService.snapshot(context: context, openingBalanceCents: UserDefaults.standard.integer(forKey: "openingBalanceCents"),
                                              currencySymbol: Money.symbol)
        file.preferences = PreferenceBackup.capture()
        file.receipts = ReceiptStore.backupItems(context: context, includePhotos: includeReceiptPhotos ?? (UserDefaults.standard.object(forKey: AutoBackup.receiptsKey) as? Bool ?? true))
        let envelope = try makeEnvelope(file: file, kind: kind, passphrase: passphrase, now: now, iterations: iterations)
        // The test restore runs on the plain data, before anything is saved.
        let check = testRestore(file)
        guard check.ok else { throw VaultError.restoreCheckFailed(check.mismatches) }
        let url = try write(envelope, to: dir)
        // And once more from the file itself, exactly as a real restore would read it.
        do { _ = try open(Data(contentsOf: url), passphrase: passphrase) } catch { try? FileManager.default.removeItem(at: url); throw error }
        return entry(for: url) ?? Entry(url: url, createdAt: now, size: 0, kind: kind, encrypted: envelope.encrypted, summary: envelope.summary, appVersion: envelope.appVersion, intact: true)
    }

    static func entry(for url: URL) -> Entry? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let size = data.count
        if let e = try? readEnvelope(data) {
            return Entry(url: url, createdAt: e.createdAt, size: size, kind: e.kind, encrypted: e.encrypted, summary: e.summary, appVersion: e.appVersion, intact: true)
        }
        let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
        return Entry(url: url, createdAt: date, size: size, kind: "unknown", encrypted: false, summary: .init(), appVersion: "?", intact: false)
    }

    static func history(dir: URL = directory) -> [Entry] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == fileExtension }.compactMap(entry(for:)).sorted { $0.createdAt > $1.createdAt }
    }

    /// Keeps the newest `keep` automatic backups and the newest three safety copies. Manual backups are only ever deleted by you.
    @discardableResult
    static func prune(keepAutomatic keep: Int, dir: URL = directory) -> Int {
        let all = history(dir: dir)
        var removed = 0
        for (kind, limit) in [("auto", max(keep, 1)), ("safety", 3)] {
            for e in all.filter({ $0.kind == kind }).dropFirst(limit) { if (try? FileManager.default.removeItem(at: e.url)) != nil { removed += 1 } }
        }
        return removed
    }

    static func delete(_ e: Entry) { try? FileManager.default.removeItem(at: e.url) }
}

// MARK: - Automatic backups

enum AutoBackup {
    enum Frequency: String, CaseIterable, Identifiable {
        case off, daily, weekly, monthly
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    static let frequencyKey = "autoBackupFrequency", keepKey = "autoBackupKeep", encryptKey = "autoBackupEncrypt", lastKey = "lastAutoBackupAt"
    static let passphraseAccount = "backup-passphrase"
    static let receiptsKey = "autoBackupReceipts"

    static func isDue(_ f: Frequency, last: Date?, now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard f != .off else { return false }
        guard let last else { return true }
        switch f {
        case .off: return false
        case .daily: return !calendar.isDate(last, inSameDayAs: now)
        case .weekly: return (calendar.dateComponents([.day], from: calendar.startOfDay(for: last), to: calendar.startOfDay(for: now)).day ?? 0) >= 7
        case .monthly: return MonthKey(last, calendar: calendar) != MonthKey(now, calendar: calendar)
        }
    }

    /// Runs when the app opens. iOS doesn't let an app run on a schedule in the background, so "daily" means
    /// "the first time you open MONO each day". Returns a message only when something needs your attention.
    @MainActor
    @discardableResult
    static func runIfDue(context: ModelContext, defaults: UserDefaults = .standard, now: Date = .now, dir: URL = BackupVault.directory) -> String? {
        let f = Frequency(rawValue: defaults.string(forKey: frequencyKey) ?? "off") ?? .off
        let last = (defaults.object(forKey: lastKey) as? Double).map { Date(timeIntervalSince1970: $0) }
        guard isDue(f, last: last, now: now) else { return nil }
        let hasData = ((try? context.fetchCount(FetchDescriptor<TransactionRecord>())) ?? 0) > 0 || ((try? context.fetchCount(FetchDescriptor<SavingsGoal>())) ?? 0) > 0
        guard hasData else { return nil }
        var passphrase: String?
        if defaults.bool(forKey: encryptKey) {
            passphrase = Keychain.get(account: passphraseAccount)
            if passphrase == nil { return "Automatic backup skipped: the backup passphrase isn’t on this iPhone any more. Set it again in Backup & recovery." }
        }
        do {
            try BackupVault.create(context: context, kind: "auto", passphrase: passphrase, now: now, dir: dir)
            defaults.set(now.timeIntervalSince1970, forKey: lastKey)
            BackupVault.prune(keepAutomatic: defaults.object(forKey: keepKey) as? Int ?? 10, dir: dir)
            return nil
        } catch { return "Automatic backup failed: \(error.localizedDescription)" }
    }
}
