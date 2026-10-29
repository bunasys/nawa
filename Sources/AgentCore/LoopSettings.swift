/// A model's price, in USD per million tokens.
public struct TokenPrice: Codable, Sendable, Equatable {
    public var inputPerMillion: Double
    public var outputPerMillion: Double

    public init(inputPerMillion: Double, outputPerMillion: Double) {
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
    }

    private enum CodingKeys: String, CodingKey {
        case inputPerMillion = "input_per_million"
        case outputPerMillion = "output_per_million"
    }
}

/// The agent loop's settings a person or a server may change, as a
/// published contract.
///
/// Every field is optional: nil leaves the program's own choice in place,
/// so the same settings can be applied over different defaults
/// (`LoopOptions.applying(_:)` in `AgentLoop`). The JSON keys are fixed
/// snake_case names: `nawa config` saves them under them, and a server
/// can send them to an agent it runs (Hafez to its reviewers).
///
/// ```json
/// { "compact_at": 600000, "helper_model": "gpt-4o-mini",
///   "price": { "input_per_million": 3, "output_per_million": 15 },
///   "max_budget_usd": 2, "stream": false }
/// ```
public struct LoopSettings: Codable, Sendable, Equatable {
    /// Summarize older messages once a request reaches this many tokens.
    public var compactAt: Int?
    /// A cheaper model, same provider, for sub-agents and summaries.
    public var helperModel: String?
    /// The main model's price; turns on cost estimates.
    public var price: TokenPrice?
    /// `helperModel`'s price; without it, helper calls cost `price`.
    public var helperPrice: TokenPrice?
    /// Stop a prompt once the session's estimated cost reaches this (needs `price`).
    public var maxBudgetUSD: Double?
    /// The model to retry on when the session's model declines a prompt.
    public var fallbackModel: String?
    /// Stream replies as they arrive.
    public var stream: Bool?

    public init(
        compactAt: Int? = nil,
        helperModel: String? = nil,
        price: TokenPrice? = nil,
        helperPrice: TokenPrice? = nil,
        maxBudgetUSD: Double? = nil,
        fallbackModel: String? = nil,
        stream: Bool? = nil
    ) {
        self.compactAt = compactAt
        self.helperModel = helperModel
        self.price = price
        self.helperPrice = helperPrice
        self.maxBudgetUSD = maxBudgetUSD
        self.fallbackModel = fallbackModel
        self.stream = stream
    }

    private enum CodingKeys: String, CodingKey {
        case compactAt = "compact_at"
        case helperModel = "helper_model"
        case price
        case helperPrice = "helper_price"
        case maxBudgetUSD = "max_budget_usd"
        case fallbackModel = "fallback_model"
        case stream
    }

    /// These settings with every field `other` sets replacing this one's.
    public func overlaid(by other: LoopSettings) -> LoopSettings {
        LoopSettings(
            compactAt: other.compactAt ?? compactAt,
            helperModel: other.helperModel ?? helperModel,
            price: other.price ?? price,
            helperPrice: other.helperPrice ?? helperPrice,
            maxBudgetUSD: other.maxBudgetUSD ?? maxBudgetUSD,
            fallbackModel: other.fallbackModel ?? fallbackModel,
            stream: other.stream ?? stream
        )
    }
}
