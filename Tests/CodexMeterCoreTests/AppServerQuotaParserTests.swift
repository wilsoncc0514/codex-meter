import Foundation
import Testing
@testable import CodexMeterCore

struct AppServerQuotaParserTests {
    @Test func parsesCurrentCamelCaseResponse() throws {
        let now = Date(timeIntervalSince1970: 1_785_500_000)
        let result: [String: Any] = [
            "rateLimits": [
                "limitId": "codex",
                "primary": [
                    "usedPercent": 37.0,
                    "resetsAt": 1_785_600_000.0,
                    "windowDurationMins": 300
                ],
                "secondary": [
                    "usedPercent": 12.0,
                    "resetsAt": 1_786_000_000.0,
                    "windowDurationMins": 10_080
                ]
            ]
        ]

        let reading = try #require(AppServerQuotaParser.parse(result: result, now: now))
        #expect(reading.window(minutes: 300)?.usedPercent == 37)
        #expect(reading.window(minutes: 10_080)?.usedPercent == 12)
    }

    @Test func selectsAggregateCodexBucket() throws {
        let result: [String: Any] = [
            "rateLimitsByLimitId": [
                "model": [
                    "limitId": "codex_bengalfox",
                    "primary": [
                        "usedPercent": 99,
                        "resetsAt": 1_900_000_000,
                        "windowDurationMins": 300
                    ]
                ],
                "aggregate": [
                    "limitId": "codex",
                    "primary": [
                        "usedPercent": 25,
                        "resetsAt": 1_900_000_000,
                        "windowDurationMins": 300
                    ]
                ]
            ]
        ]

        let reading = try #require(AppServerQuotaParser.parse(result: result))
        #expect(reading.window(minutes: 300)?.usedPercent == 25)
    }
}
