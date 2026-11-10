import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The on-device agent's availability, as the app layer sees it.
///
/// A plain iOS 17-safe value on purpose: Settings renders it on every device,
/// and the app holds the (iOS 27+) runner behind a gate that starts from this
/// value — nothing Foundation Models-typed leaks below the gate.
public enum AgentAvailability: Equatable, Sendable {
    /// Why the agent cannot run on this device.
    public enum Reason: Equatable, Sendable {
        /// The OS is too old for the agent core's Foundation Models APIs
        /// (`NilesAgent` is @available(iOS 27)); Foundation Models itself
        /// starts at iOS 26, but the merged agent core needs the newer SDK.
        case needsIOS27
        /// The hardware cannot run Apple Intelligence.
        case deviceNotEligible
        /// Eligible hardware, but the user has Apple Intelligence turned off.
        case appleIntelligenceNotEnabled
        /// Apple Intelligence is on, but the on-device model is not ready.
        case modelNotReady
        /// A reason the current SDK does not name — never guessed.
        case unknown
    }

    case available
    case unavailable(Reason)
}

#if canImport(FoundationModels)
/// The one availability check, evaluated at feature entry (spec
/// art_VrC0iUUA §Availability gate): the OS bar plus
/// `SystemLanguageModel.default.availability`, which covers Apple
/// Intelligence hardware and the user's model-availability setting.
///
/// Everything agent-related composes behind this check; on a device it
/// fails, no agent path exists — there is no degraded fallback.
@available(iOS 26.0, *)
public enum AgentAvailabilityGate {

    /// Production entry. The OS bar is 27: the agent core
    /// (`NilesAgent`) uses Foundation Models APIs that only exist in the
    /// iOS 27 SDK, so an iOS 26 device must read as unsupported, not
    /// eligible.
    public static func evaluate() -> AgentAvailability {
        guard #available(iOS 27.0, *) else { return .unavailable(.needsIOS27) }
        // Checked at feature entry, not per request: the on-device model's
        // availability changes only at system level (settings, OS update).
        return evaluate(isOS27OrNewer: true, systemAvailability: SystemLanguageModel.default.availability)
    }

    /// Pure form of the full state matrix — the OS bar plus the system
    /// model's availability — so tests cover every reason without needing
    /// hardware that reports it.
    public static func evaluate(
        isOS27OrNewer: Bool,
        systemAvailability: SystemLanguageModel.Availability
    ) -> AgentAvailability {
        guard isOS27OrNewer else { return .unavailable(.needsIOS27) }
        return Self.map(systemAvailability)
    }

    /// Maps the framework's availability onto the agent's, preserving the
    /// reason so Settings can state exactly what is missing.
    public static func map(_ availability: SystemLanguageModel.Availability) -> AgentAvailability {
        switch availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .unavailable(.deviceNotEligible)
            case .appleIntelligenceNotEnabled: return .unavailable(.appleIntelligenceNotEnabled)
            case .modelNotReady: return .unavailable(.modelNotReady)
            @unknown default: return .unavailable(.unknown)
            }
        @unknown default:
            // A future SDK shape: report honestly rather than guess
            // "available" for a state this SDK cannot name.
            return .unavailable(.unknown)
        }
    }
}
#endif
