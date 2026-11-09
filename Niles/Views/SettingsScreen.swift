import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Settings: the server control card (kill switch, endpoint, sessions,
/// agents) and pairing (QR, token reveal, trusted agents) absorbed from the
/// former Dashboard and Pairing screens, which are removed.
struct SettingsScreen: View {
    var model: any DashboardViewModel & PairingViewModel

    var body: some View {
        ScreenScaffold(title: "Settings", subtitle: "Niles · HomeKit MCP proxy · \(model.homeName)") {
            serverCard
            SectionHeader(title: "Connected agents")
            if model.connectedAgents.isEmpty {
                EmptyStateCard(text: "No MCP agents are connected right now. Pair one below with the QR code.")
            } else {
                agentsCard
            }
            SectionHeader(title: "Pairing")
            pairingCard
            SectionHeader(title: "Connection")
            connectionCard
            SectionHeader(title: "Trusted agents")
            trustedCard
        }
    }

    /// The former Dashboard server card: serving state, the kill switch,
    /// and the endpoint/sessions key-value rows.
    private var serverCard: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    Circle()
                        .fill(model.serverIsRunning ? NilesTheme.good : Color.secondary)
                        .frame(width: 9, height: 9)
                    Text(model.serverIsRunning ? "Serving" : "Stopped")
                        .font(.system(size: 15, weight: .bold))
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.serverIsRunning },
                    set: { model.setServerRunning($0) }
                ))
                .labelsHidden()
                .tint(NilesTheme.accent)
            }
            .padding(.bottom, 10)
            KeyValueList(rows: [
                KeyValueRow(key: "Endpoint", value: model.endpoint),
                KeyValueRow(key: "Bonjour", value: model.bonjourService),
                KeyValueRow(key: "Sessions", value: model.sessionsSummary),
                KeyValueRow(key: "Approved today", value: "\(model.approvedTodayCount)"),
            ])
        }
        .card()
    }

    private var agentsCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.connectedAgents.enumerated()), id: \.element.id) { index, agent in
                AgentRow(agent: agent)
                if index < model.connectedAgents.count - 1 {
                    Divider()
                }
            }
        }
        .card()
    }

    private var pairingCard: some View {
        VStack(spacing: 6) {
            QRCodeView(string: model.token)
                .frame(width: 160, height: 160)
                .padding(10)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)))
            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .card()
    }

    private var caption: String {
        if let error = (model as? LiveNilesStore)?.tokenError {
            return error
        }
        return "Scan to share the bearer token out-of-band. It lives in the Keychain and is never sent over the wire."
    }

    private var connectionCard: some View {
        VStack(spacing: 0) {
            KeyValueList(rows: [
                KeyValueRow(key: "URL", value: model.endpoint),
                KeyValueRow(key: "Transport", value: model.transportName),
                KeyValueRow(key: "Bearer token", value: model.isTokenRevealed ? model.token : "•••• •••• ••••"),
            ])
            ActionButton(
                title: model.isTokenRevealed ? "Hide token" : "Reveal token",
                style: .ghost
            ) {
                model.toggleTokenRevealed()
            }
            .padding(.top, 10)
        }
        .card()
    }

    private var trustedCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.trustedAgents.enumerated()), id: \.element.id) { index, agent in
                AgentRow(agent: agent)
                if index < model.trustedAgents.count - 1 {
                    Divider()
                }
            }
        }
        .card()
    }
}

/// Renders a string as a real, scannable QR code (CoreImage), scaled without
/// interpolation so the modules stay crisp.
struct QRCodeView: View {
    let string: String

    var body: some View {
        if let image = Self.image(from: string) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.primary.opacity(0.04))
                Text("Token unavailable")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// nil for an empty string (no token yet) or a CoreImage failure.
    static func image(from string: String) -> UIImage? {
        guard !string.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // The generator emits a 1x module chain; scale up before rendering so
        // the CG image has real pixels to show.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

#Preview("Settings") {
    SettingsScreen(model: InMemoryNilesStore())
}
