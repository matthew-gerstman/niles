// swift-tools-version: 6.0
import PackageDescription

/// NilesCore is a real SwiftPM package (cleanup W1, audit §1.3): the app
/// target links this product and nothing else, so the framework boundary —
/// "the app depends on NilesCore, never around it" — is enforced by the
/// build system. The MCP SDK stays a package-internal dependency; the MCP
/// `Value` type never appears in the app-facing API.
let package = Package(
    name: "NilesCore",
    // iOS 17 is the app's floor. macOS 13 exists so the package can be
    // built standalone on a Mac host (`swift build`) — the MCP SDK's floor.
    platforms: [.iOS(.v17), .macOS(.v13)],
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
