import Foundation
import Testing
@testable import CodexMeter

struct ChatGPTCLIExecutableLocatorTests {
    @Test func findsOnlyExecutableInsideProvidedChatGPTBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("ChatGPT.app")
        let executable = app.appendingPathComponent("Contents/Resources/codex")
        let info = app.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleName": "ChatGPT"],
            format: .xml,
            options: 0
        )
        #expect(FileManager.default.createFile(atPath: info.path, contents: infoData))
        #expect(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(
            ChatGPTCLIExecutableLocator.find(in: [app])?.standardizedFileURL
                == executable.standardizedFileURL
        )
    }

    @Test func doesNotSearchStandaloneCodexCLI() {
        #expect(ChatGPTCLIExecutableLocator.find(in: []) == nil)
        #expect(ChatGPTCLIExecutableLocator.failureDetails.contains("PATH"))
        #expect(ChatGPTCLIExecutableLocator.failureDetails.contains("独立 codex CLI"))
    }

    @Test func rejectsOldCodexAppEvenWhenItContainsAnExecutable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Codex.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleName": "Codex"],
            format: .xml,
            options: 0
        )
        #expect(
            FileManager.default.createFile(
                atPath: app.appendingPathComponent("Contents/Info.plist").path,
                contents: infoData
            )
        )
        let executable = resources.appendingPathComponent("codex")
        #expect(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(ChatGPTCLIExecutableLocator.find(in: [app]) == nil)
    }
}
