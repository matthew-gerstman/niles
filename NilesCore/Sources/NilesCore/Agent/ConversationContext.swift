import Foundation

/// Bounded conversation history for agent requests (spec art_PFPlXrMj).
/// Follow-ups like "the office ones" only resolve when the agent sees the
/// turn that introduced the referent, so each send composes the recent
/// completed transcript into the request string. A fresh launch starts a
/// new window; nothing persists across sessions. Shared by the in-app chat
/// and remote MCP sessions so both surfaces compose history identically.
public enum ConversationContext {
    /// Composes `current` with prior transcript rows (oldest first) into a
    /// single request string. Returns nil when there is no history — the
    /// caller then sends the raw text unchanged. `history` rows count
    /// against the budget and are trimmed oldest-first; `current` is never
    /// trimmed.
    public static func compose(
        current: String,
        history: [(role: ConversationEntry.Role, text: String)],
        maxMessages: Int = 6,
        maxChars: Int = 1200
    ) -> String? {
        // Last N rows, oldest first, rendered as the caller would read them.
        var window = history.suffix(maxMessages).map {
            "\(roleName($0.role)): \($0.text)"
        }
        while window.count > 1, window.map(\.count).reduce(0, +) + window.count - 1 > maxChars {
            window.removeFirst()
        }
        guard !window.isEmpty else { return nil }
        return """
        Conversation so far:
        \(window.joined(separator: "\n"))

        Current message:
        \(current)
        """
    }

    private static func roleName(_ role: ConversationEntry.Role) -> String {
        switch role {
        case .user: "User"
        case .agent: "Niles"
        }
    }
}
