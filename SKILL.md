---
name: niles
description: Connect to and use Niles, an iPhone app that runs a Model Context Protocol (MCP) server for an Apple Home on the local network. Covers service discovery, one-time device-flow pairing, MCP session setup, and the staged-write approval model. Use when an agent needs to read or change HomeKit configuration — scenes, rooms, zones, service groups, triggers, accessories, or characteristic values — through Niles.
---

# Niles — HomeKit MCP server

Niles exposes an Apple Home over MCP. **Reads are direct. Every write is staged as a proposal and applies only after a human approves it in the Niles app on the iPhone.** Denial and expiry (24 hours) apply nothing. There is no way to bypass the approval step, and you should never try — it is the product's safety boundary, not an obstacle.

## 1. Discover the server

Niles advertises itself over Bonjour while the app is open and in the foreground:

- Service type: `_niles-mcp._tcp`
- Example instance shape: `<device-name>._niles-mcp._tcp.local` → e.g. `someones-iphone.local`, port `8901`
- TXT records: `mcp=/mcp` (MCP endpoint path), `pairing=v1` (pairing protocol version)

Resolve with standard tools, e.g. `dns-sd -B _niles-mcp._tcp` or an mDNS library. The port is assigned by the OS and can change between runs — always use the resolved port, never assume 8901.

**The server is foreground-only.** If discovery or a request fails, the most likely cause is that the Niles app is not open on the iPhone. Ask the human to open Niles; do not retry indefinitely.

## 2. Pair (first time only)

Pairing is a one-time exchange: the human reads a six-digit code from Niles Settings (the code regenerates live and expires after five minutes), and you trade it for a permanent bearer token.

```
POST http://<host>:<port>/pairing
Content-Type: application/json

{"code": "482917", "name": "Obvious agent"}
```

- `code` — the six-digit string from Settings. Single-use; burned after five failed attempts.
- `name` — a label for this agent. It appears in Niles Settings → Paired agents, where the human can revoke it later.

Success returns a per-agent bearer token. Store it in your own secret store; Niles never expires it, and revocation in Settings is the only way to invalidate it. A revoked token's gateway sessions are closed immediately.

## 3. Establish the MCP session

Niles speaks stateful Streamable HTTP. Every request carries `Authorization: Bearer <token>`; the initialize response carries an `Mcp-Session-Id` header you echo on subsequent calls.

```
POST http://<host>:<port>/mcp
Authorization: Bearer <token>
Content-Type: application/json
Accept: application/json, text/event-stream

{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"<your name>","version":"1.0"}}}
```

Then send `notifications/initialized` (same headers, plus `Mcp-Session-Id`), and call tools with `tools/call`. Responses may be SSE-framed (`event: message` / `data: {…}`); skip empty `data:` frames when parsing. Unauthenticated requests get HTTP 401.

If your MCP client supports HTTP transports natively, point it at `http://<host>:<port>/mcp` with the bearer token as a header — no manual JSON-RPC needed.

## 4. Tool surface

**Reads (no approval):**
`get_homes`, `get_rooms` (nested accessories, services, and characteristics with values and metadata), `get_zones`, `get_scenes`, `get_service_groups`, `get_triggers`.

**Writes (staged — nothing applies until a human approves on the iPhone):**
- Rooms: `create_room`, `rename_room`, `delete_room`
- Zones: `create_zone`, `rename_zone`, `delete_zone`, `set_zone_rooms`
- Scenes: `create_scene`, `set_scene_actions`, `rename_scene`, `delete_scene`
- Service groups: `create_service_group`, `rename_service_group`, `delete_service_group`, `set_service_group_members`
- Triggers: `create_timer_trigger`, `create_event_trigger`, `update_event_trigger`, `delete_trigger`, `set_trigger_state`
- Accessories: `rename_accessory`, `assign_accessory_to_room`, `identify_accessory`, `unblock_accessory`, `remove_accessory`

**Device-immediate (physical state changes the moment the human approves):**
- `write_characteristic` — e.g. set Brightness on a lamp
- `execute_scene` — fire a scene

**Proposal status:**
- `get_proposal` — poll with the `proposalId` returned at staging to learn the outcome (`staged`, `executed`, `denied`, `expired`) and read execution evidence.

## 5. Working with the approval model

- Every write tool returns immediately with a **staged** proposal and its `proposalId`. Nothing has happened yet.
- The proposal appears in the human's Niles queue. Approve applies it; deny or 24-hour expiry applies nothing. You cannot approve your own proposal, and you should not ask the human to approve blindly — summarize what you staged and why.
- Poll `get_proposal` for the outcome rather than re-staging. Staging an identical change twice creates duplicate cards.
- Staging validates against the live home graph and fails fast with named errors — e.g. a characteristic the accessory does not support, a duplicate scene name, or a trigger armed without a linked scene. Fix the payload and re-stage; do not argue with validation.
- Destructive proposals (deletes) preview what will dangle. Delete scenes and rooms only on explicit human instruction.
- Triggers are created disabled; arming one is a separate approval. Leave them disabled unless the human asks to arm.
- Execution is forward-only with read-back evidence — there is no automatic rollback. If a multi-part execution fails partway, `get_proposal` evidence shows which operations applied.
