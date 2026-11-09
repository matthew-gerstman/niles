import Foundation
import MCP

/// Serializes MCP `HTTPResponse` values onto the wire (HTTP/1.1).
///
/// Pure enum-in/bytes-out. Non-stream responses carry `Content-Length`; SSE `.stream`
/// responses use chunked transfer encoding so the connection stays reusable after the
/// stream ends. Header output is deterministic (sorted) for testability.
public enum HTTPResponseWriter {

    /// Status reasons for every code the MCP SDK can emit, plus a safe fallback.
    static let reasons: [Int: String] = [
        200: "OK",
        202: "Accepted",
        204: "No Content",
        400: "Bad Request",
        401: "Unauthorized",
        403: "Forbidden",
        404: "Not Found",
        405: "Method Not Allowed",
        406: "Not Acceptable",
        409: "Conflict",
        413: "Payload Too Large",
        415: "Unsupported Media Type",
        421: "Misdirected Request",
        431: "Request Header Fields Too Large",
        429: "Too Many Requests",
        410: "Gone",
        500: "Internal Server Error",
        501: "Not Implemented",
        503: "Service Unavailable",
    ]

    static func reason(for statusCode: Int) -> String {
        reasons[statusCode] ?? "Status \(statusCode)"
    }

    /// The response head: status line + headers, with `Content-Length` for complete
    /// bodies or `Transfer-Encoding: chunked` for streaming ones.
    ///
    /// `keepAlive` decides the `Connection` header; the caller's decision always wins
    /// over any header the SDK supplied.
    public static func head(_ response: MCP.HTTPResponse, keepAlive: Bool, chunked: Bool = false) -> Data {
        head(
            statusCode: response.statusCode,
            headers: response.headers,
            keepAlive: keepAlive,
            bodyLength: chunked ? nil : response.bodyData?.count ?? 0
        )
    }

    /// Status line + headers for a complete body framed by `Content-Length`
    /// (`bodyLength` set) or by chunked transfer encoding (`bodyLength` nil).
    public static func head(statusCode: Int, headers: [String: String], keepAlive: Bool, bodyLength: Int?) -> Data {
        var out = "HTTP/1.1 \(statusCode) \(reason(for: statusCode))\r\n"

        var headers = headers
        headers["Connection"] = keepAlive ? (headers["Connection"] ?? "keep-alive") : "close"
        for name in headers.keys.sorted() {
            out += "\(name): \(headers[name] ?? "")\r\n"
        }

        if let bodyLength {
            out += "Content-Length: \(bodyLength)\r\n"
        } else {
            out += "Transfer-Encoding: chunked\r\n"
        }
        out += "\r\n"
        return Data(out.utf8)
    }

    /// Head + complete body for a plain (non-MCP) response — the pairing
    /// endpoint's status+JSON shapes, which `MCP.HTTPResponse` cannot express
    /// for non-200 codes. Same deterministic header emission as `head`.
    public static func serialize(
        statusCode: Int,
        body: Data,
        headers: [String: String] = [:],
        keepAlive: Bool
    ) -> Data {
        var out = head(statusCode: statusCode, headers: headers, keepAlive: keepAlive, bodyLength: body.count)
        out.append(body)
        return out
    }

    /// Head + complete body for non-stream responses.
    ///
    /// Streams are framed by the connection runner: `head(_:keepAlive:chunked:)`,
    /// then one `chunk(_:)` per SSE event, then `endOfChunkedBody`.
    public static func serialize(_ response: MCP.HTTPResponse, keepAlive: Bool) -> Data {
        if case .stream = response {
            preconditionFailure("serialize is for complete responses only; frame streams with head + chunk + endOfChunkedBody")
        }
        var out = head(response, keepAlive: keepAlive)
        if let body = response.bodyData { out.append(body) }
        return out
    }

    /// One chunked-transfer-encoding frame: `<hex length>\r\n<payload>\r\n`.
    public static func chunk(_ payload: Data) -> Data {
        guard !payload.isEmpty else { return Data() }
        var out = Data(String(payload.count, radix: 16).uppercased().appending("\r\n").utf8)
        out.append(payload)
        out.append(Data("\r\n".utf8))
        return out
    }

    /// The terminal chunk that closes a chunked body.
    public static var endOfChunkedBody: Data { Data("0\r\n\r\n".utf8) }
}
