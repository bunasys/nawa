import AgentCore
import AgentJSONRPC
import Testing

struct JSONRPCParsingTests {
    @Test
    func nullErrorNextToAResultIsASuccess() throws {
        let message = try parseJSONRPCLine(#"{"jsonrpc":"2.0","id":4,"result":{"ok":true},"error":null}"#)
        guard case .successResponse(let response) = message else {
            Issue.record("parsed as \(message)")
            return
        }
        #expect(response.id == 4)
    }

    @Test
    func nonStringMethodIsRejected() {
        #expect(throws: JSONRPCParseError.self) {
            try parseJSONRPCLine(#"{"jsonrpc":"2.0","id":1,"method":7}"#)
        }
    }

    @Test
    func responseWithNeitherResultNorErrorIsRejected() {
        #expect(throws: JSONRPCParseError.self) {
            try parseJSONRPCLine(#"{"jsonrpc":"2.0","id":2}"#)
        }
    }

    /// A request with an id nobody can echo still expects an answer: it
    /// is an invalid request, not a notification to drop silently.
    @Test(arguments: [#"1.5"#, #"null"#, #"1e30"#])
    func requestWithUnusableIDIsRejected(id: String) {
        #expect(throws: JSONRPCParseError.self) {
            try parseJSONRPCLine(#"{"jsonrpc":"2.0","id":\#(id),"method":"ping"}"#)
        }
    }

    @Test
    func methodWithoutIDKeyIsANotification() throws {
        let message = try parseJSONRPCLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        guard case .notification(let notification) = message else {
            Issue.record("parsed as \(message)")
            return
        }
        #expect(notification.method == "notifications/initialized")
    }

    @Test
    func errorResponseWithNullIDParses() throws {
        let message = try parseJSONRPCLine(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"bad"}}"#)
        guard case .errorResponse(let response) = message else {
            Issue.record("parsed as \(message)")
            return
        }
        #expect(response.id == nil)
        #expect(response.error.message == "bad")
    }

    @Test
    func errorResponseKeepsItsDataOnTheWire() throws {
        let message = JSONRPCMessage.makeError(id: 1, code: .invalidParams, message: "nope", data: .string("detail"))
        let error = message.json.objectValue?["error"]?.objectValue
        #expect(error?["code"] == .int(-32602))
        #expect(error?["message"] == .string("nope"))
        #expect(error?["data"] == .string("detail"))
        let withoutData = JSONRPCMessage.makeError(id: 1, code: .invalidParams, message: "nope")
        #expect(withoutData.json.objectValue?["error"]?.objectValue?["data"] == nil)
    }
}
