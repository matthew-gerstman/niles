import SwiftUI

/// Placeholder for the Activity timeline (built in a later PR of the
/// queue-first rebuild). Renders the shared empty state until then.
struct ActivityScreenPlaceholder: View {
    var model: any DashboardViewModel

    var body: some View {
        ScreenScaffold(title: "Activity", subtitle: "Everything that happened, in order") {
            EmptyStateCard(
                text: "Proposals will appear here as they are staged, decided, and executed."
            )
        }
    }
}

#Preview("Activity") {
    ActivityScreenPlaceholder(model: InMemoryNilesStore())
}
