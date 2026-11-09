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
                let color = XCTUnwrap(
                    UIColor(named: name, in: .main, compatibleWith: trait),
                    "\(name) must resolve (\(trait.userInterfaceStyle) appearance)"
                )
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                XCTAssertEqual(alpha, 1, "\(name) must be opaque")
            }
        }
    }

    func testAccentIsGrappaInLightMode() throws {
        let accent = try XCTUnwrap(
            UIColor(named: "accent", in: .main, compatibleWith: UITraitCollection(userInterfaceStyle: .light))
        )
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        accent.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        // Grappa #544556.
        XCTAssertEqual(red, 0x54 / 255, accuracy: 0.005)
        XCTAssertEqual(green, 0x45 / 255, accuracy: 0.005)
        XCTAssertEqual(blue, 0x56 / 255, accuracy: 0.005)
    }

    func testDarkAccentIsLighterThanLightAccent() throws {
        let light = try XCTUnwrap(
            UIColor(named: "accent", in: .main, compatibleWith: UITraitCollection(userInterfaceStyle: .light))
        )
        let dark = try XCTUnwrap(
            UIColor(named: "accent", in: .main, compatibleWith: UITraitCollection(userInterfaceStyle: .dark))
        )
        var lRed: CGFloat = 0, lGreen: CGFloat = 0, lBlue: CGFloat = 0, _: CGFloat = 0
        var dRed: CGFloat = 0, dGreen: CGFloat = 0, dBlue: CGFloat = 0, _: CGFloat = 0
        light.getRed(&lRed, green: &lGreen, blue: &lBlue, alpha: nil)
        dark.getRed(&dRed, green: &dGreen, blue: &dBlue, alpha: nil)
        // Dark mode resolves the lightened variant for contrast on dark surfaces.
        let lLuma = 0.2126 * lRed + 0.7152 * lGreen + 0.0722 * lBlue
        let dLuma = 0.2126 * dRed + 0.7152 * dGreen + 0.0722 * dBlue
        XCTAssertGreaterThan(dLuma, lLuma)
    }
}
