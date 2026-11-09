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

    nonisolated public init(
        port: UInt16 = LANServer.defaultPort,
        tokenStore: any TokenStoring = KeychainTokenStore(),
        homeKitService: (any HomeKitWriting)? = nil
    ) {
        self.port = port
        self.tokenStore = tokenStore
        self.proposalStore = homeKitService.map { ProposalStore(homeKit: $0) }
    }

    /// Starts serving if not already running; on failure records `.failed` with the
    /// cause (the listener is retryable — the next foreground tries again).
    public func start() async {
        guard server == nil else { return }
        do {
            // One token guards both entry points: the gateway's pre-transport gate
            // and each session transport's validation pipeline.
            let token = try tokenStore.loadOrCreate()
            let gateway: MCPGateway
            if let proposalStore {
                gateway = MCPGateway(
                    serverFactory: NilesServerFactory.makeFactory(store: proposalStore),
                    validationPipeline: NilesValidationPipeline(expectedToken: token),
                    auth: BearerTokenAuthMiddleware(expectedToken: token)
                )
            } else {
                // No service injected yet — serving with the empty default
                // tool surface (the pre-tools behavior) rather than crashing.
                gateway = MCPGateway(
                    validationPipeline: NilesValidationPipeline(expectedToken: token),
                    auth: BearerTokenAuthMiddleware(expectedToken: token)
                )
            }
            let server = LANServer(gateway: gateway, port: port)
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
}
