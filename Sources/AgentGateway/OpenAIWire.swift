import AgentCore
import Foundation

/// Wire-level encoding of the OpenAI chat-completions request.
struct OpenAIRequest: Encodable {
    let model: String
    let messages: [OpenAIMessage]
    let tools: [OpenAITool]?
    let stream: Bool
    let temperature: Double?
    let maxTokens: Int?
    let streamOptions: [String: Bool]?

    init(
        model: String,
        messages: [OpenAIMessage],
        tools: [OpenAITool]? = nil,
        stream: Bool = false,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        streamOptions: [String: Bool]? = nil
    ) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.stream = stream
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.streamOptions = streamOptions
    }
}

enum OpenAIRole: String, Encodable {
    case system, user, assistant, tool
}

struct OpenAIMessage: Encodable {
    let role: OpenAIRole
    let content: String?
    let toolCalls: [OpenAIToolCall]?
    let toolCallID: String?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case role, content, name
        case toolCalls = "tool_calls"
        case toolCallID = "tool_call_id"
    }
}

struct OpenAIToolCall: Encodable {
    let id: String
    let type: String
    let function: OpenAIToolFunction
}

struct OpenAIToolFunction: Encodable {
    let name: String
    let arguments: String
}

struct OpenAITool: Encodable {
    let type: String
    let function: OpenAIToolDefinition
}

struct OpenAIToolDefinition: Encodable {
    let name: String
    let description: String
    let parameters: JSON
}

// Response types -------------------------------------------------------------

struct OpenAIResponse: Decodable {
    let id: String?
    let choices: [OpenAIChoice]
    let usage: OpenAIUsage?
}

struct OpenAIChoice: Decodable {
    let message: OpenAIMessageResponse?
    let finishReason: String?
    private enum CodingKeys: String, CodingKey {
        case message
        case finishReason = "finish_reason"
    }
}

struct OpenAIMessageResponse: Decodable {
    let role: String?
    let content: String?
    let toolCalls: [OpenAIToolCallResponse]?
    private enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
    }
}

struct OpenAIToolCallResponse: Decodable {
    let id: String?
    let type: String?
    let function: OpenAIToolFunctionResponse?
}

struct OpenAIToolFunctionResponse: Decodable {
    let name: String?
    let arguments: String?
}

struct OpenAIUsage: Decodable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    private enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

// Streaming chunks -----------------------------------------------------------

struct OpenAIStreamChunk: Decodable {
    let choices: [OpenAIStreamChoice]?
    let usage: OpenAIUsage?
}

struct OpenAIStreamChoice: Decodable {
    let delta: OpenAIDelta?
    let finishReason: String?
    private enum CodingKeys: String, CodingKey {
        case delta
        case finishReason = "finish_reason"
    }
}

struct OpenAIDelta: Decodable {
    let content: String?
    let toolCalls: [OpenAIStreamToolCall]?
    private enum CodingKeys: String, CodingKey {
        case content
        case toolCalls = "tool_calls"
    }
}

struct OpenAIStreamToolCall: Decodable {
    let index: Int?
    let id: String?
    let type: String?
    let function: OpenAIMessageFunctionDelta?
}

struct OpenAIMessageFunctionDelta: Decodable {
    let name: String?
    let arguments: String?
}

/// Model listing response from `GET /v1/models`.
struct OpenAIModelList: Decodable {
    let data: [OpenAIModelEntry]
}

struct OpenAIModelEntry: Decodable {
    let id: String
    let ownedBy: String?
    private enum CodingKeys: String, CodingKey {
        case id
        case ownedBy = "owned_by"
    }
}
