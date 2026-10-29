import AgentCore
import Foundation

/// The journal's line format: one JSON object per record (proposal 0005).
///
/// Every line has the same envelope (`v`, `type`, `seq`, `at`, `session`)
/// and the record's own fields beside it. Field names are snake_case and a
/// missing value is left out rather than written as null, so tools like
/// DuckDB or `jq` read the file without knowing Nawa.
///
/// Encoding and decoding sit side by side, one record type after another,
/// so a field can't be renamed on one side only.
public enum JournalFormat {
    /// Raised when the meaning of a field changes or a field is removed;
    /// new optional fields don't change it.
    public static let version = 1

    /// One record as a line of JSON, without the trailing newline.
    public static func encode(_ entry: JournalEntry, seq: Int) throws -> Data {
        var fields = recordFields(entry.record)
        fields["v"] = .int(version)
        fields["seq"] = .int(seq)
        fields["at"] = .string(timestamp(entry.at))
        fields["session"] = .string(entry.session)
        let encoder = JSONEncoder()
        // Sorted keys keep lines stable, so two journals can be diffed.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(JSON.object(fields))
    }

    /// One line back into a record.
    public static func decode(_ line: Data) throws -> JournalLine {
        let json = try JSONDecoder().decode(JSON.self, from: line)
        let fields = Fields(json)
        let lineVersion = try fields.int("v")
        guard lineVersion <= version else { throw JournalFormatError.unsupportedVersion(lineVersion) }
        let entry = JournalEntry(
            session: try fields.string("session"),
            at: try fields.date("at"),
            record: try record(from: fields)
        )
        return JournalLine(seq: try fields.int("seq"), entry: entry)
    }

    // MARK: Records

    private static func recordFields(_ record: JournalRecord) -> [String: JSON] {
        switch record {
        case .sessionStarted(let start):
            return object(
                ("type", .string("session_started")),
                ("mode", .string(start.origin.mode)),
                ("nawa_version", start.origin.nawaVersion.map(JSON.string)),
                ("cwd", .string(start.cwd)),
                ("model", start.model.map(JSON.string)),
                ("options", start.options),
                ("parent", start.parent.map { .object(["session": .string($0.session), "call_id": .string($0.callID)]) }),
                ("resumed", start.resumed ? .bool(true) : nil)
            )
        case .message(let message, let appendedToContext):
            return object(
                ("type", .string("message")),
                ("message", messageJSON(message)),
                ("appended_to_context", .bool(appendedToContext))
            )
        case .tools(let id, let definitions):
            return object(
                ("type", .string("tools")),
                ("id", .string(id)),
                ("definitions", .array(definitions.map(toolDefinitionJSON)))
            )
        case .runStarted(let promptMessageID, let model):
            return object(
                ("type", .string("run_started")),
                ("prompt_message", .string(promptMessageID)),
                ("model", model.map(JSON.string))
            )
        case .modelCall(let call):
            return modelCallFields(call)
        case .toolRun(let run):
            return object(
                ("type", .string("tool_run")),
                ("call_id", .string(run.callID)),
                ("name", .string(run.name)),
                ("started_at", .string(timestamp(run.startedAt))),
                ("duration_ms", .int(run.durationMS)),
                ("output_chars", .int(run.outputChars)),
                ("is_error", .bool(run.isError))
            )
        case .contextRewrite(let rewrite):
            return object(
                ("type", .string("context_rewrite")),
                ("reason", .string(rewrite.reason.rawValue)),
                ("removed", strings(rewrite.removed)),
                ("added", strings(rewrite.added)),
                ("context", strings(rewrite.context)),
                ("model_call", rewrite.modelCallID.map(JSON.string))
            )
        case .steered(let messageID):
            return object(("type", .string("steered")), ("message", .string(messageID)))
        case .noteSaved(let note):
            return object(("type", .string("note_saved")), ("note", .string(note)))
        case .modelChanged(let from, let to):
            return object(("type", .string("model_changed")), ("from", from.map(JSON.string)), ("to", to.map(JSON.string)))
        case .refusal(let notice):
            var fields = refusalFields(notice)
            fields["type"] = .string("refusal")
            return fields
        case .runFinished(let result):
            return object(
                ("type", .string("run_finished")),
                ("kind", .string(result.kind.rawValue)),
                ("text", result.text.map(JSON.string)),
                ("num_turns", .int(result.numTurns)),
                ("usage", usageJSON(result.usage)),
                ("cost_usd", result.costEstimate.map(JSON.double)),
                ("stop_reason", result.stopReason.map { .string($0.rawValue) }),
                ("error", result.errorMessage.map(JSON.string)),
                ("refusal", result.refusal.map { .object(refusalFields($0)) })
            )
        }
    }

    private static func record(from fields: Fields) throws -> JournalRecord {
        let type = try fields.string("type")
        switch type {
        case "session_started":
            let parent = try fields.optionalObject("parent").map {
                JournalParent(session: try $0.string("session"), callID: try $0.string("call_id"))
            }
            let origin = JournalOrigin(mode: try fields.string("mode"), nawaVersion: fields.optionalString("nawa_version"))
            let start = SessionStart(
                origin: origin,
                cwd: try fields.string("cwd"),
                model: fields.optionalString("model"),
                options: fields.raw["options"] ?? .object([:]),
                parent: parent,
                resumed: fields.raw["resumed"]?.boolValue ?? false
            )
            return .sessionStarted(start)
        case "message":
            return .message(try message(from: try fields.object("message")), appendedToContext: try fields.bool("appended_to_context"))
        case "tools":
            let definitions = try fields.objects("definitions").map(toolDefinition)
            return .tools(id: try fields.string("id"), definitions: definitions)
        case "run_started":
            return .runStarted(promptMessageID: try fields.string("prompt_message"), model: fields.optionalString("model"))
        case "model_call":
            return .modelCall(try modelCall(from: fields))
        case "tool_run":
            let run = ToolRunRecord(
                callID: try fields.string("call_id"),
                name: try fields.string("name"),
                startedAt: try fields.date("started_at"),
                durationMS: try fields.int("duration_ms"),
                outputChars: try fields.int("output_chars"),
                isError: try fields.bool("is_error")
            )
            return .toolRun(run)
        case "context_rewrite":
            guard let reason = ContextRewrite.Reason(rawValue: try fields.string("reason")) else {
                throw JournalFormatError.badValue("reason")
            }
            let rewrite = ContextRewrite(
                reason: reason,
                removed: try fields.strings("removed"),
                added: try fields.strings("added"),
                context: try fields.strings("context"),
                modelCallID: fields.optionalString("model_call")
            )
            return .contextRewrite(rewrite)
        case "steered":
            return .steered(messageID: try fields.string("message"))
        case "note_saved":
            return .noteSaved(try fields.string("note"))
        case "model_changed":
            return .modelChanged(from: fields.optionalString("from"), to: fields.optionalString("to"))
        case "refusal":
            return .refusal(refusal(from: fields))
        case "run_finished":
            guard let kind = AgentResultKind(rawValue: try fields.string("kind")) else {
                throw JournalFormatError.badValue("kind")
            }
            let result = AgentResult(
                kind: kind,
                text: fields.optionalString("text"),
                usage: try usage(from: try fields.object("usage")),
                numTurns: try fields.int("num_turns"),
                sessionID: try fields.string("session"),
                stopReason: fields.optionalString("stop_reason").flatMap(StopReason.init(rawValue:)),
                costEstimate: fields.optionalDouble("cost_usd"),
                errorMessage: fields.optionalString("error"),
                refusal: fields.optionalObject("refusal").map(refusal)
            )
            return .runFinished(result)
        default:
            throw JournalFormatError.unknownType(type)
        }
    }

    // MARK: Model calls

    private static func modelCallFields(_ call: ModelCallRecord) -> [String: JSON] {
        let request = object(
            ("messages", strings(call.request.messageIDs)),
            ("tools", call.request.toolsID.map(JSON.string)),
            ("model", call.request.model.map(JSON.string)),
            ("provider", call.request.provider.map(JSON.string)),
            ("max_output_tokens", call.request.maxOutputTokens.map(JSON.int)),
            ("temperature", call.request.temperature.map(JSON.double)),
            ("streamed", .bool(call.request.streamed))
        )
        let response = call.response.map { response in
            JSON.object(object(
                ("message", .string(response.messageID)),
                ("stop_reason", response.stopReason.map { .string($0.rawValue) }),
                ("model", response.model.map(JSON.string)),
                ("provider", response.provider.map(JSON.string)),
                ("replaced_provider", response.replacedProvider.map(JSON.string)),
                ("declined_by", strings(response.declinedBy))
            ))
        }
        let timing = object(
            ("started_at", .string(timestamp(call.startedAt))),
            ("first_chunk_ms", call.firstChunkMS.map(JSON.int)),
            ("duration_ms", .int(call.durationMS))
        )
        let failedAttempts = call.failedAttempts.map { attempt in
            JSON.object([
                "provider": .string(attempt.provider),
                "error": .string(attempt.error),
                "duration_ms": .int(attempt.durationMS),
            ])
        }
        let wire = call.wire.map { wire in
            JSON.object(object(
                ("request_bytes", .int(wire.requestBytes)),
                ("provider_request_id", wire.providerRequestID.map(JSON.string)),
                ("rate_limit", wire.rateLimitHeaders.isEmpty ? nil : .object(wire.rateLimitHeaders.mapValues(JSON.string)))
            ))
        }
        return object(
            ("type", .string("model_call")),
            ("id", .string(call.id)),
            ("purpose", .string(call.purpose.rawValue)),
            ("request", .object(request)),
            ("response", response),
            ("usage", usageJSON(call.usage)),
            ("cost_usd", call.costUSD.map(JSON.double)),
            ("timing", .object(timing)),
            ("failed_attempts", failedAttempts.isEmpty ? nil : .array(failedAttempts)),
            ("wire", wire),
            ("error", call.error.map(JSON.string))
        )
    }

    private static func modelCall(from fields: Fields) throws -> ModelCallRecord {
        guard let purpose = ModelCallRecord.Purpose(rawValue: try fields.string("purpose")) else {
            throw JournalFormatError.badValue("purpose")
        }
        let requestFields = try fields.object("request")
        let request = ModelCallRecord.Request(
            messageIDs: try requestFields.strings("messages"),
            toolsID: requestFields.optionalString("tools"),
            model: requestFields.optionalString("model"),
            provider: requestFields.optionalString("provider"),
            maxOutputTokens: requestFields.optionalInt("max_output_tokens"),
            temperature: requestFields.optionalDouble("temperature"),
            streamed: try requestFields.bool("streamed")
        )
        let response = try fields.optionalObject("response").map { response in
            ModelCallRecord.Response(
                messageID: try response.string("message"),
                stopReason: response.optionalString("stop_reason").flatMap(StopReason.init(rawValue:)),
                model: response.optionalString("model"),
                provider: response.optionalString("provider"),
                replacedProvider: response.optionalString("replaced_provider"),
                declinedBy: try response.strings("declined_by")
            )
        }
        let timing = try fields.object("timing")
        let failedAttempts = try (fields.optionalObjects("failed_attempts") ?? []).map { attempt in
            FailedAttempt(provider: try attempt.string("provider"), error: try attempt.string("error"), durationMS: try attempt.int("duration_ms"))
        }
        let wire = try fields.optionalObject("wire").map { wire in
            WireFacts(
                requestBytes: try wire.int("request_bytes"),
                providerRequestID: wire.optionalString("provider_request_id"),
                rateLimitHeaders: (wire.raw["rate_limit"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
            )
        }
        return ModelCallRecord(
            id: try fields.string("id"),
            purpose: purpose,
            request: request,
            response: response,
            usage: try usage(from: try fields.object("usage")),
            costUSD: fields.optionalDouble("cost_usd"),
            startedAt: try timing.date("started_at"),
            firstChunkMS: timing.optionalInt("first_chunk_ms"),
            durationMS: try timing.int("duration_ms"),
            failedAttempts: failedAttempts,
            wire: wire,
            error: fields.optionalString("error")
        )
    }

    // MARK: Messages

    /// Content blocks as `{"type": .string("text"), …}` objects, the shape most
    /// readers expect, not Swift's synthesized enum encoding.
    private static func messageJSON(_ message: Message) -> JSON {
        let blocks: [JSON] = message.content.map { block in
            switch block {
            case .text(let text):
                return .object(["type": .string("text"), "text": .string(text)])
            case .toolCall(let call):
                return .object(["type": .string("tool_call"), "id": .string(call.id), "name": .string(call.name), "arguments": call.arguments])
            case .toolResult(let result):
                return .object([
                    "type": .string("tool_result"),
                    "call_id": .string(result.callID),
                    "name": .string(result.name),
                    "content": .string(result.content),
                    "is_error": .bool(result.isError),
                ])
            case .opaque(let provider, let payload):
                return .object(["type": .string("opaque"), "provider": .string(provider), "payload": payload])
            }
        }
        return .object(["id": .string(message.id), "role": .string(message.role.rawValue), "content": .array(blocks)])
    }

    private static func message(from fields: Fields) throws -> Message {
        guard let role = Role(rawValue: try fields.string("role")) else { throw JournalFormatError.badValue("role") }
        let content = try fields.objects("content").map { block -> ContentBlock in
            switch try block.string("type") {
            case "text":
                return .text(try block.string("text"))
            case "tool_call":
                return .toolCall(ToolCall(id: try block.string("id"), name: try block.string("name"), arguments: block.raw["arguments"] ?? .object([:])))
            case "tool_result":
                let result = ToolCallResult(
                    callID: try block.string("call_id"),
                    name: try block.string("name"),
                    content: try block.string("content"),
                    isError: try block.bool("is_error")
                )
                return .toolResult(result)
            case "opaque":
                return .opaque(provider: try block.string("provider"), payload: block.raw["payload"] ?? .null)
            case let other:
                throw JournalFormatError.badValue("content block type \(other)")
            }
        }
        return Message(id: try fields.string("id"), role: role, content: content)
    }

    // MARK: Small types

    private static func toolDefinitionJSON(_ definition: ToolDefinition) -> JSON {
        .object(["name": .string(definition.name), "description": .string(definition.description), "parameters": definition.parameters])
    }

    private static func toolDefinition(from fields: Fields) throws -> ToolDefinition {
        ToolDefinition(name: try fields.string("name"), description: try fields.string("description"), parameters: fields.raw["parameters"] ?? .object([:]))
    }

    private static func usageJSON(_ usage: Usage) -> JSON {
        .object(object(
            ("input_tokens", .int(usage.inputTokens)),
            ("output_tokens", .int(usage.outputTokens)),
            ("cache_read_tokens", .int(usage.cacheReadTokens)),
            ("cache_write_tokens", .int(usage.cacheWriteTokens)),
            // Only reasoning models report it: absent means "not reported".
            ("reasoning_tokens", usage.reasoningTokens > 0 ? .int(usage.reasoningTokens) : nil)
        ))
    }

    private static func usage(from fields: Fields) throws -> Usage {
        Usage(
            inputTokens: try fields.int("input_tokens"),
            outputTokens: try fields.int("output_tokens"),
            cacheReadTokens: try fields.int("cache_read_tokens"),
            cacheWriteTokens: try fields.int("cache_write_tokens"),
            reasoningTokens: fields.optionalInt("reasoning_tokens") ?? 0
        )
    }

    private static func refusalFields(_ notice: RefusalNotice) -> [String: JSON] {
        object(
            ("declined_by", notice.declinedBy.map(JSON.string)),
            ("category", notice.category.map(JSON.string)),
            ("explanation", notice.explanation.map(JSON.string)),
            ("answered_by", notice.answeredBy.map(JSON.string))
        )
    }

    private static func refusal(from fields: Fields) -> RefusalNotice {
        RefusalNotice(
            declinedBy: fields.optionalString("declined_by"),
            category: fields.optionalString("category"),
            explanation: fields.optionalString("explanation"),
            answeredBy: fields.optionalString("answered_by")
        )
    }

    // MARK: Helpers

    /// An object from key-value pairs, leaving out the nil values.
    private static func object(_ pairs: (String, JSON?)...) -> [String: JSON] {
        var fields: [String: JSON] = [:]
        for (key, value) in pairs {
            if let value { fields[key] = value }
        }
        return fields
    }

    private static func strings(_ values: [String]) -> JSON {
        .array(values.map(JSON.string))
    }

    /// UTC with milliseconds, e.g. `2026-10-28T08:01:12.481Z`.
    static func timestamp(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}

/// A record read back from a journal, with its place in the file.
public struct JournalLine: Sendable, Hashable {
    public var seq: Int
    public var entry: JournalEntry

    public init(seq: Int, entry: JournalEntry) {
        self.seq = seq
        self.entry = entry
    }
}

public enum JournalFormatError: Error, Sendable, Equatable {
    case missingField(String)
    case badValue(String)
    case unknownType(String)
    case unsupportedVersion(Int)
}

/// Typed access to a decoded object's fields, throwing on what a record
/// can't do without.
private struct Fields {
    let raw: [String: JSON]

    init(_ json: JSON) {
        raw = json.objectValue ?? [:]
    }

    func string(_ key: String) throws -> String {
        guard let value = raw[key]?.stringValue else { throw JournalFormatError.missingField(key) }
        return value
    }

    func optionalString(_ key: String) -> String? {
        raw[key]?.stringValue
    }

    func int(_ key: String) throws -> Int {
        guard let value = raw[key]?.intValue else { throw JournalFormatError.missingField(key) }
        return value
    }

    func optionalInt(_ key: String) -> Int? {
        raw[key]?.intValue
    }

    /// A whole number decodes as `.int`, so both cases count.
    func optionalDouble(_ key: String) -> Double? {
        switch raw[key] {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    func bool(_ key: String) throws -> Bool {
        guard let value = raw[key]?.boolValue else { throw JournalFormatError.missingField(key) }
        return value
    }

    func date(_ key: String) throws -> Date {
        let text = try string(key)
        guard let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) else {
            throw JournalFormatError.badValue(key)
        }
        return date
    }

    func strings(_ key: String) throws -> [String] {
        guard let values = raw[key]?.arrayValue else { throw JournalFormatError.missingField(key) }
        return values.compactMap(\.stringValue)
    }

    func object(_ key: String) throws -> Fields {
        guard let value = raw[key], value.objectValue != nil else { throw JournalFormatError.missingField(key) }
        return Fields(value)
    }

    func optionalObject(_ key: String) -> Fields? {
        guard let value = raw[key], value.objectValue != nil else { return nil }
        return Fields(value)
    }

    func objects(_ key: String) throws -> [Fields] {
        guard let values = raw[key]?.arrayValue else { throw JournalFormatError.missingField(key) }
        return values.map(Fields.init)
    }

    func optionalObjects(_ key: String) -> [Fields]? {
        raw[key]?.arrayValue?.map(Fields.init)
    }
}
