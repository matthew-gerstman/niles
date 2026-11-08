import SwiftUI

/// Pairing: QR placeholder, MCP connection details with token reveal, and the
/// trusted-agent list.
struct PairingScreen: View {
    var model: any PairingViewModel

    var body: some View {
        ScreenScaffold(title: "Pairing", subtitle: "Connect an MCP agent to Niles") {
            qrCard
            SectionHeader(title: "Connection")
            connectionCard
            SectionHeader(title: "Trusted agents")
            trustedCard
        }
    }

    private var qrCard: some View {
        VStack(spacing: 6) {
            QRPlaceholder()
                .frame(width: 160, height: 160)
                .padding(10)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)))
            Text("QR placeholder — scan-to-configure ships in a later build.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .card()
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
            Text("Token lives in the Keychain and is shared out-of-band, never over the wire.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
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

/// Decorative 9×9 grid standing in for the pairing QR code.
private struct QRPlaceholder: View {
    // "d" = dark cell, "l" = light cell; mirrors the mockup's pattern.
    private static let pattern = [
        "dlddlddld",
        "ldlldldll",
        "dldldldld",
        "ldldldldl",
        "dldldldld",
        "ldlldldll",
        "dldldldld",
        "ldlldldll",
        "dlddlddld",
    ]

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(Self.pattern.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 2) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(cell == "d" ? Color.primary : .clear)
                    }
                }
            }
        }
    }
}

#Preview("Pairing") {
    PairingScreen(model: InMemoryNilesStore())
}
