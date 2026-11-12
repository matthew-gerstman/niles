import Foundation
import NilesCore

/// A `HomeKitWriting` backed by the real home database.
///
/// Reads and writes both run on `HomeManagerHomeKitService`: the actor owns
/// the `HMHomeManager` and executes approved operations against it through
/// the resolver + continuation executor (spec: write execution).
struct DeviceHomeKitService: HomeKitWriting {
    private let reader = HomeManagerHomeKitService()

    func snapshot() async throws -> HomeGraph {
        try await reader.snapshot()
    }

    func perform(_ operation: HomeKitOperation) async throws -> String? {
        try await reader.perform(operation)
    }
}
