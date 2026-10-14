import AgentCore
import Foundation

/// A JSON-RPC 2.0 request id. The spec allows a number or a string, and
/// clients differ: Waku's ACP library sends UUID strings, MCP servers usually
/// numbers. A response must echo the id exactly as it was sent.
public enum JSONRPCID: Sendable, Hashable, ExpressibleByIntegerLiteral, ExpressibleByStringLiteral {
    case number(Int)
    case string(String)

    public init(integerLiteral value: Int) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }

    /// The id carried by a wire `id` field, if it is a valid one.
    public init?(json: JSON?) {
        switch json {
        case .int(let value): self = .number(value)
        case .string(let value): self = .string(value)
        default: return nil
        }
    }

    public var json: JSON {
        switch self {
        case .number(let value): return .int(value)
        case .string(let value): return .string(value)
        }
    }
}

/// A JSON-RPC 2.0 message on the wire: a request, a response, or a notification.
///
/// Shared by the MCP and ACP transports so both speak the same framing rules.
public enum JSONRPCMessage: Sendable, Hashable {
    /// A request expecting a response (has an `id`).
    case request(JSONRPCRequest)
    /// A notification — no response expected (no `id`).
    case notification(JSONRPCMethod)
    /// A successful response correlating to a request `id`.
    case successResponse(JSONRPCSuccess)
    /// An error response correlating to a request `id`.
    case errorResponse(JSONRPCError)

    public var id: JSONRPCID? {
        switch self {
        case .request(let r): return r.id
        case .successResponse(let r): return r.id
        case .errorResponse(let r): return r.id
        case .notification: return nil
        }
    }

    public var method: String? {
        switch self {
        case .request(let r): return r.method
        case .notification(let n): return n.method
        default: return nil
        }
    }
}

/// A JSON-RPC request: a call that expects a response correlated by `id`.
/// Calls without an id are notifications (`JSONRPCMethod`), so the id here
/// is never absent.
public struct JSONRPCRequest: Sendable, Hashable {
    public var jsonrpc: String
    public var id: JSONRPCID
    public var method: String
    public var params: JSON?

    public init(method: String, id: JSONRPCID, params: JSON? = nil, jsonrpc: String = "2.0") {
        self.method = method
        self.id = id
        self.params = params
        self.jsonrpc = jsonrpc
    }
}

/// A JSON-RPC method call without an id = a notification.
public struct JSONRPCMethod: Sendable, Hashable, Codable {
    public var jsonrpc: String
    public var method: String
    public var params: JSON?
    public init(method: String, params: JSON? = nil, jsonrpc: String = "2.0") {
        self.method = method
        self.params = params
        self.jsonrpc = jsonrpc
    }
}

/// A successful JSON-RPC response.
public struct JSONRPCSuccess: Sendable, Hashable {
    public var jsonrpc: String
    public var id: JSONRPCID
    public var result: JSON?
    public init(id: JSONRPCID, result: JSON?, jsonrpc: String = "2.0") {
        self.id = id
        self.result = result
        self.jsonrpc = jsonrpc
    }
}

/// A JSON-RPC error object.
public struct JSONRPCErrorObject: Sendable, Hashable, Codable {
    public var code: Int
    public var message: String
    public var data: JSON?

    public init(code: Int, message: String, data: JSON? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

/// An error JSON-RPC response.
public struct JSONRPCError: Sendable, Hashable {
    public var jsonrpc: String
    public var id: JSONRPCID?
    public var error: JSONRPCErrorObject
    public init(id: JSONRPCID?, error: JSONRPCErrorObject, jsonrpc: String = "2.0") {
        self.id = id
        self.error = error
        self.jsonrpc = jsonrpc
    }
}

/// Standard JSON-RPC error codes.
public enum JSONRPCErrorCode: Int, Sendable {
    case parseError = -32700
    case invalidRequest = -32600
    case methodNotFound = -32601
    case invalidParams = -32602
    case internalError = -32603
}

// MARK: - Construction & serialization helpers

public extension JSONRPCMessage {
    /// Make a request message.
    static func makeRequest(method: String, id: JSONRPCID, params: JSON? = nil) -> JSONRPCMessage {
        .request(JSONRPCRequest(method: method, id: id, params: params))
    }

    /// Make a notification message (no response expected).
    static func makeNotification(method: String, params: JSON? = nil) -> JSONRPCMessage {
        .notification(JSONRPCMethod(method: method, params: params))
    }

    /// Make a success response.
    static func makeSuccess(id: JSONRPCID, result: JSON? = nil) -> JSONRPCMessage {
        .successResponse(JSONRPCSuccess(id: id, result: result))
    }

    /// Make an error response.
    static func makeError(id: JSONRPCID?, code: JSONRPCErrorCode, message: String, data: JSON? = nil) -> JSONRPCMessage {
        .errorResponse(JSONRPCError(id: id, error: .init(code: code.rawValue, message: message, data: data)))
    }

    /// Serialize to JSON for the wire.
    var json: JSON {
        switch self {
        case .request(let r):
            var obj: [String: JSON] = [
                "jsonrpc": .string("2.0"),
                "method": .string(r.method),
            ]
            obj["id"] = r.id.json
            if let params = r.params { obj["params"] = params }
            return .object(obj)
        case .notification(let n):
            var obj: [String: JSON] = [
                "jsonrpc": .string("2.0"),
                "method": .string(n.method),
            ]
            if let params = n.params { obj["params"] = params }
            return .object(obj)
        case .successResponse(let r):
            var obj: [String: JSON] = [
                "jsonrpc": .string("2.0"),
                "id": r.id.json,
            ]
            if let result = r.result { obj["result"] = result }
            return .object(obj)
        case .errorResponse(let r):
            var obj: [String: JSON] = [
                "jsonrpc": .string("2.0"),
                "id": r.id?.json ?? .null,
                "error": .object([
                    "code": .int(r.error.code),
                    "message": .string(r.error.message),
                ]),
            ]
            if let data = r.error.data { obj["error"] = .object(["code": .int(r.error.code), "message": .string(r.error.message), "data": data]) }
            return .object(obj)
        }
    }

    /// One newline-delimited line for stdio transports.
    var line: String { json.description + "\n" }
}

/// Parse a newline-delimited JSON-RPC line.
public func parseJSONRPCLine(_ line: String) throws -> JSONRPCMessage {
    let data = Data(line.utf8)
    let json = try JSONDecoder().decode(JSON.self, from: data)
    guard let object = json.objectValue else { throw JSONRPCParseError.notAnObject }
    if let method = object["method"]?.stringValue {
        if let id = JSONRPCID(json: object["id"]) {
            return .request(JSONRPCRequest(method: method, id: id, params: object["params"]))
        } else {
            return .notification(JSONRPCMethod(method: method, params: object["params"]))
        }
    } else if object["error"] != nil {
        let code = object["error"]?.objectValue?["code"]?.intValue ?? -32603
        let message = object["error"]?.objectValue?["message"]?.stringValue ?? "unknown error"
        return .errorResponse(JSONRPCError(id: JSONRPCID(json: object["id"]), error: .init(code: code, message: message, data: object["error"]?.objectValue?["data"])))
    } else {
        // A success response that names no request cannot be correlated;
        // inventing an id would resolve the wrong pending call.
        guard let id = JSONRPCID(json: object["id"]) else { throw JSONRPCParseError.missingID }
        return .successResponse(JSONRPCSuccess(id: id, result: object["result"]))
    }
}

public extension JSONRPCMessage {
    /// The error response to send for a line `parseJSONRPCLine` rejected:
    /// `-32700` for malformed JSON, `-32600` for JSON that is not a valid
    /// message. Its id is `null`, since no id could be read.
    static func parseFailure(_ error: any Error) -> JSONRPCMessage {
        if error is JSONRPCParseError {
            return .makeError(id: nil, code: .invalidRequest, message: "invalid JSON-RPC message: \(error)")
        }
        return .makeError(id: nil, code: .parseError, message: "parse error: \(error)")
    }
}

public enum JSONRPCParseError: Error, Sendable {
    case notAnObject
    /// A response without a usable `id`.
    case missingID
}
