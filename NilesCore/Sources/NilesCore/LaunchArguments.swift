import Foundation

/// The one launch-argument parser. Every `ProcessInfo.processInfo.arguments`
/// read in the tree lives here: flags are named constants, so a renamed flag
/// fails at compile time at every call site instead of silently never
/// matching (cleanup W4, audit §3.4).
///
/// The namespace lives in NilesCore so the Bonjour capture-fixture safety
/// property can be enforced where the server advertises (see
/// `NilesBonjour.advertisedInstanceName`); the flags themselves are the
/// app's screenshot/preview/QA hooks, inert in every normal launch.
public enum LaunchArguments {
    /// The raw spelling of every recognized flag. Nothing outside this enum
    /// may carry a `-UI…` string literal.
    private enum Name: String {
        case activityFixtures = "-UIActivityFixtures"
        case activityOpenDetail = "-UIActivityOpenDetail"
        case agentGateToggle = "-UIAgentGateToggle"
        case chatFixtures = "-UIChatFixtures"
        case homeFixtures = "-UIHomeFixtures"
        case homeScroll = "-UIHomeScroll"
        case notificationsDisabled = "-UINotificationsDisabled"
        case proposalDetail = "-UIProposalDetail"
        case proposalDetailEvidence = "-UIProposalDetailEvidence"
        case safeAreaProbe = "-UISafeAreaProbe"
        case seedQueue = "-UISeedQueue"
        case proposalsFixture = "-UIProposalsFixture"
        case tabSelect = "-UITabSelect"
        case wideLayout = "-UIWideLayout"
    }

    /// Stable for the life of the process; read once.
    private static let arguments = ProcessInfo.processInfo.arguments

    private static func isPresent(_ name: Name) -> Bool {
        arguments.contains(name.rawValue)
    }

    /// The argument immediately following the flag, or nil when the flag is
    /// absent or last — matching the pre-namespace index arithmetic exactly.
    private static func value(after name: Name) -> String? {
        guard let index = arguments.firstIndex(of: name.rawValue),
              index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    // MARK: - Boolean flags (true when present)

    /// `-UIActivityFixtures` — render the Activity tab on the fixture store.
    public static var uiActivityFixtures: Bool { isPresent(.activityFixtures) }
    /// `-UIHomeFixtures` — render the Home tab on the in-memory fixture store.
    public static var uiHomeFixtures: Bool { isPresent(.homeFixtures) }
    /// `-UIChatFixtures` — stand-in agent runner for the chat flow.
    public static var uiChatFixtures: Bool { isPresent(.chatFixtures) }
    /// `-UIAgentGateToggle` — flip the agent gate in-process a few seconds
    /// after launch.
    public static var uiAgentGateToggle: Bool { isPresent(.agentGateToggle) }
    /// `-UIActivityOpenDetail` — open the newest decided activity group.
    public static var uiActivityOpenDetail: Bool { isPresent(.activityOpenDetail) }
    /// `-UIProposalDetailEvidence` — jump the proposal detail sheet to the
    /// evidence section.
    public static var uiProposalDetailEvidence: Bool { isPresent(.proposalDetailEvidence) }
    /// `-UISafeAreaProbe` — overlay measured safe-area geometry.
    public static var uiSafeAreaProbe: Bool { isPresent(.safeAreaProbe) }
    /// `-UINotificationsDisabled` — skip the notification permission prompt
    /// (headless fixture captures).
    public static var uiNotificationsDisabled: Bool { isPresent(.notificationsDisabled) }

    // MARK: - Valued flags (the argument immediately following, or nil)

    /// `-UITabSelect <tab>` — select a tab on launch.
    public static var uiTabSelect: String? { value(after: .tabSelect) }
    /// `-UIProposalDetail <id|tool>` — present that proposal's detail sheet
    /// directly.
    public static var uiProposalDetail: String? { value(after: .proposalDetail) }
    /// `-UISeedQueue <fixture>` — stage a named queue fixture through the
    /// real pipeline.
    public static var uiSeedQueue: String? { value(after: .seedQueue) }
    /// `-UIProposalsFixture <mode>` — relaunch-persistence fixture driver.
    public static var uiProposalsFixture: String? { value(after: .proposalsFixture) }
    /// `-UIHomeScroll <section>` — scroll the Home list to a section.
    public static var uiHomeScroll: String? { value(after: .homeScroll) }

    /// `-UIWideLayout [on|off]` — pins the adaptive layout: bare or `on`
    /// forces the side-by-side panes, `off` forces the tab pair, absent is
    /// nil (measure the width normally).
    public static var uiWideLayout: Bool? {
        guard isPresent(.wideLayout) else { return nil }
        return value(after: .wideLayout)?.lowercased() == "off" ? false : true
    }

    // MARK: - Safety property

    /// True when the app launched with a capture-fixture argument. A capture
    /// instance must never advertise on Bonjour: a fixture visible in a
    /// browse as "Niles" can impersonate a real endpoint and capture pairing
    /// codes. Evaluated here — the one launch-argument parser — and enforced
    /// by `NilesBonjour.advertisedInstanceName`, so fixture hygiene holds
    /// even if a caller forgets to opt out.
    public static var isCaptureFixture: Bool {
        uiWideLayout != nil || uiHomeFixtures || uiActivityFixtures
    }

    // MARK: - Environment (not an argument)

    /// The XCTest host marker: the app entry checks it so a test host never
    /// trips the notification permission prompt. Lives beside the arguments
    /// so this file stays the only ProcessInfo reader in the tree.
    public static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
