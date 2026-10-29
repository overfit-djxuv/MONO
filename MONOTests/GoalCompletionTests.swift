import XCTest
import SwiftData
@testable import MONO

@MainActor
final class GoalCompletionTests: XCTestCase {
    private func goal() -> SavingsGoal {
        let g = SavingsGoal(name: "Laptop", kind: .general, symbol: "laptopcomputer")
        g.targetCents = 600_000; g.plannedMonthlyCents = 100_000; g.contributionDay = 1
        g.deadline = Calendar.current.date(byAdding: .month, value: 6, to: .now)
        return g
    }
    private func flexible(_ g: SavingsGoal) -> Int {
        let a = Account(name: "Main", kind: .cash, currencyCode: "MYR", openingCents: 1_000_000, sortOrder: 0)
        let books = Books(accounts: [a], rates: [], transactions: [], entries: [])
        var cfg = SafeToSpend.Config(); cfg.horizon = .days(60)
        return SafeToSpend.make(config: cfg, books: books, planned: [], rules: [], goals: [g], costs: [], entries: [], categories: [],
                                limits: [], monthBudgets: [], reserved: []).flexible
    }

    func testAnOngoingGoalReservesMoneyButACompletedOrArchivedOneDoesNot() {
        let g = goal()
        let reserved = flexible(g)
        g.completedAt = .now
        XCTAssertGreaterThan(flexible(g), reserved, "a completed goal stops holding back planned savings")
        g.completedAt = nil; g.isArchived = true
        XCTAssertEqual(flexible(g), flexible({ let x = goal(); x.completedAt = .now; return x }()))
        XCTAssertFalse(g.isOngoing)
    }

    func testCompletionAndArchiveSurviveBackupAndRestore() throws {
        let container = try Persistence.inMemoryContainer(); let ctx = ModelContext(container)
        let done = goal(); done.completedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let hidden = SavingsGoal(name: "Old", kind: .general, symbol: "target"); hidden.isArchived = true
        ctx.insert(done); ctx.insert(hidden); ctx.insert(goal()); try ctx.save()
        let file = try BackupService.snapshot(context: ctx, openingBalanceCents: 0, currencySymbol: "RM")
        XCTAssertTrue(BackupVault.testRestore(file).ok)
        try BackupService.replaceAll(with: file, in: ctx, applyPreferences: false)
        let back = try ctx.fetch(FetchDescriptor<SavingsGoal>()).sorted { $0.name < $1.name }
        XCTAssertEqual(back.map(\.name), ["Laptop", "Laptop", "Old"])
        XCTAssertEqual(back.filter { !$0.isOngoing }.count, 2)
        XCTAssertEqual(back.first { $0.isArchived }?.name, "Old")
        XCTAssertEqual(back.first { $0.completedAt != nil }?.completedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testOlderBackupsWithoutTheNewFieldsStillRestoreAsOngoing() throws {
        let container = try Persistence.inMemoryContainer(); let ctx = ModelContext(container)
        ctx.insert(goal()); try ctx.save()
        var file = try BackupService.snapshot(context: ctx, openingBalanceCents: 0, currencySymbol: "RM")
        file.goals = file.goals.map { var g = $0; g.completedAt = nil; g.isArchived = nil; return g }
        try BackupService.replaceAll(with: file, in: ctx, applyPreferences: false)
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<SavingsGoal>()).allSatisfy(\.isOngoing))
    }
}

@MainActor
final class ToastCenterTests: XCTestCase {
    func testAToastShowsThenClearsAndANewerOneIsNotClearedByTheOlderTimer() async throws {
        let t = ToastCenter()
        t.show("First", seconds: 0.15)
        XCTAssertEqual(t.message, "First")
        t.show("Second", seconds: 0.6)
        try await Task.sleep(for: .seconds(0.3))
        XCTAssertEqual(t.message, "Second", "the first timer must not remove the second message")
        try await Task.sleep(for: .seconds(0.5))
        XCTAssertNil(t.message)
    }
}
