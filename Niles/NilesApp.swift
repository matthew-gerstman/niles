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
        // The shared environment: a background Siri intent launches this
        // process without foregrounding the UI, so both entry points must
        // observe the same store.
        _store = State(initialValue: AppEnvironment.shared)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                // Neutral chrome, per UI pass 2: no brand accent — tinted
                // controls resolve to white, and text keeps system colors.
                .tint(.white)
                // First launch: scenePhase is already .active, so start here…
                .task { await store.handleScene(isActive: true) }
                // …and follow transitions afterwards (app switcher, background).
                .onChange(of: scenePhase) { _, phase in
                    Task { await store.handleScene(isActive: phase == .active) }
                }
        }
    }
}
