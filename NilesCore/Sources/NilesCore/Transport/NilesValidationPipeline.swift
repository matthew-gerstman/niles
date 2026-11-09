import Foundation
import MCP

/// The validation pipeline Niles hands every session transport.
///
/// Same checks as the SDK default with two changes: the bearer-token validator runs
/// first (defense in depth behind the gateway's pre-transport gate), and the
/// localhost `OriginValidator` is dropped — see `BearerTokenAuthMiddleware` for why
/// origin validation does not fit a LAN token server.
public struct NilesValidationPipeline: MCP.HTTPRequestValidationPipeline {

    private let standard: MCP.StandardValidationPipeline

    public init(expectedToken: String) {
        self.init(tokens: [expectedToken])
    }

    public init(tokens: [String]) {
        self.init(tokenProvider: { tokens })
    }

    public init(tokenProvider: @escaping @Sendable () throws -> [String]) {
        standard = MCP.StandardValidationPipeline(validators: [
            BearerTokenAuthMiddleware(tokenProvider: tokenProvider),
            MCP.AcceptHeaderValidator(mode: .sseRequired),
            MCP.ContentTypeValidator(),
            MCP.ProtocolVersionValidator(),
            MCP.SessionValidator(),
        ])
    }

    public func validate(_ request: MCP.HTTPRequest, context: MCP.HTTPValidationContext) -> MCP.HTTPResponse? {
        standard.validate(request, context: context)
    }
}
