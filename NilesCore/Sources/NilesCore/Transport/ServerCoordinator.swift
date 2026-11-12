import Foundation
import Observation

/// App-facing server lifecycle: foregrounded means serving, anything else means closed.
///
/// Owns the gateway, the LAN listener, and the pairing token, so the app target's
/// scene-phase handling only ever calls `start()`/`stop()`. Observable so the server
/// dashboard can render status without its own plumbing.
@MainActor
@Observable
public final class ServerCoordinator {

    public enum Status: Equatable {
        case stopped
        case running(port: UInt16)
        case failed(String)
    }

    public private(set) var status: Status = .stopped

    private let port: UInt16
    private let tokenStore: any TokenStoring
    private var server: LANServer?
    /// The gateway the current server serves through, if any — the live source
    /// for session state on the dashboard and pairing screens.
    private var gateway: MCPGateway?

    /// The proposal pipeline for the injected service, if any. Created once at
    /// init so staged proposals survive foreground cycles and expire only by
    /// TTL — and so the approval UI binds to the same instance the server
    /// stages into.
    public let proposalStore: ProposalStore?

    /// The live pairing-code lifecycle, shared by the `/pairing` exchange and
    /// the Settings pairing card. Created once at init so the code the user
    /// reads survives foreground cycles, and so minting from Settings and
    /// verifying on the wire hit the same code.
    public let pairingCodes: PairingCodeManager

    nonisolated public init(
        port: UInt16 = LANServer.defaultPort,
        tokenStore: any TokenStoring = KeychainTokenStore(),
        homeKitService: (any HomeKitWriting)? = nil,
        pairingCodes: PairingCodeManager = PairingCodeManager(),
        proposalStoreFile: ProposalStoreFile? = ProposalStoreFile()
    ) {
        self.port = port
        self.tokenStore = tokenStore
        self.pairingCodes = pairingCodes
        self.proposalStore = homeKitService.map {
            ProposalStore(homeKit: $0, persistence: proposalStoreFile)
        }
    }

    /// Revalidates persisted proposal state before the server can accept a
    /// staging or decision call. The store loads from disk at init; this
    /// pass reads the current home once and flags staged proposals whose
    /// target object is gone. Idempotent, so every start path can call it.
    public func revalidateProposals() async {
        await proposalStore?.revalidateAtLaunch()
    }

    /// Starts serving if not already running; on failure records `.failed` with the
    /// cause (the listener is retryable — the next foreground tries again).
    public func start() async {
        guard server == nil else { return }
        // Before anything can stage or decide: revalidate what the launch
        // loaded, so the queue reflects the live home from the first read.
        await proposalStore?.revalidateAtLaunch()
        do {
            // Bootstrap the credential set (fresh installs have no Keychain
            // items yet); the gate itself re-reads the live set on every
            // request, so issuing and revoking tokens takes effect without a
            // restart.
            _ = try tokenStore.loadOrCreate()
            let store = tokenStore
            let tokenProvider: @Sendable () throws -> [String] = {
                try store.listAgents().map(\.token)
            }
            let gateway: MCPGateway
            // Sessions record which paired agent created them, so revocation
            // can close the agent's live session along with its token.
            let tokenIdentity: MCPGateway.TokenIdentity = { token in
                try? store.listAgents().first(where: { $0.token == token })?.id
            }
            if let proposalStore {
                gateway = MCPGateway(
                    serverFactory: NilesServerFactory.makeFactory(store: proposalStore),
                    validationPipeline: NilesValidationPipeline(tokenProvider: tokenProvider),
                    auth: BearerTokenAuthMiddleware(tokenProvider: tokenProvider),
                    tokenIdentity: tokenIdentity
                )
            } else {
                // No service injected yet — serving with the empty default
                // tool surface (the pre-tools behavior) rather than crashing.
                gateway = MCPGateway(
                    validationPipeline: NilesValidationPipeline(tokenProvider: tokenProvider),
                    auth: BearerTokenAuthMiddleware(tokenProvider: tokenProvider),
                    tokenIdentity: tokenIdentity
                )
            }
            // The pairing exchange answers on the same listener, routed ahead
            // of the gateway's auth gate by the connection runner. The shared
            // code manager means a Settings-minted code is exchangeable live.
            let pairing = PairingService(codes: pairingCodes, tokens: tokenStore)
            let server = LANServer(gateway: gateway, pairingService: pairing, port: port)
            try await server.start()
            self.server = server
            self.gateway = gateway
            status = .running(port: port)
        } catch {
            status = .failed(String(describing: error))
        }
    }

    /// Stops serving, closes all connections, and tears down sessions. Idempotent.
    public func stop() async {
        guard let server else { return }
        self.server = nil
        gateway = nil
        await server.stop()
        status = .stopped
    }

    /// The sessions currently connected to the running server, if any.
    public func sessionInfos() async -> [MCPGateway.SessionInfo] {
        await gateway?.sessionInfos() ?? []
    }

    /// Disconnects every live session bound to one paired agent's token —
    /// the transport half of revocation. No server running means nothing to
    /// close; a no-op, not an error.
    @discardableResult
    public func closeSessions(tokenId: UUID) async -> Int {
        await gateway?.closeSessions(tokenId: tokenId) ?? 0
    }
}
