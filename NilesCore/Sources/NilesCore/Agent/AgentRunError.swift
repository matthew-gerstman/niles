import Foundation

/// A session-level agent failure the app layer renders typed copy for
/// (`AskNilesRouter.failureMessage`), as opposed to a tool-level failure —
/// those are already in-band in the run's summary.
///
/// Deliberately iOS 17-safe: Settings and the intent layer hold this type
/// below the iOS 27 gate, and nothing Foundation Models-typed leaks out of
/// the mapping.
public enum AgentRunError: Error, Equatable, Sendable {
    /// The on-device model asset was unavailable when generation ran. The
    /// availability gate can read `.available` at feature entry and the
    /// asset still be missing when a run actually executes — the reported
    /// "Resource (Local Model Asset) unavailable" failure. The user-facing
    /// copy asks the user to retry in a few minutes (the asset downloads
    /// on its own); it is not the same as the gate's `.modelNotReady`,
    /// which Settings renders with its own reason.
    case assetUnavailable
    /// The per-run availability recheck failed — the gate no longer passes,
    /// for the reason it names.
    case unavailable(AgentAvailability.Reason)
}

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 27.0, *)
extension AgentRunError {
    /// Maps a Foundation Models session failure onto the typed error. The
    /// asset-unavailable family becomes `.assetUnavailable`; anything this
    /// SDK names differently comes back unchanged — the mapping never
    /// rewraps an unknown failure, so the generic failure copy keeps
    /// rendering the real localized description.
    static func mapped(from error: Error) -> Error {
        switch error {
        case SystemLanguageModel.Error.assetsUnavailable(_):
            // The iOS 27 spelling of the asset-unavailable family.
            return Self.assetUnavailable
        case LanguageModelSession.GenerationError.assetsUnavailable(_):
            // Deprecated in iOS 27 in favor of the case above; matched
            // deliberately so a runtime that still throws the legacy
            // spelling cannot slip past the typed handling.
            return Self.assetUnavailable
        default:
            return error
        }
    }
}
#endif
