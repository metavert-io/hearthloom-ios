# Hearthloom for iOS: review guidance

A SwiftUI client for a self-hosted Hearthloom node. The phone is an
authenticated client and an on-device adapter host, never a peer. `CLAUDE.md`
is the full rulebook, `docs/node-api.md` the API the app calls, and README
"Security posture" the promises the code must keep.

## Project generation and signing
- `project.yml` is the source of truth; the `.xcodeproj` is generated and not
  tracked. Entitlements are declared under
  `targets.<target>.entitlements.properties` in `project.yml`: xcodegen
  rewrites the entitlements file, so hand edits to it are lost.
- No team ID or concrete bundle ID in `project.yml` `settings` or in Swift.
  They come from `Config/Signing.xcconfig` and the gitignored
  `Config/Signing.local.xcconfig`.
- Declaring an entitlement before the App ID has it breaks device signing.

## Self-hosting first
- The Connect screen leads with pairing and a server address. A hosted
  provider comes only from the `HEARTHLOOM_PROVIDER_*` build settings, and is
  listed, never preselected or hardcoded.
- App Transport Security sets only `NSAllowsLocalNetworking`: plain HTTP for
  local addresses, HTTPS everywhere else. Never `NSAllowsArbitraryLoads`.

## Credentials and private data
- The device token is scoped `read,ingest,notify`, never `write`, `admin` or
  `peer`. It lives in the Keychain behind `.userPresence`,
  `WhenUnlockedThisDeviceOnly`, with Face ID gates on app open and on vault
  unlock.
- Background work (Siri, Shortcuts, the Control) uses only the capture-only
  scoped key in `CaptureKeyStore`, minted with grants `{capture, own_device}`.
  The device token never goes there.
- Private (`scope='private'`) data is never persisted on the device.
- No tokens, DSNs, hostnames or people in the repo, logs or test fixtures.
  Sentry stays an opt-in overlay (`#if canImport(Sentry)`).

## Device adapters
- Every upload goes through the shared `IngestGate` (it serializes all device
  uploads) via `HearthAPI.postIngest`, in chunks, from an incremental marker.
- A new adapter adopts the `DeviceAdapter` protocol and stays behind its
  `streamingEnabled` flag until the node endpoint ships.
- Send only what the purpose string promises: photo locations, never images;
  recognized text, never scans. A new data type needs a purpose string in
  `project.yml` and, for a required-reason API, an entry in
  `Resources/PrivacyInfo.xcprivacy`.

## Quick capture
- Queue-first (`CaptureQueue`); a 404 from the node is the feature gate.
- `OpenCaptureIntent` lives in `Sources/Shared` and must stay in both the app
  and the `HearthloomControls` targets.

## Tests
Live tests skip unless their `TEST_RUNNER_HLIOS_*` variables are set, and must
never point at a node holding real data.
