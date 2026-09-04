import Foundation
import Testing
@testable import CodexMeterCore

struct ResetCreditsTests {
    @Test func propagatesThroughQuotaResponseAndOldResponseRemainsCompatible() throws {
        var response: [String: Any] = ["rateLimits": ["limitId": "codex", "primary": [
            "usedPercent": 20, "resetsAt": 2_000_000_000, "windowDurationMins": 300
        ]]]
        #expect(AppServerQuotaParser.parse(result: response)?.resetCredits == nil)
        response["rateLimitResetCredits"] = ["availableCount": 2, "credits": NSNull()]
        let reading = try #require(AppServerQuotaParser.parse(result: response))
        #expect(reading.resetCredits?.availableCount == 2)
        #expect(reading.windows.count == 1)
        #expect(QuotaLogParser().parse(lines: []).resetCredits == nil)
    }

    @Test func boundsDetailsAndPreservesUnknownCountDistinction() throws {
        let rows = Array(repeating: ["status": "available", "expiresAt": 2_000_000_000] as [String: Any], count: 101)
        let value = try #require(ResetCredits.parse(["availableCount": 101, "credits": rows]))
        #expect(value.availableCount == 101)
        #expect(value.credits?.count == 100)
        #expect(value.detailsIncomplete)
    }
    @Test func countIsAuthoritativeAndDetailsAreSorted() throws {
        let result = ResetCredits.parse([
            "availableCount": 3,
            "credits": [
                ["status": "available", "expiresAt": 2_000_000_000],
                ["status": "available", "expiresAt": 1_900_000_000]
            ]
        ])
        let value = try #require(result)
        #expect(value.availableCount == 3)
        #expect(value.credits?.first?.expiresAt?.timeIntervalSince1970 == 1_900_000_000)
        #expect(value.detailsIncomplete)
    }

    @Test func unknownIsNotZero() {
        #expect(ResetCredits.parse(nil) == nil)
        #expect(ResetCredits.parse(NSNull()) == nil)
        #expect(ResetCredits.parse(["availableCount": -1]) == nil)
        #expect(ResetCredits.parse(["availableCount": true]) == nil)
        #expect(ResetCredits.parse(["availableCount": 1.5]) == nil)
        #expect(ResetCredits.parse(["availableCount": "2"]) == nil)
        #expect(ResetCredits.parse(["availableCount": 2])?.credits == nil)
    }

    @Test func zeroAndMissingExpiry() throws {
        let zero = try #require(ResetCredits.parse(["availableCount": 0, "credits": []]))
        #expect(zero.credits == [])
        #expect(!zero.detailsIncomplete)
        let unknownDate = try #require(ResetCredits.parse([
            "availableCount": 1, "credits": [["status": "available", "expiresAt": NSNull()]]
        ]))
        #expect(unknownDate.credits?.count == 1)
        #expect(unknownDate.credits?.first?.expiresAt == nil)
    }

    @Test func malformedAndNonAvailableDetailsAreNotPresentedAsAvailable() throws {
        let value = try #require(ResetCredits.parse([
            "availableCount": 2,
            "credits": [
                ["status": "available", "expiresAt": -1],
                ["status": "consumed", "expiresAt": 2_000_000_000],
                ["status": "available", "expiresAt": "invalid"]
            ]
        ]))
        #expect(value.availableCount == 2)
        #expect(value.credits == [])
        #expect(value.detailsIncomplete)
    }
}
