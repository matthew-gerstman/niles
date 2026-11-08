import Foundation
import MCP
import Network

/// Serves one TCP connection: parse requests, route through the gateway, write responses.
///
/// All I/O is confined to the task running `run()`; `@unchecked Sendable` covers only
/// the handle the `LANServer` actor keeps so it can `cancel()` the connection from
/// outside (NWConnection cancellation is documented thread-safe).
final class HTTPConnectionRunner: @unchecked Sendable {

    private let connection: NWConnection
    private let gateway: MCPGateway
    private let maxBodySize: Int

    init(connection: NWConnection, gateway: MCPGateway, maxBodySize: Int = HTTPRequestParser.defaultMaxBodySize) {
        self.connection = connection
        self.gateway = gateway
        self.maxBodySize = maxBodySize
    }

    /// Closes the connection; a pending receive ends with an error, unwinding `run()`.
    func cancel() {
        connection.cancel()
    }

    func run() async {
        connection.start(queue: DispatchQueue(label: "com.gerstman.niles.connection"))
        defer { connection.cancel() }

        var buffer: [UInt8] = []
        while true {
            switch HTTPRequestParser.parse(Data(buffer), maxBodySize: maxBodySize) {
            case .complete(let request, let wantsKeepAlive, let consumedBytes):
                buffer.removeFirst(consumedBytes)
                let response = await gateway.handle(request)
                guard await write(response, keepAlive: wantsKeepAlive), wantsKeepAlive else { return }
            case .invalid(let parseError):
                // The stream may be desynchronized — answer and close, never reuse.
                await writeAndIgnoreFailure(Self.errorResponse(for: parseError))
                return
            case .needMoreData:
                // Any receive failure (peer closed, cancelled, reset) ends the connection:
                // that noise needs no handling beyond stopping to serve it.
                guard let chunk = try? await receiveChunk(), !chunk.isEmpty else { return }
                buffer.append(contentsOf: chunk)
            }
        }
    }

    /// Writes one response. `.stream` bodies are piped as chunked-encoded SSE frames.
    private func write(_ response: MCP.HTTPResponse, keepAlive: Bool) async -> Bool {
        switch response {
        case .stream(let sseStream, _):
            guard await send(HTTPResponseWriter.head(response, keepAlive: keepAlive, chunked: true)) else {
                return false
            }
            do {
                for try await chunk in sseStream {
                    guard await send(HTTPResponseWriter.chunk(chunk)) else { return false }
                }
            } catch {
                // The transport closed the stream (session teardown, error) — stop serving.
                return false
            }
            return await send(HTTPResponseWriter.endOfChunkedBody)
        default:
            return await send(HTTPResponseWriter.serialize(response, keepAlive: keepAlive))
        }
    }

    private func writeAndIgnoreFailure(_ response: MCP.HTTPResponse) async {
        _ = await write(response, keepAlive: false)
    }

    private func send(_ bytes: Data) async -> Bool {
        guard !bytes.isEmpty else { return true }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: bytes, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                })
            }
            return true
        } catch {
            return false
        }
    }

    private func receiveChunk() async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data {
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(returning: Data())  // clean EOF
                    } else {
                        continuation.resume(throwing: HTTPConnectionError.receiveContractViolated)
                    }
                }
            }
        } onCancel: {
            // Unwinds a pending receive with an error so `run()` exits promptly.
            connection.cancel()
        }
    }

    /// Maps a parse failure to the error response to send before closing.
    static func errorResponse(for parseError: HTTPRequestParseError) -> MCP.HTTPResponse {
        switch parseError {
        case .malformedRequest:
            .error(statusCode: 400, .invalidRequest("Bad Request: Malformed HTTP request"))
        case .headersTooLarge(let limit):
            .error(statusCode: 431, .invalidRequest("Request Header Fields Too Large: limit is \(limit) bytes"))
        case .bodyTooLarge(let limit):
            .error(statusCode: 413, .invalidRequest("Payload Too Large: limit is \(limit) bytes"))
        case .transferEncodingUnsupported:
            .error(statusCode: 501, .invalidRequest("Not Implemented: Chunked transfer encoding is not supported"))
        }
    }
}

enum HTTPConnectionError: Error {
    case receiveContractViolated
}
