import Foundation
import SwiftUI

/// Public reporting is separate from account entitlements and never changes quota.
struct PublicResetEvent: Decodable, Equatable, Sendable {
    struct Schedule: Decodable, Equatable, Sendable {
        let from: Date
        let through: Date
    }
    let id: String
    let status: String
    let title: String
    let updatedAt: Date
    let confirmedAt: Date?
    let schedule: Schedule?

    func isCurrent(at now: Date) -> Bool {
        switch status {
        case "confirmed":
            let age = now.timeIntervalSince(confirmedAt ?? updatedAt)
            return age >= 0 && age <= 24 * 3600
        case "announced":
            if let schedule { return schedule.from <= schedule.through && now <= schedule.through }
            let age = now.timeIntervalSince(updatedAt)
            return age >= 0 && age <= 48 * 3600
        default: return false
        }
    }

    static func current(_ events: [Self], now: Date) -> Self? {
        events.filter { $0.isCurrent(at: now) }.sorted { a, b in
            if (a.status == "confirmed") != (b.status == "confirmed") { return a.status == "confirmed" }
            if a.status == "confirmed" { return (a.confirmedAt ?? a.updatedAt) > (b.confirmedAt ?? b.updatedAt) }
            let aActive = a.schedule.map { $0.from <= now && now <= $0.through } ?? false
            let bActive = b.schedule.map { $0.from <= now && now <= $0.through } ?? false
            if aActive != bActive { return aActive }
            if let x = a.schedule?.from, let y = b.schedule?.from, x != y { return x < y }
            return a.updatedAt > b.updatedAt
        }.first
    }
}

enum PublicResetNewsState: Equatable {
    case loading
    case unavailable
    case empty
    case event(PublicResetEvent, stale: Bool)
}

actor PublicResetNewsService {
    private static let endpoint = URL(string: "https://aihot.news/api/v1/codex-resets")!
    private var lastEvent: PublicResetEvent?
    private var nextAllowedAt: Date?

    func fetch(now: Date = Date()) async -> PublicResetNewsState {
        if let nextAllowedAt, now < nextAllowedAt { return fallback(now: now) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: Self.endpoint)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { return fallback(now: now) }
            if http.statusCode == 429 {
                nextAllowedAt = Self.retryDate(http.value(forHTTPHeaderField: "Retry-After"), now: now)
                return fallback(now: now)
            }
            guard (200..<300).contains(http.statusCode),
                  response.expectedContentLength <= 1_000_000 else {
                return fallback(now: now)
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 1_000_000 else { return fallback(now: now) }
                data.append(byte)
            }
            let event = try Self.decode(data, now: now)
            nextAllowedAt = nil
            lastEvent = event
            return event.map { .event($0, stale: false) } ?? .empty
        } catch {
            return fallback(now: now)
        }
    }

    private func fallback(now: Date) -> PublicResetNewsState {
        guard let lastEvent, lastEvent.isCurrent(at: now) else { return .unavailable }
        return .event(lastEvent, stale: true)
    }

    static func retryDate(_ value: String?, now: Date) -> Date {
        if let value, let seconds = TimeInterval(value), seconds.isFinite {
            return now.addingTimeInterval(max(15 * 60, min(seconds, 24 * 3600)))
        }
        if let value {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
            if let date = formatter.date(from: value) {
                return now.addingTimeInterval(max(15 * 60, min(date.timeIntervalSince(now), 24 * 3600)))
            }
        }
        return now.addingTimeInterval(15 * 60)
    }

    static func decode(_ data: Data, now: Date) throws -> PublicResetEvent? {
        struct Snapshot: Decodable { let events: [PublicResetEvent] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid timestamp"))
            }
            return date
        }
        let snapshot = try decoder.decode(Snapshot.self, from: data)
        return PublicResetEvent.current(Array(snapshot.events.prefix(200)), now: now)
    }
}

struct PublicResetNewsView: View {
    let state: PublicResetNewsState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("公开重置消息").fontWeight(.semibold)
                Spacer()
                Link("AIhot ↗", destination: URL(string: "https://aihot.news/codex-reset")!)
            }
            switch state {
            case .loading: Text("正在获取公开消息…").foregroundStyle(.secondary)
            case .unavailable: Text("消息暂不可用，请稍后重试").foregroundStyle(.secondary)
            case .empty: Text("暂无有效公开消息").foregroundStyle(.secondary)
            case let .event(event, stale):
                Text("\(event.status == "confirmed" ? "已报道" : "预告") · \(event.title)\(stale ? " · 可能过期" : "")")
                    .lineLimit(1)
                    .foregroundStyle(event.status == "confirmed" ? Color.green : Color.orange)
                if event.status == "announced", let schedule = event.schedule {
                    Text("预计：\(schedule.from.formatted(date: .abbreviated, time: .shortened)) – \(schedule.through.formatted(date: .abbreviated, time: .shortened))")
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                } else if event.status == "confirmed", let date = event.confirmedAt {
                    Text("报道时间：\(date.formatted(date: .abbreviated, time: .shortened))")
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
            }
            Text("第三方报道，不代表本账户已到账")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
        .accessibilityElement(children: .contain)
    }
}
