import CoreImage
import SwiftUI
import CoreImage.CIFilterBuiltins

/// Pairing: scannable QR of the bearer token, MCP connection details with
/// token reveal, and the connected-agent list fed by live transport sessions.
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

#Preview("Pairing") {
    PairingScreen(model: InMemoryNilesStore())
}
