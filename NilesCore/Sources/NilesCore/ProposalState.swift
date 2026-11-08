/// The lifecycle of a staged write proposal.
///
/// Every mutating MCP tool stages one proposal envelope; nothing touches
/// HomeKit until a human approves it on the device. Transitions follow the
/// spec's state machine: `staged -> approved -> executed/failed`, with
/// `staged -> denied/expired` ending a proposal without ever running it.
/// Terminal states record evidence (or the HomeKit error) and accept no
/// further transitions.
public enum ProposalState: String, Codable, Sendable, CaseIterable {
    case staged
    case approved
    case executed
    case denied
    case expired
    case failed

    /// The proposal's life has ended; its outcome is recorded either way.
    public var isTerminal: Bool {
        switch self {
        case .executed, .denied, .expired, .failed: true
        case .staged, .approved: false
        }
    }

    /// True when the proposal's HomeKit operations were never applied, so the
    /// shared home database is untouched.
    public var leftHomeUntouched: Bool {
        switch self {
        case .staged, .denied, .expired: true
        case .approved, .executed, .failed: false
        }
    }

    /// Whether `self` may transition to `next`.
    public func canTransition(to next: ProposalState) -> Bool {
        switch self {
        case .staged: next == .approved || next == .denied || next == .expired
        case .approved: next == .executed || next == .failed
        case .executed, .denied, .expired, .failed: false
        }
    }
}
