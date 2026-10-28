import XCTest
@testable import MONO

final class SavingsPlannerTests: XCTestCase {
    let today = date(2026, 10, 29)

    func input(target: Int = 600_000, saved: Int = 0, monthly: Int = 0, deadline: Date?, day: Int = 5) -> PlanInput {
        PlanInput(target: target, saved: saved, plannedMonthly: monthly, deadline: deadline, contributionDay: day)
    }

    // MARK: Schedule

    func testContributionDatesAreStrictlyAfterTodayAndWithinDeadline() {
        let d = SavingsPlanner.contributionDates(after: today, through: date(2026, 12, 31), day: 5, calendar: utc)
        XCTAssertEqual(d.map { utc.component(.month, from: $0) }, [11, 12])
        XCTAssertTrue(d.allSatisfy { $0 > today })
    }

    func testContributionOnTodayIsNotCounted() {
        let d = SavingsPlanner.contributionDates(after: date(2026, 11, 5), through: date(2026, 12, 31), day: 5, calendar: utc)
        XCTAssertEqual(d.count, 1, "only Dec 5; today's (Nov 5) is recorded manually")
    }

    func testContributionOnDeadlineDayIsIncluded() {
        let d = SavingsPlanner.contributionDates(after: today, through: date(2026, 12, 5), day: 5, calendar: utc)
        XCTAssertEqual(d.count, 2)
    }

    func testDeadlineBeforeNextContributionDateHasNone() {
        XCTAssertTrue(SavingsPlanner.contributionDates(after: today, through: date(2026, 11, 4), day: 5, calendar: utc).isEmpty)
    }

    func testPastOrSameDayDeadlineHasNoDates() {
        XCTAssertTrue(SavingsPlanner.contributionDates(after: today, through: today, day: 5, calendar: utc).isEmpty)
        XCTAssertTrue(SavingsPlanner.contributionDates(after: today, through: date(2026, 1, 1), day: 5, calendar: utc).isEmpty)
    }

    func testDayIsClampedToMonthLength() {
        let d = SavingsPlanner.contributionDates(after: date(2027, 1, 30), through: date(2027, 3, 31), day: 28, calendar: utc)
        XCTAssertEqual(d.map { utc.component(.day, from: $0) }, [28, 28])
    }

    func testScheduleSpansYearBoundary() {
        let d = SavingsPlanner.contributionDates(after: date(2026, 11, 20), through: date(2027, 2, 10), day: 1, calendar: utc)
        XCTAssertEqual(d.count, 3) // Dec 1, Jan 1, Feb 1
    }

    // MARK: Plan

    func testOnTrackWhenPlannedContributionsReachTarget() {
        // Nov 5 … Jun 5 = 8 dates; 8 × 60,000 + 120,000 = 600,000
        let p = SavingsPlanner.plan(input(saved: 120_000, monthly: 60_000, deadline: date(2027, 6, 30)), today: today, calendar: utc)
        XCTAssertEqual(p.contributionsRemaining, 8)
        XCTAssertEqual(p.expectedAtDeadline, 600_000)
        XCTAssertEqual(p.status, .onTrack)
        XCTAssertEqual(p.remaining, 480_000)
        XCTAssertEqual(p.requiredMonthly, 60_000)
        XCTAssertEqual(p.shortfall, 0)
        XCTAssertEqual(p.percentFunded, 0.2, accuracy: 1e-9)
    }

    func testBehindReportsShortfallAndRequiredMonthly() {
        let p = SavingsPlanner.plan(input(saved: 120_000, monthly: 40_000, deadline: date(2027, 6, 30)), today: today, calendar: utc)
        XCTAssertEqual(p.status, .behind)
        XCTAssertEqual(p.expectedAtDeadline, 120_000 + 8 * 40_000)
        XCTAssertEqual(p.shortfall, 600_000 - 440_000)
        XCTAssertEqual(p.requiredMonthly, 60_000)
    }

    func testRequiredMonthlyRoundsUp() {
        let p = SavingsPlanner.plan(input(target: 100_000, saved: 0, deadline: date(2027, 1, 31)), today: today, calendar: utc)
        // Nov 5, Dec 5, Jan 5 → 3 dates; 100,000 / 3 = 33,333.33 → 33,334
        XCTAssertEqual(p.contributionsRemaining, 3)
        XCTAssertEqual(p.requiredMonthly, 33_334)
        XCTAssertGreaterThanOrEqual(3 * p.requiredMonthly!, 100_000)
    }

    func testFullyFundedIgnoresDeadline() {
        let p = SavingsPlanner.plan(input(target: 100_000, saved: 130_000, monthly: 10_000, deadline: date(2026, 1, 1)), today: today, calendar: utc)
        XCTAssertEqual(p.status, .funded, "funded wins even if the date has passed")
        XCTAssertEqual(p.remaining, 0)
        XCTAssertEqual(p.percentFunded, 1.0)
        XCTAssertNil(p.requiredMonthly)
    }

    func testOverdueWhenDeadlinePassedAndNotFunded() {
        let p = SavingsPlanner.plan(input(saved: 100_000, monthly: 50_000, deadline: date(2026, 10, 1)), today: today, calendar: utc)
        XCTAssertEqual(p.status, .overdue)
        XCTAssertEqual(p.contributionsRemaining, 0)
        XCTAssertEqual(p.daysToDeadline, -28)
        XCTAssertEqual(p.remaining, 500_000)
        XCTAssertNil(p.requiredMonthly)
    }

    func testDeadlineTodayIsNotOverdueButNeedsLumpSum() {
        let p = SavingsPlanner.plan(input(saved: 100_000, monthly: 50_000, deadline: today), today: today, calendar: utc)
        XCTAssertEqual(p.status, .behind)
        XCTAssertEqual(p.daysToDeadline, 0)
        XCTAssertTrue(p.needsLumpSum)
    }

    func testNoScheduledDatesLeftNeedsLumpSum() {
        let p = SavingsPlanner.plan(input(saved: 0, monthly: 50_000, deadline: date(2026, 11, 3)), today: today, calendar: utc)
        XCTAssertEqual(p.contributionsRemaining, 0)
        XCTAssertNil(p.requiredMonthly)
        XCTAssertTrue(p.needsLumpSum)
        XCTAssertEqual(p.status, .behind)
    }

    func testOpenGoalHasNoDeadlineMath() {
        let p = SavingsPlanner.plan(input(target: 100_000, saved: 25_000, monthly: 10_000, deadline: nil), today: today, calendar: utc)
        XCTAssertEqual(p.status, .open)
        XCTAssertNil(p.daysToDeadline)
        XCTAssertEqual(p.contributionsRemaining, 0)
        XCTAssertEqual(p.monthsAtPlannedPace, 8)
        XCTAssertEqual(p.shortfall, 0)
        XCTAssertFalse(p.needsLumpSum)
    }

    func testZeroTargetIsSafe() {
        let p = SavingsPlanner.plan(input(target: 0, saved: 0, deadline: date(2027, 1, 1)), today: today, calendar: utc)
        XCTAssertEqual(p.percentFunded, 0)
        XCTAssertEqual(p.remaining, 0)
        XCTAssertNotEqual(p.status, .funded, "an empty plan isn’t ‘funded’")
    }

    func testOverfundedCapsPercentButKeepsSurplus() {
        let p = SavingsPlanner.plan(input(target: 100_000, saved: 90_000, monthly: 20_000, deadline: date(2027, 1, 31)), today: today, calendar: utc)
        XCTAssertEqual(p.status, .onTrack)
        XCTAssertEqual(p.surplus, 90_000 + 3 * 20_000 - 100_000)
        XCTAssertLessThanOrEqual(p.percentFunded, 1)
    }

    // MARK: Goal wiring

    func testTripTargetIsCostsPlusBufferForThisTripOnly() {
        let trip = SavingsGoal(name: "Tokyo", kind: .trip, symbol: "airplane")
        trip.bufferCents = 50_000
        let other = SavingsGoal(name: "Bali", kind: .trip, symbol: "airplane")
        let costs = [TripCost(goalID: trip.id, category: .flights, label: "", amountCents: 220_000),
                     TripCost(goalID: trip.id, category: .food, label: "", amountCents: 80_000),
                     TripCost(goalID: other.id, category: .flights, label: "", amountCents: 999_999)]
        XCTAssertEqual(SavingsPlanner.tripTarget(costs: costs, goal: trip), 350_000)
        XCTAssertEqual(SavingsPlanner.target(for: trip, costs: costs), 350_000)

        let general = SavingsGoal(name: "Laptop", kind: .general, symbol: "laptopcomputer")
        general.targetCents = 600_000
        XCTAssertEqual(SavingsPlanner.target(for: general, costs: costs), 600_000)
    }

    func testPlanForGoalUsesItsOwnEntriesOnly() {
        let trip = SavingsGoal(name: "Tokyo", kind: .trip, symbol: "airplane")
        trip.deadline = date(2027, 6, 30); trip.plannedMonthlyCents = 10_000
        let costs = [TripCost(goalID: trip.id, category: .flights, label: "", amountCents: 100_000)]
        let entries = [GoalEntry(goalID: trip.id, amountCents: 30_000, date: today), GoalEntry(goalID: UUID(), amountCents: 77_000, date: today)]
        let p = SavingsPlanner.plan(for: trip, costs: costs, entries: entries, today: today, calendar: utc)
        XCTAssertEqual(p.saved, 30_000)
        XCTAssertEqual(p.target, 100_000)
    }

    func testAlternativeScenarioCanBeComparedWithoutMutation() {
        let base = input(saved: 100_000, monthly: 30_000, deadline: date(2027, 3, 31))
        var alt = base
        alt.plannedMonthly = 70_000
        alt.deadline = date(2027, 6, 30)   // 8 dates × 70,000 + 100,000 = 660,000 ≥ 600,000
        let a = SavingsPlanner.plan(base, today: today, calendar: utc)
        let b = SavingsPlanner.plan(alt, today: today, calendar: utc)
        XCTAssertGreaterThan(b.expectedAtDeadline, a.expectedAtDeadline)
        XCTAssertEqual(b.status, .onTrack)
        XCTAssertEqual(a.status, .behind)
    }
}
