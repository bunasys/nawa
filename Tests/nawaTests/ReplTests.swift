import Foundation
import Testing
@testable import nawa

@Suite struct ReplTests {
    @Test func headerPathsUnderHomeUseATilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(AgentCLI.displayPath(home) == "~")
        #expect(AgentCLI.displayPath(home.appendingPathComponent("src/nawa")) == "~/src/nawa")
        #expect(AgentCLI.displayPath(URL(fileURLWithPath: "/tmp/x")) == "/tmp/x")
        // A sibling that merely starts with the same characters is not under home.
        #expect(AgentCLI.displayPath(URL(fileURLWithPath: home.path + "x/y")) == home.path + "x/y")
    }
}
