import Foundation
import NilesCore
import Observation
import OSLog

/// The pairing card's state: the live code, the paired credentials, and
/// revocation — the `PairingViewModel` seam of the former monolithic
/// `LiveNilesStore` (cleanup W3).
///
/// `refreshState(sessions:)` is the poll fan-out's per-tick update; the
/// auto-mint policy lives here too, so the card always shows a fresh
/// challenge after expiry, a successful exchange, or an attempt-cap burn.
@MainActor
@Observable
final class LivePairingStore: PairingViewModel {

    let transportName = "Streamable HTTP"
    /// The serving endpoint, recomputed on every refresh (the LAN IP can
    /// change); the pairing prompt and the Server row render it.
    private(set) var endpoint = "http://\(LANAddress.primaryIPv4 ?? "127.0.0.1"):\(LANServer.defaultPort)/mcp"
    /// The live six-digit code, or `nil` between mint failures. Auto-minted
    /// whenever refresh finds none — after expiry, a successful exchange, or
    /// an attempt-cap burn — so the card always shows a fresh challenge.
    private(set) var pairingCode: String?
    private(set) var codeExpiresAt: Date?
    private(set) var pairedAgents: [PairedAgentRow] = []

    private let coordinator: ServerCoordinator
    private let tokenStore: any TokenStoring
    /// When this store came up — the launch instant the paired-agents list
    /// filters on: only credentials paired after it render on Home.
    private let launchedAt = Date()

    private let logger = Logger(subsystem: "com.gerstman.niles", category: "live-pairing")

    init(coordinator: ServerCoordinator, tokenStore: any TokenStoring) {
        self.coordinator = coordinator
        self.tokenStore = tokenStore
    }

    // MARK: - PairingViewModel

    /// Revocation: delete the credential, then close any live session the
    /// agent's token created. A failed deletion keeps the session — no half
    /// revocation where the credential outlives the connection it guards.
    func revokeAgent(_ id: UUID) async {
        do {
            try tokenStore.revoke(id: id)
            await coordinator.closeSessions(tokenId: id)
        } catch {
            logger.error("Revoke failed for \(id.uuidString, privacy: .public): \(String(describing: error))")
        }
        await refreshState(sessions: await coordinator.sessionInfos())
    }

    // MARK: - Poll fan-out (called only by LiveNilesStore.refresh)

    /// The pairing card's state: a live code (auto-minted when refresh finds
    /// none — expiry, a successful exchange, and an attempt-cap burn all land
    /// here, so foreground-after-expiry shows a fresh one) and the paired
    /// credentials with what the live sessions say about them.
    func refreshState(sessions: [MCPGateway.SessionInfo]) async {
        endpoint = "http://\(LANAddress.primaryIPv4 ?? "127.0.0.1"):\(LANServer.defaultPort)/mcp"
        await mintPairingCode()
        if let code = await coordinator.pairingCodes.activeCode() {
            pairingCode = code.code
            codeExpiresAt = code.expiresAt
        }

        do {
            pairedAgents = Self.pairedAgentRows(
                agents: try tokenStore.listAgents(),
                sessions: sessions,
                launchedAt: launchedAt
            )
        } catch {
            // The Keychain read failing keeps the previous list on screen —
            // logged, never silently dropped.
            logger.error("Paired-agent read failed, keeping previous list: \(String(describing: error))")
        }
    }

    /// Mints a code when none is live. A mint failure is logged, not thrown —
    /// the countdown then shows the previous expiry, never a fabricated code.
    private func mintPairingCode() async {
        guard await coordinator.pairingCodes.activeCode() == nil else { return }
        do {
            _ = try await coordinator.pairingCodes.mintCode()
        } catch {
            logger.error("Pairing code mint failed: \(String(describing: error))")
        }
    }

    /// The paired-agents rows from stored credentials and live sessions —
    /// pure, so the list's rendering rules are directly testable. Only
    /// credentials paired since `launchedAt` appear: the Home list is a
    /// review of pairings that happened this session, not a credential
    /// inventory. Unnamed agents render as "Agent".
    static func pairedAgentRows(
        agents: [PairedAgent],
        sessions: [MCPGateway.SessionInfo],
        launchedAt: Date
    ) -> [PairedAgentRow] {
        agents
            .filter { $0.pairedAt >= launchedAt }
            .map { agent in
                let agentSessions = sessions
                    .filter { $0.tokenId == agent.id }
                    .sorted { $0.startedAt > $1.startedAt }
                return PairedAgentRow(
                    id: agent.id,
                    name: agent.name ?? "Agent",
                    pairedAt: agent.pairedAt,
                    sessions: agentSessions.map { session in
                        AgentSessionRow(
                            id: session.id,
                            clientName: session.clientName ?? "MCP client",
                            startedAt: session.startedAt,
                            lastAccessedAt: session.lastAccessedAt
                        )
                    }
                )
            }
    }
}
