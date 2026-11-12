---
name: niles
description: Connect to and use Niles, an iPhone app that runs a Model Context Protocol (MCP) server for an Apple Home on the local network. Covers service discovery, one-time device-flow pairing, MCP session setup, the search-first read model, and the staged-write approval model. Use when an agent needs to read or change HomeKit configuration — scenes, rooms, zones, service groups, triggers, accessories, or characteristic values — through Niles.
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

## 4. The interaction model

The tool surface follows one loop: **resolve → read → stage → poll**. The rules below are the whole discipline; every tool in §5 fits them. Following them is what keeps a staged change from deleting something you did not mean to touch.

### Resolve, never guess

Every id comes from a read. `search(query)` finds objects by name across the home — rooms, zones, scenes, accessory groups, triggers, and accessories — returning typed candidates with their ids and a one-line context qualifier (the room an accessory sits in, a trigger's enabled state). When several candidates match — "lamp" matches three accessories in a real home — **ask the human which one they meant.** Never construct an id, never take the first hit without looking.

### Lean-first reads

Start from `get_details` with **no arguments**: a lean whole-home summary — homes with counts, rooms with accessory names, zones, scenes as action counts, groups, and triggers — and no characteristic payloads. A real home fits your context window this way; it does not fit as a full dump.

Deep-read one object at a time: `get_details(kind, id)` where kind is `home`, `room`, `zone`, `scene`, `group`, `trigger`, or `accessory`. Responses are capped (20,000 characters): an oversized deep read comes back **explicitly marked `truncated: true`** with a `note` saying what was dropped — reduced to a counts-only accessory overview, never silently shortened. A summary that will not fit is refused outright with an error telling you to narrow the read. Either way, do not act on fields you cannot see; read one level deeper instead.

### One request, one batch

A human request touching many objects — "make five scenes", "rename these twelve lamps" — is **one batch proposal** via `stage_batch`, never a stream of singles: one notification, one review card, one approval. It takes 1–20 entries, each `{tool, arguments}` naming a staged write tool with its normal arguments. Every entry is planned against the same home snapshot: if any entry would fail — unknown object, bad value — the whole batch is rejected with per-entry errors and nothing is staged. Fix the named entry and re-send the whole batch. Approval applies every operation in order, and if one fails partway the read-back evidence shows which applied — there is no rollback. `set_trigger_state` is never a batch member: arming is always its own proposal and its own approval.

For changes that genuinely depend on each other — a rename whose new object id a later call needs — stage separate proposals **in order** and report every `proposalId`. Poll `get_proposal(proposalId)` to learn each outcome (`staged`, `approved`, `executed`, `denied`, `expired`, `failed`) and read execution evidence — do not re-read the home to guess whether a write landed. Staging an identical change twice returns the existing proposal instead of stacking duplicate cards.

### Declarative means destructive

`update` — and its deprecated per-type twins `set_zone_rooms`, `set_scene_actions`, `set_service_group_members` — **replaces the complete list**. Groups take `members`, zones take `rooms`, scenes take `actions`, event triggers take `events`. Anything **absent from the list is removed**. When a human asks you to add one action to a scene, you stage every action the scene should have — the new one *and* every existing one restated. If you have not read the object first, you do not know what you are about to delete.

### Read before declarative edits on triggers

`get_details(kind: "trigger", id:)` returns the trigger's structured read — events, end events, run-once, the presence condition — plus a **`readable` flag**. `readable: false` means parts of the trigger could not be represented (in practice a predicate HomeKit or another app wrote; the raw predicate string is included as evidence). A declarative edit on an unreadable trigger **discards exactly the parts the read could not show**. When you see `readable: false`, surface that to the human — "this automation has unreadable parts that will be discarded" — and stage nothing until they decide. Timer triggers have no event list; `set_trigger_state` moves their schedule.

### Immediate-effect tools

`execute_scene` and `write_characteristic` change **physical device state the moment the human approves** — the review card says so. Say it when you stage: "approving this turns the lamp off now", not just "a proposal is waiting". Their arguments are not replaced declaratively; everything else about staging is the same.

### Automations arm separately

Triggers are **created disabled** — both `create` kinds (`timer`, `event`) and the deprecated `create_timer_trigger` / `create_event_trigger`. Enabling is **always its own proposal** (`set_trigger_state`) and its own human decision; an automation can never silently start running, and no other tool changes an automation's armed state. Stage creation and arming as two separate proposals, and leave a trigger disabled unless the human asked to arm it.

## 5. Tool surface

40 tools are registered. 13 are the current surface; 27 carry **DEPRECATED** markers in their own descriptions — fully functional, listed for compatibility, each one naming its unified replacement.

**Consolidated reads (2):** `search`, `get_details`

**Unified write verbs (4)** — dispatch by id to the same staged-proposal code paths the per-type tools use; staging, validation, and review-card semantics are identical:

| Tool | Args | Notes |
|---|---|---|
| `create` | `kind` (room·zone·scene·group·timer·event), `homeId`, `name`, payload per kind | payload: `actions` (scenes), `serviceIds` (groups), `fireDate`/`recurrence` (timers), `events`/`endEvents`/`executeOnce`/`sceneId` (event triggers) |
| `update` | `entityId`, `members?`·`rooms?`·`actions?`·`events`/`endEvents`/`recurrences`/`executeOnce`/`sceneId?` | declarative replace; groups·zones·scenes·event triggers |
| `rename` | `entityId`, `newName` | room, zone, scene, group, accessory |
| `delete` | `entityId`, `deleteLinkedTriggers?` | destructive; per-type consequences on the review card |

**Dedicated, not deprecated (8):** `stage_batch` (many operations, ONE proposal — 1–20 entries, all-or-nothing planning, no `set_trigger_state` members), `execute_scene` and `write_characteristic` (device-immediate), `set_trigger_state` (arm/disarm — never absorbed into `update`), `identify_accessory`, `unblock_accessory`, `assign_accessory_to_room`, `get_proposal`.

**Deprecated per-type predecessors (27):**
- Reads: `get_homes`, `get_rooms`, `get_zones`, `get_scenes`, `get_service_groups`, `get_triggers`
- Rooms: `create_room`, `rename_room`, `delete_room`
- Zones: `create_zone`, `rename_zone`, `delete_zone`, `set_zone_rooms`
- Scenes: `create_scene`, `rename_scene`, `delete_scene`, `set_scene_actions`
- Service groups: `create_service_group`, `rename_service_group`, `delete_service_group`, `set_service_group_members`
- Triggers: `create_timer_trigger`, `create_event_trigger`, `update_event_trigger`, `delete_trigger`
- Accessories: `rename_accessory`, `remove_accessory`

**Migrating from the per-type reads:** `get_rooms` / `get_zones` / `get_scenes` / `get_service_groups` / `get_triggers` / `get_homes` still work and will keep working until a versioned removal. Replace them with `search` (to resolve names) and `get_details` (to read one object); `get_details` with no arguments replaces the whole-home slice. Every DEPRECATED description names the unified call that replaces it — per-type writes map one-to-one.

## 6. Working with the approval model

- Every write tool returns immediately with a **staged** proposal and its `proposalId`. Nothing has happened yet.
- The proposal appears in the human's Niles queue. Approve applies it; deny or 24-hour expiry applies nothing. You cannot approve your own proposal, and you should not ask the human to approve blindly — summarize what you staged and why.
- Staging validates against the live home graph and fails fast with named errors — e.g. a characteristic the accessory does not support, a duplicate scene name, or a trigger armed without a linked scene. Fix the payload and re-stage; do not argue with validation.
- Destructive proposals (deletes) preview what will dangle — where a deleted room's accessories go, which triggers a deleted scene leaves behind. Delete scenes, rooms, and accessories only on explicit human instruction; `delete` on a scene takes `deleteLinkedTriggers` to remove the triggers that run it.
- Execution is forward-only with read-back evidence — there is no automatic rollback. If a multi-part execution fails partway, `get_proposal` evidence shows which operations applied.
