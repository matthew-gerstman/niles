import Foundation
import HomeKit

/// Evidence wording for HomeKit failures: common `HMError` codes get human
/// meaning, and the raw error is never lost — it rides alongside the
/// meaning (or stands alone when no meaning is mapped).
///
/// Executor evidence used to carry `String(describing:)` alone, so HMError 3
/// surfaced as a bare code on the review card with no hint that HomeKit had
/// refused a service as a group member. The map adds the meaning in the
/// operation's context; the raw text stays for the log-minded human.
///
/// Matching is by `NSError` domain and code — the shape completion handlers
/// actually deliver — rather than by `HMError` case.
enum HomeKitErrorNarrative {
    /// Human meaning for an `HMError` the evidence should explain, or nil
    /// when the raw error stands alone.
    static func meaning(for error: Error) -> String? {
        let nsError = error as NSError
        guard nsError.domain == HMErrorDomain else { return nil }
        switch nsError.code {
        case 3:
            return "HomeKit rejected this call as invalid (HMError 3, invalidParameter)"
        case 26:
            // The sceneless-trigger equivalent: a trigger with no registered
            // action sets cannot be enabled or executed.
            return "HomeKit found no registered action sets for this trigger (HMError 26)"
        default:
            return nil
        }
    }

    /// The evidence message: meaning first where mapped, the raw error
    /// always — using the same "HomeKit reported" phrasing the read-back
    /// evidence uses for failed operations.
    static func describe(_ error: Error) -> String {
        guard let meaning = meaning(for: error) else {
            return String(describing: error)
        }
        return "\(meaning) — HomeKit reported: \(String(describing: error))"
    }

    /// The group-member refusal, named with both objects — the wording PR B
    /// pins for HMError 3 on `addService`. The executor's group-member add
    /// catches the bare HomeKit error and rethrows through here so the
    /// review card says which service and which group.
    static func groupRefusal(service: String, group: String, error: Error) -> String {
        "HomeKit refused “\(service)” as a member of group “\(group)”: \(describe(error))"
    }
}
