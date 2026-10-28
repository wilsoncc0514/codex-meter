import Foundation
import Testing
@testable import CodexMeterCore

struct RefreshPolicyTests {
    @Test func limitsIdlePollingAndRespondsToActivity() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(RefreshPolicy.interval(lastActivity: nil, lastChange: nil, now: now) == 300)
        #expect(RefreshPolicy.interval(lastActivity: now.addingTimeInterval(-30), lastChange: nil, now: now) == 60)
        #expect(RefreshPolicy.interval(lastActivity: now, lastChange: nil, isLowPower: true, now: now) == 300)
        #expect(RefreshPolicy.interval(lastActivity: now.addingTimeInterval(-601), lastChange: nil, now: now) == 300)
    }

    @Test func accountSwitchAndUnknownIdentityResetBaseline() {
        var gate = RecoveryAccountGate()
        let first = gate.canCompare(identity: "a")
        let same = gate.canCompare(identity: "a")
        let switched = gate.canCompare(identity: "b")
        let sameNew = gate.canCompare(identity: "b")
        let unknown = gate.canCompare(identity: nil)
        let afterUnknown = gate.canCompare(identity: "b")
        #expect([first, same, switched, sameNew, unknown, afterUnknown] == [false, true, false, true, false, false])
    }
}
