import Foundation
import MCP

/// Static bearer-token gate for Niles' LAN trust model.
///
/// The token is the whole credential — agents learn it out-of-band from the pairing
/// screen (QR or pasted string), mirroring the HomeKitSync pattern. Conforms to both
/// `AuthChecking` (the gateway's pre-transport gate) and the MCP SDK's
/// `HTTPRequestValidator` (first validator in the per-session pipeline), so one
/// comparison implementation guards both entry points.
public struct BearerTokenAuthMiddleware: AuthChecking, MCP.HTTPRequestValidator {

    private let expectedToken: String

    public init(expectedToken: String) {
        self.expectedToken = expectedToken
    }

    public func validate(_ request: MCP.HTTPRequest, context: MCP.HTTPValidationContext) -> MCP.HTTPResponse? {
        let header = request.header(MCP.HTTPHeaderName.authorization) ?? ""
        let parts = header.split(maxSplits: 1, whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 2,
            parts[0].caseInsensitiveCompare("Bearer") == .orderedSame,
            Self.tokensMatch(parts[1].trimmingCharacters(in: .whitespaces), expectedToken)
        else {
            return .error(
                statusCode: 401,
                .invalidRequest("Unauthorized: Missing or invalid bearer token"),
                sessionID: nil,
                extraHeaders: [MCP.HTTPHeaderName.wwwAuthenticate: "Bearer"]
            )
        }
        return nil
    }

    public func authorize(_ request: MCP.HTTPRequest) -> MCP.HTTPResponse? {
        validate(request, context: MCP.HTTPValidationContext(httpMethod: request.method))
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
