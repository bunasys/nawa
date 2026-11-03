import AgentCore
import AgentJSONRPC
import Foundation

// MARK: - Authorization (protocol negotiation)

/// ACP protocol version we implement (v1).
public enum ACPProtocolVersion: Int, Sendable {
    case v1 = 1
}

/// Metadata about the agent implementation, sent in the `initialize` result.
public struct ACPServerInfo: Sendable, Hashable {
    public var name: String
    public var title: String?
    public var version: String

    public init(name: String, title: String? = nil, version: String) {
        self.name = name
        self.title = title
        self.version = version
    }

    public static let nawa = ACPServerInfo(name: "nawa", title: "Nawa Agent Harness", version: nawaVersion)

    public var json: JSON {
        .object([
            "name": .string(name),
            "title": title.map(JSON.string) ?? .null,
            "version": .string(version),
        ])
    }
}

/// Capabilities advertised by the agent during `initialize`.
public struct ACPCapabilities: Sendable, Hashable {
    public var loadSession: Bool
    /// Supports embedded (in-prompt) resource content blocks.
    public var embeddedContext: Bool

    public init(loadSession: Bool = false, embeddedContext: Bool = true) {
        self.loadSession = loadSession
        self.embeddedContext = embeddedContext
    }

    public var json: JSON {
        .object([
            "loadSession": .bool(loadSession),
            "promptCapabilities": .object([
                "image": .bool(false),
                "audio": .bool(false),
                "embeddedContext": .bool(embeddedContext),
            ]),
            "mcpCapabilities": .object([
                "http": .bool(false),
                "sse": .bool(false),
            ]),
            "sessionCapabilities": .object([:]),
            "auth": .object([:]),
        ])
    }
}

/// Why an agent stopped processing a prompt turn.
public enum ACPStopReason: String, Sendable {
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case maxTurnRequests = "max_turn_requests"
    case refusal
    case cancelled

    public init(domain reason: StopReason?) {
        switch reason {
        case .endTurn: self = .endTurn
        case .maxTokens: self = .maxTokens
        case .refusal: self = .refusal
        case .toolUse, .cancelled, nil: self = .endTurn
        }
    }

    public init(resultKind kind: AgentResultKind) {
        switch kind {
        case .success: self = .endTurn
        case .errorMaxTurns: self = .maxTurnRequests
        case .errorMaxBudgetUSD: self = .maxTurnRequests
        // Never sent: a failed turn is answered with a JSON-RPC error (see
        // `ACPSession.runTurn`), because `refusal` would read as "the model declined".
        case .errorDuringExecution: self = .endTurn
        case .refused: self = .refusal
        }
    }
}

// MARK: - Content blocks (shared with MCP wire format)

/// A content block in an ACP message, mirroring MCP's `ContentBlock`.
public enum ACPContentBlock: Sendable, Hashable {
    case text(String)
    case image(mimeType: String, data: String, uri: String?)
    case audio(mimeType: String, data: String)
    case resource(uri: String, mimeType: String?, text: String)
    /// A file the client points at without sending its content.
    case resourceLink(uri: String, name: String)

    /// Decode from wire JSON, tolerating unknown variants (forward compat).
    public init?(json: JSON) {
        guard let object = json.objectValue else { return nil }
        switch object["type"]?.stringValue {
        case "text":
            guard let text = object["text"]?.stringValue else { return nil }
            self = .text(text)
        case "image":
            guard let data = object["data"]?.stringValue else { return nil }
            self = .image(mimeType: object["mimeType"]?.stringValue ?? "image/png", data: data, uri: object["uri"]?.stringValue)
        case "audio":
            guard let data = object["data"]?.stringValue else { return nil }
            self = .audio(mimeType: object["mimeType"]?.stringValue ?? "audio/wav", data: data)
        case "resource":
            // A binary (`blob`) resource has no text to give the model.
            guard let resource = object["resource"]?.objectValue,
                let uri = resource["uri"]?.stringValue,
                let text = resource["text"]?.stringValue
            else { return nil }
            self = .resource(uri: uri, mimeType: resource["mimeType"]?.stringValue, text: text)
        case "resource_link":
            guard let uri = object["uri"]?.stringValue else { return nil }
            self = .resourceLink(uri: uri, name: object["name"]?.stringValue ?? uri)
        default:
            return nil
        }
    }

    public var json: JSON {
        switch self {
        case .text(let t):
            return .object(["type": .string("text"), "text": .string(t)])
        case .image(let m, let d, let uri):
            var o: [String: JSON] = ["type": .string("image"), "mimeType": .string(m), "data": .string(d)]
            if let uri { o["uri"] = .string(uri) }
            return .object(o)
        case .audio(let m, let d):
            return .object(["type": .string("audio"), "mimeType": .string(m), "data": .string(d)])
        case .resource(let uri, let mime, let text):
            var r: [String: JSON] = ["uri": .string(uri)]
            if let mime { r["mimeType"] = .string(mime) }
            r["text"] = .string(text)
            return .object(["type": .string("resource"), "resource": .object(r)])
        case .resourceLink(let uri, let name):
            return .object(["type": .string("resource_link"), "uri": .string(uri), "name": .string(name)])
        }
    }

    /// How the block reads in the prompt the model gets; nil for kinds the
    /// agent doesn't advertise (images, audio).
    public var promptText: String? {
        switch self {
        case .text(let text):
            return text
        case .resource(let uri, _, let text):
            return "<file uri=\"\(uri)\">\n\(text)\n</file>"
        case .resourceLink(let uri, _):
            return "@\(uri)"
        case .image, .audio:
            return nil
        }
    }
}

/// The kinds of `session/update` payloads (wire `sessionUpdate` discriminator).
public enum ACPSessionUpdateKind: String, Sendable {
    case userMessageChunk = "user_message_chunk"
    case agentMessageChunk = "agent_message_chunk"
    case agentThoughtChunk = "agent_thought_chunk"
    case toolCall = "tool_call"
    case toolCallUpdate = "tool_call_update"
    case plan
    case usageUpdate = "usage_update"
}

/// Kinds a tool call can belong to (icon hints).
public enum ACPToolKind: String, Sendable {
    case read, edit, delete, move, search, execute, think, fetch, other
}

/// Lifecycle status of a tool call.
public enum ACPToolCallStatus: String, Sendable {
    case pending
    case running = "in_progress"
    case completed
    case failed
}

/// A `session/update` payload builder producing wire-faithful JSON.
public enum ACPSessionUpdate {
    /// Stream a chunk of the agent's (or user's) message.
    public static func messageChunk(kind: ACPSessionUpdateKind, messageID: String, content: ACPContentBlock) -> JSON {
        .object([
            "sessionUpdate": .string(kind.rawValue),
            "messageId": .string(messageID),
            "content": content.json,
        ])
    }

    /// Report that a new tool call has been initiated.
    public static func toolCall(callID: String, title: String, kind: ACPToolKind = .other, status: ACPToolCallStatus = .pending) -> JSON {
        .object([
            "sessionUpdate": .string(ACPSessionUpdateKind.toolCall.rawValue),
            "toolCallId": .string(callID),
            "title": .string(title),
            "kind": .string(kind.rawValue),
            "status": .string(status.rawValue),
        ])
    }

    /// Update an existing tool call's status/content.
    public static func toolCallUpdate(callID: String, status: ACPToolCallStatus?, title: String? = nil, content: ACPContentBlock? = nil) -> JSON {
        var update: [String: JSON] = [
            "sessionUpdate": .string(ACPSessionUpdateKind.toolCallUpdate.rawValue),
            "toolCallId": .string(callID),
        ]
        if let status { update["status"] = .string(status.rawValue) }
        if let title { update["title"] = .string(title) }
        if let content {
            update["content"] = .array([.object(["type": .string("content"), "content": content.json])])
        }
        return .object(update)
    }

    /// Update usage/context accounting for the session: `used` tokens of a
    /// context of `size`, and what the session has cost so far.
    public static func usageUpdate(used: Int, size: Int, costUSD: Double? = nil) -> JSON {
        var update: [String: JSON] = [
            "sessionUpdate": .string(ACPSessionUpdateKind.usageUpdate.rawValue),
            "used": .int(used),
            "size": .int(size),
        ]
        if let costUSD {
            update["cost"] = .object(["amount": .double(costUSD), "currency": .string("USD")])
        }
        return .object(update)
    }
}
