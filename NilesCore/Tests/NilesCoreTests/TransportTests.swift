import Foundation
import Security
import Testing
import MCP

@testable import NilesCore

// Transport-layer unit tests. Everything here runs against the pure parser/serializer
// and the MCPGateway actor — no sockets, no bound ports — mirroring how the connection
// loop feeds bytes in and writes responses out.

// MARK: - Shared fixtures

private let testToken = "test-token-0123456789abcdef"

private func makeGateway(token: String) -> MCPGateway {
    MCPGateway(
        validationPipeline: NilesValidationPipeline(expectedToken: token),
        auth: BearerTokenAuthMiddleware(expectedToken: token)
    )
}

private func initializeBody() -> Data {
    let object: [String: Any] = [
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": [
            "protocolVersion": "2025-11-25",
            "capabilities": [:],
            "clientInfo": ["name": "niles-tests", "version": "0"],
        ],
    ]
    return try! JSONSerialization.data(withJSONObject: object)
}

private func jsonRPCRequest(id: Int, method: String) -> Data {
    let object: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
    return try! JSONSerialization.data(withJSONObject: object)
}

private func post(
    _ body: Data?,
    token: String? = testToken,
    sessionID: String? = nil,
    path: String = "/mcp"
) -> MCP.HTTPRequest {
    var headers = [
        MCP.HTTPHeaderName.contentType: "application/json",
        MCP.HTTPHeaderName.accept: "application/json, text/event-stream",
        MCP.HTTPHeaderName.protocolVersion: "2025-11-25",
    ]
    if let token { headers[MCP.HTTPHeaderName.authorization] = "Bearer \(token)" }
    if let sessionID { headers[MCP.HTTPHeaderName.sessionID] = sessionID }
    return MCP.HTTPRequest(method: "POST", headers: headers, body: body, path: path)
}

/// Scans a buffer for the first JSON-RPC message on an SSE `data:` line; priming
/// events (empty data) and partial lines don't match.
private func jsonRPCMessage(in buffer: Data) -> [String: Any]? {
    guard let text = String(data: buffer, encoding: .utf8) else { return nil }
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) where line.hasPrefix("data: ") {
        let payload = String(line.dropFirst("data: ".count))
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
            object["jsonrpc"] != nil
        else { continue }
        return object
    }
    return nil
}

/// Drains an SSE `.stream` response, returning every chunk and the first JSON-RPC
/// message found. Deadline-bounded so a silent server fails fast instead of hanging.
private func drainedSSE(
    from response: MCP.HTTPResponse,
    within seconds: TimeInterval = 10
) async -> (chunks: [Data], message: [String: Any]?) {
    guard case .stream(let stream, _) = response else {
        Issue.record("Expected an SSE stream response, got: \(response)")
        return ([], nil)
    }
    var chunks: [Data] = []
    var buffer = Data()
    let deadline = Date().addingTimeInterval(seconds)
    do {
        for try await chunk in stream {
            chunks.append(chunk)
            buffer.append(chunk)
            if let message = jsonRPCMessage(in: buffer) { return (chunks, message) }
            guard Date() < deadline else { break }
        }
    } catch {
        Issue.record("SSE stream errored: \(error)")
    }
    return (chunks, jsonRPCMessage(in: buffer))
}

private func firstJSONRPCMessage(from response: MCP.HTTPResponse) async -> [String: Any]? {
    await drainedSSE(from: response).message
}

// MARK: - Adapter round-trip

@Suite("HTTPRequestParser")
struct HTTPRequestParserTests {

    private static func requestBytes(
        method: String = "POST",
        path: String = "/mcp",
        headers: [String: String] = ["Authorization": "Bearer \(testToken)"],
        body: String
    ) -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(body.utf8.count)\r\n\r\n"
        return Data((head + body).utf8)
    }

    @Test("Complete request parses with correct method, path, headers, and body")
    func parsesCompleteRequest() throws {
        let body = #"{"jsonrpc":"2.0","id":7,"method":"ping"}"#
        let all = Self.requestBytes(body: body)
        guard case .complete(let request, wantsKeepAlive: let keepAlive, consumedBytes: let consumed) =
            HTTPRequestParser.parse(all)
        else {
            Issue.record("Expected a complete parse")
            return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/mcp")
        #expect(request.header("authorization") == "Bearer \(testToken)")
        #expect(request.body == Data(body.utf8))
        #expect(keepAlive)
        #expect(consumed == all.count)
    }

    @Test("Partial request needs more data")
    func needsMoreData() {
        let all = Self.requestBytes(body: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        let split = all.index(all.startIndex, offsetBy: all.count / 2)
        #expect(matches(HTTPRequestParser.parse(all[..<split]), .needMoreData))
    }

    @Test("Transfer-Encoding fails closed")
    func rejectsTransferEncoding() {
        let body = "{}"
        let head = "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n\(body)"
        #expect(matches(HTTPRequestParser.parse(Data(head.utf8)), .invalid(.transferEncodingUnsupported)))
    }

    @Test("Body larger than the limit fails closed")
    func rejectsOversizedBody() {
        let bytes = Self.requestBytes(body: String(repeating: "x", count: 24))
        #expect(matches(
            HTTPRequestParser.parse(bytes, maxBodySize: 16),
            .invalid(.bodyTooLarge(limit: 16))
        ))
    }

    @Test("Query string is stripped from the path")
    func stripsQuery() {
        let bytes = Self.requestBytes(path: "/mcp?trace=1", body: "{}")
        guard case .complete(let request, _, _) = HTTPRequestParser.parse(bytes) else {
            Issue.record("Expected a complete parse")
            return
        }
        #expect(request.path == "/mcp")
    }
}

// MARK: - Response serialization

@Suite("HTTPResponseWriter")
struct HTTPResponseWriterTests {

    @Test("401 error serializes with WWW-Authenticate and Content-Length")
    func serializes401() {
        let response = MCP.HTTPResponse.error(
            statusCode: 401,
            .invalidRequest("Unauthorized"),
            sessionID: nil,
            extraHeaders: [MCP.HTTPHeaderName.wwwAuthenticate: "Bearer"]
        )
        let text = String(
            decoding: HTTPResponseWriter.serialize(response, keepAlive: true),
            as: UTF8.self
        )
        #expect(text.hasPrefix("HTTP/1.1 401 "))
        #expect(text.lowercased().contains("www-authenticate: bearer"))
        #expect(text.lowercased().contains("content-length:"))
    }

    @Test("Full round-trip: initialize bytes → parse → gateway → SSE response → chunked wire")
    func adapterRoundTrip() async throws {
        let gateway = makeGateway(token: testToken)
        let body = initializeBody()
        var raw = "POST /mcp HTTP/1.1\r\n"
        for (name, value) in [
            "Authorization": "Bearer \(testToken)",
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
        ].sorted(by: { $0.key < $1.key }) {
            raw += "\(name): \(value)\r\n"
        }
        raw += "Content-Length: \(body.count)\r\n\r\n"
        raw += String(decoding: body, as: UTF8.self)

        guard case .complete(let request, _, _) = HTTPRequestParser.parse(Data(raw.utf8)) else {
            Issue.record("Expected the request bytes to parse")
            return
        }
        let handled = await gateway.handle(request)

        // Initialize answers as an SSE stream carrying the JSON-RPC result.
        #expect(handled.statusCode == 200)
        #expect(handled.headers[MCP.HTTPHeaderName.sessionID] != nil)
        #expect(handled.headers[MCP.HTTPHeaderName.contentType] == "text/event-stream")

        let (chunks, message) = await drainedSSE(from: handled)
        guard let message else {
            Issue.record("Expected an initialize result on the SSE stream")
            return
        }
        #expect((message["result"] as? [String: Any])?["serverInfo"] != nil)

        // The connection runner frames streams with the chunked writer path.
        var wire = HTTPResponseWriter.head(handled, keepAlive: true, chunked: true)
        for chunk in chunks { wire.append(HTTPResponseWriter.chunk(chunk)) }
        wire.append(HTTPResponseWriter.endOfChunkedBody)
        let text = String(decoding: wire, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 "))
        #expect(text.lowercased().contains("mcp-session-id"))
        #expect(text.lowercased().contains("transfer-encoding: chunked"))
        #expect(text.contains("event: message"))
        #expect(text.contains("serverInfo"))
    }
}

// MARK: - Bearer-token gate

@Suite("BearerTokenAuthMiddleware")
struct BearerTokenAuthMiddlewareTests {

    private let middleware = BearerTokenAuthMiddleware(expectedToken: testToken)

    @Test("Missing token is denied with 401 and WWW-Authenticate")
    func missingToken() {
        let response = middleware.authorize(post(initializeBody(), token: nil))
        #expect(response?.statusCode == 401)
        #expect(response?.headers[MCP.HTTPHeaderName.wwwAuthenticate] == "Bearer")
    }

    @Test("Wrong token is denied with 401")
    func wrongToken() {
        let response = middleware.authorize(post(initializeBody(), token: "wrong-token"))
        #expect(response?.statusCode == 401)
    }

    @Test("Correct token is allowed")
    func correctToken() {
        #expect(middleware.authorize(post(initializeBody(), token: testToken)) == nil)
    }

    @Test("Auth precedes routing: wrong token on an unknown path still answers 401")
    func authBeforeRouting() async {
        let gateway = makeGateway(token: testToken)
        let response = await gateway.handle(post(initializeBody(), token: "wrong-token", path: "/nope"))
        #expect(response.statusCode == 401)
    }

    @Test("Gateway rejects off-path requests with 404 after auth")
    func offPathAfterAuth() async {
        let gateway = makeGateway(token: testToken)
        let response = await gateway.handle(post(initializeBody(), path: "/nope"))
        #expect(response.statusCode == 404)
    }

    @Test("tokensMatch is exact and length-safe")
    func tokensMatch() {
        #expect(BearerTokenAuthMiddleware.tokensMatch(testToken, testToken))
        #expect(!BearerTokenAuthMiddleware.tokensMatch("short", testToken))
        #expect(!BearerTokenAuthMiddleware.tokensMatch(String(testToken.dropLast()), testToken))
        #expect(!BearerTokenAuthMiddleware.tokensMatch(testToken + "x", testToken))
        #expect(!BearerTokenAuthMiddleware.tokensMatch("", "a"))
        #expect(BearerTokenAuthMiddleware.tokensMatch("", ""))
    }

    // MARK: Set-aware gate

    @Test("Any live token in the set authenticates")
    func anyLiveTokenAuthenticates() {
        let store = FakeTokenStore(tokens: ["token-a", "token-b"])
        let middleware = BearerTokenAuthMiddleware(tokenProvider: { try store.listAgents().map(\.token) })

        #expect(middleware.authorize(post(initializeBody(), token: "token-a")) == nil)
        #expect(middleware.authorize(post(initializeBody(), token: "token-b")) == nil)
        #expect(middleware.authorize(post(initializeBody(), token: "token-c"))?.statusCode == 401)
    }

    @Test("A revoked token is rejected live; other tokens keep working")
    func revokedTokenRejectedLive() {
        let store = FakeTokenStore(tokens: ["token-a", "token-b"])
        let middleware = BearerTokenAuthMiddleware(tokenProvider: { try store.listAgents().map(\.token) })

        #expect(middleware.authorize(post(initializeBody(), token: "token-b")) == nil)
        store.removeToken("token-b")

        #expect(middleware.authorize(post(initializeBody(), token: "token-b"))?.statusCode == 401)
        #expect(middleware.authorize(post(initializeBody(), token: "token-a")) == nil)
    }

    @Test("A token issued after the gate was built authenticates")
    func issuedTokenAuthenticates() throws {
        let store = FakeTokenStore(tokens: ["token-a"])
        let middleware = BearerTokenAuthMiddleware(tokenProvider: { try store.listAgents().map(\.token) })

        let issued = try store.issueToken(name: "Obvious")

        #expect(middleware.authorize(post(initializeBody(), token: issued.token)) == nil)
    }

    @Test("A failing store fails closed with 401")
    func storeFailureFailsClosed() {
        struct StoreUnavailable: Error {}
        let middleware = BearerTokenAuthMiddleware(tokenProvider: { throw StoreUnavailable() })

        #expect(middleware.authorize(post(initializeBody(), token: testToken))?.statusCode == 401)
    }

    @Test("Over the real Keychain store, issued tokens authenticate and revoked tokens are rejected")
    func gateOverRealStore() throws {
        let service = isolatedService()
        defer { deleteAllItems(service: service) }
        let store = KeychainTokenStore(service: service)
        let middleware = BearerTokenAuthMiddleware(tokenProvider: { try store.listAgents().map(\.token) })

        let first = try store.issueToken(name: "a")
        let second = try store.issueToken(name: "b")

        #expect(middleware.authorize(post(initializeBody(), token: first.token)) == nil)
        #expect(middleware.authorize(post(initializeBody(), token: second.token)) == nil)
        #expect(middleware.authorize(post(initializeBody(), token: "unknown-token"))?.statusCode == 401)

        try store.revoke(id: second.id)

        #expect(middleware.authorize(post(initializeBody(), token: second.token))?.statusCode == 401)
        #expect(middleware.authorize(post(initializeBody(), token: first.token)) == nil)
    }
}

// MARK: - Session continuity

@Suite("MCPGateway sessions")
struct MCPGatewaySessionTests {

    @Test("Session continuity: initialize mints a session, the next request routes to it")
    func continuityAcrossTwoRequests() async throws {
        let gateway = makeGateway(token: testToken)

        let initializeResponse = await gateway.handle(post(initializeBody()))
        #expect(initializeResponse.statusCode == 200)
        guard let sessionID = initializeResponse.headers[MCP.HTTPHeaderName.sessionID] else {
            Issue.record("Initialize response carried no session id")
            return
        }

        let pingResponse = await gateway.handle(post(jsonRPCRequest(id: 2, method: "ping"), sessionID: sessionID))
        #expect(pingResponse.statusCode == 200)
        guard let ping = await firstJSONRPCMessage(from: pingResponse) else {
            Issue.record("Expected a ping result on the SSE stream")
            return
        }
        #expect(ping["result"] != nil)
        #expect(ping["id"] as? Int == 2)
    }

    @Test("Unknown session id answers 404")
    func unknownSession() async {
        let gateway = makeGateway(token: testToken)
        let response = await gateway.handle(
            post(jsonRPCRequest(id: 2, method: "ping"), sessionID: "not-a-real-session")
        )
        #expect(response.statusCode == 404)
    }

    @Test("Non-initialize POST without a session id answers 400")
    func missingSession() async {
        let gateway = makeGateway(token: testToken)
        let response = await gateway.handle(post(jsonRPCRequest(id: 2, method: "ping")))
        #expect(response.statusCode == 400)
    }

    @Test("DELETE retires the session; the retired id stops routing")
    func deleteRetiresSession() async {
        let gateway = makeGateway(token: testToken)
        let initializeResponse = await gateway.handle(post(initializeBody()))
        guard let sessionID = initializeResponse.headers[MCP.HTTPHeaderName.sessionID] else {
            Issue.record("Initialize response carried no session id")
            return
        }

        var deleteHeaders = [MCP.HTTPHeaderName.sessionID: sessionID]
        deleteHeaders[MCP.HTTPHeaderName.authorization] = "Bearer \(testToken)"
        let delete = MCP.HTTPRequest(method: "DELETE", headers: deleteHeaders, body: nil, path: "/mcp")
        #expect(await gateway.handle(delete).statusCode == 200)

        let after = await gateway.handle(post(jsonRPCRequest(id: 3, method: "ping"), sessionID: sessionID))
        #expect(after.statusCode == 404)
    }

    @Test("Sessions record the paired agent's token id at initialize")
    func sessionsRecordTokenIdentity() async throws {
        let agentID = UUID()
        let gateway = MCPGateway(
            validationPipeline: NilesValidationPipeline(expectedToken: testToken),
            auth: BearerTokenAuthMiddleware(expectedToken: testToken),
            tokenIdentity: { token in token == testToken ? agentID : nil }
        )

        let response = await gateway.handle(post(initializeBody()))
        #expect(response.statusCode == 200)

        let infos = await gateway.sessionInfos()
        #expect(infos.count == 1)
        #expect(infos.first?.tokenId == agentID)
        #expect(infos.first?.clientName == "niles-tests")
    }

    @Test("closeSessions(tokenId:) retires only the bound agent's session")
    func revocationClosesBoundSessions() async throws {
        let agentA = UUID()
        let agentB = UUID()
        let tokenA = "agent-token-a"
        let tokenB = "agent-token-b"
        let gateway = MCPGateway(
            validationPipeline: NilesValidationPipeline(tokens: [tokenA, tokenB]),
            auth: BearerTokenAuthMiddleware(tokens: [tokenA, tokenB]),
            tokenIdentity: { token in
                token == tokenA ? agentA : token == tokenB ? agentB : nil
            }
        )

        let responseA = await gateway.handle(post(initializeBody(), token: tokenA))
        let responseB = await gateway.handle(post(initializeBody(), token: tokenB))
        guard let sessionA = responseA.headers[MCP.HTTPHeaderName.sessionID],
            let sessionB = responseB.headers[MCP.HTTPHeaderName.sessionID]
        else {
            Issue.record("An initialize response carried no session id")
            return
        }

        #expect(await gateway.closeSessions(tokenId: agentA) == 1)
        let revokedAgent = await gateway.handle(
            post(jsonRPCRequest(id: 3, method: "ping"), token: tokenA, sessionID: sessionA)
        )
        #expect(revokedAgent.statusCode == 404)
        let otherAgent = await gateway.handle(
            post(jsonRPCRequest(id: 4, method: "ping"), token: tokenB, sessionID: sessionB)
        )
        #expect(otherAgent.statusCode == 200)
    }

    @Test("An unresolved token still creates a session, without an identity to revoke")
    func unresolvedTokenYieldsNilIdentity() async throws {
        let gateway = MCPGateway(
            validationPipeline: NilesValidationPipeline(expectedToken: testToken),
            auth: BearerTokenAuthMiddleware(expectedToken: testToken),
            tokenIdentity: { _ in nil }
        )

        let response = await gateway.handle(post(initializeBody()))
        #expect(response.statusCode == 200)
        let infos = await gateway.sessionInfos()
        #expect(infos.count == 1)
        #expect(infos.first?.tokenId == nil)
    }
}

// MARK: - Keychain token store

@Suite("KeychainTokenStore")
struct KeychainTokenStoreTests {

    @Test("Generated tokens are 64 hex characters and never repeat")
    func generatesHexTokens() throws {
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        var seen = Set<String>()
        for _ in 0..<16 {
            let token = try KeychainTokenStore.generateToken()
            #expect(token.count == 64)
            #expect(token.unicodeScalars.allSatisfy { hex.contains($0) })
            seen.insert(token)
        }
        #expect(seen.count == 16)
    }

    @Test("Issued agents list with their names and distinct tokens; revoke round-trips")
    func issueListRevokeRoundTrip() throws {
        let service = isolatedService()
        defer { deleteAllItems(service: service) }
        let store = KeychainTokenStore(service: service)

        let first = try store.issueToken(name: "Obvious")
        let second = try store.issueToken(name: nil)

        let agents = try store.listAgents()
        #expect(agents.count == 2)
        let byID = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0) })
        #expect(byID[first.id]?.name == "Obvious")
        #expect(byID[first.id]?.token == first.token)
        #expect(byID[second.id]?.name == nil)
        #expect(byID[second.id]?.token == second.token)
        #expect(first.token != second.token)

        try store.revoke(id: first.id)
        #expect(try store.listAgents().map(\.id) == [second.id])

        // Revoking an already-revoked id is a no-op, not an error.
        try store.revoke(id: first.id)
        #expect(try store.listAgents().map(\.id) == [second.id])
    }

    @Test("Legacy token migrates to a listed agent entry without being deleted or replaced")
    func legacyMigration() throws {
        let service = isolatedService()
        defer { deleteAllItems(service: service) }
        let store = KeychainTokenStore(service: service)

        let legacy = try store.loadOrCreate()

        let agents = try store.listAgents()
        #expect(agents.map(\.id) == [KeychainTokenStore.legacyAgentID])
        #expect(agents.first?.name == "Legacy token")
        #expect(agents.first?.token == legacy)

        // Re-reading is stable — migration does not mint a replacement.
        #expect(try store.loadOrCreate() == legacy)

        // An issued agent coexists with the migrated legacy entry.
        let issued = try store.issueToken(name: "Obvious")
        let combined = try store.listAgents()
        #expect(combined.count == 2)
        #expect(Set(combined.map(\.id)) == [KeychainTokenStore.legacyAgentID, issued.id])
        #expect(combined.first(where: { $0.id == KeychainTokenStore.legacyAgentID })?.token == legacy)
    }

    @Test("Revoking the legacy entry deletes it for good; the single-token surface falls back to the oldest agent token")
    func legacyRevocationIsPermanent() throws {
        let service = isolatedService()
        defer { deleteAllItems(service: service) }
        let store = KeychainTokenStore(service: service)

        _ = try store.loadOrCreate()
        let agent = try store.issueToken(name: "Obvious")

        try store.revoke(id: KeychainTokenStore.legacyAgentID)

        #expect(try store.listAgents().map(\.id) == [agent.id])
        // No resurrection: loadOrCreate returns the agent token rather than
        // minting a fresh legacy item.
        #expect(try store.loadOrCreate() == agent.token)
        let afterRevoke = try store.listAgents()
        #expect(!afterRevoke.contains { $0.id == KeychainTokenStore.legacyAgentID })
    }
}

// MARK: - Helpers

/// Outcome matcher for the parser's non-associated cases; associated values are
/// compared field-by-field at the assertion site.
private func matches(_ outcome: HTTPParseOutcome, _ expected: HTTPParseOutcome) -> Bool {
    switch (outcome, expected) {
    case (.needMoreData, .needMoreData):
        return true
    case (.invalid(let left), .invalid(let right)):
        return left == right
    default:
        return false
    }
}

// MARK: - Token-set helpers

/// Thread-safe in-memory `TokenStoring` double: mutating the set between
/// requests proves the middleware reads live state, not a construction-time
/// snapshot.
private final class FakeTokenStore: TokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String]

    init(tokens: [String]) {
        self.tokens = tokens
    }

    func loadOrCreate() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        return tokens.first ?? ""
    }

    func listAgents() throws -> [PairedAgent] {
        lock.lock()
        defer { lock.unlock() }
        return tokens.map { PairedAgent(id: UUID(), name: nil, token: $0, pairedAt: .distantPast) }
    }

    func issueToken(name: String?) throws -> PairedAgent {
        let token = "issued-" + UUID().uuidString
        lock.lock()
        defer { lock.unlock() }
        tokens.append(token)
        return PairedAgent(id: UUID(), name: name, token: token, pairedAt: Date())
    }

    func revoke(id: UUID) throws {}

    func removeToken(_ token: String) {
        lock.lock()
        defer { lock.unlock() }
        tokens.removeAll { $0 == token }
    }
}
