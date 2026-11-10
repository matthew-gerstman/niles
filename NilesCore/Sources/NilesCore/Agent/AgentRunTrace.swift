import Foundation
import MCP
import os

/// Shared plumbing for the agent's run trace — the diagnostics-only log
/// surface that shows how a run reaches its outcome (entry, model rounds,
/// tool calls, errors). Nothing here touches the run path.
///
/// Every line goes through one logger (subsystem `com.gerstman.niles`,
/// category `agent`) at public privacy, so a single Console filter — or a
/// collected log archive — captures a whole run end to end without
/// `<private>` redactions.
public enum AgentRunTrace {
    /// The one logger the whole run trace shares (NilesAgent declares its
    /// own instance of the same subsystem/category for its pre-existing
    /// failure diagnostics; the lines interleave in the same stream).
    public static let logger = Logger(subsystem: "com.gerstman.niles", category: "agent")

    /// A length-bounded public preview that names its own truncation: the
    /// archive shows the head of the payload and its true total length, so
    /// "was the model's text long?" stays answerable after cutting it.
    public static func truncated(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "… [truncated, \(text.count) chars total]"
    }

    /// The raw tool-call arguments as full public JSON — exactly what the
    /// model sent, unredacted, so a wrong proposal traces back to the
    /// arguments that produced it. Unencodable arguments (there are none
    /// among MCP values today) fall back to the reflected description
    /// rather than an empty object.
    public static func argumentsJSON(_ arguments: [String: MCP.Value]?) -> String {
        guard let arguments else { return "{}" }
        do {
            let data = try JSONEncoder().encode(arguments)
            return String(decoding: data, as: UTF8.self)
        } catch {
            return String(describing: arguments)
        }
    }

    /// The full public error chain: the error in `String(describing:)`
    /// (reflected) form plus every nested `underlyingError` beneath it.
    /// The SDK's localized descriptions lose the root cause; this keeps
    /// the whole chain visible in the archive, never `<private>`.
    public static func reflectedErrorChain(_ error: Error) -> String {
        var descriptions = [String(describing: error)]
        var current = error
        // Error chains here run one or two links deep; the bound keeps the
        // walk finite even against a (pathological) reference cycle.
        for _ in 0..<5 {
            guard let underlying = Mirror(reflecting: current).children.first(where: {
                $0.label == "underlyingError" && $0.value is Error
            })?.value as? Error else { break }
            descriptions.append(String(describing: underlying))
            current = underlying
        }
        return descriptions.joined(separator: " ← ")
    }
}
