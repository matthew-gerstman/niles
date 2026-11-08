/// Read access to the HomeKit configuration surface.
///
/// Mirrors the spec's read surface — homes, rooms with their accessory
/// assignments, zones, scenes, service groups, and triggers — delivered as
/// one consistent snapshot per call. The snapshot is the unit of consistency:
/// each MCP read tool projects a slice of a single graph, so concurrent agent
/// calls can never observe a half-applied HomeKit change across tools.
///
/// The protocol is read-only by construction; mutations in Niles go through
/// staged write proposals (a different, not-yet-built layer).
public protocol HomeKitService: Sendable {
    /// The current configuration graph.
    ///
    /// Throws when HomeKit data cannot be read (for example, the initial
    /// load timed out). Callers surface the error to the agent rather than
    /// reporting an empty home, which an agent could act on as truth.
    func snapshot() async throws -> HomeGraph
}

/// Errors raised by `HomeKitService` implementations.
public enum HomeKitServiceError: Error, Equatable, Sendable {
    /// HomeKit had not finished loading its home database within the wait
    /// budget. Retryable.
    case homeLoadTimedOut
}
