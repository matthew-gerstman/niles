import Foundation
import Network
import Security
import Testing
import MCP

@testable import NilesCore

// Pairing-core tests: the six-digit code lifecycle, the POST /pairing exchange
// routed through the connection runner's pairing-before-gateway branch, and the
// Bonjour TXT discovery record. Like TransportTests, no sockets are bound — the
// runner's routing decision is exercised directly on an inert NWConnection.

// MARK: - Fixtures

/// A mutable clock: tests set the time, the manager's injected `now` reads it.
private final class MutableClock: @unchecked Sendable {
    var date: Date

    init(_ date: Date = Date(timeIntervalSinceReferenceDate: 0)) {
        self.date = date
    }

    func now() -> Date { date }
}

/// A store whose issuance fails — the exchange must fail closed (500, no agent).
private struct FailingTokenStore: TokenStoring {
    func loadOrCreate() throws -> String { "" }
    func listAgents() throws -> [PairedAgent] { [] }
    func issueToken(name: String?) throws -> PairedAgent {
        throw KeychainTokenStore.TokenStoreError.keychainFailure(errSecFailure)
    }
    func revoke(id: UUID) throws {}
}

/// A 6-digit string differing from `code` at every position, so it can never
/// collide with the live code however the generator lands.
private func wrongGuess(for code: String) -> String {
    String(code.map { $0 == "0" ? "1" : "0" })
}

private func pairingRequest(
    code: String?,
    name: String? = nil,
    path: String = PairingService.defaultPath,
    method: String = "POST"
) -> MCP.HTTPRequest {
    var body: Data?
    if let code {
        var object: [String: Any] = ["code": code]
        if let name { object["name"] = name }
        body = try! JSONSerialization.data(withJSONObject: object)
    }
    return MCP.HTTPRequest(method: method, headers: [:], body: body, path: path)
}

private func rawPairingRequest(_ body: Data?, path: String = PairingService.defaultPath) -> MCP.HTTPRequest {
    MCP.HTTPRequest(method: "POST", headers: [:], body: body, path: path)
}

private func mcpRequest(body: Data, token: String?, sessionID: String? = nil) -> MCP.HTTPRequest {
    var headers = [
        MCP.HTTPHeaderName.contentType: "application/json",
        MCP.HTTPHeaderName.accept: "application/json, text/event-stream",
        MCP.HTTPHeaderName.protocolVersion: "2025-11-25",
    ]
    if let token { headers[MCP.HTTPHeaderName.authorization] = "Bearer \(token)" }
    if let sessionID { headers[MCP.HTTPHeaderName.sessionID] = sessionID }
    return MCP.HTTPRequest(method: "POST", headers: headers, body: body, path: "/mcp")
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

private func jsonBody(of response: PairingService.ExchangeResponse) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
        Issue.record("Expected a JSON object body, got: \(String(decoding: response.body, as: UTF8.self))")
        return [:]
    }
    return object
}

private struct ExchangeFixture {
    let runner: HTTPConnectionRunner
    let codes: PairingCodeManager
    let store: KeychainTokenStore
    let clock: MutableClock
    let service: String
}

/// The real wiring the server uses: one isolated Keychain store feeding the
/// pairing service AND the gateway's bearer gate, behind one connection runner.
private func makeExchangeFixture() -> ExchangeFixture {
    let service = isolatedService()
    let store = KeychainTokenStore(service: service)
    let clock = MutableClock()
    let codes = PairingCodeManager(now: clock.now)
    let pairing = PairingService(codes: codes, tokens: store)
    let tokenProvider: @Sendable () throws -> [String] = { try store.listAgents().map(\.token) }
    let gateway = MCPGateway(
        validationPipeline: NilesValidationPipeline(tokenProvider: tokenProvider),
        auth: BearerTokenAuthMiddleware(tokenProvider: tokenProvider)
    )
    // An inert connection: `route` never touches it; only `run` would.
    let connection = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
    let runner = HTTPConnectionRunner(connection: connection, gateway: gateway, pairing: pairing)
    return ExchangeFixture(runner: runner, codes: codes, store: store, clock: clock, service: service)
}

private func pairingExchange(
    from runner: HTTPConnectionRunner,
    code: String,
    name: String? = nil
) async throws -> PairingService.ExchangeResponse {
    let routed = await runner.route(pairingRequest(code: code, name: name))
    guard case .pairing(let exchange) = routed else {
        Issue.record("Expected the pairing route for a POST /pairing, got: \(routed)")
        return PairingService.ExchangeResponse(statusCode: -1, body: Data())
    }
    return exchange
}

// MARK: - Code lifecycle

@Suite("PairingCodeManager")
struct PairingCodeManagerTests {

    @Test("Minted codes are six distinct zero-padded digits")
    func mintFormatDistinct() async throws {
        let manager = PairingCodeManager()
        let digits = CharacterSet(charactersIn: "0123456789")
        var seen = Set<String>()
        for _ in 0..<6 {
            let code = try await manager.mintCode().code
            #expect(code.count == 6)
            #expect(code.unicodeScalars.allSatisfy { digits.contains($0) })
            seen.insert(code)
        }
        #expect(seen.count == 6)
    }

    @Test("generateCode yields zero-padded six digits across many draws")
    func generateFormat() throws {
        let digits = CharacterSet(charactersIn: "0123456789")
        for _ in 0..<32 {
            let code = try PairingCodeManager.generateCode()
            #expect(code.count == 6)
            #expect(code.unicodeScalars.allSatisfy { digits.contains($0) })
        }
    }

    @Test("The correct code verifies while live")
    func verifiesCorrectCode() async throws {
        let manager = PairingCodeManager()
        let code = try await manager.mintCode().code
        #expect(await manager.verify(code) == .success)
    }

    @Test("The code is still live just before expiry, with its expiry surfaced for the countdown")
    func liveJustBeforeExpiry() async throws {
        let clock = MutableClock()
        let manager = PairingCodeManager(now: clock.now)
        let minted = try await manager.mintCode()

        clock.date = minted.expiresAt.addingTimeInterval(-1)
        #expect(await manager.activeCode() == minted)
    }

    @Test("The code expires after its TTL and verifies as gone")
    func expiryAfterTTL() async throws {
        let clock = MutableClock()
        let manager = PairingCodeManager(now: clock.now)
        let minted = try await manager.mintCode()

        clock.date = minted.expiresAt.addingTimeInterval(1)
        #expect(await manager.activeCode() == nil)
        #expect(await manager.verify(minted.code) == .expired)
    }

    @Test("A successful exchange burns the code — no replay")
    func singleUseBurn() async throws {
        let manager = PairingCodeManager()
        let code = try await manager.mintCode().code

        #expect(await manager.verify(code) == .success)
        #expect(await manager.verify(code) == .expired)
        #expect(await manager.activeCode() == nil)
    }

    @Test("Five failed attempts burn the code; even the correct code is gone after")
    func attemptCapBurns() async throws {
        let manager = PairingCodeManager()
        let code = try await manager.mintCode().code
        let wrong = wrongGuess(for: code)

        for _ in 0..<4 {
            #expect(await manager.verify(wrong) == .invalidCode)
        }
        #expect(await manager.verify(wrong) == .tooManyAttempts)
        #expect(await manager.verify(code) == .expired)
        #expect(await manager.activeCode() == nil)
    }

    @Test("Failures below the cap do not kill the code")
    func belowCapStillWorks() async throws {
        let manager = PairingCodeManager()
        let code = try await manager.mintCode().code

        for _ in 0..<3 {
            #expect(await manager.verify(wrongGuess(for: code)) == .invalidCode)
        }
        #expect(await manager.verify(code) == .success)
    }

    @Test("Attempts are counted per code — minting resets them")
    func mintResetsAttempts() async throws {
        let manager = PairingCodeManager()
        let first = try await manager.mintCode().code

        for _ in 0..<4 {
            #expect(await manager.verify(wrongGuess(for: first)) == .invalidCode)
        }

        let second = try await manager.mintCode().code
        // A single failure on the fresh code is the first, not the fifth.
        #expect(await manager.verify(wrongGuess(for: second)) == .invalidCode)
        #expect(await manager.verify(second) == .success)
    }

    @Test("Wrong-length candidates are counted attempts — no length fast-path past the constant-time compare")
    func wrongLengthCountsAsAttempt() async throws {
        let manager = PairingCodeManager()
        let code = try await manager.mintCode().code

        #expect(await manager.verify(String(code.dropLast())) == .invalidCode)
        #expect(await manager.verify(code + "9") == .invalidCode)
        for _ in 0..<3 {
            #expect(await manager.verify(wrongGuess(for: code)) == .invalidCode)
        }
        // Five attempts counted in total: this fifth burns the code.
        #expect(await manager.verify(wrongGuess(for: code)) == .tooManyAttempts)
    }

    @Test("A fresh mint after expiry verifies")
    func remintAfterExpiry() async throws {
        let clock = MutableClock()
        let manager = PairingCodeManager(now: clock.now)
        let first = try await manager.mintCode()

        clock.date = first.expiresAt.addingTimeInterval(1)
        let second = try await manager.mintCode()
        #expect(second.expiresAt > clock.date)
        #expect(await manager.verify(second.code) == .success)
    }
}

// MARK: - Exchange over the connection runner

@Suite("Pairing exchange over HTTPConnectionRunner")
struct PairingExchangeTests {

    @Test("Happy path: correct code exchanges for a per-agent token that authenticates /mcp")
    func happyPath() async throws {
        let f = makeExchangeFixture()
        defer { deleteAllItems(service: f.service) }
        let code = try await f.codes.mintCode().code

        let exchange = try await pairingExchange(from: f.runner, code: code, name: "Obvious")
        #expect(exchange.statusCode == 200)
        let body = try jsonBody(of: exchange)
        let token = body["access_token"] as? String
        #expect(token?.count == 64)
        #expect(body["token_type"] as? String == "Bearer")

        // The issued token initializes an MCP session through the same runner.
        let routed = await f.runner.route(mcpRequest(body: initializeBody(), token: token))
        guard case .gateway(let response) = routed else {
            Issue.record("Expected the gateway route for /mcp, got: \(routed)")
            return
        }
        #expect(response.statusCode == 200)
        #expect(response.headers[MCP.HTTPHeaderName.sessionID] != nil)

        // The agent is listed under its pairing name.
        let agents = try f.store.listAgents()
        #expect(agents.count == 1)
        #expect(agents.first?.name == "Obvious")
    }

    @Test("Wrong code: 401 invalid_code, attempts counted, fifth failure is 429, then 410 — with no token issued")
    func attemptLifecycle() async throws {
        let f = makeExchangeFixture()
        defer { deleteAllItems(service: f.service) }
        let code = try await f.codes.mintCode().code
        let wrong = wrongGuess(for: code)

        for _ in 0..<4 {
            let exchange = try await pairingExchange(from: f.runner, code: wrong)
            #expect(exchange.statusCode == 401)
            let body = try jsonBody(of: exchange)
            #expect(body["error"] as? String == "invalid_code")
        }
        let fifth = try await pairingExchange(from: f.runner, code: wrong)
        #expect(fifth.statusCode == 429)
        #expect(try jsonBody(of: fifth)["error"] as? String == "too_many_attempts")

        let after = try await pairingExchange(from: f.runner, code: code)
        #expect(after.statusCode == 410)
        #expect(try jsonBody(of: after)["error"] as? String == "expired")

        #expect(try f.store.listAgents().isEmpty)
    }

    @Test("Expired code: 410 expired")
    func expiredTTL() async throws {
        let f = makeExchangeFixture()
        defer { deleteAllItems(service: f.service) }
        let minted = try await f.codes.mintCode()
        f.clock.date = minted.expiresAt.addingTimeInterval(1)

        let exchange = try await pairingExchange(from: f.runner, code: minted.code)
        #expect(exchange.statusCode == 410)
        #expect(try jsonBody(of: exchange)["error"] as? String == "expired")
    }

    @Test("No code minted yet: 410 expired — nothing distinguishes it from an expired code")
    func noCodeAtAll() async throws {
        let f = makeExchangeFixture()
        defer { deleteAllItems(service: f.service) }

        let exchange = try await pairingExchange(from: f.runner, code: "123456")
        #expect(exchange.statusCode == 410)
        #expect(try jsonBody(of: exchange)["error"] as? String == "expired")
    }

    @Test("Single use: the token is delivered once — a replay gets 410 and issues nothing")
    func replayAfterSuccess() async throws {
        let f = makeExchangeFixture()
        defer { deleteAllItems(service: f.service) }
        let code = try await f.codes.mintCode().code

        let first = try await pairingExchange(from: f.runner, code: code, name: "Obvious")
        #expect(first.statusCode == 200)

        let replay = try await pairingExchange(from: f.runner, code: code)
        #expect(replay.statusCode == 410)

        #expect(try f.store.listAgents().count == 1)
    }

    @Test("Responses never echo the submitted code and carry only the contracted fields")
    func noCodeEcho() async throws {
        let f = makeExchangeFixture()
        defer { deleteAllItems(service: f.service) }
        let code = try await f.codes.mintCode().code

        let wrong = try await pairingExchange(from: f.runner, code: code + "7")
        #expect(Array(try jsonBody(of: wrong).keys) == ["error"])
        #expect(!String(decoding: wrong.body, as: UTF8.self).contains(code))

        let success = try await pairingExchange(from: f.runner, code: code)
        #expect(Set(try jsonBody(of: success).keys) == ["access_token", "token_type"])
        #expect(!String(decoding: success.body, as: UTF8.self).contains(code))
    }

    @Test("Malformed body: 400 invalid_request without consuming an attempt")
    func malformedBodyDoesNotCountAttempt() async throws {
        let f = makeExchangeFixture()
        defer { deleteAllItems(service: f.service) }
        let code = try await f.codes.mintCode().code

        for raw in [Data("not json".utf8), Data(#"{"name":"x"}"#.utf8), Data(#"{"code":483920}"#.utf8)] {
            let routed = await f.runner.route(rawPairingRequest(raw))
            guard case .pairing(let exchange) = routed else {
                Issue.record("Expected the pairing route, got: \(routed)")
                return
            }
            #expect(exchange.statusCode == 400)
            #expect(try jsonBody(of: exchange)["error"] as? String == "invalid_request")
        }

        // The correct code still exchanges — no attempt was consumed.
        let exchange = try await pairingExchange(from: f.runner, code: code)
        #expect(exchange.statusCode == 200)
    }

    @Test("Pairing is unreachable through /mcp: the auth gate first, then the gateway's own handling")
    func pairingNotReachableThroughMCP() async throws {
        let f = makeExchangeFixture()
        defer { deleteAllItems(service: f.service) }
        let code = try await f.codes.mintCode().code
        let pairingBody = pairingRequest(code: code).body!

        // Unauthenticated: the gateway's bearer gate denies before anything else.
        let unauthenticated = await f.runner.route(mcpRequest(body: pairingBody, token: nil))
        guard case .gateway(let denial) = unauthenticated else {
            Issue.record("The MCP path must answer from the gateway, never the pairing service")
            return
        }
        #expect(denial.statusCode == 401)

        // Authorized but pairing-shaped: the gateway treats it as MCP traffic
        // (a non-initialize POST without a session id), not a pairing exchange.
        let legacy = try f.store.loadOrCreate()
        let authorized = await f.runner.route(mcpRequest(body: pairingBody, token: legacy))
        guard case .gateway(let gatewayResponse) = authorized else {
            Issue.record("The MCP path must answer from the gateway, never the pairing service")
            return
        }
        #expect(gatewayResponse.statusCode == 400)

        // A non-POST to the pairing path also flows to the gateway as before.
        let get = await f.runner.route(
            MCP.HTTPRequest(method: "GET", headers: [:], body: nil, path: PairingService.defaultPath)
        )
        guard case .gateway(let getResponse) = get else {
            Issue.record("GET /pairing must flow to the gateway unchanged")
            return
        }
        #expect(getResponse.statusCode == 401)

        // The code survived all of it — no credential was ever issued.
        #expect(try f.store.listAgents().count == 1)  // the legacy entry only
    }

    @Test("Keychain failure after a correct code: 500, no token, code burned — fail closed")
    func issuanceFailureFailsClosed() async throws {
        let codes = PairingCodeManager()
        let pairing = PairingService(codes: codes, tokens: FailingTokenStore())
        let connection = NWConnection(host: "127.0.0.1", port: 1, using: .tcp)
        let runner = HTTPConnectionRunner(connection: connection, gateway: MCPGateway(), pairing: pairing)

        let code = try await codes.mintCode().code
        let exchange = try await pairingExchange(from: runner, code: code)
        #expect(exchange.statusCode == 500)
        #expect(try jsonBody(of: exchange)["error"] as? String == "internal_error")

        // The burned code cannot be replayed to retry the issuance.
        let replay = try await pairingExchange(from: runner, code: code)
        #expect(replay.statusCode == 410)
    }
}

// MARK: - Bonjour TXT record

@Suite("Bonjour TXT record")
struct BonjourTXTTests {

    /// Decodes a NetService TXT record: length-prefixed `key=value` entries.
    private func decode(_ data: Data) -> [String: String] {
        var entries: [String: String] = [:]
        var index = data.startIndex
        while index < data.endIndex {
            let length = Int(data[index])
            index = data.index(after: index)
            let entry = String(decoding: data[index..<data.index(index, offsetBy: length)], as: UTF8.self)
            index = data.index(index, offsetBy: length)
            guard let equals = entry.firstIndex(of: "=") else { continue }
            entries[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return entries
    }

    @Test("The advertised TXT record carries the MCP path, pairing version, and code flag")
    func advertisedRecord() {
        #expect(decode(NilesBonjour.serviceTXT) == [
            "mcp": "/mcp",
            "pairing": "v1",
            "code": "1",
        ])
    }

    @Test("Encoding round-trips and is deterministic for equal inputs")
    func encodingRoundTrip() {
        let entries = ["mcp": "/mcp", "pairing": "v1", "code": "1", "empty": ""]
        let first = NilesBonjour.txtRecord(entries)
        #expect(first == NilesBonjour.txtRecord(entries))
        #expect(decode(first) == entries)
    }
}

// MARK: - Pairing serialization

@Suite("HTTPResponseWriter — pairing serialization")
struct PairingSerializationTests {

    @Test("Plain responses serialize with status, content type, connection, and exact body length")
    func plainResponse() {
        let body = Data(#"{"error":"invalid_code"}"#.utf8)
        let wire = HTTPResponseWriter.serialize(
            statusCode: 401,
            body: body,
            headers: [MCP.HTTPHeaderName.contentType: PairingService.ExchangeResponse.jsonContentType],
            keepAlive: true
        )
        let text = String(decoding: wire, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 401 "))
        #expect(text.lowercased().contains("content-type: application/json"))
        #expect(text.lowercased().contains("connection: keep-alive"))
        #expect(text.contains("content-length: \(body.count)"))
        #expect(wire.suffix(body.count) == body)
    }

    @Test("410 and 429 carry proper reason phrases")
    func reasonPhrases() {
        let gone = HTTPResponseWriter.head(statusCode: 410, headers: [:], keepAlive: false, bodyLength: 0)
        #expect(String(decoding: gone, as: UTF8.self).hasPrefix("HTTP/1.1 410 Gone\r\n"))
        let capped = HTTPResponseWriter.head(statusCode: 429, headers: [:], keepAlive: false, bodyLength: 0)
        #expect(String(decoding: capped, as: UTF8.self).hasPrefix("HTTP/1.1 429 Too Many Requests\r\n"))
    }
}
