import SwiftUI
import NilesCore

/// Diagnostics (no user surface): launching with `-UISafeAreaProbe` overlays
/// safe-area geometry — inset values plus boundary lines at each safe-area
/// edge — on the root view and each pane's List, so the insets a device
/// actually reports can be read straight off a screenshot. Same family as the
/// other `-UI…` screenshot hooks (inert without the argument); built for the
/// status-pillar clearance diagnosis.
enum SafeAreaProbe {
    static let active = LaunchArguments.uiSafeAreaProbe
}

/// One overlay unit: dashed boundary lines at the hosting view's safe-area
/// edges (cyan trailing, yellow leading, green top, orange bottom) and a
/// monospace badge with the measured size and insets. Hit-testing is
/// disabled, so it never intercepts taps.
struct SafeAreaOverlay: View {
    var label: String
    /// Corner for the badge; the root and List probes overlap when both sit
    /// bottom-leading, so List probes pass .topLeading.
    var badgeAlignment: Alignment = .bottomLeading

    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: badgeAlignment) {
                Path { path in
                    path.move(to: CGPoint(x: w - insets.trailing, y: 0))
                    path.addLine(to: CGPoint(x: w - insets.trailing, y: h))
                }
                .stroke(.cyan, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                Path { path in
                    path.move(to: CGPoint(x: insets.leading, y: 0))
                    path.addLine(to: CGPoint(x: insets.leading, y: h))
                }
                .stroke(.yellow, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                Path { path in
                    path.move(to: CGPoint(x: 0, y: insets.top))
                    path.addLine(to: CGPoint(x: w, y: insets.top))
                }
                .stroke(.green, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h - insets.bottom))
                    path.addLine(to: CGPoint(x: w, y: h - insets.bottom))
                }
                .stroke(.orange, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))

                VStack(alignment: .leading, spacing: 2) {
                    Text("[\(label)] " + String(format: "%.0f×%.0f", w, h))
                    Text(String(format: "L %.1f  R %.1f  T %.1f  B %.1f",
                                insets.leading, insets.trailing, insets.top, insets.bottom))
                }
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.cyan)
                .padding(4)
                .background(.black.opacity(0.75))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(2)
            }
            .allowsHitTesting(false)
        }
    }
}
