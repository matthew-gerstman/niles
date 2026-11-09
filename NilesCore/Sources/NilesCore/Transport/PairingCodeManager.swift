import Foundation
import Security

/// Owns the live pairing code: the six-digit challenge the user reads to an
/// agent, exchanged once at `POST /pairing`.
///
/// The code is a challenge, not a secret — six digits is only 10⁶ space, so
/// the defense is the attempt cap and the single-use burn, not entropy. It
/// lives only in memory (never the Keychain or UserDefaults), so it dies with
/// the app exactly as the server does.
public actor PairingCodeManager {

    /// The outcome of one code verification attempt.
    public enum Verification: Sendable, Equatable {
        /// The code matched; it is burned as of this result.
        case success
        /// No match; the failed attempt is counted against the live code.
        case invalidCode
        /// No live code — none was minted, the TTL elapsed, or the code burned.
        case expired
        /// This fifth consecutive failure burned the code.
        case tooManyAttempts
    }

    /// Thrown when the platform CSPRNG fails; pairing cannot proceed safely.
    public enum CodeError: Error, Equatable {
        case randomnessFailed(OSStatus)
    }

    /// A live code as the pairing card renders it: the digits plus the expiry
    /// for the countdown.
    public struct ActiveCode: Sendable, Equatable {
        public let code: String
        public let expiresAt: Date

        public init(code: String, expiresAt: Date) {
            self.code = code
            self.expiresAt = expiresAt
        }
    }

    /// Five wrong answers burn the code — with 5 attempts per 5-minute window,
    /// brute force is bounded at ~1,440 tries/day against 10⁶ combinations.
    private static let maxAttempts = 5
    private static let ttl: TimeInterval = 300

    private struct Active {
        let code: String
        let expiresAt: Date
        var failedAttempts: Int
    }

    private let now: @Sendable () -> Date
    private var active: Active?

    /// - Parameter now: the clock, injected so tests can drive expiry.
    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    /// Mints a fresh code, discarding any live one (the "New code" tap, or the
    /// card refreshing an expired code). Failed attempts reset with the code.
    @discardableResult
    public func mintCode() throws -> ActiveCode {
        let fresh = Active(
            code: try Self.generateCode(),
            expiresAt: now().addingTimeInterval(Self.ttl),
            failedAttempts: 0
        )
        active = fresh
        return ActiveCode(code: fresh.code, expiresAt: fresh.expiresAt)
    }

    /// The live code, if one is minted and unexpired.
    public func activeCode() -> ActiveCode? {
        liveCode().map { ActiveCode(code: $0.code, expiresAt: $0.expiresAt) }
    }

    /// Verifies one candidate exchange code. Comparison is constant-time (the
    /// bearer gate's XOR pattern), so timing never hints at leading digits.
    public func verify(_ candidate: String) -> Verification {
        guard var live = liveCode() else { return .expired }
        guard BearerTokenAuthMiddleware.tokensMatch(candidate, live.code) else {
            live.failedAttempts += 1
            if live.failedAttempts >= Self.maxAttempts {
                active = nil
                return .tooManyAttempts
            }
            active = live
            return .invalidCode
        }
        // Single use: a successful exchange invalidates the code immediately.
        active = nil
        return .success
    }

    /// The active code only while unexpired — expiry is checked, never stored.
    private func liveCode() -> Active? {
        guard let code = active, now() < code.expiresAt else { return nil }
        return code
    }

    /// Six digits from the system CSPRNG: four random bytes mapped into
    /// 000000–999999 and zero-padded. (The modulo bias is ~0.02% — immaterial
    /// for a challenge that dies after five wrong guesses.)
    static func generateCode() throws -> String {
        var value: UInt32 = 0
        let status = withUnsafeMutableBytes(of: &value) { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw CodeError.randomnessFailed(status)
        }
        return String(format: "%06u", value % 1_000_000)
    }
}
