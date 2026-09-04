import Foundation

/// Read-only earned reset information. Never infer the count from detail rows.
public struct ResetCredits: Equatable, Sendable {
    public struct Credit: Equatable, Sendable {
        public let expiresAt: Date?
    }

    public let availableCount: Int
    public let credits: [Credit]?
    public let detailsIncomplete: Bool

    public static func parse(_ value: Any?) -> ResetCredits? {
        struct Count: Decodable { let availableCount: Int }
        struct Detail: Decodable { let status: String; let expiresAt: Double? }
        guard let object = value as? [String: Any],
              let countData = try? JSONSerialization.data(withJSONObject: ["availableCount": object["availableCount"] ?? NSNull()]),
              let count = try? JSONDecoder().decode(Count.self, from: countData).availableCount,
              count >= 0 else { return nil }
        guard let rows = object["credits"] as? [Any] else {
            return Self(availableCount: count, credits: nil, detailsIncomplete: count > 0)
        }
        // Bound rendering and parsing independently of an untrusted service response.
        let details: [Credit] = rows.prefix(100).compactMap { row in
            guard JSONSerialization.isValidJSONObject(row),
                  let data = try? JSONSerialization.data(withJSONObject: row),
                  let detail = try? JSONDecoder().decode(Detail.self, from: data),
                  detail.status == "available" else { return nil }
            if let expiry = detail.expiresAt {
                guard expiry.isFinite, (0...253_402_300_799).contains(expiry) else { return nil }
                return Credit(expiresAt: Date(timeIntervalSince1970: expiry))
            }
            return Credit(expiresAt: nil)
        }.sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        return Self(
            availableCount: count,
            credits: Array(details.prefix(count)),
            detailsIncomplete: rows.count != details.count || details.count != count
        )
    }
}
