import Foundation
import Testing
@testable import CodexMeter

struct AntigravityQuotaTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ANTIGRAVITY_LIVE_TEST"] == "1"))
    func readsRunningLocalService() async {
        let status = await AntigravityQuotaService().fetch()
        guard case let .ready(windows) = status else {
            Issue.record("Local Antigravity quota unavailable")
            return
        }
        #expect(!windows.isEmpty)
    }
    @Test func parsesIndependentQuotaWindows() throws {
        let json = #"{"response":{"groups":[{"displayName":"Gemini","buckets":[{"window":"5h","remainingFraction":0.75,"resetTime":"2026-11-19T10:00:00Z"},{"window":"weekly","remainingFraction":0.4,"resetTime":null}]}]}}"#
        let windows = try AntigravityQuotaService.parse(Data(json.utf8))
        #expect(windows.count == 2)
        #expect(windows[0].remaining == 75)
        #expect(windows[1].remaining == 40)
        #expect(windows[0].reset != nil)
    }

    @Test func rejectsOutOfRangeAndIncompleteValues() throws {
        let json = #"{"response":{"groups":[{"displayName":"x","buckets":[{"window":"5h","remainingFraction":2},{"remainingFraction":0.5}]}]}}"#
        #expect(try AntigravityQuotaService.parse(Data(json.utf8)).isEmpty)
    }
}
