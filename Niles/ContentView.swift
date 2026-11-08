import SwiftUI

/// Placeholder screen until the server dashboard lands in the UI task.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "house.fill")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(.tint)
            Text("Niles")
                .font(.largeTitle.bold())
            Text("HomeKit MCP Proxy")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Label("Server stopped", systemImage: "pause.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
