import SwiftUI
import CodexMeterCore

struct ResetCreditsDetails: View {
    let summary: ResetCredits?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("使用限额重置").fontWeight(.semibold)
                Spacer()
                Text(summary.map { "可用 \($0.availableCount) 次" } ?? "暂不可用")
                    .foregroundStyle(summary == nil ? Color.secondary : Color.green)
            }
            if let summary {
                if summary.availableCount == 0 {
                    Text("当前没有可用重置卡").foregroundStyle(.secondary)
                } else if let credits = summary.credits, !credits.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(credits.enumerated()), id: \.offset) { index, credit in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("\(index + 1).").foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        if let expiry = credit.expiresAt {
                                            Text("\(Self.expiryText(expiry)) 到期")
                                                .foregroundStyle(.secondary)
                                            if expiry <= Date() {
                                                Text("已到期，请刷新确认可用次数")
                                                    .foregroundStyle(.orange)
                                            }
                                        } else {
                                            Text("到期时间未提供").foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .frame(minHeight: 30, alignment: .topLeading)
                                Divider()
                            }
                        }
                    }
                    .frame(height: min(CGFloat(credits.count) * 44, 88))
                    if credits.count > 2 {
                        Text("共 \(credits.count) 张，可滚动查看").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if summary.availableCount > 0 && (summary.credits == nil || summary.detailsIncomplete) {
                    Text("接口未提供完整明细；可用次数以服务端为准。")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("未获取重置卡数据。请刷新；旧版接口、离线日志和额度缓存可能不提供此信息。")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
    }

    static func expiryText(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = .current
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMdjmm" : "yMMMdjmm")
        return formatter.string(from: date)
    }
}
