import AgentCore
import AgentGateway
import AgentLoop
import AgentTools
import Foundation

/// The small slice of the Kimi Code CLI that Waku (https://github.com/egoist/waku)
/// calls, so Nawa can be plugged into Waku as its "Kimi Code" provider by
/// pointing that provider's binary path at `nawa`.
///
/// Waku has no slot for arbitrary agents, but it drives Kimi Code purely over
/// ACP on stdio (`<binary> acp`, served by `ACPStdioTransport`). Outside the
/// ACP session it runs only these commands:
///
/// - `<binary> --version` — install detection (handled in `AgentCLI`).
/// - `<binary> provider list --json` / `<binary> provider list` — the model
///   picker's catalog and its default.
/// - `<binary> --prompt <text> --output-format text [--model <id>]` — one-shot
///   generation, used for commit messages.
enum WakuCompatibility {
    /// `nawa provider list [--json]`: the active provider's models.
    ///
    /// JSON shape (Kimi's): `{"models": {"<id>": {"model": "<id>"}}}`.
    /// Text shape: a `Default model: <id>` line followed by one id per line.
    static func providerCommand(arguments: [String]) async throws {
        guard arguments.first == "list" else {
            print("Usage: nawa provider list [--json]")
            return
        }
        let gateway = try AgentCLI.resolveGateway()
        let defaultModel = gateway.activeProvider?.model

        var modelIDs: [String] = []
        do {
            modelIDs = try await gateway.listModels().map(\.id).sorted()
        } catch {
            // An unreachable endpoint must not break Waku's picker; it falls
            // back to the configured default below.
            FileHandle.standardError.write(Data("nawa: could not list models: \(error)\n".utf8))
        }
        if let defaultModel, !modelIDs.contains(defaultModel) {
            modelIDs.insert(defaultModel, at: 0)
        }

        if arguments.contains("--json") {
            var models: [String: JSON] = [:]
            for id in modelIDs {
                models[id] = .object(["model": .string(id)])
            }
            print(JSON.object(["models": .object(models)]).description)
            return
        }
        if let defaultModel {
            print("Default model: \(defaultModel)")
        }
        for id in modelIDs {
            print(id)
        }
    }

    /// `nawa --prompt <text> [--model <id>] [--output-format text]`: answer
    /// one prompt with no tools and print the reply.
    static func oneShotPrompt(arguments: [String]) async throws {
        guard let prompt = value(after: "--prompt", in: arguments) else {
            throw WakuCompatibilityError.missingValue("--prompt")
        }
        let loop = AgentLoop(
            gateway: try AgentCLI.resolveGateway(),
            tools: ToolRegistry([]),
            options: LoopOptions(maxTurns: 1, sendTools: false)
        )
        loop.model = value(after: "--model", in: arguments)

        for try await event in loop.run(prompt: prompt) {
            switch event {
            case .result(let result):
                guard result.isSuccess else {
                    throw WakuCompatibilityError.failed(result.errorMessage ?? result.kind.rawValue)
                }
                print(result.text ?? "")
            default:
                break
            }
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}

enum WakuCompatibilityError: Error, LocalizedError {
    case missingValue(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let flag): return "\(flag) needs a value"
        case .failed(let reason): return "prompt failed: \(reason)"
        }
    }
}
