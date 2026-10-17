import Testing
@testable import nawa

@Suite struct ReplInputTests {
    @Test func shiftEnterFromModifyOtherKeysBecomesNewline() {
        let line = "last session returned this error:\u{1B}[27;2;13~1. Inline."
        #expect(AgentCLI.modifiedEnterAsNewline(line) == "last session returned this error:\n1. Inline.")
    }

    @Test func shiftEnterFromKittyProtocolBecomesNewline() {
        #expect(AgentCLI.modifiedEnterAsNewline("a\u{1B}[13;2ub\u{1B}[13;5uc") == "a\nb\nc")
    }

    @Test func sequenceWithoutEscIsStillANewline() {
        #expect(AgentCLI.modifiedEnterAsNewline("error:[27;2;13~1.") == "error:\n1.")
    }

    @Test func ordinaryTextIsUntouched() {
        let line = "array[27] and [13;2] stay as they are"
        #expect(AgentCLI.modifiedEnterAsNewline(line) == line)
    }
}
