import XCTest
#if canImport(FoundationModels)
import FoundationModels
@testable import NilesCore

/// The gate's full state matrix (spec art_VrC0iUUA §Availability gate):
/// the OS bar plus every system-availability reason, mapped onto what
/// Settings shows. The pure form covers states no CI hardware reports;
/// the production `evaluate()` entry only composes the same pieces.
final class AgentAvailabilityGateTests: XCTestCase {
    func testOSBelowAgentCoreBarIsUnavailableRegardlessOfModel() {
        // Foundation Models itself starts at iOS 26, but the agent core
        // needs the iOS 27 SDK — even an "available" model on iOS 26 must
        // read as unsupported.
        XCTAssertEqual(
            AgentAvailabilityGate.evaluate(
                isOS27OrNewer: false,
                systemAvailability: .available
            ),
            .unavailable(.needsIOS27)
        )
    }

    func testAvailableModelOnOS27OrNewerIsAvailable() {
        XCTAssertEqual(
            AgentAvailabilityGate.evaluate(
                isOS27OrNewer: true,
                systemAvailability: .available
            ),
            .available
        )
    }

    func testUnavailableReasonsCarryThroughToSettings() {
        let cases: [(SystemLanguageModel.Availability, AgentAvailability)] = [
            (.unavailable(.deviceNotEligible), .unavailable(.deviceNotEligible)),
            (.unavailable(.appleIntelligenceNotEnabled), .unavailable(.appleIntelligenceNotEnabled)),
            (.unavailable(.modelNotReady), .unavailable(.modelNotReady)),
        ]
        for (system, expected) in cases {
            XCTAssertEqual(
                AgentAvailabilityGate.evaluate(isOS27OrNewer: true, systemAvailability: system),
                expected,
                "the reason must survive to the Settings surface verbatim"
            )
        }
    }
}
#endif
