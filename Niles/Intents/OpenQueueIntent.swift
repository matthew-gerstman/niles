import AppIntents

/// Process-wide navigation signal from App Intents into the UI. App Intents
/// cannot drive SwiftUI state directly, so the intent sets the flag and
/// ContentView consumes it on change — and at init for a cold launch.
@MainActor
@Observable
final class AppNavigation {
    static let shared = AppNavigation()

    private(set) var queueSelectionPending = false

    func requestQueue() { queueSelectionPending = true }
    func consumeQueueSelection() { queueSelectionPending = false }
}

/// The deep link into the Queue, where staged proposals wait for human
/// approval — the review hand-off for an Ask-Niles run. It only navigates;
/// approving or denying stays a human action in the app.
struct OpenQueueIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Queue"
    static let description = IntentDescription(
        "Opens Niles' Queue, where staged proposals wait for your approval."
    )

    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppNavigation.shared.requestQueue()
        return .result(dialog: "Opening the Queue — staged proposals are waiting for your approval.")
    }
}
