import AppKit
import CodexMeterCore
import Darwin
import Foundation

protocol AppServerQuotaClient: Sendable {
    func readRateLimits(timeout: TimeInterval) throws -> QuotaReading
    func setUpdateHandler(_ handler: CodexAppServerClient.UpdateHandler?)
}

enum CodexAppServerError: Error, LocalizedError {
    case executableNotFound(String)
    case launchFailed(String)
    case requestTimedOut(method: String, seconds: TimeInterval)
    case connectionClosed(String?)
    case chatGPTLoginRequired(currentAccountType: String?)
    case serverError(code: Int, message: String)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case let .executableNotFound(details):
            "未找到 ChatGPT.app 内置 CLI：\(details)"
        case let .launchFailed(message):
            "无法启动 ChatGPT CLI：\(message)"
        case let .requestTimedOut(method, seconds):
            "ChatGPT App Server 在 \(method) 阶段等待超过 \(Int(seconds)) 秒"
        case let .connectionClosed(details):
            if let details, !details.isEmpty {
                "ChatGPT App Server 连接已关闭：\(details)"
            } else {
                "ChatGPT App Server 连接已关闭"
            }
        case let .chatGPTLoginRequired(accountType):
            accountType == nil
                ? "ChatGPT 尚未登录"
                : "当前账户模式为 \(accountType ?? "unknown")，需要 ChatGPT 登录"
        case let .serverError(code, message):
            "ChatGPT App Server 错误 \(code)：\(message)"
        case .unexpectedResponse:
            "ChatGPT App Server 返回了无法识别的数据"
        }
    }

    var isTransient: Bool {
        switch self {
        case .requestTimedOut, .connectionClosed:
            true
        case let .serverError(_, message):
            message.localizedCaseInsensitiveContains("fetch")
                || message.localizedCaseInsensitiveContains("network")
                || message.localizedCaseInsensitiveContains("timed out")
                || message.localizedCaseInsensitiveContains("connection")
        default:
            false
        }
    }
}

final class CodexAppServerClient: @unchecked Sendable, AppServerQuotaClient {
    typealias UpdateHandler = @Sendable (QuotaReading) -> Void

    func readRateLimits(timeout: TimeInterval) throws -> QuotaReading {
        guard let executable = ChatGPTCLIExecutableLocator.resolve() else {
            throw CodexAppServerError.executableNotFound(
                ChatGPTCLIExecutableLocator.failureDetails
            )
        }

        let session = AppServerSession(executable: executable)
        defer { session.close() }
        try session.start()

        _ = try session.request(
            id: 1,
            method: "initialize",
            params: [
                "clientInfo": [
                    "name": "codex_meter",
                    "title": "Codex 额度",
                    "version": "0.4"
                ],
                "capabilities": [:]
            ],
            timeout: timeout
        )
        try session.notify(method: "initialized", params: [:])

        let accountResult = try session.request(
            id: 2,
            method: "account/read",
            params: ["refreshToken": false],
            timeout: timeout
        )
        guard let account = accountResult["account"] as? [String: Any] else {
            throw CodexAppServerError.chatGPTLoginRequired(currentAccountType: nil)
        }
        let accountType = account["type"] as? String
        guard accountType == "chatgpt" else {
            throw CodexAppServerError.chatGPTLoginRequired(currentAccountType: accountType)
        }

        let result = try session.request(
            id: 3,
            method: "account/rateLimits/read",
            params: nil,
            timeout: timeout
        )
        guard let reading = AppServerQuotaParser.parse(result: result) else {
            throw CodexAppServerError.unexpectedResponse
        }
        return reading
    }

    func setUpdateHandler(_ handler: UpdateHandler?) {
        // Each refresh uses a short-lived ChatGPT App Server process.
        // The 60-second timer and session-log monitor provide bounded updates.
    }
}

final class AppServerSession: @unchecked Sendable {
    private let executable: URL
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errorOutput = Pipe()
    private let condition = NSCondition()
    private var buffer = Data()
    private var stderrBuffer = Data()
    private var responses: [Int: Result<[String: Any], Error>] = [:]
    private var closed = false

    init(executable: URL) {
        self.executable = executable
    }

    var isRunning: Bool {
        process.isRunning
    }

    func start() throws {
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        errorOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeStderr(handle.availableData)
        }
        process.terminationHandler = { [weak self] _ in
            self?.markClosed()
        }

        do {
            try process.run()
        } catch {
            throw CodexAppServerError.launchFailed(error.localizedDescription)
        }
    }

    func notify(method: String, params: [String: Any]) throws {
        try write(["method": method, "params": params])
    }

    func request(
        id: Int,
        method: String,
        params: [String: Any]?,
        timeout: TimeInterval
    ) throws -> [String: Any] {
        var message: [String: Any] = ["id": id, "method": method]
        if let params {
            message["params"] = params
        }
        try write(message)

        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while responses[id] == nil, !closed {
            if !condition.wait(until: deadline) {
                throw CodexAppServerError.requestTimedOut(
                    method: method,
                    seconds: timeout
                )
            }
        }
        guard let response = responses.removeValue(forKey: id) else {
            throw CodexAppServerError.connectionClosed(stderrText())
        }
        return try response.get()
    }

    func close() {
        output.fileHandleForReading.readabilityHandler = nil
        errorOutput.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
        }
        try? output.fileHandleForReading.close()
        try? errorOutput.fileHandleForReading.close()
    }

    private func write(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        input.fileHandleForWriting.write(data)
        input.fileHandleForWriting.write(Data([0x0A]))
    }

    private func consume(_ data: Data) {
        guard !data.isEmpty else {
            markClosed()
            return
        }
        condition.lock()
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = object["id"] as? Int else {
                continue
            }
            if let error = object["error"] as? [String: Any] {
                let code = error["code"] as? Int ?? -1
                let message = error["message"] as? String ?? "unknown error"
                responses[id] = .failure(
                    CodexAppServerError.serverError(code: code, message: message)
                )
            } else if let result = object["result"] as? [String: Any] {
                responses[id] = .success(result)
            } else {
                responses[id] = .failure(CodexAppServerError.unexpectedResponse)
            }
        }
        condition.broadcast()
        condition.unlock()
    }

    private func markClosed() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    private func consumeStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        condition.lock()
        if stderrBuffer.count < 8 * 1024 {
            stderrBuffer.append(data.prefix(8 * 1024 - stderrBuffer.count))
        }
        condition.unlock()
    }

    private func stderrText() -> String? {
        let text = String(decoding: stderrBuffer, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(800))
    }
}

enum ChatGPTCLIExecutableLocator {
    static let bundleIdentifiers = [
        "com.openai.codex",
        "com.openai.chat",
        "com.openai.chatgpt"
    ]

    static var failureDetails: String {
        "只检查 ChatGPT.app，不再检查 Codex.app、PATH、Homebrew 或独立 codex CLI"
    }

    static func resolve(
        fileManager: FileManager = .default,
        workspace: NSWorkspace = .shared
    ) -> URL? {
        let registeredApps = bundleIdentifiers.compactMap {
            workspace.urlForApplication(withBundleIdentifier: $0)
        }
        let home = fileManager.homeDirectoryForCurrentUser
        let apps = registeredApps + [
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            home.appendingPathComponent("Applications/ChatGPT.app")
        ]
        return find(in: apps, fileManager: fileManager)
    }

    static func find(in appURLs: [URL], fileManager: FileManager = .default) -> URL? {
        var seen = Set<String>()
        for appURL in appURLs where seen.insert(appURL.standardizedFileURL.path).inserted {
            guard isChatGPTBundle(appURL, fileManager: fileManager) else { continue }
            let candidates = [
                appURL.appendingPathComponent("Contents/Resources/codex"),
                appURL.appendingPathComponent("Contents/Resources/codex/codex")
            ]
            if let executable = candidates.first(where: {
                fileManager.isExecutableFile(atPath: $0.path)
            }) {
                return executable
            }
        }
        return nil
    }

    private static func isChatGPTBundle(
        _ appURL: URL,
        fileManager: FileManager
    ) -> Bool {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = fileManager.contents(atPath: infoURL.path),
              let info = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any] else {
            return false
        }
        let names = [
            info["CFBundleName"] as? String,
            info["CFBundleDisplayName"] as? String
        ].compactMap { $0?.lowercased() }
        return names.contains("chatgpt")
    }

    static func diagnosticExecutablePath() -> String {
        resolve()?.path ?? "not found (\(failureDetails))"
    }
}
