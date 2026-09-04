import Foundation

public struct QuotaWindow: Equatable, Sendable {
    public let usedPercent: Double
    public let resetsAt: Date
    public let windowMinutes: Int

    public init(usedPercent: Double, resetsAt: Date, windowMinutes: Int) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes
    }
}

public enum QuotaDiagnostic: String, Equatable, Sendable {
    case ready
    case noSessionDirectories
    case noSessionFiles
    case noQuotaEvents
    case unsupportedFormat
    case expired

    public var userMessage: String {
        switch self {
        case .ready: "额度数据可用"
        case .noSessionDirectories: "未找到 Codex 会话目录"
        case .noSessionFiles: "未找到 Codex 会话日志"
        case .noQuotaEvents: "日志中尚无额度记录"
        case .unsupportedFormat: "发现额度记录，但格式暂不兼容"
        case .expired: "额度记录已过期，等待 Codex 写入新数据"
        }
    }
}

public enum QuotaFreshness: String, Equatable, Sendable {
    case current
    case delayed
    case stale

    public static func evaluate(dataTimestamp: Date, now: Date) -> QuotaFreshness {
        let age = max(0, now.timeIntervalSince(dataTimestamp))
        if age <= 5 * 60 { return .current }
        if age <= 30 * 60 { return .delayed }
        return .stale
    }
}

public struct QuotaReading: Equatable, Sendable {
    public let resetCredits: ResetCredits?
    public let windows: [QuotaWindow]
    public let dataTimestamp: Date?
    public let checkedAt: Date
    public let diagnostic: QuotaDiagnostic
    public let quotaEventCount: Int

    public init(
        windows: [QuotaWindow],
        dataTimestamp: Date?,
        checkedAt: Date,
        diagnostic: QuotaDiagnostic,
        quotaEventCount: Int,
        resetCredits: ResetCredits? = nil
    ) {
        self.windows = windows
        self.dataTimestamp = dataTimestamp
        self.checkedAt = checkedAt
        self.diagnostic = diagnostic
        self.quotaEventCount = quotaEventCount
        self.resetCredits = resetCredits
    }

    public var freshness: QuotaFreshness? {
        dataTimestamp.map { QuotaFreshness.evaluate(dataTimestamp: $0, now: checkedAt) }
    }

    public func window(minutes: Int) -> QuotaWindow? {
        windows.first { $0.windowMinutes == minutes }
    }
}

public struct QuotaLogParser: Sendable {
    public init() {}

    public func parse(lines: [String], now: Date = Date()) -> QuotaReading {
        var candidates: [WindowCandidate] = []
        var quotaEventCount = 0
        var aggregateEventCount = 0

        for line in lines {
            guard line.contains("\"rate_limits\"") else { continue }
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let rateLimits = payload["rate_limits"] as? [String: Any] else {
                continue
            }
            quotaEventCount += 1
            guard (rateLimits["limit_id"] as? String) == "codex" else { continue }
            aggregateEventCount += 1
            let timestamp = Self.parseDate(object["timestamp"] as? String)
            candidates.append(contentsOf: Self.extractWindows(from: rateLimits, timestamp: timestamp))
        }

        guard quotaEventCount > 0 else {
            return QuotaReading(windows: [], dataTimestamp: nil, checkedAt: now, diagnostic: .noQuotaEvents, quotaEventCount: 0)
        }
        guard aggregateEventCount > 0, !candidates.isEmpty else {
            return QuotaReading(windows: [], dataTimestamp: nil, checkedAt: now, diagnostic: .unsupportedFormat, quotaEventCount: quotaEventCount)
        }

        let active = candidates.filter { $0.window.resetsAt > now }
        guard !active.isEmpty else {
            return QuotaReading(
                windows: [],
                dataTimestamp: candidates.compactMap(\.timestamp).max(),
                checkedAt: now,
                diagnostic: .expired,
                quotaEventCount: quotaEventCount
            )
        }

        let durations = Set(active.map { $0.window.windowMinutes })
        let windows = durations.compactMap { duration -> QuotaWindow? in
            let durationCandidates = active.filter { $0.window.windowMinutes == duration }
            guard let latestReset = durationCandidates.map({ $0.window.resetsAt }).max() else { return nil }
            let sameWindow = durationCandidates.filter {
                abs($0.window.resetsAt.timeIntervalSince(latestReset)) <= 120
            }
            return sameWindow.max { lhs, rhs in
                if lhs.window.usedPercent == rhs.window.usedPercent {
                    return (lhs.timestamp ?? .distantPast) < (rhs.timestamp ?? .distantPast)
                }
                return lhs.window.usedPercent < rhs.window.usedPercent
            }?.window
        }.sorted { $0.windowMinutes < $1.windowMinutes }

        let matchingTimestamps = active.compactMap(\.timestamp)
        return QuotaReading(
            windows: windows,
            dataTimestamp: matchingTimestamps.max(),
            checkedAt: now,
            diagnostic: .ready,
            quotaEventCount: quotaEventCount
        )
    }

    private static func extractWindows(from rateLimits: [String: Any], timestamp: Date?) -> [WindowCandidate] {
        ["primary", "secondary", "individual_limit"].flatMap { key -> [WindowCandidate] in
            guard let value = rateLimits[key] else { return [] }
            return extractWindowsRecursively(from: value, timestamp: timestamp, depth: 0)
        }
    }

    private static func extractWindowsRecursively(from value: Any, timestamp: Date?, depth: Int) -> [WindowCandidate] {
        guard depth < 4 else { return [] }
        if let dictionary = value as? [String: Any] {
            if let usedPercent = number(dictionary["used_percent"]),
               let resetsAt = number(dictionary["resets_at"]),
               let windowMinutes = integer(dictionary["window_minutes"]),
               (0...100).contains(usedPercent),
               windowMinutes > 0 {
                return [WindowCandidate(
                    window: QuotaWindow(
                        usedPercent: usedPercent,
                        resetsAt: Date(timeIntervalSince1970: resetsAt),
                        windowMinutes: windowMinutes
                    ),
                    timestamp: timestamp
                )]
            }
            return dictionary.values.flatMap { extractWindowsRecursively(from: $0, timestamp: timestamp, depth: depth + 1) }
        }
        if let array = value as? [Any] {
            return array.flatMap { extractWindowsRecursively(from: $0, timestamp: timestamp, depth: depth + 1) }
        }
        return []
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

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

public struct SessionQuotaReader: Sendable {
    private let parser = QuotaLogParser()

    public init() {}

    public func read(
        roots: [URL],
        now: Date = Date(),
        maxFiles: Int = 40,
        maxBytesPerFile: UInt64 = 512 * 1024
    ) -> QuotaReading {
        let existingRoots = roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existingRoots.isEmpty else {
            return QuotaReading(windows: [], dataTimestamp: nil, checkedAt: now, diagnostic: .noSessionDirectories, quotaEventCount: 0)
        }

        let files = existingRoots
            .flatMap(recentJSONLFiles)
            .sorted {
                if $0.isSubagent != $1.isSubagent {
                    return !$0.isSubagent
                }
                return $0.modifiedAt > $1.modifiedAt
            }
        guard !files.isEmpty else {
            return QuotaReading(windows: [], dataTimestamp: nil, checkedAt: now, diagnostic: .noSessionFiles, quotaEventCount: 0)
        }

        var lines: [String] = []
        for file in files.prefix(maxFiles) {
            guard let tail = readTail(from: file.url, maxBytes: maxBytesPerFile) else { continue }
            lines.append(contentsOf: tail.split(separator: "\n").map(String.init))
        }
        return parser.parse(lines: lines, now: now)
    }

    private func recentJSONLFiles(under root: URL) -> [SessionFile] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [SessionFile] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate else { continue }
            files.append(
                SessionFile(
                    url: url,
                    modifiedAt: modifiedAt,
                    isSubagent: url.pathComponents.contains("subagents")
                )
            )
        }
        return files
    }

    private func readTail(from url: URL, maxBytes: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > maxBytes ? size - maxBytes : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

private struct WindowCandidate {
    let window: QuotaWindow
    let timestamp: Date?
}

private struct SessionFile {
    let url: URL
    let modifiedAt: Date
    let isSubagent: Bool
}
