import Foundation
import Testing
@testable import NilesCore

/// The persistent activity timeline: append-only in memory, write-through to
/// one JSON file, reloaded on init — the history that survives relaunch.
@Suite struct ActivityLogTests {

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("niles-activity-\(UUID().uuidString)", isDirectory: true)
    }

    private func sampleEvent(kind: ActivityEvent.Kind, proposalId: String = "prop_1") -> ActivityEvent {
        ActivityEvent(
            at: Date(timeIntervalSince1970: 1_762_592_000),
            kind: kind,
            proposalId: proposalId,
            proposalTitle: "Create scene “Movie Night”",
            agentName: "Claude Code",
            decision: kind == .decided ? "approved" : nil,
            detail: kind == .undone ? "Approval cancelled — nothing applied" : nil,
            evidence: kind == .executed
                ? [ProposalEvidence(claim: "Scene exists", observed: "Scene “Movie Night” holds 2 actions", confirmed: true)]
                : []
        )
    }

    @Test func appendPersistsAndRoundTripsAcrossReinit() async throws {
        let directory = tempDirectory()
        let log = ActivityLog(directory: directory)
        await log.append(sampleEvent(kind: .staged))
        await log.append(sampleEvent(kind: .decided))
        await log.append(sampleEvent(kind: .executed))

        // A fresh log over the same directory reloads what was written.
        let reloaded = ActivityLog(directory: directory)
        let reloadedEvents = await reloaded.allEvents()
        let originalEvents = await log.allEvents()
        #expect(reloadedEvents == originalEvents)
        #expect(reloadedEvents.map(\.kind) == [.staged, .decided, .executed])

        // Order is chronological (append order), agents and ids intact.
        #expect(reloadedEvents.first?.kind == .staged)
        #expect(reloadedEvents.first?.agentName == "Claude Code")
        #expect(reloadedEvents.allSatisfy { $0.proposalId == "prop_1" })
        #expect(reloadedEvents.allSatisfy { $0.proposalTitle == "Create scene “Movie Night”" })
    }

    @Test func executedEvidenceSurvivesRoundTripStructured() async throws {
        let directory = tempDirectory()
        let log = ActivityLog(directory: directory)
        await log.append(sampleEvent(kind: .executed))

        let reloaded = ActivityLog(directory: directory)
        let events = await reloaded.allEvents()
        let evidence = try #require(events.first?.evidence)
        #expect(evidence.count == 1)
        #expect(evidence.first?.claim == "Scene exists")
        #expect(evidence.first?.observed == "Scene “Movie Night” holds 2 actions")
        #expect(evidence.first?.confirmed == true)
    }

    @Test func eventsAppendInOrderAcrossTheActorBoundary() async {
        let log = ActivityLog(directory: tempDirectory())
        for index in 0..<25 {
            await log.append(sampleEvent(kind: .staged, proposalId: "prop_\(index)"))
        }
        let events = await log.allEvents()
        #expect(events.map(\.proposalId) == (0..<25).map { "prop_\($0)" })
    }

    @Test func missingFileStartsEmpty() async {
        let log = ActivityLog(directory: tempDirectory())
        let events = await log.allEvents()
        #expect(events.isEmpty)
    }

    @Test func corruptFileStartsEmptyInsteadOfCrashing() async {
        let directory = tempDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data("not json".utf8).write(to: directory.appendingPathComponent("activity-log.json"))

        // History must not take the app down: an unreadable log starts empty.
        let log = ActivityLog(directory: directory)
        let events = await log.allEvents()
        #expect(events.isEmpty)
    }
}
