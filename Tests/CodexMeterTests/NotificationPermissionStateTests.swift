import Testing
@testable import CodexMeter

struct NotificationPermissionStateTests {
    @Test func notificationStatusDistinguishesSystemPermissionFromLocalPreference() {
        #expect(NotificationPermissionState.checking.statusText(localEnabled: false) == "检查中")
        #expect(NotificationPermissionState.notDetermined.statusText(localEnabled: false) == "已关闭")
        #expect(NotificationPermissionState.requesting.statusText(localEnabled: false) == "申请中")
        #expect(NotificationPermissionState.denied.statusText(localEnabled: false) == "需授权")
        #expect(NotificationPermissionState.authorized.statusText(localEnabled: false) == "已关闭")
        #expect(NotificationPermissionState.authorized.statusText(localEnabled: true) == "已开启")
    }

    @Test func notificationIconMakesDeniedPermissionVisible() {
        #expect(NotificationPermissionState.denied.icon(localEnabled: false) == "bell.badge.fill")
        #expect(NotificationPermissionState.authorized.icon(localEnabled: true) == "bell.fill")
        #expect(NotificationPermissionState.authorized.icon(localEnabled: false) == "bell.slash")
    }
}
