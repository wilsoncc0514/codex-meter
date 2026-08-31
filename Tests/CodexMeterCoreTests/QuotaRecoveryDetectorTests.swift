import Foundation
import Testing
@testable import CodexMeterCore

struct QuotaRecoveryDetectorTests {
    private let detector = QuotaRecoveryDetector()
    private let now = Date(timeIntervalSince1970: 1_785_300_000)

    @Test func detectsScheduledWindowReset() throws {
        let previous = observation(remaining: 17, resetOffset: -30, observedOffset: -60)
        let current = observation(remaining: 100, resetOffset: 7 * 86_400, observedOffset: 0)

        let event = try #require(detector.detect(previous: previous, current: current, now: now))
        #expect(event.kind == .scheduledReset)
    }

    @Test func detectsEarlyWindowReplacement() throws {
        let previous = observation(remaining: 32, resetOffset: 4 * 86_400, observedOffset: -60)
        let current = observation(remaining: 100, resetOffset: 7 * 86_400, observedOffset: 0)

        let event = try #require(detector.detect(previous: previous, current: current, now: now))
        #expect(event.kind == .earlyReset)
    }

    @Test func detectsLargeRecoveryWithoutResetDateChange() throws {
        let previous = observation(remaining: 18, resetOffset: 4 * 86_400, observedOffset: -60)
        let current = observation(remaining: 74, resetOffset: 4 * 86_400, observedOffset: 0)

        let event = try #require(detector.detect(previous: previous, current: current, now: now))
        #expect(event.kind == .significantRecovery)
    }

    @Test func detectsSmallDropToZeroUsage() throws {
        let previous = observation(remaining: 96, resetOffset: 4 * 86_400, observedOffset: -60)
        let current = observation(remaining: 100, resetOffset: 4 * 86_400, observedOffset: 0)

        let event = try #require(detector.detect(previous: previous, current: current, now: now))
        #expect(event.kind == .significantRecovery)
    }

    @Test func ignoresSmallCorrectionsAndUsageGrowth() {
        let previous = observation(remaining: 52, resetOffset: 4 * 86_400, observedOffset: -60)
        let smallCorrection = observation(remaining: 55, resetOffset: 4 * 86_400, observedOffset: 0)
        let normalUsage = observation(remaining: 49, resetOffset: 4 * 86_400, observedOffset: 60)

        #expect(detector.detect(previous: previous, current: smallCorrection, now: now) == nil)
        #expect(detector.detect(previous: smallCorrection, current: normalUsage, now: now) == nil)
    }

    @Test func earlyResetRequiresAnActualQuotaGain() {
        let previous = observation(remaining: 80, resetOffset: 4 * 86_400, observedOffset: -60)
        let shiftedOnly = observation(remaining: 80, resetOffset: 7 * 86_400, observedOffset: 0)

        #expect(detector.detect(previous: previous, current: shiftedOnly, now: now) == nil)
    }

    @Test func confirmationAllowsNormalUsageButRejectsRollback() throws {
        let previous = observation(remaining: 20, resetOffset: 4 * 86_400, observedOffset: -60)
        let recovered = observation(remaining: 90, resetOffset: 4 * 86_400, observedOffset: 0)
        let event = try #require(detector.detect(previous: previous, current: recovered, now: now))

        let confirmed = observation(remaining: 87, resetOffset: 4 * 86_400, observedOffset: 8)
        let rolledBack = observation(remaining: 30, resetOffset: 4 * 86_400, observedOffset: 8)
        #expect(detector.confirms(event, with: confirmed))
        #expect(!detector.confirms(event, with: rolledBack))
    }

    @Test func rejectsOutOfOrderObservations() {
        let previous = observation(remaining: 20, resetOffset: 4 * 86_400, observedOffset: 0)
        let stale = observation(remaining: 100, resetOffset: 7 * 86_400, observedOffset: -60)

        #expect(detector.detect(previous: previous, current: stale, now: now) == nil)
    }

    private func observation(
        remaining: Int,
        resetOffset: TimeInterval,
        observedOffset: TimeInterval
    ) -> QuotaObservation {
        QuotaObservation(
            windowMinutes: 10_080,
            remainingPercent: remaining,
            resetsAt: now.addingTimeInterval(resetOffset),
            observedAt: now.addingTimeInterval(observedOffset)
        )
    }
}
