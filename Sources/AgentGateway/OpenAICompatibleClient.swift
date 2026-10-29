import AgentCore
import Foundation
import Synchronization

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
    /// Seconds a request may wait for its reply; see `defaultRequestTimeout`.
    public let requestTimeout: TimeInterval
    /// Sent as `reasoning_effort`; see `ProviderConfig.reasoningEffort`.
    public let reasoningEffort: String?
    public let session: URLSession

    public init(
        providerName: String,
        baseURL: URL,
        apiKey: String? = nil,
        requestTimeout: TimeInterval = Self.defaultRequestTimeout,
        reasoningEffort: String? = nil,
        session: URLSession = .shared
    ) {
        self.providerName = providerName
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.requestTimeout = requestTimeout
        self.reasoningEffort = reasoningEffort
        self.session = session
    }

    // MARK: LanguageModel

    public func complete(_ request: ModelRequest) async throws -> ModelResponse {
        let body = OpenAIRequest(
            model: try request.requiredModel(),
            messages: Self.openAIMessages(request.messages),
            tools: Self.openAITools(request.tools),
            stream: false,
            temperature: request.temperature,
            maxTokens: request.maxOutputTokens,
            reasoningEffort: reasoningEffort
        )
        let (data, wire) = try await Self.post(session: session, url: chatCompletionsURL, apiKey: apiKey, sessionID: request.sessionID, timeout: requestTimeout, body: body)
        do {
            let response = try JSONDecoder().decode(OpenAIResponse.self, from: data)
            guard let choice = response.choices.first, let message = choice.message else {
                throw GatewayError.invalidResponse("no choices in /chat/completions response")
            }
            let assistant = Self.assistantMessage(from: message)
            let stop = Self.stopReason(from: choice.finishReason)
            return ModelResponse(message: assistant, finishReason: stop, usage: Self.usage(response.usage), wire: wire)
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
                    let (bytes, wire) = try await openStream(request)
                    var assembler = OpenAIStreamAssembler()
                    try await ServerSentEvents.forEachData(in: bytes) { payload in
                        for chunk in try assembler.consume(payload) { continuation.yield(chunk) }
                    }
                    var response = assembler.response()
                    response.wire = wire
                    continuation.yield(.finished(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A chat reply can take minutes before its first byte: a long context, a
    /// slow model, or a proxy in front that waits for the whole reply (as
    /// Hafez's does). URLSession's 60-second default cut those off; this
    /// matches `AnthropicClient.defaultRequestTimeout`.
    public static let defaultRequestTimeout: TimeInterval = 600

    /// Endpoints that answered `stream_options` with a 400, by URL: asked
    /// once per process, then streamed without usage.
    private static let rejectsStreamOptions = Mutex<Set<String>>([])

    /// Starts the streaming request. Usage is asked for with
    /// `stream_options.include_usage` (OpenAI sends none without it); a
    /// server that refuses the field gets one retry without it.
    private func openStream(_ request: ModelRequest) async throws -> (HTTPResponseBytes, WireFacts) {
        let endpoint = chatCompletionsURL.absoluteString
        let askForUsage = !Self.rejectsStreamOptions.withLock { $0.contains(endpoint) }
        do {
            return try await openStream(request, askForUsage: askForUsage)
        } catch GatewayError.httpError(statusCode: 400, let body) where askForUsage && body.contains("stream_options") {
            Self.rejectsStreamOptions.withLock { _ = $0.insert(endpoint) }
            return try await openStream(request, askForUsage: false)
        }
    }

    private func openStream(_ request: ModelRequest, askForUsage: Bool) async throws -> (HTTPResponseBytes, WireFacts) {
        let body = OpenAIRequest(
            model: try request.requiredModel(),
            messages: Self.openAIMessages(request.messages),
            tools: Self.openAITools(request.tools),
            stream: true,
            temperature: request.temperature,
            maxTokens: request.maxOutputTokens,
            streamOptions: askForUsage ? ["include_usage": true] : nil,
            reasoningEffort: reasoningEffort
        )
        var urlRequest = URLRequest(url: chatCompletionsURL)
        // Assigned, not passed to init: on Linux only the setter marks the
        // timeout as set, and otherwise URLSession uses the session's 60 s.
        urlRequest.timeoutInterval = requestTimeout
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        if let sessionID = request.sessionID { urlRequest.setValue(sessionID, forHTTPHeaderField: "x-session-id") }
        urlRequest.httpBody = try sortedJSON(body)

        let (bytes, response) = try await session.streamBytes(for: urlRequest)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw GatewayError.httpError(statusCode: http.statusCode, body: try await collectText(bytes))
        }
        return (bytes, WireFacts(request: urlRequest, response: response))
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

    /// `prompt_tokens` includes the cached tokens; `Usage` counts them apart.
    static func usage(_ usage: OpenAIUsage?) -> Usage {
        let prompt = usage?.promptTokens ?? 0
        let cached = usage?.promptTokensDetails?.cachedTokens ?? 0
        return Usage(
            inputTokens: prompt - cached,
            outputTokens: usage?.completionTokens ?? 0,
            cacheReadTokens: cached,
            reasoningTokens: usage?.completionTokensDetails?.reasoningTokens ?? 0
        )
    }

    static func argumentsString(_ arguments: JSON) -> String {
        guard let data = try? sortedJSON(arguments) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: HTTP plumbing

    static func post(
        session: URLSession,
        url: URL,
        apiKey: String?,
        sessionID: String? = nil,
        timeout: TimeInterval = defaultRequestTimeout,
        body: some Encodable
    ) async throws -> (Data, WireFacts) {
        var urlRequest = URLRequest(url: url)
        // Assigned, not passed to init: on Linux only the setter marks the
        // timeout as set, and otherwise URLSession uses the session's 60 s.
        urlRequest.timeoutInterval = timeout
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey { urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        if let sessionID { urlRequest.setValue(sessionID, forHTTPHeaderField: "x-session-id") }
        urlRequest.httpBody = try sortedJSON(body)
        let (data, response) = try await session.data(for: urlRequest)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw GatewayError.httpError(statusCode: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return (data, WireFacts(request: urlRequest, response: response))
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
}

/// Turns chat-completions stream chunks into `StreamChunk`s, and builds
/// the reply `complete` would have returned from them.
struct OpenAIStreamAssembler {
    private struct PendingToolCall {
        var id: String
        var name: String
        var arguments = ""
    }

    private var text = ""
    private var calls: [Int: PendingToolCall] = [:]
    private var usage = Usage.zero
    private var finishReason: String?

    /// One `data:` payload in, the deltas it carries out.
    mutating func consume(_ payload: String) throws -> [StreamChunk] {
        if payload == "[DONE]" { return [] }
        guard let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: Data(payload.utf8)) else { return [] }
        if let error = chunk.error {
            throw GatewayError.invalidResponse(error.message ?? "the server reported an error mid-stream")
        }
        if let wire = chunk.usage { usage = OpenAICompatibleClient.usage(wire) }
        guard let choice = chunk.choices?.first else { return [] }
        if let reason = choice.finishReason { finishReason = reason }
        guard let delta = choice.delta else { return [] }

        var out: [StreamChunk] = []
        if let thinking = delta.reasoningContent ?? delta.reasoning, !thinking.isEmpty {
            out.append(.thinkingDelta(thinking))
        }
        if let content = delta.content, !content.isEmpty {
            text += content
            out.append(.textDelta(content))
        }
        for call in delta.toolCalls ?? [] {
            let index = call.index ?? 0
            if calls[index] == nil {
                let pending = PendingToolCall(id: call.id ?? "call_\(index)", name: call.function?.name ?? "")
                calls[index] = pending
                out.append(.toolCallStart(ToolCall(id: pending.id, name: pending.name)))
            } else if let name = call.function?.name, calls[index]?.name.isEmpty == true {
                calls[index]?.name = name
            }
            if let arguments = call.function?.arguments, !arguments.isEmpty, let id = calls[index]?.id {
                calls[index]?.arguments += arguments
                try ServerSentEvents.checkToolArguments(calls[index]?.arguments ?? "")
                out.append(.toolCallArguments(id: id, partialJSON: arguments))
            }
        }
        return out
    }

    func response() -> ModelResponse {
        var blocks: [ContentBlock] = []
        if !text.isEmpty { blocks.append(.text(text)) }
        for (_, call) in calls.sorted(by: { $0.key < $1.key }) {
            let arguments = (try? JSONDecoder().decode(JSON.self, from: Data(call.arguments.utf8))) ?? .object([:])
            blocks.append(.toolCall(ToolCall(id: call.id, name: call.name, arguments: arguments)))
        }
        if blocks.isEmpty { blocks.append(.text("")) }
        return ModelResponse(
            message: Message(role: .assistant, content: blocks),
            finishReason: OpenAICompatibleClient.stopReason(from: finishReason),
            usage: usage
        )
    }
}
