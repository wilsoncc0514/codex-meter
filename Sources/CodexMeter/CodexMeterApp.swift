import AppKit
import AVFoundation
import Combine
import CodexMeterCore
import Darwin
import ServiceManagement
import SwiftUI
@preconcurrency import UserNotifications

@main
struct CodexMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

private enum PanelMetrics {
    static let cardWidth: CGFloat = 360
    static let cardHeight: CGFloat = 220
    static let windowPadding: CGFloat = 14
    static let width: CGFloat = cardWidth + windowPadding * 2
    static let height: CGFloat = cardHeight + windowPadding * 2
    static let verticalGap: CGFloat = 14
    static let screenPadding: CGFloat = 8
}

private enum CodexSessionPaths {
    static let roots = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/archived_sessions")
    ]
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let quotaStore = QuotaStore()
    private var statusItem: NSStatusItem?
    private var statusButton: NSStatusBarButton?
    private var panelWindow: NSPanel?
    private var outsideClickMonitor: Any?
    private var snapshotCancellable: AnyCancellable?
    private var installationMonitor: Timer?
    private var launchedExecutableIdentity: ExecutableIdentity?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard enforceSingleInstance() else { return }
        launchedExecutableIdentity = ExecutableIdentity.current()
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configurePanelWindow()
        configureWakeRefreshObservers()
        configureInstallationMonitor()
        quotaStore.start()

        snapshotCancellable = quotaStore.$snapshot.sink { [weak self] snapshot in
            self?.updateStatusItem(with: snapshot)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        installationMonitor?.invalidate()
        stopOutsideClickMonitor()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        quotaStore.syncNotificationAuthorizationStatus()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(togglePanel)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        button.setAccessibilityLabel("Codex 额度")
        statusButton = button

        updateStatusItem(with: quotaStore.snapshot)
    }

    private func configurePanelWindow() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: PanelMetrics.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentViewController = NSHostingController(
            rootView: StatusPanelView(store: quotaStore)
                .frame(width: PanelMetrics.width, height: PanelMetrics.height)
        )
        self.panelWindow = panel
    }

    private func configureWakeRefreshObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        notificationCenter.addObserver(
            self,
            selector: #selector(refreshAfterSleepOrUnlock),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(refreshAfterSleepOrUnlock),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(refreshAfterSleepOrUnlock),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
    }

    private func configureInstallationMonitor() {
        installationMonitor = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.relaunchIfExecutableWasReplaced()
            }
        }
    }

    private func relaunchIfExecutableWasReplaced() {
        guard let launchedExecutableIdentity,
              let currentIdentity = ExecutableIdentity.current(),
              currentIdentity != launchedExecutableIdentity else {
            return
        }
        installationMonitor?.invalidate()
        installationMonitor = nil
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, error in
            guard error == nil else { return }
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }

    private func updateStatusItem(with snapshot: QuotaSnapshot) {
        let title = snapshot.menuBarTitle
        let tooltip = snapshot.isUnavailable
            ? snapshot.diagnostic.userMessage
            : "\(snapshot.primaryQuotaShortLabel)额度剩余 \(snapshot.remainingPercent)% · \(snapshot.freshnessLabel) · \(snapshot.resetText)恢复"
        let attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: snapshot.tagTextColor,
                .kern: -0.2
            ]
        )
        statusButton?.attributedTitle = attributedTitle
        statusButton?.layer?.backgroundColor = snapshot.tagBackgroundColor.cgColor
        statusButton?.toolTip = tooltip
        statusButton?.setAccessibilityValue(tooltip)
        statusItem?.length = ceil(attributedTitle.size().width + 12)
    }

    @objc private func togglePanel() {
        guard let statusButton, let panelWindow else { return }

        if panelWindow.isVisible {
            closePanel()
        } else {
            positionPanel(relativeTo: statusButton)
            panelWindow.orderFrontRegardless()
            startOutsideClickMonitor()
            quotaStore.refresh()
            quotaStore.syncNotificationAuthorizationStatus()
        }
    }

    private func closePanel() {
        panelWindow?.orderOut(nil)
        stopOutsideClickMonitor()
    }

    private func positionPanel(relativeTo anchorView: NSView) {
        guard let window = anchorView.window else { return }
        let anchorRectInWindow = anchorView.convert(anchorView.bounds, to: nil)
        let anchorRect = window.convertToScreen(anchorRectInWindow)
        let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let proposedX = anchorRect.midX - PanelMetrics.width / 2
        let x = min(
            max(proposedX, visibleFrame.minX + PanelMetrics.screenPadding),
            visibleFrame.maxX - PanelMetrics.width - PanelMetrics.screenPadding
        )
        let y = anchorRect.minY - PanelMetrics.height - PanelMetrics.verticalGap
        panelWindow?.setFrame(
            NSRect(x: x, y: y, width: PanelMetrics.width, height: PanelMetrics.height),
            display: true
        )
    }

    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.closePanel()
            }
        }
    }

    private func stopOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    @objc private func refreshAfterSleepOrUnlock(_ notification: Notification) {
        quotaStore.refresh()
        quotaStore.syncNotificationAuthorizationStatus()
    }

    private func enforceSingleInstance() -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return true }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != currentPID }
        guard !others.isEmpty else { return true }

        let currentBuild = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
        let newerOther = others.first { application in
            guard let url = application.bundleURL,
                  let bundle = Bundle(url: url),
                  let value = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return false }
            return (Int(value) ?? 0) > currentBuild
        }
        if let newerOther {
            newerOther.activate()
            NSApp.terminate(nil)
            return false
        }
        others.forEach { $0.terminate() }
        return true
    }
}

struct ExecutableIdentity: Equatable {
    let inode: UInt64
    let size: UInt64
    let modifiedAt: TimeInterval

    static func current(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> ExecutableIdentity? {
        guard let executableURL = bundle.executableURL else { return nil }
        return current(executableURL: executableURL, fileManager: fileManager)
    }

    static func current(
        executableURL: URL,
        fileManager: FileManager = .default
    ) -> ExecutableIdentity? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: executableURL.path),
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let date = attributes[.modificationDate] as? Date else {
            return nil
        }
        return ExecutableIdentity(
            inode: inode,
            size: size,
            modifiedAt: date.timeIntervalSince1970
        )
    }
}

struct StatusPanelView: View {
    @ObservedObject var store: QuotaStore

    var body: some View {
        ZStack {
            ZStack {
                PanelGlassBackground()

                VStack(alignment: .leading, spacing: 12) {
                    header
                    quotaOverview
                }
                .padding(18)
            }
            .frame(width: PanelMetrics.cardWidth, height: PanelMetrics.cardHeight)
            .padding(PanelMetrics.windowPadding)
        }
        .frame(width: PanelMetrics.width, height: PanelMetrics.height)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("\(store.snapshot.sourceName) · \(store.snapshot.lastUpdatedText)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(
                    store.snapshot.isUnavailable
                        ? Color.red
                        : (store.snapshot.freshness == .stale ? Color.orange : Color.secondary)
                )
                .lineLimit(1)
                .help(store.snapshot.diagnosticText)

            Spacer()

            RefreshIconButton(isRefreshing: store.isRefreshing) {
                store.refresh()
            }

            MoreActionsMenu(store: store)
        }
    }

    private var quotaOverview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.snapshot.percentText)
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(store.snapshot.primaryQuotaLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text(store.snapshot.shortResetText)
                        .font(.system(size: 23, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(store.snapshot.resetClockText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            QuotaProgressBar(percent: store.snapshot.displayRemainingPercent, tint: store.snapshot.tint)

            if store.snapshot.hasSeparateWeeklyQuota {
                Divider()
                    .padding(.vertical, 1)

                SecondaryQuotaRow(
                    title: "周额度",
                    percentText: store.snapshot.weeklyPercentText,
                    trailing: store.snapshot.weeklyResetDateText
                )
            }
        }
        .padding(14)
        .notificationInsetSurface(cornerRadius: 12)
    }

}

struct PanelGlassBackground: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

        ZStack {
            shape
                .fill(.ultraThinMaterial)

            shape
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.64),
                            Color(red: 0.82, green: 0.94, blue: 1.0).opacity(0.48),
                            Color.white.opacity(0.30)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.84),
                            Color(red: 0.90, green: 0.98, blue: 1.0).opacity(0.32),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 4,
                        endRadius: 82
                    )
                )
                .frame(width: 130, height: 150)
                .offset(x: 130, y: -56)
                .blur(radius: 4)

            shape
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.68),
                            Color.white.opacity(0.38),
                            Color(red: 0.42, green: 0.70, blue: 0.88).opacity(0.20)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )

            shape
                .stroke(Color.white.opacity(0.22), lineWidth: 0.7)
                .padding(1.2)
        }
        .clipShape(shape)
        .shadow(color: Color.black.opacity(0.12), radius: 18, x: 0, y: 10)
    }
}

private extension View {
    func notificationInsetSurface(cornerRadius: CGFloat) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.28))
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.28), lineWidth: 0.8)
        )
    }

    func glassSurface(cornerRadius: CGFloat) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.12),
                            Color.white.opacity(0.028),
                            Color.white.opacity(0.006)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.20),
                            Color.white.opacity(0.05),
                            Color.white.opacity(0.012)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
    }

    func glassIconSurface(cornerRadius: CGFloat = 4, isPressed: Bool = false, isHovered: Bool = false) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isPressed ? 0.12 : (isHovered ? 0.54 : 0.40)),
                            Color.white.opacity(isPressed ? 0.04 : (isHovered ? 0.24 : 0.15)),
                            Color.black.opacity(isPressed ? 0.14 : 0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isPressed ? 0.22 : (isHovered ? 0.68 : 0.52)),
                            Color.white.opacity(isPressed ? 0.10 : (isHovered ? 0.42 : 0.30)),
                            Color.black.opacity(isPressed ? 0.20 : 0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius - 1, style: .continuous)
                .stroke(Color.white.opacity(isPressed ? 0.04 : 0.10), lineWidth: 0.6)
                .padding(1.25)
        )
        .shadow(color: Color.white.opacity(isPressed ? 0.04 : (isHovered ? 0.16 : 0.08)), radius: 0, x: 0, y: -0.6)
        .shadow(color: Color.black.opacity(isPressed ? 0.06 : (isHovered ? 0.13 : 0.10)), radius: isPressed ? 1 : (isHovered ? 3 : 2), x: 0, y: isPressed ? 0.4 : (isHovered ? 1.6 : 1.2))
        .shadow(color: Color.black.opacity(isPressed ? 0.03 : (isHovered ? 0.07 : 0.05)), radius: isPressed ? 1 : (isHovered ? 5 : 3), x: 0, y: isPressed ? 0.8 : (isHovered ? 3 : 2))
        .offset(y: isPressed ? 0.75 : (isHovered ? -0.6 : 0))
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

}

struct RefreshIconButton: View {
    let isRefreshing: Bool
    let action: () -> Void
    @State private var isPressed = false
    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24, height: 24)
                    .glassIconSurface(isPressed: false, isHovered: isHovered)
            } else {
                PanelIconFrame(systemImage: "arrow.clockwise", isPressed: isPressed, isHovered: isHovered)
            }
        }
        .buttonStyle(.plain)
        .disabled(isRefreshing)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.08)) {
                isHovered = hovering
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if isPressed == false {
                        withAnimation(.easeOut(duration: 0.035)) {
                            isPressed = true
                        }
                    }
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.12, dampingFraction: 0.72)) {
                        isPressed = false
                    }
                }
        )
        .help(isRefreshing ? "正在通过 ChatGPT 查询额度" : "刷新额度")
    }
}

struct PanelIconFrame: View {
    let systemImage: String
    var isPressed = false
    var isHovered = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .foregroundStyle(.secondary)
            .glassIconSurface(isPressed: isPressed, isHovered: isHovered)
    }
}

struct MoreActionsMenu: View {
    @ObservedObject var store: QuotaStore
    @State private var isShowingActions = false
    @State private var isPressed = false
    @State private var isHovered = false
    
    var body: some View {
        Button {
            isShowingActions.toggle()
        } label: {
            PanelIconFrame(systemImage: "ellipsis", isPressed: isPressed || isShowingActions, isHovered: isHovered || isShowingActions)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.08)) {
                isHovered = hovering
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if isPressed == false {
                        withAnimation(.easeOut(duration: 0.035)) {
                            isPressed = true
                        }
                    }
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.12, dampingFraction: 0.72)) {
                        isPressed = false
                    }
                }
        )
        .popover(isPresented: $isShowingActions, arrowEdge: .top) {
            ActionsPopover(store: store)
                .frame(width: 224)
        }
        .help("更多")
    }
}

struct ActionsPopover: View {
    @ObservedObject var store: QuotaStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.snapshot.requiresCodexLogin {
                Button {
                    store.openChatGPTForLogin()
                } label: {
                    ActionMenuRow(
                        systemImage: "person.crop.circle.badge.exclamationmark",
                        title: "打开 ChatGPT 登录",
                        trailing: nil
                    )
                }
                .buttonStyle(.plain)

                Divider()
            }

            Button {
                store.toggleNotifications()
            } label: {
                ActionMenuRow(
                    systemImage: store.notificationStatusIcon,
                    title: "额度通知",
                    trailing: store.notificationStatusText
                )
            }
            .buttonStyle(.plain)
            .disabled(store.notificationPermissionState == .requesting)

            Button {
                store.toggleLaunchAtLogin()
            } label: {
                ActionMenuRow(
                    systemImage: store.launchAtLoginEnabled ? "checkmark.circle.fill" : "circle",
                    title: "登录时启动",
                    trailing: store.launchAtLoginEnabled ? "已开启" : "已关闭"
                )
            }
            .buttonStyle(.plain)

            Divider()

            Button {
                store.toggleVoiceBroadcast()
            } label: {
                ActionMenuRow(
                    systemImage: store.voiceBroadcastEnabled ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    title: store.voiceBroadcastEnabled ? "关闭播报" : "开启播报",
                    trailing: store.voiceBroadcastEnabled ? nil : "\(store.voiceBroadcastIntervalMinutes) 分钟"
                )
            }
            .buttonStyle(.plain)

            if store.voiceBroadcastEnabled {
                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("播报间隔")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)

                    BroadcastIntervalButton(minutes: 1, store: store)
                    BroadcastIntervalButton(minutes: 5, store: store)
                    BroadcastIntervalButton(minutes: 10, store: store)
                }
            }

            Divider()

            Button {
                store.copyDiagnostics()
            } label: {
                ActionMenuRow(systemImage: "doc.on.clipboard", title: "复制诊断信息", trailing: nil)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text("Codex 额度 \(appVersionText)")
                Text(Bundle.main.bundleURL.path)
                    .lineLimit(2)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)

            if let message = store.settingsMessage {
                Text(message)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }

            Divider()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                ActionMenuRow(systemImage: "power", title: "退出应用", trailing: nil)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(PanelGlassBackground())
    }

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }
}

struct BroadcastIntervalButton: View {
    let minutes: Int
    @ObservedObject var store: QuotaStore

    var body: some View {
        Button {
            store.setVoiceBroadcastInterval(minutes: minutes)
        } label: {
            ActionMenuRow(
                systemImage: store.voiceBroadcastIntervalMinutes == minutes ? "checkmark.circle.fill" : "circle",
                title: "\(minutes) 分钟",
                trailing: nil
            )
        }
        .buttonStyle(.plain)
    }
}

struct ActionMenuRow: View {
    let systemImage: String
    let title: String
    let trailing: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 18)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .glassSurface(cornerRadius: 6)
    }
}

struct QuotaProgressBar: View {
    let percent: Int
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.thinMaterial)
                    .overlay(Color(nsColor: .separatorColor).opacity(0.16))
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                tint.opacity(0.78),
                                tint
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(8, proxy.size.width * min(max(Double(percent) / 100, 0), 1)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Color.white.opacity(0.24), lineWidth: 0.6)
                    )
            }
        }
        .frame(height: 8)
    }
}

struct SecondaryQuotaRow: View {
    let title: String
    let percentText: String
    let trailing: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(percentText)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(trailing)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .trailing)
        }
    }
}

enum NotificationPermissionState: Equatable {
    case checking
    case notDetermined
    case requesting
    case denied
    case authorized

    func statusText(localEnabled: Bool) -> String {
        switch self {
        case .checking:
            "检查中"
        case .requesting:
            "申请中"
        case .denied:
            "需授权"
        case .authorized:
            localEnabled ? "已开启" : "已关闭"
        case .notDetermined:
            "已关闭"
        }
    }

    func icon(localEnabled: Bool) -> String {
        switch self {
        case .checking, .requesting:
            "bell.badge"
        case .denied:
            "bell.badge.fill"
        case .authorized where localEnabled:
            "bell.fill"
        case .authorized, .notDetermined:
            "bell.slash"
        }
    }
}

@MainActor
final class QuotaStore: ObservableObject {
    @Published var snapshot: QuotaSnapshot
    @Published private(set) var isRefreshing = false
    @Published var voiceBroadcastEnabled = false
    @Published var voiceBroadcastIntervalMinutes: Int
    @Published var notificationsEnabled: Bool
    @Published private(set) var notificationPermissionState: NotificationPermissionState = .checking
    @Published var launchAtLoginEnabled: Bool
    @Published var settingsMessage: String?

    private var timer: Timer?
    private var voiceTimer: Timer?
    private var transientRefreshWorkItem: DispatchWorkItem?
    private var speakAfterRefresh = false
    private let refreshQueue = DispatchQueue(label: "com.codexmeter.refresh", qos: .utility)
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var notifiedLevels = Set<Int>()
    private let recoveryDetector = QuotaRecoveryDetector()
    private var recoveryObservations: [Int: QuotaObservation]
    private var pendingRecoveries: [Int: QuotaRecoveryEvent] = [:]
    private var notifiedRecoveryFingerprints: [String]
    private var recoveryConfirmationScheduled = false
    private let provider: QuotaProvider
    private var logMonitor: SessionLogMonitor?
    private var updateHandlerInstalled = false

    init(provider: QuotaProvider = HybridQuotaProvider()) {
        self.provider = provider
        self.snapshot = QuotaSnapshot.unavailable()
        let savedInterval = UserDefaults.standard.integer(forKey: CacheKey.voiceBroadcastIntervalMinutes)
        self.voiceBroadcastIntervalMinutes = Self.allowedVoiceBroadcastIntervals.contains(savedInterval) ? savedInterval : 1
        self.notificationsEnabled = UserDefaults.standard.bool(forKey: CacheKey.notificationsEnabled)
        self.launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        self.recoveryObservations = Dictionary(
            uniqueKeysWithValues: (QuotaSnapshot.cached()?.quotaObservations ?? []).map {
                ($0.windowMinutes, $0)
            }
        )
        self.notifiedRecoveryFingerprints = UserDefaults.standard.stringArray(
            forKey: CacheKey.notifiedRecoveryFingerprints
        ) ?? []
    }

    func start() {
        syncNotificationAuthorizationStatus()
        if !updateHandlerInstalled {
            updateHandlerInstalled = true
            provider.setUpdateHandler { [weak self] liveSnapshot in
                Task { @MainActor in
                    self?.apply(liveSnapshot)
                }
            }
        }
        refresh()
        if logMonitor == nil {
            let roots = CodexSessionPaths.roots
            let monitor = SessionLogMonitor(roots: roots) { [weak self] in
                Task { @MainActor in
                    self?.refresh()
                }
            }
            logMonitor = monitor
            monitor.start()
        }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func refresh() {
        guard isRefreshing == false else { return }
        isRefreshing = true
        let provider = provider

        refreshQueue.async { [weak self] in
            let liveSnapshot = provider.currentSnapshot()

            DispatchQueue.main.async {
                guard let self else { return }
                let shouldSpeak = self.speakAfterRefresh
                self.speakAfterRefresh = false
                self.isRefreshing = false
                self.apply(liveSnapshot)
                if shouldSpeak, self.voiceBroadcastEnabled {
                    self.speak(self.snapshot)
                }
            }
        }
    }

    private func apply(_ newSnapshot: QuotaSnapshot) {
        evaluateQuotaRecovery(in: newSnapshot)
        snapshot = newSnapshot
        newSnapshot.cache()
        evaluateNotifications()
        updateTransientRefresh(for: newSnapshot)
    }

    private func updateTransientRefresh(for snapshot: QuotaSnapshot) {
        let needsFastRetry = snapshot.sourceName.contains("实时查询异常")
            || snapshot.sourceName == "实时接口暂时不可用"
        guard needsFastRetry else {
            transientRefreshWorkItem?.cancel()
            transientRefreshWorkItem = nil
            return
        }
        guard transientRefreshWorkItem == nil else { return }

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.transientRefreshWorkItem = nil
            self.refresh()
        }
        transientRefreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: item)
    }

    func toggleVoiceBroadcast() {
        if voiceBroadcastEnabled {
            stopVoiceBroadcast()
        } else {
            startVoiceBroadcast()
        }
    }

    private func startVoiceBroadcast() {
        voiceBroadcastEnabled = true
        requestVoiceBroadcast()
        scheduleVoiceTimer()
    }

    private func scheduleVoiceTimer() {
        voiceTimer?.invalidate()
        voiceTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(voiceBroadcastIntervalMinutes * 60), repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.requestVoiceBroadcast()
            }
        }
    }

    private func stopVoiceBroadcast() {
        voiceBroadcastEnabled = false
        speakAfterRefresh = false
        voiceTimer?.invalidate()
        voiceTimer = nil
        speechSynthesizer.stopSpeaking(at: .immediate)
    }

    func setVoiceBroadcastInterval(minutes: Int) {
        guard Self.allowedVoiceBroadcastIntervals.contains(minutes) else { return }
        voiceBroadcastIntervalMinutes = minutes
        UserDefaults.standard.set(minutes, forKey: CacheKey.voiceBroadcastIntervalMinutes)
        if voiceBroadcastEnabled {
            scheduleVoiceTimer()
        }
    }

    func toggleNotifications() {
        if notificationsEnabled {
            setNotificationsEnabled(false)
            UserDefaults.standard.set(false, forKey: CacheKey.notificationEnablePending)
            settingsMessage = "额度通知已关闭"
            return
        }

        notificationPermissionState = .requesting
        settingsMessage = "正在检查通知权限…"
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()

            switch settings.authorizationStatus {
            case .notDetermined:
                UserDefaults.standard.set(true, forKey: CacheKey.notificationEnablePending)
                do {
                    let granted = try await center.requestAuthorization(options: [.alert, .sound])
                    if granted {
                        setNotificationsEnabled(true)
                        UserDefaults.standard.set(false, forKey: CacheKey.notificationEnablePending)
                        notificationPermissionState = .authorized
                        settingsMessage = "额度通知已开启"
                    } else {
                        setNotificationsEnabled(false)
                        notificationPermissionState = .denied
                        settingsMessage = "通知权限未授予；再次点击可打开系统设置"
                    }
                } catch {
                    setNotificationsEnabled(false)
                    notificationPermissionState = .notDetermined
                    settingsMessage = "通知授权失败：\(error.localizedDescription)"
                }
            case .denied:
                setNotificationsEnabled(false)
                UserDefaults.standard.set(true, forKey: CacheKey.notificationEnablePending)
                notificationPermissionState = .denied
                settingsMessage = "请在系统设置中允许 Codex 额度通知"
                openNotificationSettings()
            case .authorized, .provisional, .ephemeral:
                setNotificationsEnabled(true)
                UserDefaults.standard.set(false, forKey: CacheKey.notificationEnablePending)
                notificationPermissionState = .authorized
                settingsMessage = "额度通知已开启"
            @unknown default:
                setNotificationsEnabled(false)
                notificationPermissionState = .notDetermined
                settingsMessage = "无法识别当前通知权限状态"
            }
        }
    }

    func syncNotificationAuthorizationStatus() {
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            let pendingEnable = UserDefaults.standard.bool(forKey: CacheKey.notificationEnablePending)

            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                notificationPermissionState = .authorized
                if pendingEnable {
                    setNotificationsEnabled(true)
                    UserDefaults.standard.set(false, forKey: CacheKey.notificationEnablePending)
                    settingsMessage = "额度通知已开启"
                }
            case .denied:
                notificationPermissionState = .denied
                setNotificationsEnabled(false)
            case .notDetermined:
                notificationPermissionState = .notDetermined
                setNotificationsEnabled(false)
            @unknown default:
                notificationPermissionState = .notDetermined
                setNotificationsEnabled(false)
            }
        }
    }

    var notificationStatusText: String {
        notificationPermissionState.statusText(localEnabled: notificationsEnabled)
    }

    var notificationStatusIcon: String {
        notificationPermissionState.icon(localEnabled: notificationsEnabled)
    }

    private func setNotificationsEnabled(_ enabled: Bool) {
        notificationsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: CacheKey.notificationsEnabled)
    }

    private func openNotificationSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications"
        ]
        let opened = candidates
            .compactMap(URL.init(string:))
            .contains { NSWorkspace.shared.open($0) }
        if !opened {
            settingsMessage = "无法打开系统设置，请手动前往“通知”并允许 Codex 额度"
        }
    }

    func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            settingsMessage = launchAtLoginEnabled ? "已开启登录时启动" : "已关闭登录时启动"
        } catch {
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            settingsMessage = "登录启动设置失败：\(error.localizedDescription)"
        }
    }

    func openChatGPTForLogin() {
        let candidates = [
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.chat"),
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.chatgpt"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/ChatGPT.app")
        ].compactMap { $0 }
        guard let appURL = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            settingsMessage = "未找到 ChatGPT.app，请先安装新版 ChatGPT 桌面应用"
            return
        }

        if NSWorkspace.shared.open(appURL) {
            settingsMessage = "请在 ChatGPT 中完成登录，然后返回刷新"
        } else {
            settingsMessage = "无法打开 ChatGPT，请手动打开并登录"
        }
    }

    func copyDiagnostics() {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        let text = """
        Codex 额度 \(version) (\(build))
        Path: \(bundle.bundleURL.path)
        Status: \(snapshot.diagnosticText)
        Source: \(snapshot.sourceName)
        ChatGPT CLI: \(ChatGPTCLIExecutableLocator.diagnosticExecutablePath())
        Login required: \(snapshot.requiresCodexLogin ? "yes" : "no")
        Window: \(snapshot.primaryWindowMinutes) minutes
        Remaining: \(snapshot.isUnavailable ? "unknown" : "\(snapshot.remainingPercent)%")
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        settingsMessage = "诊断信息已复制（不含会话内容）"
    }

    private func requestVoiceBroadcast() {
        speakAfterRefresh = true
        refresh()
    }

    private func speak(_ snapshot: QuotaSnapshot) {
        guard !snapshot.isUnavailable else { return }
        let text = "Codex \(snapshot.primaryQuotaSpeechLabel)额度剩余 \(snapshot.remainingPercent)%，距离额度恢复 \(snapshot.resetText)。"
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = 0.48
        speechSynthesizer.stopSpeaking(at: .immediate)
        speechSynthesizer.speak(utterance)
    }

    private func evaluateNotifications() {
        guard notificationsEnabled, !snapshot.isUnavailable, snapshot.freshness != .stale else { return }
        let remaining = snapshot.remainingPercent

        if remaining <= 10 {
            notifyOnce(level: 10, title: "Codex 额度接近耗尽", body: "当前\(snapshot.primaryQuotaShortLabel)剩余 \(remaining)%，建议放慢高消耗任务。")
        } else if remaining <= 20 {
            notifyOnce(level: 20, title: "Codex 额度偏低", body: "当前\(snapshot.primaryQuotaShortLabel)剩余 \(remaining)%，距离额度恢复 \(snapshot.resetText)。")
        }
    }

    private func evaluateQuotaRecovery(in newSnapshot: QuotaSnapshot) {
        guard !newSnapshot.isUnavailable,
              newSnapshot.freshness != .stale,
              newSnapshot.sourceName.hasPrefix("官方") else {
            return
        }

        let observations = newSnapshot.quotaObservations
        guard notificationsEnabled else {
            pendingRecoveries.removeAll()
            recoveryObservations = Dictionary(
                uniqueKeysWithValues: observations.map { ($0.windowMinutes, $0) }
            )
            return
        }

        var detectedCandidate = false
        for observation in observations {
            let window = observation.windowMinutes

            if let pending = pendingRecoveries[window],
               observation.observedAt > pending.detectedAt {
                pendingRecoveries.removeValue(forKey: window)
                if recoveryDetector.confirms(pending, with: observation) {
                    deliverRecoveryNotification(pending, confirmedBy: observation)
                }
            }

            if pendingRecoveries[window] == nil,
               let previous = recoveryObservations[window],
               let event = recoveryDetector.detect(
                   previous: previous,
                   current: observation,
                   now: observation.observedAt
               ),
               !notifiedRecoveryFingerprints.contains(event.fingerprint) {
                pendingRecoveries[window] = event
                detectedCandidate = true
            }

            recoveryObservations[window] = observation
        }

        if detectedCandidate {
            scheduleRecoveryConfirmation()
        }
    }

    private func scheduleRecoveryConfirmation() {
        guard !recoveryConfirmationScheduled else { return }
        recoveryConfirmationScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self else { return }
            self.recoveryConfirmationScheduled = false
            self.refresh()
        }
    }

    private func deliverRecoveryNotification(
        _ event: QuotaRecoveryEvent,
        confirmedBy observation: QuotaObservation
    ) {
        guard !notifiedRecoveryFingerprints.contains(event.fingerprint) else { return }
        notifiedRecoveryFingerprints.insert(event.fingerprint, at: 0)
        if notifiedRecoveryFingerprints.count > 50 {
            notifiedRecoveryFingerprints.removeLast(notifiedRecoveryFingerprints.count - 50)
        }
        UserDefaults.standard.set(
            notifiedRecoveryFingerprints,
            forKey: CacheKey.notifiedRecoveryFingerprints
        )

        notifiedLevels.removeAll()
        let label = quotaWindowNotificationLabel(minutes: event.windowMinutes)
        let title: String
        let body: String
        switch event.kind {
        case .scheduledReset:
            title = "Codex \(label)额度已重置"
            body = "当前剩余 \(observation.remainingPercent)%。"
        case .earlyReset:
            title = "Codex \(label)额度提前恢复"
            body = "剩余额度从 \(event.previousRemainingPercent)% 提升至 \(observation.remainingPercent)%，可能是服务端补偿或统一重置。"
        case .significantRecovery:
            title = "Codex \(label)额度大幅回升"
            body = "剩余额度从 \(event.previousRemainingPercent)% 提升至 \(observation.remainingPercent)%，可能是服务端补偿或统一重置。"
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "codex-meter-recovery-\(event.fingerprint)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func quotaWindowNotificationLabel(minutes: Int) -> String {
        switch minutes {
        case 300: "5 小时"
        case 10_080: "周"
        case let value where value % 1_440 == 0: "\(value / 1_440) 天"
        case let value where value % 60 == 0: "\(value / 60) 小时"
        default: "\(minutes) 分钟"
        }
    }

    private func notifyOnce(level: Int, title: String, body: String) {
        guard notifiedLevels.insert(level).inserted else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "codex-meter-\(level)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    private static let allowedVoiceBroadcastIntervals = [1, 5, 10]

}

protocol QuotaProvider: Sendable {
    func currentSnapshot() -> QuotaSnapshot
    func setUpdateHandler(_ handler: (@Sendable (QuotaSnapshot) -> Void)?)
}

extension QuotaProvider {
    func setUpdateHandler(_ handler: (@Sendable (QuotaSnapshot) -> Void)?) {}
}

struct CodexSessionQuotaProvider: QuotaProvider {
    private let reader = SessionQuotaReader()

    func currentSnapshot() -> QuotaSnapshot {
        QuotaSnapshot(
            reading: reader.read(roots: CodexSessionPaths.roots),
            sourceName: "Codex 会话"
        )
    }
}

final class HybridQuotaProvider: @unchecked Sendable, QuotaProvider {
    private let appServer: any AppServerQuotaClient
    private let fallback: any QuotaProvider
    private let requestTimeout: TimeInterval
    private let retryDelays: [TimeInterval]
    private let sleep: @Sendable (TimeInterval) -> Void

    init(
        appServer: any AppServerQuotaClient = CodexAppServerClient(),
        fallback: any QuotaProvider = CodexSessionQuotaProvider(),
        requestTimeout: TimeInterval = 20,
        retryDelays: [TimeInterval] = [1.5],
        sleep: @escaping @Sendable (TimeInterval) -> Void = {
            Thread.sleep(forTimeInterval: $0)
        }
    ) {
        self.appServer = appServer
        self.fallback = fallback
        self.requestTimeout = requestTimeout
        self.retryDelays = retryDelays
        self.sleep = sleep
    }

    func currentSnapshot() -> QuotaSnapshot {
        let liveResult = readLiveRateLimits()
        switch liveResult.result {
        case let .success(reading):
            var snapshot = QuotaSnapshot(
                reading: reading,
                sourceName: "官方实时接口"
            )
            if liveResult.attempts > 1 {
                snapshot.sourceNote = "实时查询重试后第 \(liveResult.attempts) 次成功"
            }
            return snapshot
        case let .failure(error):
            let requiresLogin: Bool
            let executableMissing: Bool
            let transientFailure: Bool
            if let appServerError = error as? CodexAppServerError,
               case .chatGPTLoginRequired = appServerError {
                requiresLogin = true
            } else {
                requiresLogin = false
            }
            if let appServerError = error as? CodexAppServerError,
               case .executableNotFound = appServerError {
                executableMissing = true
            } else {
                executableMissing = false
            }
            transientFailure = (error as? CodexAppServerError)?.isTransient == true

            var snapshot = fallback.currentSnapshot()
            snapshot.requiresCodexLogin = requiresLogin
            if requiresLogin {
                snapshot.sourceName = snapshot.isUnavailable ? "请先登录 ChatGPT" : "会话日志（需登录）"
            } else if executableMissing {
                snapshot.sourceName = snapshot.isUnavailable ? "未找到新版 ChatGPT" : "会话日志（未找到新版 ChatGPT）"
            } else if transientFailure {
                snapshot.sourceName = snapshot.isUnavailable ? "实时接口暂时不可用" : "会话日志（实时查询异常）"
            } else {
                snapshot.sourceName = snapshot.isUnavailable ? "额度未获取" : "会话日志（降级）"
            }
            snapshot.sourceNote = Self.safeMessage(for: error, attempts: liveResult.attempts)
            if snapshot.isUnavailable, let cached = QuotaSnapshot.cached() {
                snapshot = cached
                snapshot.requiresCodexLogin = requiresLogin
                if requiresLogin {
                    snapshot.sourceName = "本机缓存（需登录）"
                } else if transientFailure {
                    snapshot.sourceName = "本机缓存（实时查询异常）"
                } else {
                    snapshot.sourceName = "本机缓存（降级）"
                }
                snapshot.sourceNote = Self.safeMessage(for: error, attempts: liveResult.attempts)
            }
            return snapshot
        }
    }

    private func readLiveRateLimits() -> (result: Result<QuotaReading, Error>, attempts: Int) {
        var attempts = 0
        while true {
            attempts += 1
            do {
                return (
                    .success(try appServer.readRateLimits(timeout: requestTimeout)),
                    attempts
                )
            } catch {
                guard let appServerError = error as? CodexAppServerError,
                      appServerError.isTransient,
                      attempts <= retryDelays.count else {
                    return (.failure(error), attempts)
                }
                let delay = retryDelays[attempts - 1]
                if delay > 0 {
                    sleep(delay)
                }
            }
        }
    }

    func setUpdateHandler(_ handler: (@Sendable (QuotaSnapshot) -> Void)?) {
        appServer.setUpdateHandler { reading in
            handler?(
                QuotaSnapshot(
                    reading: reading,
                    sourceName: "官方实时推送"
                )
            )
        }
    }

    private static func safeMessage(for error: Error, attempts: Int) -> String {
        let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if let appServerError = error as? CodexAppServerError,
           case .chatGPTLoginRequired = appServerError {
            return description
        }
        let attemptText = attempts > 1 ? "（已尝试 \(attempts) 次）" : ""
        return "实时查询失败\(attemptText)，已使用本地数据：\(description)"
    }
}

final class SessionLogMonitor: @unchecked Sendable {
    private let roots: [URL]
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.codexmeter.file-monitor", qos: .utility)
    private var sources: [DispatchSourceFileSystemObject] = []
    private var rebuildScheduled = false

    init(roots: [URL], onChange: @escaping @Sendable () -> Void) {
        self.roots = roots
        self.onChange = onChange
    }

    func start() {
        queue.async { [weak self] in
            self?.rebuildSources()
        }
    }

    deinit {
        sources.forEach { $0.cancel() }
    }

    private func rebuildSources() {
        sources.forEach { $0.cancel() }
        sources.removeAll()

        let paths = roots.filter { FileManager.default.fileExists(atPath: $0.path) }
            + recentSessionFiles(limit: 12)
        for url in paths {
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .rename, .delete],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.onChange()
                self.scheduleRebuild()
            }
            source.setCancelHandler {
                close(descriptor)
            }
            sources.append(source)
            source.resume()
        }
    }

    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.rebuildScheduled = false
            self.rebuildSources()
        }
    }

    private func recentSessionFiles(limit: Int) -> [URL] {
        var files: [(url: URL, date: Date)] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true,
                      let date = values.contentModificationDate else { continue }
                files.append((url, date))
            }
        }
        return files.sorted { $0.date > $1.date }.prefix(limit).map(\.url)
    }
}

struct QuotaSnapshot: Sendable {
    var remainingPercent: Int
    var weeklyRemainingPercent: Int
    var resetDate: Date
    var weeklyResetDate: Date
    var dataTimestamp: Date?
    var checkedAt: Date
    var primaryWindowMinutes: Int
    var weeklyWindowMinutes: Int
    var diagnostic: QuotaDiagnostic
    var sourceName: String
    var sourceNote: String?
    var requiresCodexLogin: Bool
    var isUnavailable: Bool

    init(reading: QuotaReading, sourceName: String) {
        let primary = reading.window(minutes: 300)
            ?? reading.window(minutes: 10_080)
            ?? reading.windows.min { $0.windowMinutes < $1.windowMinutes }
        let weekly = reading.window(minutes: 10_080)
            ?? reading.windows.max { $0.windowMinutes < $1.windowMinutes }

        guard let primary else {
            self = .unavailable(diagnostic: reading.diagnostic, checkedAt: reading.checkedAt, dataTimestamp: reading.dataTimestamp)
            return
        }
        let effectiveWeekly = weekly ?? primary
        remainingPercent = Self.remaining(from: primary.usedPercent)
        weeklyRemainingPercent = Self.remaining(from: effectiveWeekly.usedPercent)
        resetDate = primary.resetsAt
        weeklyResetDate = effectiveWeekly.resetsAt
        dataTimestamp = reading.dataTimestamp
        checkedAt = reading.checkedAt
        primaryWindowMinutes = primary.windowMinutes
        weeklyWindowMinutes = effectiveWeekly.windowMinutes
        diagnostic = reading.diagnostic
        self.sourceName = sourceName
        sourceNote = nil
        requiresCodexLogin = false
        isUnavailable = false
    }

    private init(
        remainingPercent: Int,
        weeklyRemainingPercent: Int,
        resetDate: Date,
        weeklyResetDate: Date,
        dataTimestamp: Date?,
        checkedAt: Date,
        primaryWindowMinutes: Int,
        weeklyWindowMinutes: Int,
        diagnostic: QuotaDiagnostic,
        sourceName: String,
        sourceNote: String?,
        requiresCodexLogin: Bool = false,
        isUnavailable: Bool
    ) {
        self.remainingPercent = remainingPercent
        self.weeklyRemainingPercent = weeklyRemainingPercent
        self.resetDate = resetDate
        self.weeklyResetDate = weeklyResetDate
        self.dataTimestamp = dataTimestamp
        self.checkedAt = checkedAt
        self.primaryWindowMinutes = primaryWindowMinutes
        self.weeklyWindowMinutes = weeklyWindowMinutes
        self.diagnostic = diagnostic
        self.sourceName = sourceName
        self.sourceNote = sourceNote
        self.requiresCodexLogin = requiresCodexLogin
        self.isUnavailable = isUnavailable
    }

    var hasSeparateWeeklyQuota: Bool {
        guard !isUnavailable else { return true }
        return primaryWindowMinutes != weeklyWindowMinutes
    }

    var primaryQuotaLabel: String {
        "\(windowLabel(minutes: primaryWindowMinutes))额度剩余"
    }

    var primaryQuotaShortLabel: String {
        primaryWindowMinutes == 300 ? "5h " : "\(windowLabel(minutes: primaryWindowMinutes))"
    }

    var primaryQuotaSpeechLabel: String {
        primaryWindowMinutes == 300 ? "五小时" : windowLabel(minutes: primaryWindowMinutes)
    }

    var freshness: QuotaFreshness? {
        dataTimestamp.map { QuotaFreshness.evaluate(dataTimestamp: $0, now: checkedAt) }
    }

    var freshnessLabel: String {
        switch freshness {
        case .current: "实时"
        case .delayed: "数据延迟"
        case .stale: "数据已过期"
        case nil: isUnavailable ? diagnostic.userMessage : "缺少数据时间"
        }
    }

    var menuBarTitle: String {
        guard !isUnavailable else { return "— | 无数据" }
        let prefix = freshness == .stale ? "! " : ""
        return "\(prefix)\(percentText) | \(shortResetText)"
    }

    var diagnosticText: String {
        if isUnavailable {
            return sourceNote.map { "\(diagnostic.userMessage) · \($0)" } ?? diagnostic.userMessage
        }
        guard let dataTimestamp else {
            return sourceNote ?? "额度可用，但缺少数据时间"
        }
        let dataText = dataTimestamp.formatted(date: .abbreviated, time: .shortened)
        let checkedText = checkedAt.formatted(date: .omitted, time: .shortened)
        let base = "数据 \(dataText) · 检查 \(checkedText) · \(freshnessLabel)"
        return sourceNote.map { "\(base) · \($0)" } ?? base
    }

    var percentText: String {
        isUnavailable ? "—" : "\(remainingPercent)%"
    }

    var weeklyPercentText: String {
        isUnavailable ? "—" : "\(weeklyRemainingPercent)%"
    }

    var displayRemainingPercent: Int {
        isUnavailable ? 0 : remainingPercent
    }

    var usedPercent: Int {
        100 - remainingPercent
    }

    var weeklyUsedPercent: Int {
        100 - weeklyRemainingPercent
    }

    var quotaObservations: [QuotaObservation] {
        guard !isUnavailable else { return [] }
        let observedAt = dataTimestamp ?? checkedAt
        var observations = [
            QuotaObservation(
                windowMinutes: primaryWindowMinutes,
                remainingPercent: remainingPercent,
                resetsAt: resetDate,
                observedAt: observedAt
            )
        ]
        if weeklyWindowMinutes != primaryWindowMinutes {
            observations.append(
                QuotaObservation(
                    windowMinutes: weeklyWindowMinutes,
                    remainingPercent: weeklyRemainingPercent,
                    resetsAt: weeklyResetDate,
                    observedAt: observedAt
                )
            )
        }
        return observations
    }

    static func cached() -> QuotaSnapshot? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: CacheKey.remainingPercent) != nil else {
            return nil
        }

        return QuotaSnapshot(
            remainingPercent: defaults.integer(forKey: CacheKey.remainingPercent),
            weeklyRemainingPercent: defaults.integer(forKey: CacheKey.weeklyRemainingPercent),
            resetDate: Date(timeIntervalSince1970: defaults.double(forKey: CacheKey.resetDate)),
            weeklyResetDate: Date(timeIntervalSince1970: defaults.double(forKey: CacheKey.weeklyResetDate)),
            dataTimestamp: defaults.object(forKey: CacheKey.dataTimestamp).map { _ in
                Date(timeIntervalSince1970: defaults.double(forKey: CacheKey.dataTimestamp))
            },
            checkedAt: Date(timeIntervalSince1970: defaults.double(forKey: CacheKey.checkedAt)),
            primaryWindowMinutes: defaults.object(forKey: CacheKey.primaryWindowMinutes) == nil ? 300 : defaults.integer(forKey: CacheKey.primaryWindowMinutes),
            weeklyWindowMinutes: defaults.object(forKey: CacheKey.weeklyWindowMinutes) == nil ? 10_080 : defaults.integer(forKey: CacheKey.weeklyWindowMinutes),
            diagnostic: .ready,
            sourceName: "本机缓存",
            sourceNote: nil,
            isUnavailable: false
        )
    }

    func cache() {
        guard !isUnavailable else { return }

        let defaults = UserDefaults.standard
        defaults.set(remainingPercent, forKey: CacheKey.remainingPercent)
        defaults.set(weeklyRemainingPercent, forKey: CacheKey.weeklyRemainingPercent)
        defaults.set(resetDate.timeIntervalSince1970, forKey: CacheKey.resetDate)
        defaults.set(weeklyResetDate.timeIntervalSince1970, forKey: CacheKey.weeklyResetDate)
        if let dataTimestamp {
            defaults.set(dataTimestamp.timeIntervalSince1970, forKey: CacheKey.dataTimestamp)
        }
        defaults.set(checkedAt.timeIntervalSince1970, forKey: CacheKey.checkedAt)
        defaults.set(primaryWindowMinutes, forKey: CacheKey.primaryWindowMinutes)
        defaults.set(weeklyWindowMinutes, forKey: CacheKey.weeklyWindowMinutes)
    }

    var tint: Color {
        guard !isUnavailable else { return .secondary }
        return Self.tint(for: remainingPercent)
    }

    var tagBackgroundColor: NSColor {
        guard !isUnavailable else { return NSColor(calibratedWhite: 1, alpha: 0.36) }
        return Self.tagBackgroundColor(for: remainingPercent)
    }

    var tagTextColor: NSColor {
        guard !isUnavailable else { return .labelColor }
        return Self.tagTextColor(for: remainingPercent)
    }

    var weeklyTint: Color {
        Self.tint(for: weeklyRemainingPercent)
    }

    private static func tint(for percent: Int) -> Color {
        switch percent {
        case 0...20:
            return .red
        case 21...45:
            return .yellow
        default:
            return .green
        }
    }

    private static func tagBackgroundColor(for percent: Int) -> NSColor {
        switch percent {
        case 0...20:
            return NSColor(calibratedRed: 1.0, green: 0.784, blue: 0.780, alpha: 0.92)
        case 21...45:
            return NSColor(calibratedRed: 0.973, green: 0.910, blue: 0.714, alpha: 0.92)
        default:
            return NSColor(calibratedRed: 0.722, green: 0.953, blue: 0.820, alpha: 0.92)
        }
    }

    private static func tagTextColor(for percent: Int) -> NSColor {
        switch percent {
        case 0...20:
            return NSColor(calibratedRed: 0.290, green: 0.071, blue: 0.075, alpha: 1)
        case 21...45:
            return NSColor(calibratedRed: 0.227, green: 0.176, blue: 0.043, alpha: 1)
        default:
            return NSColor(calibratedRed: 0.063, green: 0.247, blue: 0.157, alpha: 1)
        }
    }

    var resetText: String {
        guard !isUnavailable else { return "暂无重置信息" }
        return relativeResetText(for: resetDate)
    }

    var shortResetText: String {
        guard !isUnavailable else { return "—" }
        return compactResetText(for: resetDate)
    }

    var resetClockText: String {
        guard !isUnavailable else { return "未同步" }
        return resetDate.formatted(date: .omitted, time: .shortened)
    }

    var lastUpdatedText: String {
        diagnosticText
    }

    var weeklyResetDateText: String {
        guard !isUnavailable else { return "—" }
        let dateText = weeklyResetDate.formatted(
            Date.FormatStyle()
                .month(.wide)
                .day(.defaultDigits)
                .locale(Locale(identifier: "zh_CN"))
        )
        return "\(dateText)恢复"
    }

    private func relativeResetText(for date: Date) -> String {
        let seconds = max(Int(date.timeIntervalSinceNow), 0)
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 {
            return "\(days)天\(hours)小时后"
        }
        if hours > 0 {
            return "\(hours)小时\(minutes)分后"
        }
        return "\(minutes)分后"
    }

    private func compactResetText(for date: Date) -> String {
        let seconds = max(Int(date.timeIntervalSinceNow), 0)
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 {
            return "\(days)d\(hours)h"
        }
        if hours > 0 {
            return "\(hours)h\(minutes)m"
        }
        return "\(minutes)m"
    }

    static func unavailable(
        diagnostic: QuotaDiagnostic = .noQuotaEvents,
        checkedAt: Date = Date(),
        dataTimestamp: Date? = nil
    ) -> QuotaSnapshot {
        return QuotaSnapshot(
            remainingPercent: 0,
            weeklyRemainingPercent: 0,
            resetDate: checkedAt,
            weeklyResetDate: checkedAt,
            dataTimestamp: dataTimestamp,
            checkedAt: checkedAt,
            primaryWindowMinutes: 300,
            weeklyWindowMinutes: 10_080,
            diagnostic: diagnostic,
            sourceName: "额度未获取",
            sourceNote: nil,
            isUnavailable: true
        )
    }

    private static func remaining(from usedPercent: Double) -> Int {
        max(0, min(100, 100 - Int(usedPercent.rounded())))
    }

    private func windowLabel(minutes: Int) -> String {
        switch minutes {
        case 300: "5 小时"
        case 10_080: "周"
        case let value where value % 1_440 == 0: "\(value / 1_440) 天"
        case let value where value % 60 == 0: "\(value / 60) 小时"
        default: "\(minutes) 分钟"
        }
    }

}

private enum CacheKey {
    static let remainingPercent = "quota.remainingPercent"
    static let weeklyRemainingPercent = "quota.weeklyRemainingPercent"
    static let resetDate = "quota.resetDate"
    static let weeklyResetDate = "quota.weeklyResetDate"
    static let dataTimestamp = "quota.dataTimestamp"
    static let checkedAt = "quota.checkedAt"
    static let primaryWindowMinutes = "quota.primaryWindowMinutes"
    static let weeklyWindowMinutes = "quota.weeklyWindowMinutes"
    static let voiceBroadcastIntervalMinutes = "voiceBroadcast.intervalMinutes"
    static let notificationsEnabled = "notifications.enabled"
    static let notificationEnablePending = "notifications.enablePending"
    static let notifiedRecoveryFingerprints = "notifications.recoveryFingerprints"
}
