import AgentCore

/// Spots a run that is stuck: the model keeps making the same tool calls and
/// getting the same results back. It stands in for a hard turn cap, so long
/// tasks run as long as they make progress.
///
/// The check is deterministic — turns are compared exactly, no model is
/// asked. Results are part of the comparison on purpose: re-running a build
/// that fails differently each time is progress, not a loop.
struct LoopDetector {
    /// No check before this many tool turns. Nil = never check.
    let checkAfterTurns: Int?
    /// How many of the newest turns are compared.
    static let window = 10
    /// A turn seen this many times within the window means the run is stuck.
    static let repeatLimit = 3

    /// One tool call and what it returned.
    private struct Step: Hashable {
        var name: String
        var arguments: JSON
        var result: String
        var isError: Bool
    }

    private var recentTurns: [[Step]] = []
    private var turnCount = 0

    init(checkAfterTurns: Int?) {
        self.checkAfterTurns = checkAfterTurns
    }

    /// Forget the previous prompt's turns.
    mutating func reset() {
        recentTurns = []
        turnCount = 0
    }

    /// Records a finished tool turn. Returns the repeated turn's tool names
    /// when the run is stuck, nil while it is making progress.
    mutating func record(calls: [ToolCall], results: [ToolCallResult]) -> [String]? {
        let turn = calls.map { call in
            let result = results.first { $0.callID == call.id }
            return Step(name: call.name, arguments: call.arguments, result: result?.content ?? "", isError: result?.isError ?? false)
        }
        turnCount += 1
        recentTurns.append(turn)
        if recentTurns.count > Self.window {
            recentTurns.removeFirst()
        }

        guard let checkAfterTurns, turnCount >= checkAfterTurns else { return nil }
        // Counting every turn in the window (not just the newest) also
        // catches cycles such as A, B, A, B, A, B.
        let counts = recentTurns.reduce(into: [[Step]: Int]()) { $0[$1, default: 0] += 1 }
        guard let stuck = counts.first(where: { $0.value >= Self.repeatLimit }) else { return nil }
        return stuck.key.map(\.name)
    }
}
