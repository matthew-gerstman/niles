import Foundation
import MCP
import NilesCore
import Testing
@testable import Niles

/// The pure swipe-action mapping: a Home row + action resolves to the same
/// write tool an agent would call, and unsupported combinations return nil
/// instead of staging something wrong.
struct HomeRowActionTests {

    private func row(_ kind: HomeRowKind, _ entityId: String, isEnabled: Bool = true) -> HomeRow {
        HomeRow(name: entityId, subtitle: "", systemImage: "house", isEnabled: isEnabled, kind: kind, entityId: entityId)
    }

    @Test func sceneRowsRunButNeverRenameOrDelete() {
        let scene = row(.scene, "scene-1")
        #expect(scene.primaryAction == .run)
        let run = scene.stageRequest(for: .run, newName: nil)
        #expect(run?.tool == "execute_scene")
        #expect(run?.arguments["sceneId"] == .string("scene-1"))
        // The UI no longer offers rename/delete; the write-tool mapping
        // stays intact for the agent-facing pipeline.
        let rename = scene.stageRequest(for: .rename, newName: "Evening")
        #expect(rename?.tool == "rename_scene")
        #expect(rename?.arguments["name"] == .string("Evening"))
        #expect(scene.stageRequest(for: .delete, newName: nil)?.tool == "delete_scene")
        #expect(scene.quickActions == [.run])
    }

    @Test func triggerRowsArmDisarmAndDeleteButNeverRename() {
        let enabled = row(.trigger, "trigger-1", isEnabled: true)
        #expect(enabled.primaryAction == .setArmed(false))
        let disarm = enabled.stageRequest(for: .setArmed(false), newName: nil)
        #expect(disarm?.tool == "set_trigger_state")
        #expect(disarm?.arguments["enabled"] == .bool(false))

        let disabled = row(.trigger, "trigger-2", isEnabled: false)
        #expect(disabled.primaryAction == .setArmed(true))
        let arm = disabled.stageRequest(for: .setArmed(true), newName: nil)
        #expect(arm?.tool == "set_trigger_state")
        #expect(arm?.arguments["enabled"] == .bool(true))

        #expect(enabled.stageRequest(for: .rename, newName: "x") == nil)
        #expect(enabled.stageRequest(for: .run, newName: nil) == nil)
        #expect(enabled.stageRequest(for: .delete, newName: nil)?.tool == "delete_trigger")
        #expect(enabled.quickActions == [.setArmed(false)])
    }

    @Test func roomAndZoneRowsHaveNoQuickActionsButKeepToolMapping() {
        let room = row(.room, "room-1")
        #expect(room.primaryAction == nil)
        // Structural management is not a Home-tab quick action; the
        // write-tool mapping below is still exercised for the pipeline.
        let rename = room.stageRequest(for: .rename, newName: "Studio")
        #expect(rename?.tool == "rename_room")
        #expect(rename?.arguments["roomId"] == .string("room-1"))
        #expect(rename?.arguments["name"] == .string("Studio"))
        #expect(room.stageRequest(for: .delete, newName: nil)?.tool == "delete_room")
        #expect(room.stageRequest(for: .run, newName: nil) == nil)
        #expect(room.quickActions.isEmpty)

        let zone = row(.zone, "zone-1")
        #expect(zone.primaryAction == nil)
        #expect(zone.stageRequest(for: .rename, newName: "Up")?.tool == "rename_zone")
        #expect(zone.stageRequest(for: .delete, newName: nil)?.tool == "delete_zone")
        #expect(zone.quickActions.isEmpty)
    }

    @Test func rowsWithoutIdentityAreInert() {
        let bare = HomeRow(name: "Unknown", subtitle: "", systemImage: "house")
        #expect(!bare.isActionable)
        #expect(bare.primaryAction == nil)
        #expect(bare.quickActions.isEmpty)
        #expect(bare.stageRequest(for: .run, newName: nil) == nil)
    }
}
