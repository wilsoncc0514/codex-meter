import Foundation
import Testing
@testable import CodexMeter

struct ChatGPTCLIExecutableLocatorTests {
    @Test func findsExecutableInsideOfficialChatGPTBundle() throws {
        let fixture = try makeApp(named: "ChatGPT", bundleIdentifier: "com.openai.codex")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(
            ChatGPTCLIExecutableLocator.find(in: [fixture.app])?.standardizedFileURL
                == fixture.executable.standardizedFileURL
        )
    }

    @Test func findsExecutableInsideOfficialCodexBundle() throws {
        let fixture = try makeApp(named: "Codex", bundleIdentifier: "com.openai.codex")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(
            ChatGPTCLIExecutableLocator.find(in: [fixture.app])?.standardizedFileURL
                == fixture.executable.standardizedFileURL
        )
    }

    @Test func skipsRegisteredHostWithoutCLIAndFindsCodexHost() throws {
        let chatGPT = try makeApp(
            named: "ChatGPT",
            bundleIdentifier: "com.openai.codex",
            executable: false
        )
        let codex = try makeApp(named: "Codex", bundleIdentifier: "com.openai.codex")
        defer {
            try? FileManager.default.removeItem(at: chatGPT.root)
            try? FileManager.default.removeItem(at: codex.root)
        }

        #expect(
            ChatGPTCLIExecutableLocator.find(in: [chatGPT.app, codex.app])?.standardizedFileURL
                == codex.executable.standardizedFileURL
        )
    }

    @Test func doesNotSearchStandaloneCodexCLI() {
        #expect(ChatGPTCLIExecutableLocator.find(in: []) == nil)
        #expect(ChatGPTCLIExecutableLocator.failureDetails.contains("PATH"))
        #expect(ChatGPTCLIExecutableLocator.failureDetails.contains("独立 codex CLI"))
    }

    @Test func rejectsUntrustedBundleEvenWhenNamedCodex() throws {
        let fixture = try makeApp(named: "Codex", bundleIdentifier: "example.untrusted.codex")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(ChatGPTCLIExecutableLocator.find(in: [fixture.app]) == nil)
    }

    private func makeApp(
        named name: String,
        bundleIdentifier: String,
        executable shouldCreateExecutable: Bool = true
    ) throws -> (root: URL, app: URL, executable: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("\(name).app")
        let executable = app.appendingPathComponent("Contents/Resources/codex")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleName": name,
                "CFBundleIdentifier": bundleIdentifier
            ],
            format: .xml,
            options: 0
        )
        #expect(
            FileManager.default.createFile(
                atPath: app.appendingPathComponent("Contents/Info.plist").path,
                contents: infoData
            )
        )
        if shouldCreateExecutable {
            #expect(FileManager.default.createFile(atPath: executable.path, contents: Data()))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: executable.path
            )
        }
        return (root, app, executable)
    }
}
