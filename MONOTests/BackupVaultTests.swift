import XCTest
import SwiftData
@testable import MONO

@MainActor
final class BackupVaultTests: XCTestCase {
    var dir: URL!
    var ctx: ModelContext!
    private let fast = 1_000   // key-derivation rounds: tests don't need the real strength

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "vault-\(UUID().uuidString)", directoryHint: .isDirectory)
        (_, ctx) = try makeContext()
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: AccountMigration.safetyDirectory) }

    @discardableResult
    private func populate(_ context: ModelContext? = nil) throws -> BackupFile {
        let c = context ?? ctx!
        let main = Account(name: "Main", kind: .bank, currencyCode: "MYR", openingCents: 100_000, sortOrder: 0); c.insert(main)
        c.insert(TransactionRecord(amountCents: 4_550, kind: .expense, category: "Food", date: date(2026, 3, 2), title: "Lunch", accountID: main.id, merchant: "Café Zed", tags: "work"))
        c.insert(TransactionRecord(amountCents: 500_000, kind: .income, category: "Salary", date: date(2026, 3, 1), title: "Pay", accountID: main.id))
        let g = SavingsGoal(name: "Trip", kind: .general, symbol: "target"); g.targetCents = 90_000; c.insert(g)
        let e = GoalEntry(goalID: g.id, amountCents: 20_000, date: date(2026, 3, 3)); e.accountID = main.id; c.insert(e)
        c.insert(MoneyCategory(name: "Food", symbol: "fork.knife", kind: .expense, sortOrder: 0))
        try c.save()
        return try BackupService.snapshot(context: c, openingBalanceCents: 0, currencySymbol: "RM")
    }

    // MARK: envelope

    func testAPlainBackupRoundTrips() throws {
        let file = try populate()
        let env = try BackupVault.makeEnvelope(file: file, kind: "manual", passphrase: nil, iterations: fast)
        XCTAssertFalse(env.encrypted)
        let opened = try BackupVault.open(try BackupVault.encode(env), passphrase: nil)
        XCTAssertEqual(opened.file.transactions.map(\.id).sorted { $0.uuidString < $1.uuidString }, file.transactions.map(\.id).sorted { $0.uuidString < $1.uuidString })
        XCTAssertEqual(opened.envelope?.summary.transactions, 2); XCTAssertEqual(opened.envelope?.dataFormat, BackupFile.currentVersion)
    }
    func testAnEncryptedBackupNeedsItsPassphraseAndHidesItsContents() throws {
        let file = try populate()
        let env = try BackupVault.makeEnvelope(file: file, kind: "manual", passphrase: "correct horse", iterations: fast)
        let data = try BackupVault.encode(env)
        XCTAssertTrue(env.encrypted)
        XCTAssertNil(data.range(of: Data("Café Zed".utf8)), "no readable merchant in the file"); XCTAssertNil(data.range(of: Data("Lunch".utf8)))
        XCTAssertNil(data.range(of: Data("correct horse".utf8)), "the passphrase is never written to the file")
        XCTAssertNoThrow(try BackupVault.open(data, passphrase: "correct horse"))
        XCTAssertThrowsError(try BackupVault.open(data, passphrase: "wrong")) { XCTAssertEqual($0 as? BackupVault.VaultError, .wrongPassphrase) }
        XCTAssertThrowsError(try BackupVault.open(data, passphrase: nil)) { XCTAssertEqual($0 as? BackupVault.VaultError, .passphraseRequired) }
        XCTAssertThrowsError(try BackupVault.open(data, passphrase: "")) { XCTAssertEqual($0 as? BackupVault.VaultError, .passphraseRequired) }
    }
    func testTwoBackupsOfTheSameDataDifferBecauseEachHasItsOwnSaltAndNonce() throws {
        let file = try populate()
        let a = try BackupVault.makeEnvelope(file: file, kind: "manual", passphrase: "pw", iterations: fast)
        let b = try BackupVault.makeEnvelope(file: file, kind: "manual", passphrase: "pw", iterations: fast)
        XCTAssertNotEqual(a.salt, b.salt); XCTAssertNotEqual(a.payload, b.payload)
    }
    func testDamageIsDetectedBeforeAnythingIsRestored() throws {
        let env = try BackupVault.makeEnvelope(file: try populate(), kind: "manual", passphrase: nil, iterations: fast)
        var bad = env; bad.payload[bad.payload.count / 2] ^= 0xFF           // one flipped byte, checksum left as it was
        XCTAssertThrowsError(try BackupVault.open(try BackupVault.encode(bad), passphrase: nil)) {
            guard case .corrupt = $0 as? BackupVault.VaultError else { return XCTFail("expected corrupt, got \($0)") } }
        let whole = try BackupVault.encode(env)
        XCTAssertThrowsError(try BackupVault.open(whole.prefix(whole.count / 2), passphrase: nil), "a file cut short") { XCTAssertEqual($0 as? BackupVault.VaultError, .notABackup) }
    }
    func testATamperedEncryptedPayloadWithAMatchingChecksumStillFailsAuthentication() throws {
        var env = try BackupVault.makeEnvelope(file: try populate(), kind: "manual", passphrase: "pw", iterations: fast)
        env.payload[env.payload.count - 3] ^= 0x01
        env.sha256 = BackupVault.sha256Hex(env.payload)    // an attacker who fixes the checksum
        XCTAssertThrowsError(try BackupVault.open(try BackupVault.encode(env), passphrase: "pw")) { XCTAssertEqual($0 as? BackupVault.VaultError, .wrongPassphrase) }
    }
    func testStrangersAreRejectedAndOldPlainBackupsStillOpen() throws {
        XCTAssertThrowsError(try BackupVault.open(Data("{\"hello\": 1}".utf8), passphrase: nil)) { XCTAssertEqual($0 as? BackupVault.VaultError, .notABackup) }
        XCTAssertThrowsError(try BackupVault.open(Data("not even json".utf8), passphrase: nil))
        let legacy = try BackupService.encode(try populate())          // what “Create JSON backup” used to save
        let opened = try BackupVault.open(legacy, passphrase: nil)
        XCTAssertNil(opened.envelope); XCTAssertEqual(opened.file.transactions.count, 2)
    }
    func testABackupFromANewerAppIsRefusedPolitely() throws {
        var f = try populate(); f.version = 99
        let data = try JSONEncoder().encode(f)   // bypass the encoder's own validation
        XCTAssertThrowsError(try BackupVault.open(data, passphrase: nil))
        var env = try BackupVault.makeEnvelope(file: try populate(), kind: "manual", passphrase: nil, iterations: fast)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .custom { d, e in var c = e.singleValueContainer(); try c.encode(ISO8601DateFormatter().string(from: d)) }
        env.payload = try enc.encode(f); env.sha256 = BackupVault.sha256Hex(env.payload)
        XCTAssertThrowsError(try BackupVault.open(try BackupVault.encode(env), passphrase: nil)) { XCTAssertEqual($0 as? BackupVault.VaultError, .newerFormat(99)) }
    }
    func testKeyDerivationIsDeterministicAndSensitiveToEveryInput() {
        let salt = Data(repeating: 7, count: 16)
        func k(_ pw: String, _ s: Data, _ n: Int) -> Data { BackupVault.deriveKey(passphrase: pw, salt: s, iterations: n).withUnsafeBytes { Data($0) } }
        XCTAssertEqual(k("a", salt, 100), k("a", salt, 100)); XCTAssertNotEqual(k("a", salt, 100), k("b", salt, 100))
        XCTAssertNotEqual(k("a", salt, 100), k("a", Data(repeating: 8, count: 16), 100)); XCTAssertNotEqual(k("a", salt, 100), k("a", salt, 101))
    }

    // MARK: files

    func testCreatingABackupSavesAVerifiedFileAndListsIt() throws {
        try populate()
        let e = try BackupVault.create(context: ctx, kind: "manual", passphrase: nil, dir: dir, iterations: fast, includeReceiptPhotos: false)
        XCTAssertEqual(e.kind, "manual"); XCTAssertTrue(e.intact); XCTAssertGreaterThan(e.size, 100); XCTAssertEqual(e.summary.transactions, 2)
        XCTAssertEqual(BackupVault.history(dir: dir).map(\.name), [e.name]); XCTAssertEqual(e.url.pathExtension, "monobackup")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).count, 1, "no temporary files left behind")
    }
    func testAFailedWriteLeavesNothingBehind() throws {
        let file = try populate()
        let env = try BackupVault.makeEnvelope(file: file, kind: "manual", passphrase: nil, iterations: fast)
        let notADirectory = FileManager.default.temporaryDirectory.appending(path: "plainfile-\(UUID().uuidString)")
        try Data("x".utf8).write(to: notADirectory)
        defer { try? FileManager.default.removeItem(at: notADirectory) }
        XCTAssertThrowsError(try BackupVault.write(env, to: notADirectory))
        XCTAssertEqual(try Data(contentsOf: notADirectory), Data("x".utf8), "the thing in the way was not touched")
    }
    func testAFileThatIsDamagedOnDiskIsReportedAsNotIntact() throws {
        try populate()
        let e = try BackupVault.create(context: ctx, kind: "manual", passphrase: nil, dir: dir, iterations: fast, includeReceiptPhotos: false)
        var bytes = try Data(contentsOf: e.url); bytes[bytes.count / 2] ^= 0xFF; try bytes.write(to: e.url)
        XCTAssertFalse(try XCTUnwrap(BackupVault.history(dir: dir).first).intact)
    }
    func testRetentionKeepsTheNewestAutomaticBackupsAndNeverTouchesManualOnes() throws {
        try populate()
        func make(_ kind: String, _ minutes: Int) throws { try BackupVault.create(context: ctx, kind: kind, passphrase: nil, now: Date(timeIntervalSince1970: 1_800_000_000 + Double(minutes) * 60), dir: dir, iterations: fast, includeReceiptPhotos: false) }
        for m in 1...5 { try make("auto", m) }
        try make("manual", 10); try make("manual", 11)
        for m in 20...24 { try make("safety", m) }
        BackupVault.prune(keepAutomatic: 2, dir: dir)
        let h = BackupVault.history(dir: dir)
        XCTAssertEqual(h.filter { $0.kind == "auto" }.count, 2); XCTAssertEqual(h.filter { $0.kind == "manual" }.count, 2)
        XCTAssertEqual(h.filter { $0.kind == "safety" }.count, 3, "the last three safety copies are kept")
        XCTAssertEqual(h.filter { $0.kind == "auto" }.map(\.createdAt), [Date(timeIntervalSince1970: 1_800_000_300), Date(timeIntervalSince1970: 1_800_000_240)], "the newest were kept")
    }

    // MARK: restore test and real restore

    func testTheTestRestorePassesForGoodDataAndNeverTouchesYourSettings() throws {
        let file = try populate()
        UserDefaults.standard.set(777, forKey: "openingBalanceCents"); UserDefaults.standard.set("USD", forKey: Money.reportingKey)
        defer { UserDefaults.standard.removeObject(forKey: "openingBalanceCents"); UserDefaults.standard.removeObject(forKey: Money.reportingKey) }
        var other = file; other.openingBalanceCents = 111; other.currencySymbol = "XX"; other.reportingCurrency = "EUR"
        XCTAssertTrue(BackupVault.testRestore(other).ok, "\(BackupVault.testRestore(other).mismatches)")
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "openingBalanceCents"), 777)
        XCTAssertEqual(UserDefaults.standard.string(forKey: Money.reportingKey), "USD")
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<TransactionRecord>()), 2, "and not your database either")
    }
    func testBackUpWipeRestoreBringsEverythingBack() throws {
        let original = try populate()
        // Settings that should travel with the backup
        let theme = ThemeStore(defaults: UserDefaults(suiteName: "vault-theme-\(UUID().uuidString)")!)
        _ = theme
        UserDefaults.standard.set(14, forKey: "reminderHour"); UserDefaults.standard.set(true, forKey: "appLockEnabled")
        defer { UserDefaults.standard.removeObject(forKey: "reminderHour"); UserDefaults.standard.removeObject(forKey: "appLockEnabled") }
        let e = try BackupVault.create(context: ctx, kind: "manual", passphrase: "pw", dir: dir, iterations: fast, includeReceiptPhotos: false)
        UserDefaults.standard.set(9, forKey: "reminderHour")
        // wipe
        try Ledger.eraseEverything(in: ctx)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<TransactionRecord>()), 0)
        // restore
        let restored = try BackupVault.open(try Data(contentsOf: e.url), passphrase: "pw").file
        try BackupService.replaceAll(with: restored, in: ctx)
        let back = try BackupService.snapshot(context: ctx, openingBalanceCents: 0, currencySymbol: "RM")
        XCTAssertEqual(Set(back.transactions.map(\.id)), Set(original.transactions.map(\.id)))
        XCTAssertEqual(back.transactions.first { $0.title == "Lunch" }?.merchant, "Café Zed")
        XCTAssertEqual(back.goals.map(\.name), ["Trip"]); XCTAssertEqual(back.goalEntries.first?.amountCents, 20_000)
        XCTAssertEqual(back.accounts?.first?.openingCents, 100_000)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "reminderHour"), 14, "settings came back")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "appLockEnabled"), "…and security settings were left exactly as they were")
    }

    // MARK: preferences

    func testOnlyAllowListedSettingsTravelAndSecurityOnesNever() {
        let d = UserDefaults(suiteName: "vault-pref-\(UUID().uuidString)")!
        d.set(true, forKey: "remindersEnabled"); d.set(true, forKey: "appLockEnabled"); d.set(true, forKey: "hideAmounts")
        d.set(15, forKey: "reminderHour"); d.set("hello", forKey: "randomKey"); d.set(Data([1, 2, 3]), forKey: "themeState.v1")
        d.set(1_700_000_000.0, forKey: "lastBackupAt"); d.set("MYR", forKey: "reportingCurrency")
        let captured = PreferenceBackup.capture(d)
        XCTAssertEqual(Set(captured.keys), ["remindersEnabled", "reminderHour", "themeState.v1", "reportingCurrency"])
        for forbidden in ["appLockEnabled", "hideAmounts", "lastBackupAt", "randomKey", "lastAutoBackupAt"] { XCTAssertNil(captured[forbidden], forbidden) }
    }
    func testRestoreIgnoresUnknownAndWrongTypedSettings() {
        let d = UserDefaults(suiteName: "vault-pref-\(UUID().uuidString)")!
        PreferenceBackup.restore(["reminderHour": .string("nine"), "appLockEnabled": .bool(true), "remindersEnabled": .bool(true), "mystery": .int(1)], defaults: d, refresh: false)
        XCTAssertNil(d.object(forKey: "reminderHour"), "wrong type"); XCTAssertNil(d.object(forKey: "appLockEnabled"), "not allowed")
        XCTAssertNil(d.object(forKey: "mystery")); XCTAssertTrue(d.bool(forKey: "remindersEnabled"))
    }
    func testSettingValuesKeepTheirTypeThroughJSON() throws {
        let all: [String: PrefValue] = ["a": .bool(true), "b": .int(-5), "c": .double(2.5), "d": .string("é"), "e": .data(Data([0, 255]))]
        XCTAssertEqual(try JSONDecoder().decode([String: PrefValue].self, from: JSONEncoder().encode(all)), all)
    }

    // MARK: automatic backups

    func testWhenAutomaticBackupsAreDue() {
        let now = date(2026, 3, 10, hour: 12)
        func due(_ f: AutoBackup.Frequency, _ last: Date?) -> Bool { AutoBackup.isDue(f, last: last, now: now, calendar: utc) }
        XCTAssertFalse(due(.off, nil)); XCTAssertTrue(due(.daily, nil))
        XCTAssertFalse(due(.daily, date(2026, 3, 10, hour: 1))); XCTAssertTrue(due(.daily, date(2026, 3, 9, hour: 23)))
        XCTAssertFalse(due(.weekly, date(2026, 3, 4))); XCTAssertTrue(due(.weekly, date(2026, 3, 3)))
        XCTAssertFalse(due(.monthly, date(2026, 3, 1))); XCTAssertTrue(due(.monthly, date(2026, 2, 28)))
    }
    func testRunningWhenDueCreatesPrunesAndRecordsTheTime() throws {
        try populate()
        let d = UserDefaults(suiteName: "vault-auto-\(UUID().uuidString)")!
        d.set("daily", forKey: AutoBackup.frequencyKey); d.set(2, forKey: AutoBackup.keepKey)
        for day in 1...4 { XCTAssertNil(AutoBackup.runIfDue(context: ctx, defaults: d, now: date(2026, 3, day), dir: dir)) }
        XCTAssertEqual(BackupVault.history(dir: dir).filter { $0.kind == "auto" }.count, 2)
        XCTAssertNil(AutoBackup.runIfDue(context: ctx, defaults: d, now: date(2026, 3, 4, hour: 20), dir: dir), "already done today")
        XCTAssertEqual(BackupVault.history(dir: dir).count, 2)
        XCTAssertNotNil(d.object(forKey: AutoBackup.lastKey))
    }
    func testAnEmptyAppIsNotBackedUpAndAMissingPassphraseIsReportedNotIgnored() throws {
        let d = UserDefaults(suiteName: "vault-auto-\(UUID().uuidString)")!
        d.set("daily", forKey: AutoBackup.frequencyKey)
        XCTAssertNil(AutoBackup.runIfDue(context: ctx, defaults: d, now: date(2026, 3, 1), dir: dir)); XCTAssertTrue(BackupVault.history(dir: dir).isEmpty)
        try populate(); d.set(true, forKey: AutoBackup.encryptKey)
        Keychain.delete(account: AutoBackup.passphraseAccount)
        XCTAssertNotNil(AutoBackup.runIfDue(context: ctx, defaults: d, now: date(2026, 3, 2), dir: dir), "tells you instead of silently skipping")
        XCTAssertTrue(BackupVault.history(dir: dir).isEmpty)
    }
    func testEncryptedAutomaticBackupsUseThePassphraseFromTheKeychain() throws {
        try populate()
        XCTAssertTrue(Keychain.set("vault-test-pass", account: AutoBackup.passphraseAccount)); defer { Keychain.delete(account: AutoBackup.passphraseAccount) }
        let d = UserDefaults(suiteName: "vault-auto-\(UUID().uuidString)")!
        d.set("daily", forKey: AutoBackup.frequencyKey); d.set(true, forKey: AutoBackup.encryptKey)
        XCTAssertNil(AutoBackup.runIfDue(context: ctx, defaults: d, now: date(2026, 3, 2), dir: dir))
        let e = try XCTUnwrap(BackupVault.history(dir: dir).first)
        XCTAssertTrue(e.encrypted); XCTAssertNoThrow(try BackupVault.open(Data(contentsOf: e.url), passphrase: "vault-test-pass"))
    }
    func testKeychainRoundTrip() {
        XCTAssertTrue(Keychain.set("s3cret", account: "test-account")); XCTAssertEqual(Keychain.get(account: "test-account"), "s3cret")
        XCTAssertTrue(Keychain.set("changed", account: "test-account")); XCTAssertEqual(Keychain.get(account: "test-account"), "changed")
        XCTAssertTrue(Keychain.delete(account: "test-account")); XCTAssertNil(Keychain.get(account: "test-account"))
    }
}
