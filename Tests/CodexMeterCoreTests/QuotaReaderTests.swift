import Foundation
import Testing
@testable import CodexMeterCore

struct QuotaReaderTests {
    private let now = Date(timeIntervalSince1970: 1_784_700_000)

    @Test func parsesDualWindowFixture() throws {
        let reading = QuotaLogParser().parse(lines: try fixtureLines("dual-window"), now: now)
        #expect(reading.diagnostic == .ready)
        #expect(reading.window(minutes: 300)?.usedPercent == 38)
        #expect(reading.window(minutes: 10_080)?.usedPercent == 12)
    }

    @Test func parsesWeeklyOnlyFixture() throws {
        let reading = QuotaLogParser().parse(lines: try fixtureLines("weekly-only"), now: now)
        #expect(reading.diagnostic == .ready)
        #expect(reading.windows.count == 1)
        #expect(reading.window(minutes: 10_080)?.usedPercent == 17)
    }

    @Test func ignoresTransientZeroWithinSameResetWindow() throws {
        let reading = QuotaLogParser().parse(lines: try fixtureLines("transient-zero"), now: now)
        #expect(reading.window(minutes: 300)?.usedPercent == 21)
        #expect(reading.window(minutes: 10_080)?.usedPercent == 12)
    }

    @Test func reportsUnsupportedAggregateFormat() {
        let line = #"{"timestamp":"2026-07-22T01:00:00Z","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":1}}}}"#
        let reading = QuotaLogParser().parse(lines: [line], now: now)
        #expect(reading.diagnostic == .unsupportedFormat)
    }

    @Test func ignoresModelSpecificLimits() {
        let line = #"{"timestamp":"2026-07-22T01:00:00Z","payload":{"rate_limits":{"limit_id":"codex_bengalfox","primary":{"used_percent":99,"window_minutes":300,"resets_at":1893456000}}}}"#
        let reading = QuotaLogParser().parse(lines: [line], now: now)
        #expect(reading.diagnostic == .unsupportedFormat)
    }

    @Test func reportsExpiredRecords() {
        let line = #"{"timestamp":"2026-07-22T01:00:00Z","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":20,"window_minutes":300,"resets_at":100}}}}"#
        let reading = QuotaLogParser().parse(lines: [line], now: now)
        #expect(reading.diagnostic == .expired)
        #expect(reading.windows.isEmpty)
    }

    @Test func evaluatesFreshnessBoundaries() {
        #expect(QuotaFreshness.evaluate(dataTimestamp: now.addingTimeInterval(-299), now: now) == .current)
        #expect(QuotaFreshness.evaluate(dataTimestamp: now.addingTimeInterval(-600), now: now) == .delayed)
        #expect(QuotaFreshness.evaluate(dataTimestamp: now.addingTimeInterval(-1_801), now: now) == .stale)
    }

    private func fixtureLines(_ name: String) throws -> [String] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl"))
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
    }
}
