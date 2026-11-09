import Foundation
import MCP

/// Serves the device-flow pairing exchange: `POST <path>` with
/// `{ "code": "483920", "name": "Obvious" }` answered by a per-agent bearer
/// token.
///
/// Routed by the connection runner BEFORE the MCP gateway — the gateway's
/// auth gate runs ahead of its path check, so an unauthenticated pairing
/// exchange could never be reached through it. The service holds no state of
/// its own: the code's lifecycle lives in `PairingCodeManager`, the issued
/// credentials in the `TokenStoring` store.
public actor PairingService {

    /// The wire response for one exchange: a status plus a complete JSON body.
    ///
    /// Not an `MCP.HTTPResponse`: the SDK's response enum cannot express a
    /// non-200 body (its `.error` case always renders a JSON-RPC envelope),
    /// and the pairing contract fixes plain JSON bodies.
    public struct ExchangeResponse: Sendable, Equatable {
        public static let jsonContentType = "application/json"

        public let statusCode: Int
        public let headers: [String: String]
        public let body: Data

        public init(
            statusCode: Int,
            headers: [String: String] = ["Content-Type": ExchangeResponse.jsonContentType],
            body: Data
        ) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
        }
    }

    /// The exchange request body: `{ "code": "483920", "name": "Obvious" }`.
    /// `name` is optional and display-only (the paired-agents list).
    private struct ExchangeRequest: Decodable {
        let code: String
        let name: String?
    }

    /// The success body: fixed field names per the pairing contract.
    private struct TokenResponseBody: Encodable {
        let accessToken: String
        let tokenType: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case tokenType = "token_type"
        }
    }

    /// Error classes and their fixed status codes. The response body carries
    /// the class string only — never the submitted code.
    private enum ExchangeError {
        case invalidRequest      // 400 — body could not carry a code (not a guess; no attempt counted)
        case invalidCode         // 401 — wrong code, attempt counted
        case expired             // 410 — no live code (never minted, TTL elapsed, or burned)
        case tooManyAttempts     // 429 — the fifth consecutive failure burned the code
        case tokenIssuanceFailed // 500 — the store failed after the code burned; fails closed

        var statusCode: Int {
            switch self {
            case .invalidRequest: 400
            case .invalidCode: 401
            case .expired: 410
            case .tooManyAttempts: 429
            case .tokenIssuanceFailed: 500
            }
        }

        var errorClass: String {
            switch self {
            case .invalidRequest: "invalid_request"
            case .invalidCode: "invalid_code"
            case .expired: "expired"
            case .tooManyAttempts: "too_many_attempts"
            case .tokenIssuanceFailed: "internal_error"
            }
        }
    }

    public static let defaultPath = "/pairing"

    private let codes: PairingCodeManager
    private let tokens: any TokenStoring
    private let path: String

    public init(
        codes: PairingCodeManager,
        tokens: any TokenStoring,
        path: String = PairingService.defaultPath
    ) {
        self.codes = codes
        self.tokens = tokens
        self.path = path
    }

    /// The response for this request if it belongs to the pairing endpoint;
    /// `nil` hands the request on to the MCP gateway unchanged.
    public func handle(_ request: MCP.HTTPRequest) async -> ExchangeResponse? {
        guard request.method.uppercased() == "POST", request.path == path else { return nil }
        return await exchange(request.body)
    }

    private func exchange(_ body: Data?) async -> ExchangeResponse {
        let request: ExchangeRequest
        do {
            request = try JSONDecoder().decode(ExchangeRequest.self, from: body ?? Data())
        } catch {
            // A body that cannot carry a code is a client bug, not a guess:
            // 400 without counting an attempt (there is no code in it to try).
            return Self.errorResponse(.invalidRequest)
        }
        switch await codes.verify(request.code) {
        case .success:
            return issueToken(named: request.name)
        case .invalidCode:
            return Self.errorResponse(.invalidCode)
        case .expired:
            return Self.errorResponse(.expired)
        case .tooManyAttempts:
            return Self.errorResponse(.tooManyAttempts)
        }
    }

    /// Issues the pairing token. Runs after `verify` burned the code, so a
    /// Keychain failure here fails closed — no token, no code replay; the
    /// user mints a fresh code and retries.
    private func issueToken(named name: String?) -> ExchangeResponse {
        do {
            let agent = try tokens.issueToken(name: name)
            let body = try JSONEncoder().encode(TokenResponseBody(accessToken: agent.token, tokenType: "Bearer"))
            return ExchangeResponse(statusCode: 200, body: body)
        } catch {
            return Self.errorResponse(.tokenIssuanceFailed)
        }
    }

    /// Error bodies are built from fixed class strings — no request input
    /// reaches this JSON, so interpolation cannot smuggle content into it.
    private static func errorResponse(_ error: ExchangeError) -> ExchangeResponse {
        ExchangeResponse(statusCode: error.statusCode, body: Data(#"{"error":"\#(error.errorClass)"}"#.utf8))
    }
}
