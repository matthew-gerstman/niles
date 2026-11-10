import AppIntents
import NilesCore
import os

/// What one Ask-Niles run produced, shaped for the Siri dialog.
struct AskNilesOutcome: Equatable, Sendable {
    var dialog: String
    var stagedProposalIds: [String]
}

/// The routing core of the Siri entry point — the piece unit tests drive
/// without the App Intents runtime. Hands the utterance to the app's gated
/// agent runner and shapes the result into a dialog.
///
/// The runner is `any AgentRunning`, whose only write surface is the staging
/// path (`NilesToolDispatcher` → `WriteToolRegistry` → `ProposalStore.stage`).
/// There is no approve or execute reference anywhere in this layer: nothing a
/// spoken request triggers can leave the Queue (spec art_VrC0iUUA — the agent
/// never crosses the review boundary).
struct AskNilesRouter {
    /// The gated runner, or `nil` when this device cannot run the agent.
    var runner: (any AgentRunning)?

    /// Run-trace logger for the Siri entry point — the entry line (with the
    /// request text) lives here because the entry point is known only at
    /// this layer; the shared run trace continues in AgentService.
    private static let trace = AgentRunTrace.logger

    /// Why the agent can't take requests here, stated once — a pure-background
    /// intent has no conversational channel beyond the dialog.
    static let unavailableOutcome = AskNilesOutcome(
        dialog: "Niles' agent isn't available on this device. The Settings tab explains why.",
        stagedProposalIds: []
    )

    /// The one session-failure copy, shared by the Siri dialog and the
    /// in-app chat's failed turns — one wording, one source of truth.
    /// The typed asset-unavailable case gets the retry-oriented wording:
    /// the gate passed when the run was accepted but the on-device model
    /// asset was missing at generation time — a state that resolves on
    /// its own, not a request the agent misunderstood.
    static func failureMessage(for error: Error) -> String {
        if case AgentRunError.assetUnavailable = error {
            return "The on-device model isn't ready yet — try again in a few minutes."
        }
        return "Niles couldn't complete that request: \(error.localizedDescription)"
    }

    /// One request to completion. Tool-level failures are already in-band in
    /// the runner's summary; only a session-level failure throws, and that
    /// surfaces as a dialog rather than a silent drop.
    func run(_ prompt: String) async -> AskNilesOutcome {
        Self.trace.info(
            "Ask Niles run start: entry=Siri request: \(AgentRunTrace.truncated(prompt, to: 500), privacy: .public)"
        )
        await AgentRunTraceStore.shared.recordRunStart(entryPoint: "Siri", request: prompt)
        guard let runner else {
            Self.trace.error("Ask Niles run refused: entry=Siri — no runner (agent unavailable at feature entry)")
            await AgentRunTraceStore.shared.recordError("Run refused — no runner (agent unavailable at feature entry)")
            return Self.unavailableOutcome
        }
        do {
            let result = try await runner.run(prompt)
            // The agent's summary already reports the staged outcome — titles,
            // ids, and anything left undone — so the dialog surfaces it
            // verbatim (spec: the dialog reports the outcome, never a
            // follow-up question).
            return AskNilesOutcome(
                dialog: result.summary,
                stagedProposalIds: result.stagedProposalIds
            )
        } catch {
            return AskNilesOutcome(
                dialog: Self.failureMessage(for: error),
                stagedProposalIds: []
            )
        }
    }
}

/// The Siri entry point (spec art_VrC0iUUA §Siri): a spoken request becomes
/// staged proposals, reported by dialog. Pure background — nothing executes,
/// nothing opens, no follow-up prompts. Human approval stays in the Queue.
///
/// Declared by plain `AppIntent` conformance: in the iOS 27 SDK the
/// `@AppIntent` macro is schema-only — `@AppIntent(schema: .domain.action)`
/// for a system-defined assistant schema (there is no argument-less form and
/// no `.tool` member). Niles' home-configuration actions map to no system
/// domain, so Siri routes here via the shortcut phrase below.
struct AskNilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Niles"
    static let description = IntentDescription(
        "Stages a home configuration change — a scene, group, room, rename, or move — as a proposal awaiting your approval in Niles' Queue. Nothing is applied until you approve it."
    )

    /// Pure background per the locked spec decision: stage, report, done.
    static let openAppWhenRun = false

    @Parameter(title: "Request", description: "The home configuration change, in the user's own words.")
    var prompt: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // The same gated runner the UI holds — availability is decided once
        // at feature entry, not re-decided per request.
        let outcome = await AskNilesRouter(runner: AppEnvironment.shared.agentRunner).run(prompt)
        return .result(dialog: "\(outcome.dialog)")
    }
}

/// The app's shortcut phrases. The free-form `prompt` parameter cannot be
/// interpolated into a phrase — phrases only expand finite named sets
/// (AppEnum/AppEntity/Bool) — so the phrase anchors on the app name and Siri
/// elicits the request.
struct NilesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AskNilesIntent(),
            phrases: ["Ask \(.applicationName)"],
            shortTitle: "Ask Niles",
            systemImageName: "house"
        )
    }
}
