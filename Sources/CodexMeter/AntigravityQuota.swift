import Darwin
import Foundation
import SwiftUI

struct AntigravityWindow: Equatable, Sendable {
    let group: String
    let window: String
    let remaining: Int
    let reset: Date?
}

enum AntigravityStatus: Equatable, Sendable {
    case loading
    case unavailable
    case ready([AntigravityWindow])
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor AntigravityQuotaService {
    private struct Endpoint: Decodable { let pid: Int32?; let httpPort: Int; let csrfToken: String }
    private struct Response: Decodable { struct Body: Decodable { let groups: [Group] }; let response: Body }
    private struct Group: Decodable { let displayName: String?; let buckets: [Bucket] }
    private struct Bucket: Decodable { let window: String?; let remainingFraction: Double; let resetTime: String? }

    static func parse(_ data: Data) throws -> [AntigravityWindow] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        let result = response.response.groups.prefix(20).flatMap { group in
            group.buckets.prefix(20).compactMap { bucket -> AntigravityWindow? in
                guard let window = bucket.window, bucket.remainingFraction.isFinite,
                      (0...1).contains(bucket.remainingFraction) else { return nil }
                let reset = bucket.resetTime.flatMap { dateFormatter.date(from: $0) ?? fallback.date(from: $0) }
                return AntigravityWindow(group: String((group.displayName ?? "模型额度").prefix(80)),
                                         window: String(window.prefix(40)),
                                         remaining: Int((bucket.remainingFraction * 100).rounded()), reset: reset)
            }
        }
        return result
    }

    func fetch() async -> AntigravityStatus {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity/daemon")
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        for file in files.filter({ $0.pathExtension == "json" }).prefix(16) {
            guard let attrs = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  attrs.isRegularFile == true, (attrs.fileSize ?? .max) <= 65536,
                  let data = try? Data(contentsOf: file), let endpoint = try? JSONDecoder().decode(Endpoint.self, from: data),
                  (1...65535).contains(endpoint.httpPort), !endpoint.csrfToken.isEmpty,
                  endpoint.pid.map({ $0 > 0 && (kill($0, 0) == 0 || errno == EPERM) }) ?? true,
                  let url = URL(string: "http://127.0.0.1:\(endpoint.httpPort)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(endpoint.csrfToken, forHTTPHeaderField: "x-codeium-csrf-token")
            request.httpBody = Data("{}".utf8)
            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200, response.expectedContentLength <= 1_000_000 else { continue }
                var body = Data()
                for try await byte in bytes {
                    guard body.count < 1_000_000 else { return .unavailable }
                    body.append(byte)
                }
                let windows = try Self.parse(body)
                if !windows.isEmpty { return .ready(windows) }
            } catch { continue }
        }
        return .unavailable
    }
}

struct AntigravityQuotaView: View {
    let status: AntigravityStatus

    private func label(_ window: String) -> String {
        switch window.lowercased() {
        case "5h": "5 小时"
        case "weekly": "周"
        default: window
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Antigravity").fontWeight(.semibold)
            switch status {
            case .loading: Text("正在读取本机额度…").foregroundStyle(.secondary)
            case .unavailable: Text("额度暂不可用，请确认 Antigravity 已打开并登录").foregroundStyle(.secondary)
            case let .ready(windows):
                ForEach(Array(windows.enumerated()), id: \.offset) { _, item in
                    HStack {
                        Text("\(item.group) · \(label(item.window))").lineLimit(1)
                        Spacer()
                        Text("\(item.remaining)% 剩余").monospacedDigit()
                    }
                    if let reset = item.reset {
                        Text("恢复：\(reset.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .contain)
    }
}
