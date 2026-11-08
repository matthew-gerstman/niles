import XCTest

@testable import NilesCore

final class ProposalStateTests: XCTestCase {
    func testRawValuesMatchSpec() {
        let expected = ["staged", "approved", "executed", "denied", "expired", "failed"]
        XCTAssertEqual(ProposalState.allCases.map(\.rawValue), expected)
    }

    func testTerminalStates() {
        let terminal: Set<ProposalState> = [.executed, .denied, .expired, .failed]
        for state in ProposalState.allCases {
            XCTAssertEqual(state.isTerminal, terminal.contains(state), "\(state) misclassified")
        }
    }

    func testStatesThatLeaveHomeUntouched() {
        let untouched: Set<ProposalState> = [.staged, .denied, .expired]
        for state in ProposalState.allCases {
            XCTAssertEqual(state.leftHomeUntouched, untouched.contains(state), "\(state) misclassified")
        }
    }

    func testLegalTransitions() {
        XCTAssertTrue(ProposalState.staged.canTransition(to: .approved))
        XCTAssertTrue(ProposalState.staged.canTransition(to: .denied))
        XCTAssertTrue(ProposalState.staged.canTransition(to: .expired))
        XCTAssertTrue(ProposalState.approved.canTransition(to: .executed))
        XCTAssertTrue(ProposalState.approved.canTransition(to: .failed))
    }

    func testIllegalTransitions() {
        // Denied and expired proposals never execute.
        XCTAssertFalse(ProposalState.staged.canTransition(to: .executed))
        XCTAssertFalse(ProposalState.staged.canTransition(to: .failed))
        XCTAssertFalse(ProposalState.denied.canTransition(to: .approved))
        XCTAssertFalse(ProposalState.expired.canTransition(to: .approved))
        // A failed execution is terminal, not a retry loop.
        XCTAssertFalse(ProposalState.failed.canTransition(to: .approved))
    }

    func testNoTransitionsOutOfTerminalStates() {
        for terminal in ProposalState.allCases where terminal.isTerminal {
            for next in ProposalState.allCases {
                XCTAssertFalse(
                    terminal.canTransition(to: next),
                    "terminal state \(terminal) must not transition to \(next)"
                )
            }
        }
    }
}
