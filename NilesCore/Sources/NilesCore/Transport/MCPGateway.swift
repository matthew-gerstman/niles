import Foundation
import MCP

/// A gate that may deny an HTTP request before it reaches MCP handling.
///
/// Lives between the LAN adapter and the session transport: a denial short-circuits
/// the request before any MCP logic — even 404/405 error shapes — is reached.
public protocol AuthChecking: Sendable {
    /// `nil` allows the request; otherwise the response to return instead of MCP handling.
    func authorize(_ request: MCP.HTTPRequest) -> MCP.HTTPResponse?
}

/// The MCP layer between the LAN adapter and per-session SDK transports.
///
/// Mirrors the MCP SDK conformance app's routing: an `initialize` POST mints a session
/// (one `StatefulHTTPServerTransport` + one `Server`), later requests route by
/// `Mcp-Session-Id`, and a successful DELETE retires the session. Unauthenticated or
/// off-path requests never reach MCP handling. No idle sweep is needed: the server
/// only exists while the app is foregrounded, and stop tears every session down.
public actor MCPGateway {

    /// Builds the MCP `Server` behind a session. Tool registration lands with the
    /// read-tools task; the transport stack is complete without it.
    public typealias ServerFactory = @Sendable (MCP.StatefulHTTPServerTransport) async throws -> MCP.Server

    /// The server every session gets until the tool registry task lands.
    public static let defaultServerFactory: ServerFactory = { _ in
        MCP.Server(name: "Niles", version: "0.1.0")
    }

    /// The pipeline every session transport gets: the SDK's Streamable-HTTP checks
    /// minus `OriginValidator.localhost()`. Origin validation is DNS-rebinding
    /// protection for browser-facing localhost servers; Niles is a LAN token server
    /// whose CLI agents send no Origin. The bearer-token validator is prepended by
    /// the caller when auth is wired up.
    public static let defaultValidationPipeline: any MCP.HTTPRequestValidationPipeline =
        MCP.StandardValidationPipeline(validators: [
            MCP.AcceptHeaderValidator(mode: .sseRequired),
            MCP.ContentTypeValidator(),
            MCP.ProtocolVersionValidator(),
            MCP.SessionValidator(),
        ])

    struct Session {
        let transport: MCP.StatefulHTTPServerTransport
        let server: MCP.Server
        var lastAccessedAt: Date
    }

    private let endpointPath: String
    private let serverFactory: ServerFactory
    private let validationPipeline: any MCP.HTTPRequestValidationPipeline
    private let auth: (any AuthChecking)?
    private var sessions: [String: Session] = [:]

    public init(
        endpointPath: String = "/mcp",
        serverFactory: @escaping ServerFactory = MCPGateway.defaultServerFactory,
        validationPipeline: (any MCP.HTTPRequestValidationPipeline)? = MCPGateway.defaultValidationPipeline,
        auth: (any AuthChecking)? = nil
    ) {
        self.endpointPath = endpointPath
        self.serverFactory = serverFactory
        self.validationPipeline = validationPipeline ?? MCPGateway.defaultValidationPipeline
        self.auth = auth
    }

    /// Routes one request: auth gate, path check, session routing, then MCP handling.
    public func handle(_ request: MCP.HTTPRequest) async -> MCP.HTTPResponse {
        if let auth, let denial = auth.authorize(request) { return denial }

        guard let path = request.path, path == endpointPath else {
            return .error(
                statusCode: 404,
                .invalidRequest("Not Found: MCP endpoint is \(endpointPath)")
            )
        }

        let sessionID = request.header(MCP.HTTPHeaderName.sessionID)
        if let sessionID, var session = sessions[sessionID] {
            session.lastAccessedAt = Date()
            sessions[sessionID] = session
            let response = await session.transport.handleRequest(request)
            if request.method.uppercased() == "DELETE", response.statusCode == 200 {
                await closeSession(sessionID)
            }
            return response
        }

        // No existing session — an initialize POST mints one.
        if request.method.uppercased() == "POST",
            let body = request.body,
            Self.isInitializeRequestBody(body)
        {
            return await createSession(thenHandle: request)
        }

        if sessionID != nil {
            return .error(statusCode: 404, .invalidRequest("Not Found: Session not found or expired"))
        }
        return .error(
            statusCode: 400,
            .invalidRequest("Bad Request: Missing \(MCP.HTTPHeaderName.sessionID) header")
        )
    }

    /// Disconnects every session's transport. The LAN server calls this when serving stops.
    public func stop() async {
        for sessionID in sessions.keys {
            await closeSession(sessionID)
        }
    }

    private func createSession(thenHandle request: MCP.HTTPRequest) async -> MCP.HTTPResponse {
        let transport = MCP.StatefulHTTPServerTransport(
            validationPipeline: validationPipeline
        )
        do {
            let server = try await serverFactory(transport)
            try await server.start(transport: transport)
            let response = await transport.handleRequest(request)
            if case .error = response {
                await transport.disconnect()
                return response
            }
            // The transport reports its freshly minted session id in the response
            // headers; without it no later request could be routed to this session.
            guard let sessionID = response.headers[MCP.HTTPHeaderName.sessionID] else {
                await transport.disconnect()
                return .error(
                    statusCode: 500,
                    .internalError("Internal error: Transport did not assign a session id")
                )
            }
            sessions[sessionID] = Session(transport: transport, server: server, lastAccessedAt: Date())
            return response
        } catch {
            await transport.disconnect()
            return .error(
                statusCode: 500,
                .internalError("Failed to create session: \(error.localizedDescription)")
            )
        }
    }

    private func closeSession(_ sessionID: String) async {
        guard let session = sessions.removeValue(forKey: sessionID) else { return }
        await session.transport.disconnect()
    }

    /// True when the POST body is an `initialize` request — the session-creation trigger.
    /// The SDK's own classifier is package-scoped, so Niles re-derives the minimal check:
    /// a JSON-RPC *request* (it carries an id) whose method is `initialize`.
    static func isInitializeRequestBody(_ body: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let method = json["method"] as? String
        else { return false }
        return method == "initialize" && json["id"] != nil
    }
}
