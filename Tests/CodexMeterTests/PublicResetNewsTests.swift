import Foundation
import Testing
@testable import CodexMeter

struct PublicResetNewsTests {
    @Test func rateLimitBackoffIsBounded() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(PublicResetNewsService.retryDate("10", now: now).timeIntervalSince(now) == 900)
        #expect(PublicResetNewsService.retryDate("3600", now: now).timeIntervalSince(now) == 3600)
        #expect(PublicResetNewsService.retryDate("999999", now: now).timeIntervalSince(now) == 86400)
        #expect(PublicResetNewsService.retryDate(nil, now: now).timeIntervalSince(now) == 900)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_METER_NEWS_FIXTURE"] != nil))
    func readsLivePublicFeedFixture() throws {
        let path = try #require(ProcessInfo.processInfo.environment["CODEX_METER_NEWS_FIXTURE"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        _ = try PublicResetNewsService.decode(data, now: Date())
    }
    @Test func prefersRecentConfirmationAndIgnoresExpiredNews() throws {
        let json = #"{"events":[{"id":"old","status":"confirmed","title":"旧消息","updatedAt":"2026-10-25T00:00:00Z","confirmedAt":"2026-10-25T00:00:00Z","schedule":null},{"id":"forecast","status":"announced","title":"预告","updatedAt":"2026-10-28T00:00:00Z","confirmedAt":null,"schedule":{"from":"2026-10-28T00:00:00Z","through":"2026-10-29T00:00:00Z"}},{"id":"confirmed","status":"confirmed","title":"报道","updatedAt":"2026-10-28T01:00:00Z","confirmedAt":"2026-10-28T01:00:00Z","schedule":null}]}"#
        let now = ISO8601DateFormatter().date(from: "2026-10-28T02:00:00Z")!
        let event = try PublicResetNewsService.decode(Data(json.utf8), now: now)
        #expect(event?.id == "confirmed")
        #expect(event?.isCurrent(at: now.addingTimeInterval(2 * 86400)) == false)
    }

    @Test func invalidDatesDoNotBecomeValidNews() {
        let json = #"{"events":[{"id":"bad","status":"announced","title":"x","updatedAt":"invalid","confirmedAt":null,"schedule":null}]}"#
        #expect(throws: (any Error).self) {
            try PublicResetNewsService.decode(Data(json.utf8), now: Date())
        }
    }
}
