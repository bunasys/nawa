import AgentCore
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Anthropic `LanguageModel` over the Messages API (`POST /v1/messages`).
///
/// Works with api.anthropic.com and any Anthropic-compatible endpoint. The
/// base URL may be given with or without the trailing `/v1`
/// (`https://api.anthropic.com` and `https://api.anthropic.com/v1` both work),
/// because Anthropic tooling conventionally omits it (`ANTHROPIC_BASE_URL`).
public struct AnthropicClient: LanguageModel, Sendable {
    public let providerName: String
    public let baseURL: URL
    public let apiKey: String?
    /// Sent as `anthropic-workspace-id` with an API key. Federation picks the
    /// workspace at token exchange instead (`WorkloadIdentityConfig.workspaceID`).
    public let workspaceID: String?
    /// Used instead of `apiKey` when that is nil (see `WorkloadIdentity.swift`).
    public let workloadIdentity: WorkloadIdentityConfig?
    public let session: URLSession

    static let apiVersion = "2023-06-01"
    /// The Messages API requires `max_tokens`; this applies when the caller sets none.
    static let defaultMaxTokens = 16_000
    /// Non-streaming replies can take minutes while the model thinks, far past
    /// URLSession's 60-second default.
    static let requestTimeout: TimeInterval = 600

    public init(
        providerName: String,
        baseURL: URL,
        apiKey: String? = nil,
        workspaceID: String? = nil,
        workloadIdentity: WorkloadIdentityConfig? = nil,
        session: URLSession = .shared
    ) {
        self.providerName = providerName
        self.baseURL = Self.versionedBaseURL(baseURL)
        self.apiKey = apiKey
        self.workspaceID = workspaceID
        self.workloadIdentity = workloadIdentity
        self.session = session
    }

    // MARK: LanguageModel

    public func complete(_ request: ModelRequest) async throws -> ModelResponse {
        let body = try Self.requestBody(request)
        let data = try await send(method: "POST", url: baseURL.appendingPathComponent("messages"), body: body)
        let reply: JSON
        do {
            reply = try JSONDecoder().decode(JSON.self, from: data)
        } catch {
            throw GatewayError.invalidResponse(String(describing: error))
        }
        return try Self.modelResponse(from: reply, providerName: providerName)
    }

    /// The harness loop only uses `complete`, so streaming is a single chunk
    /// carrying the whole reply rather than a second SSE parser to maintain.
    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await complete(request)
                    if !response.message.text.isEmpty {
                        continuation.yield(.textDelta(response.message.text))
                    }
                    continuation.yield(.finished(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func listModels() async throws -> [ModelSummary] {
        var components = URLComponents(url: baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "limit", value: "1000")]
        let data = try await send(method: "GET", url: components.url!, body: nil)
        let list = try JSONDecoder().decode(JSON.self, from: data)
        let entries = list.objectValue?["data"]?.arrayValue ?? []
        return entries.compactMap { entry in
            guard let id = entry.objectValue?["id"]?.stringValue else { return nil }
            return ModelSummary(id: id, ownedBy: "anthropic")
        }
    }

    // MARK: Domain -> wire

    /// The request carries three prompt-cache breakpoints: the last tool, the
    /// system prompt, and the last block of the newest message. Anthropic
    /// caches the whole prefix up to each breakpoint, so a turn pays full
    /// price only for what changed since the previous one; cache reads cost
    /// about a tenth of fresh input. (The API allows four breakpoints.)
    static func requestBody(_ request: ModelRequest) throws -> JSON {
        var body: [String: JSON] = [
            "model": .string(try request.requiredModel()),
            "max_tokens": .int(request.maxOutputTokens ?? defaultMaxTokens),
            "messages": .array(markLastBlockCacheable(anthropicMessages(request.messages))),
        ]
        let systemText = request.messages
            .filter { $0.role == .system }
            .map(\.text)
            .joined(separator: "\n\n")
        if !systemText.isEmpty {
            body["system"] = .array([
                .object(["type": .string("text"), "text": .string(systemText), "cache_control": cacheControl]),
            ])
        }
        if let tools = request.tools, !tools.isEmpty {
            var wireTools: [JSON] = tools.map { tool in
                .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "input_schema": inputSchema(tool.parameters),
                ])
            }
            wireTools[wireTools.count - 1] = withCacheControl(wireTools[wireTools.count - 1])
            body["tools"] = .array(wireTools)
        }
        // Current Claude models reject sampling parameters, so only send one
        // when the caller explicitly asked for it.
        if let temperature = request.temperature {
            body["temperature"] = .double(temperature)
        }
        return .object(body)
    }

    static let cacheControl: JSON = .object(["type": .string("ephemeral")])

    static func withCacheControl(_ block: JSON) -> JSON {
        var fields = block.objectValue ?? [:]
        fields["cache_control"] = cacheControl
        return .object(fields)
    }

    /// Put the moving cache breakpoint on the newest message, so the next
    /// turn reads everything before it from the cache. Thinking blocks
    /// refuse `cache_control`, so the breakpoint goes on the last block that
    /// accepts one.
    static func markLastBlockCacheable(_ turns: [JSON]) -> [JSON] {
        guard var lastTurn = turns.last?.objectValue,
              var blocks = lastTurn["content"]?.arrayValue
        else { return turns }
        let cacheableTypes: Set<String> = ["text", "tool_use", "tool_result"]
        let cacheableIndex = blocks.lastIndex { block in
            let type = block.objectValue?["type"]?.stringValue ?? ""
            return cacheableTypes.contains(type)
        }
        guard let cacheableIndex else { return turns }
        blocks[cacheableIndex] = withCacheControl(blocks[cacheableIndex])
        lastTurn["content"] = .array(blocks)
        var marked = turns
        marked[marked.count - 1] = .object(lastTurn)
        return marked
    }

    /// Anthropic rejects a schema without `"type"` (OpenAI-compatible
    /// endpoints tolerate it), and tools — MCP ones especially — sometimes
    /// declare "no parameters" as `{}`. Tool inputs are always objects.
    static func inputSchema(_ parameters: JSON) -> JSON {
        var schema = parameters.objectValue ?? [:]
        if schema["type"] == nil {
            schema["type"] = .string("object")
        }
        return .object(schema)
    }

    /// Map the conversation to Anthropic's alternating user/assistant turns.
    ///
    /// System messages move to the top-level `system` field. Tool results are
    /// `tool_result` blocks inside a *user* turn, and consecutive results must
    /// share one user turn, so adjacent same-role turns are merged.
    static func anthropicMessages(_ messages: [Message]) -> [JSON] {
        var turns: [(role: String, blocks: [JSON])] = []
        for message in messages where message.role != .system {
            let role = message.role == .assistant ? "assistant" : "user"
            let blocks = message.content.compactMap(anthropicBlock)
            guard !blocks.isEmpty else { continue }
            if let last = turns.last, last.role == role {
                turns[turns.count - 1].blocks += blocks
            } else {
                turns.append((role, blocks))
            }
        }
        return turns.map { turn in
            .object(["role": .string(turn.role), "content": .array(turn.blocks)])
        }
    }

    static func anthropicBlock(_ block: ContentBlock) -> JSON? {
        switch block {
        case .text(let text):
            // The API rejects empty text blocks.
            if text.isEmpty { return nil }
            return .object(["type": .string("text"), "text": .string(text)])
        case .toolCall(let call):
            return .object([
                "type": .string("tool_use"),
                "id": .string(call.id),
                "name": .string(call.name),
                "input": call.arguments,
            ])
        case .toolResult(let result):
            return .object([
                "type": .string("tool_result"),
                "tool_use_id": .string(result.callID),
                "content": .string(result.content),
                "is_error": .bool(result.isError),
            ])
        case .opaque(let provider, let payload):
            return provider == providerKind ? payload : nil
        }
    }

    // MARK: Wire -> domain

    /// Tags the blocks this client replays verbatim (see `ContentBlock.opaque`).
    static let providerKind = ContentBlock.OpaqueProvider.anthropic

    static func modelResponse(from reply: JSON, providerName: String) throws -> ModelResponse {
        guard let object = reply.objectValue, let content = object["content"]?.arrayValue else {
            throw GatewayError.invalidResponse("no content in /messages response from \(providerName)")
        }
        var blocks: [ContentBlock] = []
        for block in content {
            let fields = block.objectValue ?? [:]
            switch fields["type"]?.stringValue {
            case "text":
                blocks.append(.text(fields["text"]?.stringValue ?? ""))
            case "tool_use":
                let call = ToolCall(
                    id: fields["id"]?.stringValue ?? "",
                    name: fields["name"]?.stringValue ?? "",
                    arguments: fields["input"] ?? .object([:])
                )
                blocks.append(.toolCall(call))
            default:
                // thinking, redacted_thinking and anything newer: keep it so
                // it goes back to the model untouched on the next request.
                blocks.append(.opaque(provider: providerKind, payload: block))
            }
        }
        return ModelResponse(
            message: Message(role: .assistant, content: blocks),
            finishReason: stopReason(from: object["stop_reason"]?.stringValue),
            usage: usage(from: object["usage"])
        )
    }

    /// Anthropic reports prompt-cache reads and writes apart from
    /// `input_tokens`, which matches how `Usage` keeps them.
    static func usage(from wire: JSON?) -> Usage {
        let fields = wire?.objectValue ?? [:]
        return Usage(
            inputTokens: fields["input_tokens"]?.intValue ?? 0,
            outputTokens: fields["output_tokens"]?.intValue ?? 0,
            cacheReadTokens: fields["cache_read_input_tokens"]?.intValue ?? 0,
            cacheWriteTokens: fields["cache_creation_input_tokens"]?.intValue ?? 0
        )
    }

    static func stopReason(from wire: String?) -> StopReason? {
        switch wire {
        case "end_turn", "stop_sequence": return .endTurn
        case "max_tokens": return .maxTokens
        case "tool_use": return .toolUse
        case "refusal": return .refusal
        default: return nil
        }
    }

    // MARK: HTTP plumbing

    static func versionedBaseURL(_ url: URL) -> URL {
        let path = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
        if path.hasSuffix("/v1") { return url }
        return url.appendingPathComponent("v1")
    }

    private func send(method: String, url: URL, body: JSON?) async throws -> Data {
        var urlRequest = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        urlRequest.httpMethod = method
        urlRequest.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if let apiKey {
            urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            if let workspaceID {
                urlRequest.setValue(workspaceID, forHTTPHeaderField: "anthropic-workspace-id")
            }
        } else if let workloadIdentity {
            let tokenSource = await WorkloadIdentityTokenSource.shared(
                for: workloadIdentity,
                tokenURL: baseURL.appendingPathComponent("oauth/token"),
                session: session
            )
            let accessToken = try await tokenSource.accessToken()
            urlRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await session.data(for: urlRequest)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw GatewayError.httpError(statusCode: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }
}
