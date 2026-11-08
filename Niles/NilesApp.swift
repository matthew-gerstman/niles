import SwiftUI
import NilesCore

@main
struct NilesApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var serverCoordinator = ServerCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                // First launch: scenePhase is already .active, so start here…
                .task { await syncServer(with: scenePhase) }
                // …and follow transitions afterwards (app switcher, background).
                .onChange(of: scenePhase) { _, phase in
                    Task { await syncServer(with: phase) }
                }
        }
    }

    /// Niles serves only while foregrounded — an iOS constraint (no background TCP
    /// listener) that matches the approval model: the human must be present anyway.
    /// Active means serving; inactive (app switcher, call overlay) and background
    /// both stop the listener, unregistering Bonjour and closing every connection.
    @MainActor
    private func syncServer(with phase: ScenePhase) async {
        if phase == .active {
            await serverCoordinator.start()
        } else {
            await serverCoordinator.stop()
        }
    }
}
