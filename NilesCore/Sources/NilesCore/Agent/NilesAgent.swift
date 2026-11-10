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
    private static func dynamicSchema(_ schema: MCP.Value, isRoot: Bool = true) -> DynamicGenerationSchema {
        guard case .object(let fields) = schema else {
            return DynamicGenerationSchema(type: String.self)
        }
        let typeString: String?
        if case .string(let type)? = fields["type"] { typeString = type } else { typeString = nil }
        switch typeString {
        case "object":
            // Nested dynamic objects (any object that is a property or array
            // item) must not build a named DynamicGenerationSchema — the
            // on-device constraint compiler fails on them at respond time
            // ("Reference to undefined symbol: #"). Only the root object
            // may be a named schema. Free-form GeneratedContent is the
            // SDK's documented representation, and registryArguments
            // forwards the raw structure verbatim to the registry's
            // argument parser, which validates the payload.
            if !isRoot {
                return DynamicGenerationSchema(type: GeneratedContent.self)
            }
            guard case .object(let definitions)? = fields["properties"], !definitions.isEmpty else {
                // A property-less object (emptyObjectSchema read tools, the
                // free-form 'recurrence' payload, 'recurrences' items) must not
                // project to DynamicGenerationSchema(name:, properties: []) —
                // an empty grammar rule the on-device constraint compiler
                // rejects ("Reference to undefined symbol: #"). GeneratedContent
                // is the SDK's documented free-form Generable: the model may
                // emit any object, and registryArguments already forwards the
                // raw structure verbatim to the registry's argument parser.
                return DynamicGenerationSchema(type: GeneratedContent.self)
            }
            var required: Set<String> = []
            if case .array(let values)? = fields["required"] {
                required = Set(values.compactMap { value in
                    if case .string(let name) = value { return name }
                    return nil
                })
            }
            let properties = definitions
                .sorted { $0.key < $1.key }
                .map { name, definition in
                    DynamicGenerationSchema.Property(
                        name: name,
                        description: Self.description(of: definition),
                        schema: Self.dynamicSchema(definition, isRoot: false),
                        isOptional: !required.contains(name)
                    )
                }
            return DynamicGenerationSchema(name: "object", properties: properties)
        case "array":
            if case .object(let itemSchema)? = fields["items"] {
                return DynamicGenerationSchema(arrayOf: Self.dynamicSchema(.object(itemSchema), isRoot: false))
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
        // One `respond(to:)` per run — the SDK's automatic tool calling
        // loops the rounds internally, and each round's tool calls surface
        // here through the dispatcher's trace lines between these two.
        Self.logger.info(
            "Model round 1: respond starting: \(AgentRunTrace.truncated(request, to: 500), privacy: .public)"
        )
        await AgentRunTraceStore.shared.recordRound(
            "respond starting: \(AgentRunTrace.truncated(request, to: 500))"
        )
        let session: LanguageModelSession
        let response: LanguageModelSession.Response<String>
        do {
            session = try LanguageModelSession(
                model: model,
                tools: NilesToolset.tools(dispatcher: dispatcher),
                instructions: instructions
            )
        } catch {
            // The full underlying error chain, public (see the logger's comment).
            Self.logger.error("Agent session creation failed with the full toolset: \(AgentRunTrace.reflectedErrorChain(error), privacy: .public)")
            await AgentRunTraceStore.shared.recordError(AgentRunTrace.reflectedErrorChain(error))
            await Self.logSessionDiagnostics(for: error)
            await bisectToolSchemas(using: model)
            throw AgentRunError.mapped(from: error)
        }
        do {
            response = try await session.respond(to: request)
        } catch let error where Self.isGenerationParseFailure(error) {
            // A malformed model emission (raw nested JSON for a free-form
            // argument — PR #58 projects nested objects as GeneratedContent)
            // is recoverable: retry the SAME respond once on a fresh session.
            // At most one retry per run; a second failure throws as before.
            Self.logger.error(
                "Agent session emitted malformed generation — retrying once: \(AgentRunTrace.reflectedErrorChain(error), privacy: .public)"
            )
            await AgentRunTraceStore.shared.recordError(
                "malformed generation, retrying once: \(AgentRunTrace.reflectedErrorChain(error))"
            )
            do {
                let retrySession = try LanguageModelSession(
                    model: model,
                    tools: NilesToolset.tools(dispatcher: dispatcher),
                    instructions: instructions
                )
                response = try await retrySession.respond(to: request)
                Self.logger.info("Agent retry after malformed generation succeeded")
                await AgentRunTraceStore.shared.recordRound(
                    "respond retry after malformed generation succeeded"
                )
            } catch {
                try await Self.failMidRun(error, note: "retry after malformed generation")
            }
        } catch {
            try await Self.failMidRun(error)
        }
        let calls = await dispatcher.attemptedCalls
        let budget = dispatcher.budget
        let stagedIds = await dispatcher.stagedProposalIds
        Self.logger.info(
            "Model round 1: respond finished: text (\(response.content.count, privacy: .public) chars): \(AgentRunTrace.truncated(response.content, to: 500), privacy: .public) toolCalls=[\(calls.map(\.tool).joined(separator: ","), privacy: .public)] budgetUsed=\(calls.count, privacy: .public)/\(budget, privacy: .public) stagedProposalIds=[\(stagedIds.joined(separator: ","), privacy: .public)]"
        )
        await AgentRunTraceStore.shared.recordRound(
            "respond finished: text (\(response.content.count) chars): \(AgentRunTrace.truncated(response.content, to: 500)) toolCalls=[\(calls.map(\.tool).joined(separator: ","))] budgetUsed=\(calls.count)/\(budget) stagedProposalIds=[\(stagedIds.joined(separator: ","))]"
        )
        return Outcome(
            summary: response.content,
            stagedProposalIds: stagedIds
        )
    }

    /// The failure path for a respond that could not be recovered: the
    /// full error chain at public privacy, diagnostics, then the mapped
    /// throw. `note` distinguishes the first attempt from the retry.
    private static func failMidRun(_ error: Error, note: String? = nil) async throws -> Never {
        Self.logger.error(
            "Agent session failed mid-run\(note.map { " (\($0))" } ?? "", privacy: .public): \(AgentRunTrace.reflectedErrorChain(error), privacy: .public)"
        )
        await AgentRunTraceStore.shared.recordError(AgentRunTrace.reflectedErrorChain(error))
        await Self.logSessionDiagnostics(for: error)
        throw AgentRunError.mapped(from: error)
    }

    /// True only when the failure is the model emitting malformed content
    /// into a free-form argument. Kept narrow on purpose: availability and
    /// constraint-creation failures must NOT retry — they fail the run as
    /// before. Matches the observed on-device text ("Encountered content
    /// that cannot be completed into valid JSON") and the SDK's generated
    /// content parse failure, in both the reflected chain and the
    /// localized description.
    private static func isGenerationParseFailure(_ error: Error) -> Bool {
        let reflected = AgentRunTrace.reflectedErrorChain(error).lowercased()
        let localized = error.localizedDescription.lowercased()
        for text in [reflected, localized] {
            if text.contains("valid json") || text.contains("failed to parse generated content") {
                return true
            }
        }
        return false
    }

    /// Runtime model diagnostics after any session failure. Logs the live
    /// system-model availability and en_US support (what the gate reads
    /// between runs), then always runs a one-shot minimal probe session: no
    /// tools, no instructions, one short prompt. The probe is NOT gated on
    /// the error mapping to `.assetUnavailable` — the SDK's localized
    /// description mislabels constraint-creation failures as asset-unavailable,
    /// so that mapping cannot be trusted as a filter. A passing probe points
    /// at the Niles session surface (tools/schema/instructions); a failing
    /// one at the device asset itself.
    private static func logSessionDiagnostics(for error: Error) async {
        let system = SystemLanguageModel.default
        let supportsEnUS = system.supportsLocale(Locale(identifier: "en_US"))
        Self.logger.error(
            "Agent session diagnostics: availability=\(String(describing: system.availability), privacy: .public) supportsEnUS=\(supportsEnUS, privacy: .public)"
        )
        do {
            let probe = try LanguageModelSession()
            let reply = try await probe.respond(to: "Reply with OK.")
            Self.logger.error(
                "Agent asset probe: minimal session succeeded (\(reply.content, privacy: .public)) — failure likely from the Niles session surface (tools/schema/instructions), not the device asset"
            )
        } catch {
            Self.logger.error(
                "Agent asset probe: minimal session failed: \(String(describing: error), privacy: .public) — the device asset itself is unavailable"
            )
        }
    }

    /// Per-tool schema bisect: rebuild a session with one tool at a time and
    /// log which tool's schema fails to compile into a grammar. Runs only
    /// after a full-toolset session-creation failure, so the next on-device
    /// QA round names the offending tool even when the free-form projection
    /// fix is not the whole story. Sessions are created with bare
    /// instructions — schema compilation is independent of them.
    private func bisectToolSchemas(using model: any LanguageModel) async {
        for tool in NilesToolset.tools(dispatcher: dispatcher) {
            do {
                _ = try LanguageModelSession(model: model, tools: [tool], instructions: "")
            } catch {
                Self.logger.error(
                    "Agent schema bisect: tool '\(tool.name, privacy: .public)' failed to build a session: \(String(describing: error), privacy: .public)"
                )
            }
        }
        Self.logger.error(
            "Agent schema bisect: complete — every tool named above fails alone; none logged means every tool builds alone and the failure needs the full toolset (or the instructions)"
        )
    }
}
#endif
