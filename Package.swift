// swift-tools-version:6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "nawa",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "AgentCore", targets: ["AgentCore"]),
        .library(name: "AgentJSONRPC", targets: ["AgentJSONRPC"]),
        .library(name: "AgentGateway", targets: ["AgentGateway"]),
        .library(name: "AgentTools", targets: ["AgentTools"]),
        .library(name: "AgentInstructions", targets: ["AgentInstructions"]),
        .library(name: "AgentJournal", targets: ["AgentJournal"]),
        .library(name: "AgentLoop", targets: ["AgentLoop"]),
        .library(name: "AgentMCP", targets: ["AgentMCP"]),
        .library(name: "AgentACP", targets: ["AgentACP"]),
        .library(name: "AgentTUI", targets: ["AgentTUI"]),
        .executable(name: "nawa", targets: ["nawa"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.24.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.6.0"),
    ],
    targets: [
        // Core domain model. No dependencies beyond the Swift standard library.
        .target(name: "AgentCore"),

        // JSON-RPC 2.0 envelope shared by MCP and ACP transports.
        .target(name: "AgentJSONRPC", dependencies: ["AgentCore"]),

        // AI Gateway: language model protocol, OpenAI-compatible provider, model discovery.
        .target(name: "AgentGateway", dependencies: ["AgentCore", "AgentJSONRPC"]),

        // Tool protocol, registry, and built-in tools.
        .target(name: "AgentTools", dependencies: ["AgentCore"]),

        // AGENTS.md discovery and parsing.
        .target(name: "AgentInstructions", dependencies: ["AgentCore"]),

        // The session journal as a JSON Lines file: writing it and reading it back.
        .target(name: "AgentJournal", dependencies: ["AgentCore"]),

        // The agent loop: the Runner/Event loop that drives a session to completion.
        .target(name: "AgentLoop", dependencies: [
            "AgentCore", "AgentGateway", "AgentTools", "AgentInstructions",
        ]),

        // MCP (Model Context Protocol) client: connects external tool servers.
        .target(name: "AgentMCP", dependencies: ["AgentCore", "AgentJSONRPC", "AgentTools"]),

        // ACP (Agent Client Protocol) server: streamable HTTP + WebSocket transports.
        .target(name: "AgentACP", dependencies: [
            "AgentCore", "AgentJSONRPC", "AgentGateway", "AgentTools",
            "AgentInstructions", "AgentLoop", "AgentMCP",
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
        ]),

        // Terminal UI for the REPL: key decoding, line editing, layout, inline rendering.
        .target(name: "AgentTUI", dependencies: ["AgentCore"]),

        // Executable: REPL + ACP server entry point.
        .executableTarget(name: "nawa", dependencies: [
            "AgentCore", "AgentGateway", "AgentTools", "AgentInstructions",
            "AgentLoop", "AgentMCP", "AgentACP", "AgentTUI",
        ]),

        .testTarget(name: "AgentCoreTests", dependencies: ["AgentCore"]),
        .testTarget(name: "AgentGatewayTests", dependencies: ["AgentCore", "AgentGateway"]),
        .testTarget(name: "AgentLoopTests", dependencies: ["AgentCore", "AgentGateway", "AgentTools", "AgentLoop", "AgentJournal"]),
        .testTarget(name: "AgentJournalTests", dependencies: ["AgentCore", "AgentJournal"]),
        .testTarget(name: "AgentToolsTests", dependencies: ["AgentCore", "AgentTools"]),
        .testTarget(name: "AgentInstructionsTests", dependencies: ["AgentInstructions"]),
        .testTarget(name: "AgentMCPTests", dependencies: ["AgentMCP"]),
        .testTarget(name: "AgentACPTests", dependencies: ["AgentACP"]),
        .testTarget(name: "AgentTUITests", dependencies: ["AgentCore", "AgentTUI"]),
        .testTarget(name: "nawaTests", dependencies: ["nawa"]),
    ]
)
