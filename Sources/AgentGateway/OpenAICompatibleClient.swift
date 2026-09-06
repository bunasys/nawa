import AgentCore
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OpenAI-compatible `LanguageModel` over `POST /v1/chat/completions`.
///
/// Works with any OpenAI-compatible endpoint: OpenAI, Azure OpenAI, Ollama,
/// vLLM, LiteLLM, LM Studio, Groq, together.xyz, localhost gateways, etc.
public struct OpenAICompatibleClient: LanguageModel, Sendable {
    public let providerName: String
    public let baseURL: URL
    public let apiKey: String?
    public let session: URLSession

    public init(
        providerName: String,
        baseURL: URL,
        apiKey: String? = nil,
        session: URLSession = .shared
    ) {
        self.providerName = providerName
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: LanguageModel

    public func complete(_ request: ModelRequest) async throws -> ModelResponse {
        let body = OpenAIRequest(
            model: request.model ?? "unknown",
            messages: Self.openAIMessages(request.messages),
            tools: Self.openAITools(request.tools),
            stream: false,
            temperature: request.temperature,
            maxTokens: request.maxOutputTokens
        )
        let data = try await Self.post(session: session, url: chatCompletionsURL, apiKey: apiKey, body: body)
        do {
            let response = try JSONDecoder().decode(OpenAIResponse.self, from: data)
            guard let choice = response.choices.first, let message = choice.message else {
                throw GatewayError.invalidResponse("no choices in /chat/completions response")
            }
            let assistant = Self.assistantMessage(from: message)
            let stop = Self.stopReason(from: choice.finishReason)
            return ModelResponse(message: assistant, finishReason: stop, usage: Self.usage(response.usage))
        } catch let error as GatewayError {
            throw error
        } catch {
            throw GatewayError.invalidResponse(String(describing: error))
        }
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    let body = OpenAIRequest(
                        model: request.model ?? "unknown",
                        messages: Self.openAIMessages(request.messages),
                        tools: Self.openAITools(request.tools),
                        stream: true,
                        temperature: request.temperature,
                        maxTokens: request.maxOutputTokens
                    )
                    let payload = try JSONEncoder().encode(body)
                    var urlRequest = URLRequest(url: chatCompletionsURL)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if let apiKey { urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
                    urlRequest.httpBody = payload

                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        let text = try await Self.collectString(from: bytes)
                        throw GatewayError.httpError(statusCode: http.statusCode, body: text)
                    }

                    var text = ""
                    var pendingToolCalls: [PendingToolCall] = []
                    var cumulativeUsage = Usage.zero

                    try await Self.drainSSE(bytes) { payload in
                        if payload.hasPrefix("[DONE]") { return }
                        guard let data = payload.data(using: .utf8),
                            let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data)
                        else { return }
                        if let usage = chunk.usage {
                            cumulativeUsage = Self.usage(usage)
                        }
                        guard let choice = chunk.choices?.first else { return }
                        if let delta = choice.delta {
                            if let content = delta.content, !content.isEmpty {
                                text += content
                                continuation.yield(.textDelta(content))
                            }
                            if let toolCalls = delta.toolCalls {
                                for tc in toolCalls {
                                    let index = tc.index ?? 0
                                    while pendingToolCalls.count <= index {
                                        pendingToolCalls.append(PendingToolCall(id: nil, name: nil, arguments: ""))
                                    }
                                    if let id = tc.id { pendingToolCalls[index].id = id }
                                    if let name = tc.function?.name {
                                        pendingToolCalls[index].name = name
                                        continuation.yield(.toolCallStart(ToolCall(id: tc.id ?? "call_\(index)", name: name)))
                                    }
                                    if let args = tc.function?.arguments {
                                        pendingToolCalls[index].arguments += args
                                        continuation.yield(.toolCallArguments(id: pendingToolCalls[index].id ?? "call_\(index)", partialJSON: args))
                                    }
                                }
                            }
                        }
                    }

                    // Final assembled message
                    var blocks: [ContentBlock] = []
                    if !text.isEmpty { blocks.append(.text(text)) }
                    for call in pendingToolCalls {
                        guard let id = call.id else { continue }
                        let name = call.name ?? ""
                        let args = (try? JSONDecoder().decode(JSON.self, from: Data(call.arguments.utf8))) ?? .object([:])
                        blocks.append(.toolCall(ToolCall(id: id, name: name, arguments: args)))
                    }
                    let message = Message(role: .assistant, content: blocks.isEmpty ? [.text("")] : blocks)
                    let completion = ModelResponse(message: message, finishReason: nil, usage: cumulativeUsage)
                    continuation.yield(.finished(completion))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func listModels() async throws -> [ModelSummary] {
        let data = try await Self.get(session: session, url: modelsURL, apiKey: apiKey)
        let list = try JSONDecoder().decode(OpenAIModelList.self, from: data)
        return list.data.map { ModelSummary(id: $0.id, ownedBy: $0.ownedBy) }
    }

    // MARK: URL building

    var chatCompletionsURL: URL { baseURL.appendingPathComponent("chat/completions") }
    var modelsURL: URL { baseURL.appendingPathComponent("models") }

    // MARK: Domain <-> wire mapping

    static func openAIMessages(_ messages: [Message]) -> [OpenAIMessage] {
        messages.map { message in
            switch message.role {
            case .system:
                return OpenAIMessage(role: .system, content: message.text, toolCalls: nil, toolCallID: nil, name: nil)
            case .assistant:
                let toolCalls = message.toolCalls.map { call in
                    OpenAIToolCall(
                        id: call.id,
                        type: "function",
                        function: OpenAIToolFunction(name: call.name, arguments: argumentsString(call.arguments))
                    )
                }
                return OpenAIMessage(
                    role: .assistant,
                    content: message.text.isEmpty ? nil : message.text,
                    toolCalls: toolCalls.isEmpty ? nil : toolCalls,
                    toolCallID: nil,
                    name: nil
                )
            case .user:
                return OpenAIMessage(role: .user, content: message.text, toolCalls: nil, toolCallID: nil, name: nil)
            case .tool:
                let result = message.content.compactMap { block -> ToolCallResult? in
                    if case .toolResult(let r) = block { return r }
                    return nil
                }.first
                return OpenAIMessage(
                    role: .tool,
                    content: result?.content,
                    toolCalls: nil,
                    toolCallID: result?.callID,
                    name: result?.name
                )
            }
        }
    }

    static func openAITools(_ tools: [ToolDefinition]?) -> [OpenAITool]? {
        guard let tools, !tools.isEmpty else { return nil }
        return tools.map {
            OpenAITool(
                type: "function",
                function: OpenAIToolDefinition(name: $0.name, description: $0.description, parameters: $0.parameters)
            )
        }
    }

    static func assistantMessage(from wire: OpenAIMessageResponse) -> Message {
        var blocks: [ContentBlock] = []
        if let text = wire.content, !text.isEmpty {
            blocks.append(.text(text))
        }
        for call in wire.toolCalls ?? [] {
            guard let id = call.id, let name = call.function?.name else { continue }
            let args = (call.function?.arguments).flatMap { payload in
                try? JSONDecoder().decode(JSON.self, from: Data(payload.utf8))
            } ?? .object([:])
            blocks.append(.toolCall(ToolCall(id: id, name: name, arguments: args)))
        }
        if blocks.isEmpty { blocks.append(.text("")) }
        return Message(role: .assistant, content: blocks)
    }

    static func stopReason(from finishReason: String?) -> StopReason? {
        switch finishReason {
        case "stop": return .endTurn
        case "length": return .maxTokens
        case "tool_calls": return .toolUse
        case "content_filter": return .refusal
        default: return nil
        }
    }

    static func usage(_ usage: OpenAIUsage?) -> Usage {
        Usage(inputTokens: usage?.promptTokens ?? 0, outputTokens: usage?.completionTokens ?? 0)
    }

    static func argumentsString(_ arguments: JSON) -> String {
        guard let data = try? JSONEncoder().encode(arguments) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: HTTP plumbing

    static func post(
        session: URLSession,
        url: URL,
        apiKey: String?,
        body: some Encodable
    ) async throws -> Data {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        urlRequest.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: urlRequest)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw GatewayError.httpError(statusCode: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    static func get(session: URLSession, url: URL, apiKey: String?) async throws -> Data {
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        if let apiKey { urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: urlRequest)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw GatewayError.httpError(statusCode: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    static func collectString(from bytes: URLSession.AsyncBytes) async throws -> String {
        var text = ""
        for try await line in bytes.lines {
            text += line + "\n"
        }
        return text
    }

    /// Read all SSE `data:` lines from the byte stream, invoking `onPayload`.
    static func drainSSE(
        _ bytes: URLSession.AsyncBytes,
        onPayload: (String) throws -> Void
    ) async throws {
        for try await line in bytes.lines {
            if line.hasPrefix("data:") {
                let payload = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                if !payload.isEmpty {
                    try onPayload(payload)
                }
            }
        }
    }
}

/// Partial state while accumulating streaming tool calls.
struct PendingToolCall {
    var id: String?
    var name: String?
    var arguments: String
}
