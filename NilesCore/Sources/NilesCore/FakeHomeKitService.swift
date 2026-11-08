/// In-memory `HomeKitService` for unit tests and SwiftUI previews.
///
/// Tests must never touch `HMHomeManager` — the fake is the only home data
/// source they see. Seed it with a `HomeGraph`; when a test needs the world
/// to change mid-test, swap the graph with `setGraph(_:)`.
public actor FakeHomeKitService: HomeKitService {
    public private(set) var graph: HomeGraph

    public init(graph: HomeGraph = HomeGraph()) {
        self.graph = graph
    }

    public func snapshot() async throws -> HomeGraph {
        graph
    }

    public func setGraph(_ newGraph: HomeGraph) {
        graph = newGraph
    }
}
