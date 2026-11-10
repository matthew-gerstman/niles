import Foundation
import MCP
#if canImport(FoundationModels)
import FoundationModels

/// One Foundation Models tool per registry tool. The tool's name and
/// (compacted) description come from the registry through
/// `NilesToolCatalog`; arguments forward verbatim to the shared dispatcher.
/// Tool protocol availability starts at iOS 26; building the toolset needs
/// nothing newer, so context-budget counting works on iOS 26 runtimes.
@available(iOS 26.0, *)
public struct NilesAgentTool: Tool {
    public let name: String
    public let description: String

    /// The registry tool's JSON schema projected into a GenerationSchema.
    public var parameters: GenerationSchema {
        Self.generationSchema(from: inputSchema)
    }

    /// Tool schemas are static per tool; the projection runs per access.
    private let inputSchema: MCP.Value
    private let dispatcher: NilesToolDispatcher

    public init(for tool: Tool, dispatcher: NilesToolDispatcher) {
        self.name = tool.name
        // One compacted definition per tool: staging boilerplate lives in the
        // session instructions, so it is stripped here, and the input schema
        // shrinks to an argument summary line.
        self.description = NilesToolCatalog.toolDescription(for: tool)
        self.inputSchema = tool.inputSchema
        self.dispatcher = dispatcher
    }

    /// Never throws: every failure is an in-band error string so the model can
    /// read what went wrong and correct course within the same session.
    public func call(arguments: GeneratedContent) async throws -> String {
        let arguments = Self.registryArguments(from: arguments)
        let outcome = await dispatcher.call(name: name, arguments: arguments)
        return outcome.text
    }

    /// The model's dynamic arguments arrive as GeneratedContent; the
    /// registries take MCP values. A malformed envelope decodes to no
    /// arguments — the registry then rejects the call in-band (missing
    /// required arguments), which teaches the model the same lesson.
    static func registryArguments(from arguments: GeneratedContent) -> [String: MCP.Value] {
        guard let data = try? JSONEncoder().encode(arguments),
              let decoded = try? JSONDecoder().decode([String: MCP.Value].self, from: data)
        else { return [:] }
        return decoded
    }

    // MARK: - Schema projection (MCP JSON schema → GenerationSchema)

    static func generationSchema(from schema: MCP.Value) -> GenerationSchema {
        let object = Self.objectShape(schema)
        return GenerationSchema(properties: object.properties, required: object.required)
    }

    private static func objectShape(_ schema: MCP.Value) -> (properties: [GenerationSchema.Property], required: [String]) {
        guard case .object(let fields) = schema else { return ([], []) }
        var required: [String] = []
        if case .array(let requiredValues)? = fields["required"] {
            required = requiredValues.compactMap { value in
                if case .string(let name) = value { return name }
                return nil
            }
        }
        guard case .object(let definitions)? = fields["properties"] else {
            return ([], required)
        }
        let properties = definitions
            .sorted { $0.key < $1.key }
            .map { name, definition in
                GenerationSchema.Property(
                    name: name,
                    type: Self.propertyKind(definition),
                    description: Self.description(of: definition)
                )
            }
        return (properties, required)
    }

    private static func propertyKind(_ definition: MCP.Value) -> GenerationSchema.PropertyKind {
        guard case .object(let fields) = definition else { return .any }
        let typeString: String
        if case .string(let type)? = fields["type"] { typeString = type } else { return .any }
        switch typeString {
        case "string":
            return .string
        case "boolean":
            return .boolean
        case "integer", "number":
            return .number
        case "array":
            let items: GenerationSchema
            if case .object(let itemSchema)? = fields["items"] {
                items = Self.generationSchema(from: .object(itemSchema))
            } else {
                items = GenerationSchema(properties: [], required: [])
            }
            return .array(items)
        case "object":
            return .object(Self.generationSchema(from: definition))
        default:
            return .any
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
    /// One `NilesAgentTool` per registry tool — all of them, reads and writes
    /// alike — backed by the shared dispatcher that owns the budget.
    public static func tools(dispatcher: NilesToolDispatcher) -> [any Tool] {
        (dispatcher.readToolDefinitions + dispatcher.writeToolDefinitions)
            .map { NilesAgentTool(for: $0, dispatcher: dispatcher) }
    }
}

/// The on-device proposal agent. One `LanguageModelSession` per request, the
/// registry tools exposed natively, and a mechanical call budget enforced in
/// the shared dispatcher.
@available(iOS 27.0, *)
public struct NilesAgent {
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

    public func tools() -> [any Tool] {
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
        let session = try LanguageModelSession(
            model: model,
            tools: NilesToolset.tools(dispatcher: dispatcher),
            instructions: instructions
        )
        let response = try await session.respond(to: request)
        return Outcome(
            summary: response.content,
            stagedProposalIds: await dispatcher.stagedProposalIds
        )
    }
}
#endif
