import Foundation
import MCP
import os
#if canImport(FoundationModels)
import FoundationModels

/// One Foundation Models tool per registry tool. The tool's name and
/// (compacted) description come from the registry through
/// `NilesToolCatalog`; arguments forward verbatim to the shared dispatcher.
/// Tool protocol availability starts at iOS 26; building the toolset needs
/// nothing newer, so context-budget counting works on iOS 26 runtimes.
@available(iOS 26.0, *)
public struct NilesAgentTool: FoundationModels.Tool {
    public let name: String
    public let description: String

    /// The registry tool's JSON schema projected into a GenerationSchema,
    /// computed once at init — projection is not cheap and the schema is static.
    public var parameters: GenerationSchema { parametersSchema }

    private let parametersSchema: GenerationSchema
    private let dispatcher: NilesToolDispatcher

    public init(for tool: MCP.Tool, dispatcher: NilesToolDispatcher) {
        self.name = tool.name
        // One compacted definition per tool: staging boilerplate lives in the
        // session instructions, so it is stripped here, and the input schema
        // shrinks to an argument summary line.
        self.description = NilesToolCatalog.toolDescription(for: tool)
        self.dispatcher = dispatcher
        do {
            self.parametersSchema = try Self.generationSchema(from: tool.inputSchema)
        } catch {
            // Registry schemas are static and reviewed; a malformed one is a
            // programmer error, and no runtime fallback can answer for it.
            fatalError("Invalid input schema for tool \(tool.name): \(error)")
        }
    }

    /// Never throws: every failure is an in-band error string so the model can
    /// read what went wrong and correct course within the same session.
    public func call(arguments: GeneratedContent) async throws -> String {
        let arguments = Self.registryArguments(from: arguments)
        let outcome = await dispatcher.call(name: name, arguments: arguments)
        return outcome.text
    }

    /// The model's dynamic arguments arrive as GeneratedContent; the
    /// registries take MCP values. A non-structure envelope decodes to no
    /// arguments — the registry then rejects the call in-band (missing
    /// required arguments), which teaches the model the same lesson.
    static func registryArguments(from arguments: GeneratedContent) -> [String: MCP.Value] {
        switch arguments.kind {
        case .structure(let properties, _):
            return properties.mapValues(Self.mcpValue)
        default:
            return [:]
        }
    }

    private static func mcpValue(from content: GeneratedContent) -> MCP.Value {
        switch content.kind {
        case .null:
            return .null
        case .bool(let value):
            return .bool(value)
        case .number(let value):
            // Whole numbers arrive as Double but travel losslessly as Int,
            // which is what the registries declare for counts and percentages.
            if value.truncatingRemainder(dividingBy: 1) == 0, abs(value) < 9_007_199_254_740_992 {
                return .int(Int(value))
            }
            return .double(value)
        case .string(let value):
            return .string(value)
        case .array(let values):
            return .array(values.map(Self.mcpValue))
        case .structure(let properties, _):
            return .object(properties.mapValues(Self.mcpValue))
        @unknown default:
            // Future kinds travel as their JSON — lossless and visible to the
            // registry's argument parser.
            return .string(content.jsonString)
        }
    }

    // MARK: - Schema projection (MCP JSON schema → GenerationSchema)

    static func generationSchema(from schema: MCP.Value) throws -> GenerationSchema {
        try GenerationSchema(root: Self.dynamicSchema(schema), dependencies: [])
    }

    /// The Foundation Models dynamic-schema surface: build a
    /// `DynamicGenerationSchema` tree from the registry's JSON schema, then
    /// root a GenerationSchema on it.
    private static func dynamicSchema(_ schema: MCP.Value) -> DynamicGenerationSchema {
        guard case .object(let fields) = schema else {
            return DynamicGenerationSchema(type: String.self)
        }
        let typeString: String?
        if case .string(let type)? = fields["type"] { typeString = type } else { typeString = nil }
        switch typeString {
        case "object":
            var required: Set<String> = []
            if case .array(let values)? = fields["required"] {
                required = Set(values.compactMap { value in
                    if case .string(let name) = value { return name }
                    return nil
                })
            }
            guard case .object(let definitions)? = fields["properties"] else {
                return DynamicGenerationSchema(name: "object", properties: [])
            }
            let properties = definitions
                .sorted { $0.key < $1.key }
                .map { name, definition in
                    DynamicGenerationSchema.Property(
                        name: name,
                        description: Self.description(of: definition),
                        schema: Self.dynamicSchema(definition),
                        isOptional: !required.contains(name)
                    )
                }
            return DynamicGenerationSchema(name: "object", properties: properties)
        case "array":
            if case .object(let itemSchema)? = fields["items"] {
                return DynamicGenerationSchema(arrayOf: Self.dynamicSchema(.object(itemSchema)))
            }
            return DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self))
        case "string":
            if case .array(let values)? = fields["enum"] {
                let choices = values.compactMap { value in
                    if case .string(let choice) = value { return choice }
                    return nil
                }
                if !choices.isEmpty {
                    return DynamicGenerationSchema(name: "choice", anyOf: choices)
                }
            }
            return DynamicGenerationSchema(type: String.self)
        case "integer":
            return DynamicGenerationSchema(type: Int.self)
        case "number":
            return DynamicGenerationSchema(type: Double.self)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        default:
            return DynamicGenerationSchema(type: String.self)
        }
    }

    private static func description(of definition: MCP.Value) -> String? {
        guard case .object(let fields) = definition,
              case .string(let description)? = fields["description"] else { return nil }
        return description
    }
}

@available(iOS 26.0, *)
public enum NilesToolset {
    /// One `NilesAgentTool` per agent-surface tool (art_yvbPAfG9, v7) —
    /// backed by the shared dispatcher that owns the budget. The registries'
    /// full surfaces stay MCP-only; the model never sees them.
    public static func tools(dispatcher: NilesToolDispatcher) -> [any FoundationModels.Tool] {
        dispatcher.agentToolDefinitions
            .map { NilesAgentTool(for: $0, dispatcher: dispatcher) }
    }
}

/// The on-device proposal agent. One `LanguageModelSession` per request, the
/// registry tools exposed natively, and a mechanical call budget enforced in
/// the shared dispatcher.
@available(iOS 27.0, *)
public struct NilesAgent {
    /// Session-failure diagnostics: the full underlying error at public
    /// privacy, so device Console capture shows the real failure (the
    /// availability gate can read `.available` while the asset is missing
    /// at generation time) instead of an os_log privacy redaction.
    private static let logger = Logger(subsystem: "com.gerstman.niles", category: "agent")

    public struct Outcome: Sendable, Equatable {
        public var summary: String
        public var stagedProposalIds: [String]
    }

    private let dispatcher: NilesToolDispatcher
    private let instructions: String

    public init(reads: ReadToolRegistry, writes: WriteToolRegistry, budget: Int = NilesToolDispatcher.defaultBudget) {
        self.dispatcher = NilesToolDispatcher(reads: reads, writes: writes, budget: budget)
        self.instructions = NilesAgentInstructions.text()
    }

    /// Exposed for tests that drive the dispatcher directly.
    public init(dispatcher: NilesToolDispatcher) {
        self.dispatcher = dispatcher
        self.instructions = NilesAgentInstructions.text()
    }

    public func tools() -> [any FoundationModels.Tool] {
        NilesToolset.tools(dispatcher: dispatcher)
    }

    /// Runs one request to completion. Throws only when the session itself
    /// fails (model unavailable, infrastructure error); every tool-level
    /// failure is in-band and surfaced through the outcome instead.
    public func run(_ request: String) async throws -> Outcome {
        try await run(request, using: SystemLanguageModel())
    }

    /// The runner seam: the scripted-model tests drive this with a custom
    /// `LanguageModel` and get the production instructions and toolset.
    public func run(_ request: String, using model: any LanguageModel) async throws -> Outcome {
        let session: LanguageModelSession
        let response: LanguageModelSession.Response<String>
        do {
            session = try LanguageModelSession(
                model: model,
                tools: NilesToolset.tools(dispatcher: dispatcher),
                instructions: instructions
            )
            response = try await session.respond(to: request)
        } catch {
            // One line at the one session-failure catch site — the full
            // underlying error, public (see the logger's comment).
            Self.logger.error("Agent session failed: \(String(describing: error), privacy: .public)")
            throw AgentRunError.mapped(from: error)
        }
        return Outcome(
            summary: response.content,
            stagedProposalIds: await dispatcher.stagedProposalIds
        )
    }
}
#endif
