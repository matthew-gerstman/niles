import Foundation
import MCP
import XCTest
#if canImport(FoundationModels)
import FoundationModels
#endif
@testable import NilesCore

/// Shared fixtures for the agent-core tests: a small home with dimmable
/// living-room lights for the scripted-model scenarios, and a Syracuse-shaped
/// graph (71 accessories / 275 services / 1,179 characteristics) for the
/// context-budget assertions.
enum AgentFixtures {
    /// Brightness characteristic with HomeKit's 0-100 percentage metadata.
    static func brightness(_ id: String, value: String? = nil) -> HomeGraph.CharacteristicRef {
        HomeGraph.CharacteristicRef(
            id: id,
            type: "Brightness",
            name: "Brightness",
            valueDescription: value,
            metadata: HomeGraph.CharacteristicMetadata(
                format: "float", units: "percentage", minValue: 0, maxValue: 100, step: 1
            )
        )
    }

    static func on(_ id: String, value: String? = nil) -> HomeGraph.CharacteristicRef {
        HomeGraph.CharacteristicRef(id: id, type: "On", name: "On", valueDescription: value)
    }

    /// One dimmable light: a lightbulb service with On + Brightness.
    static func dimmableLight(id: String, name: String) -> HomeGraph.Accessory {
        HomeGraph.Accessory(
            id: id,
            name: name,
            category: "com.apple.hap.lightbulb",
            services: [
                HomeGraph.AccessoryService(
                    id: "\(id)-svc", name: "Lightbulb", serviceType: "000043",
                    characteristics: [on("\(id)-on"), brightness("\(id)-brightness")]
                )
            ]
        )
    }

    /// The scripted-model fixture: a living room with three dimmable lights,
    /// a kitchen lamp, and an office fan — enough home for the acceptance
    /// scenarios, small enough to read every assertion by eye.
    static func graph() -> HomeGraph {
        let livingRoom = HomeGraph.Room(
            id: "room-living", name: "Living Room",
            accessories: [
                dimmableLight(id: "acc-lr-1", name: "Living Room Lamp 1"),
                dimmableLight(id: "acc-lr-2", name: "Living Room Lamp 2"),
                dimmableLight(id: "acc-lr-3", name: "Living Room Lamp 3"),
            ]
        )
        let kitchen = HomeGraph.Room(
            id: "room-kitchen", name: "Kitchen",
            accessories: [dimmableLight(id: "acc-kitchen-1", name: "Kitchen Lamp")]
        )
        let fan = HomeGraph.Accessory(
            id: "acc-office-1", name: "Ceiling Fan",
            category: "com.apple.hap.fan",
            services: [
                HomeGraph.AccessoryService(
                    id: "acc-office-1-svc", name: "Fan", serviceType: "00043",
                    characteristics: [on("acc-office-1-on")]
                )
            ]
        )
        let office = HomeGraph.Room(id: "room-office", name: "Office", accessories: [fan])
        let morningScene = HomeGraph.Scene(
            id: "scene-morning", name: "Good Morning", type: "AppleScene",
            actions: [HomeGraph.SceneAction(
                accessoryId: "acc-kitchen-1", accessoryName: "Kitchen Lamp",
                service: nil, characteristic: "Brightness", characteristicName: "Brightness",
                valueDescription: "80"
            )]
        )
        let deskLamps = HomeGraph.ServiceGroup(
            id: "sg-lamps", name: "Desk Lamps",
            services: [HomeGraph.ServiceRef(
                id: "acc-kitchen-1-svc", name: "Lightbulb", serviceType: "000043",
                accessoryId: "acc-kitchen-1", accessoryName: "Kitchen Lamp"
            )]
        )
        let home = HomeGraph.Home(
            id: "home-1", name: "Main House", rooms: [livingRoom, kitchen, office],
            zones: [HomeGraph.Zone(id: "zone-upstairs", name: "Upstairs", roomIds: ["room-office"])],
            scenes: [morningScene], serviceGroups: [deskLamps]
        )
        return HomeGraph(homes: [home])
    }

    /// Registries over the fixture, with a store whose clock never expires
    /// staged proposals mid-test (fixed epoch well within the 24h TTL).
    /// The fake service comes back too, so tests can observe the approved
    /// graph after execution.
    static func registries(graph: HomeGraph = graph()) -> (
        reads: ReadToolRegistry, writes: WriteToolRegistry, store: ProposalStore, service: FakeHomeKitService
    ) {
        let service = FakeHomeKitService(graph: graph)
        let store = ProposalStore(
            homeKit: service,
            now: { Date(timeIntervalSince1970: 1_762_592_000) }
        )
        return (ReadToolRegistry(service: service), WriteToolRegistry(store: store), store, service)
    }

    // MARK: - Syracuse-shaped fixture (direction 3 sizing)

    /// Deterministically builds 1 home, 3 zones, 11 rooms, 71 accessories,
    /// 275 services, 1,179 characteristics, 6 scenes, 31 triggers, and 20
    /// service groups — the measured Syracuse home shape.
    static func syracuseShapedGraph() -> HomeGraph {
        let roomNames = [
            "Living Room", "Family Room", "Kitchen", "Dining Room", "Primary Bedroom",
            "Guest Bedroom", "Office", "Hallway", "Entryway", "Basement", "Garage",
        ]
        let accessoryTotal = 71

        // Distribute accessories over rooms (7,7,7,7,7,6,...), services over
        // accessories (4,4,...,3), characteristics over services (5,5,...,4).
        var accessories: [HomeGraph.Accessory] = []
        accessories.reserveCapacity(accessoryTotal)
        for accessoryIndex in 0..<accessoryTotal {
            let serviceCount = accessoryIndex < 62 ? 4 : 3
            var services: [HomeGraph.AccessoryService] = []
            for serviceIndex in 0..<serviceCount {
                let globalService = accessoryIndex * 4 + serviceIndex  // ≤ 275
                let characteristicCount = globalService < 79 ? 5 : 4
                var characteristics: [HomeGraph.CharacteristicRef] = []
                for characteristicIndex in 0..<characteristicCount {
                    characteristics.append(HomeGraph.CharacteristicRef(
                        id: "ch-\(globalService)-\(characteristicIndex)",
                        type: ["On", "Brightness", "Hue", "Saturation"][characteristicIndex % 4],
                        name: nil,
                        valueDescription: "50"
                    ))
                }
                services.append(HomeGraph.AccessoryService(
                    id: "svc-\(globalService)", name: "Service \(globalService)",
                    serviceType: "000043", characteristics: characteristics
                ))
            }
            accessories.append(HomeGraph.Accessory(
                id: "acc-\(accessoryIndex)", name: "Accessory \(accessoryIndex)",
                category: "com.apple.hap.lightbulb", services: services
            ))
        }

        // Room membership: first 5 rooms hold 7 accessories, the rest 6.
        let rooms: [HomeGraph.Room] = roomNames.enumerated().map { index, name in
            let start = index * 7
            let count = index < 5 ? 7 : 6
            let upper = min(start + count, accessoryTotal)
            return HomeGraph.Room(
                id: "room-\(index)", name: name,
                accessories: Array(accessories[start..<upper])
            )
        }
        let zones = [
            HomeGraph.Zone(id: "zone-0", name: "Upstairs", roomIds: ["room-0", "room-1"]),
            HomeGraph.Zone(id: "zone-1", name: "Downstairs", roomIds: ["room-2", "room-3"]),
            HomeGraph.Zone(id: "zone-2", name: "Outside", roomIds: ["room-10"]),
        ]

        let sceneActions: [HomeGraph.SceneAction] = (0..<6).map { index in
            HomeGraph.SceneAction(
                accessoryId: "acc-\(index)", accessoryName: "Accessory \(index)",
                service: nil, characteristic: "Brightness", characteristicName: nil,
                valueDescription: "50"
            )
        }
        let scenes = (0..<6).map { index in
            HomeGraph.Scene(
                id: "scene-\(index)", name: "Scene \(index)", type: "AppleScene",
                actions: index == 0 ? sceneActions : []
            )
        }
        let triggers = (0..<31).map { index in
            HomeGraph.Trigger(
                id: "trigger-\(index)", name: "Trigger \(index)", isEnabled: false,
                linkedSceneIds: ["scene-0"],
                detail: .timer(fireDate: Date(timeIntervalSince1970: 1_762_592_400), recurrence: [:])
            )
        }
        let serviceGroups = (0..<20).map { index in
            HomeGraph.ServiceGroup(
                id: "sg-\(index)", name: "Group \(index)",
                services: [HomeGraph.ServiceRef(
                    id: "svc-\(index)", name: "Service \(index)",
                    serviceType: "000043", accessoryId: "acc-\(index)", accessoryName: "Accessory \(index)"
                )]
            )
        }

        return HomeGraph(homes: [
            HomeGraph.Home(
                id: "home-1", name: "Syracuse House",
                rooms: rooms, zones: zones, scenes: scenes,
                serviceGroups: serviceGroups, triggers: triggers
            )
        ])
    }
}

// MARK: - Scripted model (shared by the runner and service tests)

/// One scripted turn: a tool call or the final text, exactly one per
/// generation request. Internal so both test files script the same way.
@available(iOS 27.0, *)
struct ScriptedTurn: Hashable, Sendable {
    var toolName: String?
    var argumentsJSON: String?
    var finalText: String

    static func call(_ tool: String, _ argumentsJSON: String) -> ScriptedTurn {
        ScriptedTurn(toolName: tool, argumentsJSON: argumentsJSON, finalText: "")
    }
    static func done(_ text: String) -> ScriptedTurn {
        ScriptedTurn(toolName: nil, argumentsJSON: nil, finalText: text)
    }
}

@available(iOS 27.0, *)
struct ScriptedExecutorConfiguration: Hashable, Sendable {
    var turns: [ScriptedTurn]
    /// When set, every generation throws the named Foundation Models
    /// failure instead of replaying the script — the seam for
    /// session-failure tests (asset-unavailable mapping, pass-through).
    var failure: ScriptedFailure?

    init(turns: [ScriptedTurn], failure: ScriptedFailure? = nil) {
        self.turns = turns
        self.failure = failure
    }
}

/// A Foundation Models failure a scripted model throws. The real error
/// types, constructed the way the SDK's public initializers allow — never
/// a lookalike — so the production mapping is matched against the actual
/// enum cases.
@available(iOS 27.0, *)
enum ScriptedFailure: Hashable, Sendable {
    /// The iOS 27 spelling the session throws when the local model asset
    /// is unavailable (`SystemLanguageModel.Error.assetsUnavailable`).
    case systemAssetsUnavailable
    /// The deprecated `GenerationError.assetsUnavailable` spelling — the
    /// iOS 26 case, covered so the mapping cannot miss a runtime that
    /// still throws it.
    case legacyAssetsUnavailable
    /// An arbitrary error the mapping must pass through unchanged.
    case opaque(String)

    var error: Error {
        switch self {
        case .systemAssetsUnavailable:
            return SystemLanguageModel.Error.assetsUnavailable(
                SystemLanguageModel.Error.AssetsUnavailable(
                    debugDescription: "Resource (Local Model Asset) unavailable"
                )
            )
        case .legacyAssetsUnavailable:
            return LanguageModelSession.GenerationError.assetsUnavailable(
                LanguageModelSession.GenerationError.Context(
                    debugDescription: "Resource (Local Model Asset) unavailable"
                )
            )
        case .opaque(let description):
            return NSError(
                domain: "NilesCoreTests.ScriptedFailure",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: description]
            )
        }
    }
}

/// A custom `LanguageModel` replays the script with no on-device model —
/// the seam that keeps the acceptance scenarios deterministic.
@available(iOS 27.0, *)
struct ScriptedLanguageModel: LanguageModel {
    typealias Executor = ScriptedExecutor
    var configuration: ScriptedExecutorConfiguration

    var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.toolCalling])
    }

    var executorConfiguration: ScriptedExecutorConfiguration { configuration }
}

@available(iOS 27.0, *)
struct ScriptedExecutor: LanguageModelExecutor {
    typealias Model = ScriptedLanguageModel

    let configuration: ScriptedExecutorConfiguration

    init(configuration: ScriptedExecutorConfiguration) throws {
        self.configuration = configuration
    }

    func prewarm(model: ScriptedLanguageModel, transcript: Transcript) {}

    func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: ScriptedLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        // A scripted session failure replaces the whole script: every
        // generation throws the named Foundation Models error.
        if let failure = model.configuration.failure {
            throw failure.error
        }
        // Each generation corresponds to one tool-call turn or the final
        // response; count the ones already in the transcript. One tool call
        // per scripted turn keeps this indexing exact. Transcript is a
        // RandomAccessCollection, not an `entries` property.
        let completed = request.transcript.filter { entry in
            switch entry {
            case .toolCalls, .response: return true
            default: return false
            }
        }.count
        let turns = model.configuration.turns
        guard completed < turns.count else {
            // Script exhausted: emit nothing further rather than loop forever.
            await channel.send(.response(action: .appendText("", tokenCount: 0)))
            return
        }
        let turn = turns[completed]
        if let name = turn.toolName, let argumentsJSON = turn.argumentsJSON {
            await channel.send(.toolCalls(action: .toolCall(
                id: UUID().uuidString,
                name: name,
                action: .appendArguments(argumentsJSON, tokenCount: argumentsJSON.count / 4)
            )))
        } else {
            await channel.send(.response(action: .appendText(turn.finalText, tokenCount: turn.finalText.count / 4)))
        }
    }
}

