import Foundation
import CodexMeterCore
import Testing
@testable import CodexMeter

struct StatusBarQuotaRotationTests {
    @Test func weeklyTitleIsCompactAndExplicitlyLabeled() {
        let snapshot = makeSnapshot(includeWeekly: true)

        #expect(snapshot.menuBarTitle.hasPrefix("61% | "))
        #expect(snapshot.weeklyMenuBarTitle?.hasPrefix("周 89% | ") == true)
    }

    @Test func weeklyTitleIsUnavailableForSingleWindowOrMissingData() {
        #expect(makeSnapshot(includeWeekly: false).weeklyMenuBarTitle == nil)
        #expect(QuotaSnapshot.unavailable().weeklyMenuBarTitle == nil)
    }

    @MainActor
    @Test func completedRefreshAdvancesRotationSequence() async throws {
        let store = QuotaStore(provider: StubQuotaProvider(snapshot: makeSnapshot(includeWeekly: true)))

        #expect(store.completedRefreshSequence == 0)
        store.refresh()
        for _ in 0..<100 where store.completedRefreshSequence == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(store.completedRefreshSequence == 1)
        #expect(store.snapshot.weeklyMenuBarTitle?.hasPrefix("周 89% | ") == true)
    }

    private func makeSnapshot(includeWeekly: Bool) -> QuotaSnapshot {
        let now = Date()
        var windows = [
            QuotaWindow(
                usedPercent: 39,
                resetsAt: now.addingTimeInterval(4 * 3_600),
                windowMinutes: 300
            )
        ]
        if includeWeekly {
            windows.append(
                QuotaWindow(
                    usedPercent: 11,
                    resetsAt: now.addingTimeInterval(5 * 86_400),
                    windowMinutes: 10_080
                )
            )
        }
        return QuotaSnapshot(
            reading: QuotaReading(
                windows: windows,
                dataTimestamp: now,
                checkedAt: now,
                diagnostic: .ready,
                quotaEventCount: 1
            ),
            sourceName: "测试"
        )
    }
}

private struct StubQuotaProvider: QuotaProvider {
    let snapshot: QuotaSnapshot

    func currentSnapshot() -> QuotaSnapshot {
        snapshot
    }
}
