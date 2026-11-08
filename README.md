# Niles

Niles is a standalone iPhone app that runs a Streamable-HTTP MCP server exposing
HomeKit's *configuration* surface — scenes, rooms, zones, service groups, and
automations — to any agent on your LAN, with every write approved on-device
before it touches the shared home database.

Read tools answer in-band from the live home graph. Write tools stage proposals
that expire after 24 hours and record read-back evidence when executed; denied
or expired proposals never touch the home. Niles can restructure your home, but
it never changes device state — configuration only, and only with a human
tapping Approve.

## Status

🚧 Scaffold. The XcodeGen project, app entry point, `NilesCore` shared-logic
target with unit tests, and CI are in place; features land task by task against
the approved spec.

## Building

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
open Niles.xcodeproj
```

Build and test from the CLI:

```sh
xcodebuild build -project Niles.xcodeproj -scheme Niles \
  -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Niles.xcodeproj -scheme Niles \
  -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO
```

CI runs the same generate → build → test on every pull request.
