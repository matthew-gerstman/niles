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
        // Static: the single app consumer embeds NilesCore's code directly in
        // its binary. Dynamic linking here shipped a device build whose bundle
        // never contained Frameworks/NilesCore.framework (XcodeGen-generated
        // app targets do not embed dynamic package products), so the app died
        // under dyld at launch. Static keeps the same package-graph boundary
        // — the app links only this product; the MCP SDK stays internal.
        .library(name: "NilesCore", type: .static, targets: ["NilesCore"]),
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
