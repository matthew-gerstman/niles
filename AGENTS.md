# AGENTS.md — Niles

## Project layout

- `project.yml` — XcodeGen spec (app targets iOS 17, depends on `modelcontextprotocol/swift-sdk` 0.12.1). **`Niles.xcodeproj` is generated, not committed** — always run `xcodegen generate` before building.
- **Verification is manual on device — there is no CI and the repo ships without tests by policy.** Every change is validated by Debug/Release simulator builds plus device QA (see below); nothing runs in GitHub Actions.
- Builds use ad-hoc signing (`CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO`) where a test host would be needed; unsigned test hosts fail Keychain with `errSecMissingEntitlement` (-34018). (Note: the repo ships without tests, so this mainly matters if a test suite is ever restored.)

## Building on the Mac (device deploy)

Verified 2026-11-09/10 on Matthew's Mac (Xcode at `/Applications/Xcode.app`; `xcode-select` points at `/Library/Developer/CommandLineTools`, so always export `DEVELOPER_DIR`).

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate                                          # regenerate the project first
xcodebuild -project Niles.xcodeproj -scheme Niles \
  -destination 'generic/platform=iOS' \
  -derivedDataPath .build/DerivedData \
  -allowProvisioningUpdates build
```

Lessons that cost us three failed attempts — all verified by real failures:

1. **`DEVELOPER_DIR` is mandatory.** Without it, `xcodebuild` resolves to Command Line Tools and dies with "requires Xcode".
2. **Use `-destination 'generic/platform=iOS'` for a build that shouldn't wait on a phone.** Targeting a specific phone UDID fails with "Timed out waiting for all destinations" if that device is locked ("needs to be unlocked to enable development services"). Build generic, then install when the device is awake.
3. **Redirect DerivedData into the repo** (`-derivedDataPath .build/DerivedData`). The default path under `~/Library/Developer/Xcode/DerivedData` is unwritable from sandboxed command runners, which fails package resolution with "You don't have permission to save the file 'repositories'".
4. **SwiftPM needs network + the real cache.** Package clones (`swift-nio`, `swift-collections`, `swift-log`, `swift-atomics`, `swift-system`, `mcp-swift-sdk`, `EventSource`) fail without internet ("Could not resolve host"), and manifest evaluation writes diagnostics into `~/Library/Caches/org.swift.swiftpm` — `XDG_CACHE_HOME` does **not** redirect it under `xcodebuild`. Both need full (unsandboxed) access. First resolve needs `network` at minimum; the manifest-cache step needs `full`.
5. Keep `Niles/Niles.entitlements` local modifications in mind — Matthew carries an uncommitted entitlements tweak for device builds in the working copy.

### Paired devices (from this Mac)

| Device | UDID |
|---|---|
| iPhone 17 Pro Max ("Matthew's iPhone") | `00008150-000E651E3A40401C` |
| Second iPhone (iPhone19,4) | `00008160-001850A80CA8000A` |
| Bedroom Apple TV 4K (2nd gen) | `27aa3cf91abfe5816512167cfb1098b0ce36fbb2` |

Both phones share the display name "Matthew's iPhone" — always target by UDID, never by name. **The iPhone Duo (00008160-…) is Matthew's primary device** for Niles builds and QA; the 17 Pro Max is secondary. List with `xcrun devicectl list devices` (needs `DEVELOPER_DIR` set).

### Install to a phone

```bash
xcrun devicectl device install app \
  --device 00008150-000E651E3A40401C \
  .build/DerivedData/Build/Products/Debug-iphoneos/Niles.app
```

The device must be unlocked (development services won't start on a locked phone). If provisioning is stale, rerun the build with `-allowProvisioningUpdates`; the iOS Team Provisioning Profile for `com.gerstman.HomeKitSync` (team `DVM2MJ6Z3Q`, includes the HomeKit entitlement) expires 2027-10-13.
