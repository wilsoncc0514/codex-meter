import Foundation
import Testing
@testable import CodexMeter

struct ExecutableIdentityTests {
    @Test func detectsExecutableReplacement() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("CodexMeter")

        #expect(FileManager.default.createFile(atPath: executable.path, contents: Data("old".utf8)))
        let original = try #require(
            ExecutableIdentity.current(executableURL: executable)
        )

        try FileManager.default.removeItem(at: executable)
        #expect(FileManager.default.createFile(atPath: executable.path, contents: Data("new-build".utf8)))
        let replacement = try #require(
            ExecutableIdentity.current(executableURL: executable)
        )

        #expect(replacement != original)
    }

    @Test func keepsIdentityStableForAnUnchangedExecutable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("codex")
        #expect(FileManager.default.createFile(atPath: executable.path, contents: Data("same".utf8)))

        let first = try #require(ExecutableIdentity.current(executableURL: executable))
        let second = try #require(ExecutableIdentity.current(executableURL: executable))
        #expect(first == second)
    }
}
