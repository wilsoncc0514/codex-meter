import Foundation

public enum AppServerQuotaParser {
    public static func parse(result: [String: Any], now: Date = Date()) -> QuotaReading? {
        let buckets = quotaBuckets(in: result)
        let preferred = buckets.first(where: { bucket in
            string(bucket["limitId"] ?? bucket["limit_id"]) == "codex"
        }) ?? buckets.first
        guard let preferred else { return nil }

        let windows = ["primary", "secondary"]
            .compactMap { window(from: preferred[$0]) }
            .sorted { $0.windowMinutes < $1.windowMinutes }
        guard !windows.isEmpty else { return nil }

        return QuotaReading(
            windows: windows,
            dataTimestamp: now,
            checkedAt: now,
            diagnostic: .ready,
            quotaEventCount: 1
        )
    }

    private static func quotaBuckets(in result: [String: Any]) -> [[String: Any]] {
        var buckets: [[String: Any]] = []
        if let rateLimits = dictionary(result["rateLimits"] ?? result["rate_limits"]) {
            buckets.append(rateLimits)
        }
        if let byID = dictionary(result["rateLimitsByLimitId"] ?? result["rate_limits_by_limit_id"]) {
            buckets.append(contentsOf: byID.values.compactMap(dictionary))
        }
        return buckets
    }

    private static func window(from value: Any?) -> QuotaWindow? {
        guard let object = dictionary(value),
              let usedPercent = number(object["usedPercent"] ?? object["used_percent"]),
              let resetsAt = number(object["resetsAt"] ?? object["resets_at"]),
              let minutes = integer(
                object["windowDurationMins"]
                    ?? object["windowMinutes"]
                    ?? object["window_minutes"]
              ),
              (0...100).contains(usedPercent),
              minutes > 0 else {
            return nil
        }
        return QuotaWindow(
            usedPercent: usedPercent,
            resetsAt: Date(timeIntervalSince1970: resetsAt),
            windowMinutes: minutes
        )
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let value as Double: value
        case let value as Int: Double(value)
        case let value as String: Double(value)
        default: nil
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        switch value {
        case let value as Int: value
        case let value as Double: Int(value)
        case let value as String: Int(value)
        default: nil
        }
    }
}
