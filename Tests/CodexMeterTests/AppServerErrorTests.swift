import Testing
@testable import CodexMeter

struct AppServerErrorTests {
    @Test func timeoutReportsTheExactProtocolStage() {
        let error = CodexAppServerError.requestTimedOut(
            method: "account/rateLimits/read",
            seconds: 20
        )

        #expect(error.errorDescription?.contains("account/rateLimits/read") == true)
        #expect(error.errorDescription?.contains("20 秒") == true)
        #expect(error.isTransient)
    }
}
