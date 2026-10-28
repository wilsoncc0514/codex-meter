import Foundation
import Testing
@testable import CodexMeter

struct AppServerSessionTests {
    @Test func closedOutputFailsPromptlyAndReapsChild() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("closed-output.sh")
        #expect(FileManager.default.createFile(atPath: executable.path, contents: Data("#!/bin/sh\nexec 1>&-\nsleep 10\n".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let session = AppServerSession(executable: executable)
        try session.start()
        defer { session.close() }
        let started = Date()
        do {
            _ = try session.request(id: 1, method: "initialize", params: nil, timeout: 3)
            Issue.record("Expected closed connection")
        } catch let error as CodexAppServerError {
            guard case .connectionClosed = error else { Issue.record("Unexpected error: \(error)"); return }
            #expect(Date().timeIntervalSince(started) < 2)
        }
    }
    @Test func timeoutIdentifiesMethodAndCloseReapsHungChild() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = root.appendingPathComponent("hung-app-server.sh")
        let script = "#!/bin/sh\ntrap '' TERM\nsleep 30\n"
        #expect(
            FileManager.default.createFile(
                atPath: executable.path,
                contents: Data(script.utf8)
            )
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let session = AppServerSession(executable: executable)
        try session.start()
        do {
            _ = try session.request(
                id: 1,
                method: "account/rateLimits/read",
                params: nil,
                timeout: 0.05
            )
            Issue.record("Expected request timeout")
        } catch let error as CodexAppServerError {
            guard case let .requestTimedOut(method, _) = error else {
                Issue.record("Unexpected App Server error: \(error)")
                session.close()
                return
            }
            #expect(method == "account/rateLimits/read")
        }

        session.close()
        #expect(!session.isRunning)
    }
}
