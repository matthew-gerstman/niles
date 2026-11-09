import SwiftUI
import NilesCore

@main
struct NilesApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: LiveNilesStore

    init() {
        ProposalNotifier.registerForegroundPresentation()
        // Permission is asked at first launch, before a proposal needs it; the
        // test host must not trip the system prompt mid-test-run.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            ProposalNotifier.shared.requestPermissionIfNeeded()
        }
        let coordinator = ServerCoordinator(homeKitService: Self.homeKitService)
        _store = State(initialValue: LiveNilesStore(coordinator: coordinator, notifier: .shared))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                // First launch: scenePhase is already .active, so start here…
                .task { await store.handleScene(isActive: true) }
                // …and follow transitions afterwards (app switcher, background).
                .onChange(of: scenePhase) { _, phase in
                    Task { await store.handleScene(isActive: phase == .active) }
                }
        }
    }

    /// The service the pipeline stages and executes against. The simulator has
    /// no HomeKit database, so it runs the fake executor over the demo fixture;
    /// a real device reads the shared home database. (Device-side execution of
    /// staged operations is not implemented yet — approvals record an explicit
    /// failure there until the adapter's write half lands.)
    private static var homeKitService: any HomeKitWriting {
        #if targetEnvironment(simulator)
        FakeHomeKitService(graph: .demoFixture)
        #else
        DeviceHomeKitService()
        #endif
    }
}
