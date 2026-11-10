import NilesCore

/// The process-wide store. A background App Intent launches the app process
/// without foregrounding the UI, so the Siri entry point and the app's screens
/// must observe the same store — one instance, built here and handed to
/// `NilesApp` as its state.
@MainActor
enum AppEnvironment {
    static let shared: LiveNilesStore = LiveNilesStore(
        coordinator: ServerCoordinator(homeKitService: makeHomeKitService()),
        notifier: .shared
    )

    /// The service the pipeline stages and executes against. The simulator has
    /// no HomeKit database, so it runs the fake executor over the demo fixture;
    /// a real device reads the shared home database. (Device-side execution of
    /// staged operations is not implemented yet — approvals record an explicit
    /// failure there until the adapter's write half lands.)
    static func makeHomeKitService() -> any HomeKitWriting {
        #if targetEnvironment(simulator)
        FakeHomeKitService(graph: .demoFixture)
        #else
        DeviceHomeKitService()
        #endif
    }
}
