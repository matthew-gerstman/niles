import Foundation
#if canImport(FoundationModels)
import FoundationModels
import XCTest
@testable import NilesCore

/// The fixed context surface — instructions plus every tool definition —
/// must fit the on-device model's window even with the Syracuse-shaped home
/// loaded (71 accessories / 275 services / 1,179 characteristics). Direction
/// 3: a test that only ever used a small fake would pass while a real home
/// blows the window.
///
/// `SystemLanguageModel.tokenCount` is iOS 26.4+; on older runtimes the test
/// reports skipped instead of failing.
final class AgentContextBudgetTests: XCTestCase {
    @available(iOS 26.4, *)
    func testFixedSurfaceFitsContextWindowWithSyracuseShapedHome() async throws {
        let fixture = AgentFixtures.registries(graph: AgentFixtures.syracuseShapedGraph())
        let dispatcher = NilesToolDispatcher(reads: fixture.reads, writes: fixture.writes)
        let tools = NilesToolset.tools(dispatcher: dispatcher)

        let model = SystemLanguageModel()
        guard case .available = model.availability else {
            throw XCTSkip("Apple Intelligence is unavailable on this runtime; token counting needs the system model")
        }

        // Some runtimes (headless CI, simulators) report .availability as
        // .available yet ship no model-catalog assets; tokenCount then
        // fails with a ModelManager asset error. The gate is only
        // meaningful where the model's assets exist — skip with the
        // underlying error rather than fail. Anything else rethrows.
        func counted(_ body: () async throws -> Int) async throws -> Int {
            do {
                return try await body()
            } catch {
                let nsError = error as NSError
                if nsError.domain.contains("LanguageModelError") || nsError.domain.contains("ModelManager") {
                    throw XCTSkip("model-catalog assets unavailable for token counting: \(error)")
                }
                throw error
            }
        }

        let toolTokens = try await counted { try await model.tokenCount(for: tools) }
        let instructionTokens = try await counted { try await model.tokenCount(for: Instructions(NilesAgentInstructions.text())) }
        let fixedSurface = toolTokens + instructionTokens

        // The measured budget: instructions + tools ≈ 1,600 tokens, well
        // inside the 4,096-token window (TN3193), leaving room for the
        // conversation itself.
        XCTAssertLessThanOrEqual(fixedSurface, 1_600, "fixed surface must stay ≈1,600 tokens; got \(fixedSurface)")
        XCTAssertLessThanOrEqual(fixedSurface, model.contextSize, "fixed surface must fit the system context window")
    }
}
#endif
