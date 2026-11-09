import Foundation
import MCP

/// Set-aware bearer-token gate for Niles' LAN trust model.
///
/// Validates the `Authorization` header against the live set of credentials —
/// one per paired agent plus the legacy static token — so issuing a token at
/// pairing or revoking one from Settings takes effect without a restart.
/// Agents learn tokens out-of-band (pairing flow; the legacy QR/paste path),
/// mirroring the HomeKitSync pattern. Conforms to both `AuthChecking` (the
/// gateway's pre-transport gate) and the MCP SDK's `HTTPRequestValidator`
/// (first validator in the per-session pipeline), so one comparison
/// implementation guards both entry points.
public struct BearerTokenAuthMiddleware: AuthChecking, MCP.HTTPRequestValidator {

    private let liveTokens: @Sendable () throws -> [String]

    /// Validates against a fixed token set — the legacy single-token shape.
    public init(expectedToken: String) {
        self.init(tokens: [expectedToken])
    }

    /// Validates against a fixed set of tokens.
    public init(tokens: [String]) {
        self.liveTokens = { tokens }
    }

    /// Validates against tokens read at request time. A throwing provider
    /// denies the request (fail closed) — the 401 is the error's observable
    /// surface, never an open door.
    public init(tokenProvider: @escaping @Sendable () throws -> [String]) {
        self.liveTokens = tokenProvider
    }

    public func validate(_ request: MCP.HTTPRequest, context: MCP.HTTPValidationContext) -> MCP.HTTPResponse? {
        let header = request.header(MCP.HTTPHeaderName.authorization) ?? ""
        let parts = header.split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 2,
            parts[0].caseInsensitiveCompare("Bearer") == .orderedSame
        else {
            return Self.unauthorized()
        }
        let candidate = parts[1].trimmingCharacters(in: .whitespaces)
        let expected: [String]
        do {
            expected = try liveTokens()
        } catch {
            return Self.unauthorized()
        }
        // Compare cost is uniform per candidate; the candidate count is not
        // secret (an attacker sees 401 vs 401 either way).
        guard expected.contains(where: { Self.tokensMatch(candidate, $0) }) else {
            return Self.unauthorized()
        }
        return nil
    }

    public func authorize(_ request: MCP.HTTPRequest) -> MCP.HTTPResponse? {
        validate(request, context: MCP.HTTPValidationContext(httpMethod: request.method))
    }

    private static func unauthorized() -> MCP.HTTPResponse {
        .error(
            statusCode: 401,
            .invalidRequest("Unauthorized: Missing or invalid bearer token"),
            sessionID: nil,
            extraHeaders: [MCP.HTTPHeaderName.wwwAuthenticate: "Bearer"]
        )
    }

    /// Byte-wise XOR accumulation, so comparison time does not vary with how early
    /// the tokens diverge. A length difference leaks (the loop runs to the longer
    /// token's end regardless); token content timing does not.
    static func tokensMatch(_ received: String, _ expected: String) -> Bool {
        let receivedBytes = Array(received.utf8)
        let expectedBytes = Array(expected.utf8)
        var delta: UInt8 = receivedBytes.count == expectedBytes.count ? 0 : 1
        for index in 0..<max(receivedBytes.count, expectedBytes.count) {
            let left = index < receivedBytes.count ? receivedBytes[index] : 0
            let right = index < expectedBytes.count ? expectedBytes[index] : 0
            delta |= left ^ right
        }
        return delta == 0
    }
}
