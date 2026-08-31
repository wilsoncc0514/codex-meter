import Foundation
import Testing
@testable import CodexMeter

struct LiveAppServerIntegrationTests {
    @Test(
        "Reads current ChatGPT rate limits through the production client",
        .enabled(if: ProcessInfo.processInfo.environment["CODEX_METER_LIVE_TEST"] == "1")
    )
    func readsCurrentRateLimits() throws {
        let reading = try CodexAppServerClient().readRateLimits(timeout: 20)
        #expect(reading.diagnostic == .ready)
        #expect(!reading.windows.isEmpty)
    }
}
