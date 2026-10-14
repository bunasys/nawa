import AgentCore
import Foundation

/// The abstract capability every model provider offers.
///
/// CUPID: "Composable — small surface area, intention-revealing names."
/// This is the single seam the rest of the harness programs against.
public protocol LanguageModel: Sendable {
    /// Send messages and (optionally) tools, get a complete response.
    func complete(_ request: ModelRequest) async throws -> ModelResponse

    /// Stream a response in chunks; the final `.finished` chunk carries the
    /// complete `ModelResponse`.
    func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamChunk, any Error>

    /// List the models this provider offers today (auto model discovery).
    func listModels() async throws -> [ModelSummary]

    /// The canonical name of the provider (e.g. "openai", "ollama", "litellm").
    var providerName: String { get }
}

/// A request sent to a language model.
public struct ModelRequest: Sendable {
    /// Provider to use; `nil` means "the gateway's active provider".
    public var providerName: String?
    /// Model id. If nil, the provider's configured default is used.
    public var model: String?
    public var messages: [Message]
    public var tools: [ToolDefinition]?
    public var maxOutputTokens: Int?
    public var temperature: Double?

    public init(
        providerName: String? = nil,
        model: String? = nil,
        messages: [Message],
        tools: [ToolDefinition]? = nil,
        maxOutputTokens: Int? = nil,
        temperature: Double? = nil
    ) {
        self.providerName = providerName
        self.model = model
        self.messages = messages
        self.tools = tools
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
    }
}

/// The truncated (non-streaming) reply from a language model.
public struct ModelResponse: Sendable {
    /// The assistant's turn: text and/or tool calls.
    public var message: Message
    public var finishReason: StopReason?
    public var usage: Usage

    public init(message: Message, finishReason: StopReason? = nil, usage: Usage = .zero) {
        self.message = message
        self.finishReason = finishReason
        self.usage = usage
    }
}

/// A chunk of a streaming reply.
public enum StreamChunk: Sendable {
    /// Partial text emitted so far.
    case textDelta(String)
    /// Tool call began with a zero-argument stub; more deltas follow.
    case toolCallStart(ToolCall)
    /// Partial tool-call argument JSON string (appended to accumulate).
    case toolCallArguments(id: String, partialJSON: String)
    /// The final complete response (sent once streaming finishes).
    case finished(ModelResponse)
}

/// A summary of a model offered by a provider (auto model discovery).
public struct ModelSummary: Sendable, Hashable {
    public var id: String
    public var ownedBy: String?

    public init(id: String, ownedBy: String? = nil) {
        self.id = id
        self.ownedBy = ownedBy
    }
}

/// Errors the gateway surfaces.
public enum GatewayError: Error, Sendable {
    case noProvider
    case providerNotFound(String)
    case modelNotFound(String)
    case httpError(statusCode: Int, body: String)
    case network(String)
    case invalidResponse(String)
    /// Exchanging an identity token for an Anthropic access token failed.
    case workloadIdentity(String)
}

extension GatewayError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case .noProvider:
            return "no provider configured (run `nawa config` or set NAWA_GATEWAY_URL)"
        case .providerNotFound(let name):
            return "provider \"\(name)\" not found"
        case .modelNotFound(let detail):
            return "model not found: \(detail)"
        case .httpError(let statusCode, let body):
            return "HTTP \(statusCode) from the model provider: \(body)"
        case .network(let detail):
            return "network error: \(detail)"
        case .invalidResponse(let detail):
            return "invalid response from the model provider: \(detail)"
        case .workloadIdentity(let detail):
            return "workload identity federation: \(detail)"
        }
    }

    public var errorDescription: String? { description }
}
