# Niles

Niles is an iPhone app that runs a [Model Context Protocol](https://modelcontextprotocol.io) server for your Apple Home. Any AI agent on your local network can read your home's configuration — homes, rooms, zones, scenes, service groups, triggers, accessories — and stage changes, while every write waits for explicit approval in the app.

Agents pair with Niles over device flow: a six-digit code, shown live in Settings, is exchanged once for a permanent, individually revocable bearer token. No static secrets, no shared tokens.

## How it works

- **Transport.** A stateful Streamable-HTTP MCP server (official [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk)) served by the app on the local network, advertised over Bonjour as `_niles-mcp._tcp` with TXT records `mcp=/mcp` and `pairing=v1`. Serving is foreground-only; the display stays awake while the server runs.
- **Auth.** One 256-bit bearer token per paired agent, stored in the iOS Keychain and compared in constant time. Tokens never expire; revoking one in Settings immediately closes its bound gateway sessions.
- **Reads** answer in-band from the live home graph — no approval, no gating.
- **Writes** stage proposals: validated at staging against the same view the executor uses, rendered as a review card (diff, affected objects by name, severity), approved or denied in Niles, then executed forward-only with read-back evidence. Denied and expired proposals apply nothing; proposals expire after 24 hours.
- **Device-immediate** operations (`execute_scene`, `write_characteristic`) change physical state the moment a human approves — the review card says so, with current value → target value.
- **Safety rules.** Triggers are created disabled; arming one is its own approval. Destructive operations preview every reference that will dangle. Errors name the object and the reason, never a bare code.

## Connecting an agent

Point your agent at [SKILL.md](SKILL.md) — a ready-made skill covering discovery, pairing, session setup, and the full tool surface.

## Tools

| Class | Tools |
|---|---|
| Reads (no approval) | `get_homes`, `get_rooms`, `get_zones`, `get_scenes`, `get_service_groups`, `get_triggers` |
| Staged writes | `create_room`, `rename_room`, `delete_room`, `create_zone`, `rename_zone`, `delete_zone`, `set_zone_rooms`, `create_scene`, `set_scene_actions`, `rename_scene`, `delete_scene`, `create_service_group`, `rename_service_group`, `delete_service_group`, `set_service_group_members`, `create_timer_trigger`, `create_event_trigger`, `update_event_trigger`, `delete_trigger`, `set_trigger_state`, `rename_accessory`, `assign_accessory_to_room`, `identify_accessory`, `unblock_accessory`, `remove_accessory` |
| Device-immediate (on approval) | `write_characteristic`, `execute_scene` |
| Proposal status | `get_proposal` |

## Building

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
open Niles.xcodeproj
```

Build and test from the CLI (pick any available simulator from
`xcrun simctl list devices available`; iPhone 17 used here):

```sh
xcodebuild build -project Niles.xcodeproj -scheme Niles \
  -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Niles.xcodeproj -scheme Niles \
  -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO
```

CI runs the same generate → build → test on every pull request.
