import AgentCore
import Foundation
import Testing
@testable import nawa

@Suite struct ReplTests {
    @Test func settingsApplyOverTheDefaults() {
        #expect(AgentCLI.defaultLoopOptions().compaction?.atContextTokens == 120_000)
        let options = AgentCLI.defaultLoopOptions(settings: LoopSettings(compactAt: 600_000, stream: false))
        #expect(options.compaction?.atContextTokens == 600_000)
        #expect(options.compaction?.keepRecentMessages == 20)
        #expect(!options.streamReplies)
        #expect(options.keepToolResults == 20)  // untouched
    }

    @Test func headerPathsUnderHomeUseATilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(AgentCLI.displayPath(home) == "~")
        #expect(AgentCLI.displayPath(home.appendingPathComponent("src/nawa")) == "~/src/nawa")
        #expect(AgentCLI.displayPath(URL(fileURLWithPath: "/tmp/x")) == "/tmp/x")
        // A sibling that merely starts with the same characters is not under home.
        #expect(AgentCLI.displayPath(URL(fileURLWithPath: home.path + "x/y")) == home.path + "x/y")
    }
}
