import SwiftUI
import XCTest
@testable import Niles

/// Asserts the semantic design tokens resolve from the asset catalog in both
/// light and dark mode — a missing colorset or typo'd name fails here instead
/// of silently rendering the default accent.
final class NilesThemeTests: XCTestCase {
    func testSemanticTokensResolveInBothAppearances() throws {
        for name in ["accent", "destructive", "good", "warn"] {
            for trait in [UITraitCollection(userInterfaceStyle: .light),
                          UITraitCollection(userInterfaceStyle: .dark)] {
                let base = try XCTUnwrap(UIColor(named: name), "\(name) must exist in the asset catalog")
                let color = base.resolvedColor(with: trait)
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                XCTAssertEqual(alpha, 1, "\(name) must be opaque")
            }
        }
    }

    func sample(_ name: String, style: UIUserInterfaceStyle) throws -> (CGFloat, CGFloat, CGFloat) {
        let base = try XCTUnwrap(UIColor(named: name), "\(name) must exist in the asset catalog")
        let resolved = base.resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red, green, blue)
    }

    func testAccentIsGrappaInLightMode() throws {
        let (red, green, blue) = try sample("accent", style: .light)
        // Grappa #544556.
        XCTAssertEqual(red, 0x54 / 255, accuracy: 0.005)
        XCTAssertEqual(green, 0x45 / 255, accuracy: 0.005)
        XCTAssertEqual(blue, 0x56 / 255, accuracy: 0.005)
    }

    func testDarkAccentIsLighterThanLightAccent() throws {
        let (lRed, lGreen, lBlue) = try sample("accent", style: .light)
        let (dRed, dGreen, dBlue) = try sample("accent", style: .dark)
        // Dark mode resolves the lightened variant for contrast on dark surfaces.
        let lLuma = 0.2126 * lRed + 0.7152 * lGreen + 0.0722 * lBlue
        let dLuma = 0.2126 * dRed + 0.7152 * dGreen + 0.0722 * dBlue
        XCTAssertGreaterThan(dLuma, lLuma)
    }
}
