import Foundation
import MCP

/// Result of attempting to parse one HTTP/1.1 request from a connection buffer.
public enum HTTPParseOutcome: Sendable {
    /// More bytes are needed before a request can be parsed.
    case needMoreData
    /// The bytes cannot form a valid request; the connection must be answered with an error and closed.
    case invalid(HTTPRequestParseError)
    /// One complete request, whether the connection may serve another one, and how many leading bytes it consumed.
    case complete(MCP.HTTPRequest, wantsKeepAlive: Bool, consumedBytes: Int)
}

/// Reasons a byte stream cannot become a valid HTTP/1.1 request.
public enum HTTPRequestParseError: Error, Sendable, Equatable {
    case malformedRequest
    case headersTooLarge(limit: Int)
    case bodyTooLarge(limit: Int)
    case transferEncodingUnsupported
}

/// Minimal HTTP/1.1 request parser for the LAN MCP adapter.
///
/// Pure bytes-in/decision-out; the connection loop owns all socket I/O. Supports exactly
/// what MCP Streamable HTTP clients send — a request line, headers, `Content-Length`
/// bodies, keep-alive — and fails closed on everything else (any `Transfer-Encoding`,
/// oversized bodies or header blocks), so a hostile peer cannot grow our buffers.
public enum HTTPRequestParser {

    /// MCP JSON-RPC payloads are small; 1 MiB is generous and bounds memory use per request.
    public static let defaultMaxBodySize = 1_048_576
    /// No complete header block within this budget means the peer is misbehaving.
    public static let maxHeaderBlockSize = 32_768

    public static func parse(_ buffer: Data, maxBodySize: Int = defaultMaxBodySize) -> HTTPParseOutcome {
        let bytes = [UInt8](buffer)

        guard let headerEnd = bytes.firstRange(of: Array("\r\n\r\n".utf8)) else {
            if bytes.count > maxHeaderBlockSize { return .invalid(.headersTooLarge(limit: maxHeaderBlockSize)) }
            return .needMoreData
        }

        let headerBlock = String(decoding: bytes[..<headerEnd.lowerBound], as: UTF8.self)
        var lines = headerBlock.components(separatedBy: "\r\n")[...]
        guard let requestLine = lines.popFirst() else { return .invalid(.malformedRequest) }

        let parts = requestLine.split(separator: " ")
        guard parts.count == 3, parts[1].hasPrefix("/") else { return .invalid(.malformedRequest) }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        let version = String(parts[2])
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else { return .invalid(.malformedRequest) }

        // Header names are case-insensitive; repeated names are joined with ", "
        // (the same normalization the MCP SDK's own framework adapters use).
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else {
                return .invalid(.malformedRequest)
            }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
        }

        // MCP clients frame bodies with Content-Length; anything else fails closed.
        if headers["transfer-encoding"] != nil {
            return .invalid(.transferEncodingUnsupported)
        }

        var contentLength = 0
        if let rawLength = headers["content-length"] {
            guard let parsed = Int(rawLength), parsed >= 0 else { return .invalid(.malformedRequest) }
            guard parsed <= maxBodySize else { return .invalid(.bodyTooLarge(limit: maxBodySize)) }
            contentLength = parsed
        }

        let bodyStart = headerEnd.upperBound
        let bodyEnd = bodyStart + contentLength
        guard bytes.count >= bodyEnd else { return .needMoreData }
        let body = contentLength > 0 ? Data(bytes[bodyStart..<bodyEnd]) : nil

        let path = String(target.prefix(while: { $0 != "?" }))
        let request = MCP.HTTPRequest(method: method, headers: headers, body: body, path: path)

        let connectionHeader = (headers["connection"] ?? "").lowercased()
        let wantsKeepAlive = version == "HTTP/1.1"
            ? !connectionHeader.contains("close")
            : connectionHeader.contains("keep-alive")

        return .complete(request, wantsKeepAlive: wantsKeepAlive, consumedBytes: bodyEnd)
    }
}
