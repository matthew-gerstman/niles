// swift-tools-version: 6.0
import PackageDescription

/// NilesCore is a real SwiftPM package (cleanup W1, audit §1.3): the app
/// target links this product and nothing else, so the framework boundary —
/// "the app depends on NilesCore, never around it" — is enforced by the
/// build system. The MCP SDK stays a package-internal dependency; the MCP
/// `Value` type never appears in the app-facing API.
let package = Package(
    name: "NilesCore",
    // iOS 17 is the app's floor. Standalone verification builds against the
    // iOS Simulator SDK via a destination file — HomeKit does not exist in
    // the macOS SDK, so there is no meaningful Mac-host build of this
    // package.
    platforms: [.iOS(.v17)],
    products: [
        // Dynamic to keep the framework-shaped embedding the app target
        // had when NilesCore was an XcodeGen framework.
        .library(name: "NilesCore", type: .dynamic, targets: ["NilesCore"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/modelcontextprotocol/swift-sdk",
            exact: "0.12.1"
        ),
    ],
    targets: [
        .target(
            name: "NilesCore",
            dependencies: [.product(name: "MCP", package: "swift-sdk")]
        ),
    ]
)
