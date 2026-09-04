import AppKit
import SwiftUI
import Testing
import CodexMeterCore
@testable import CodexMeter

struct ResetCreditsPresentationTests {
    @Test func snapshotCarriesOnlyLiveResetInformation() throws {
        let reading = try #require(AppServerQuotaParser.parse(result: [
            "rateLimits": ["primary": ["usedPercent": 20, "resetsAt": 2_000_000_000, "windowDurationMins": 300]],
            "rateLimitResetCredits": ["availableCount": 2]
        ]))
        #expect(QuotaSnapshot(reading: reading, sourceName: "官方实时接口").resetCredits?.availableCount == 2)
        #expect(QuotaSnapshot.unavailable().resetCredits == nil)
        #expect(QuotaSnapshot(reading: QuotaLogParser().parse(lines: []), sourceName: "会话日志").resetCredits == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_METER_VISUAL_DIR"] != nil))
    @MainActor func renderResetDetails() throws {
        let directory = try #require(ProcessInfo.processInfo.environment["CODEX_METER_VISUAL_DIR"])
        _ = NSApplication.shared
        let samples: [(String, ResetCredits?)] = [
            ("two-cards", ResetCredits.parse(["availableCount": 2, "credits": [
                ["status": "available", "expiresAt": 1_800_000_000],
                ["status": "available", "expiresAt": 1_801_000_000]
            ]])),
            ("count-only", ResetCredits.parse(["availableCount": 1])),
            ("unavailable", nil)
        ]
        for (name, summary) in samples {
            let view = NSHostingView(rootView: ResetCreditsDetails(summary: summary))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 360), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            view.frame = NSRect(x: 0, y: 0, width: 300, height: 360)
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        let store = QuotaStore()
        let reading = QuotaReading(windows: [
            QuotaWindow(usedPercent: 20, resetsAt: Date().addingTimeInterval(3600), windowMinutes: 300),
            QuotaWindow(usedPercent: 30, resetsAt: Date().addingTimeInterval(86400), windowMinutes: 10080)
        ], dataTimestamp: Date(), checkedAt: Date(), diagnostic: .ready, quotaEventCount: 1,
           resetCredits: samples[0].1)
        store.snapshot = QuotaSnapshot(reading: reading, sourceName: "官方实时接口")
        let panel = NSHostingView(rootView: StatusPanelView(store: store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 388, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = panel
        panel.frame = NSRect(x: 0, y: 0, width: 388, height: 420)
        panel.layoutSubtreeIfNeeded()
        let bitmap = try #require(panel.bitmapImageRepForCachingDisplay(in: panel.bounds))
        panel.cacheDisplay(in: panel.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("panel.png"))
    }
}
