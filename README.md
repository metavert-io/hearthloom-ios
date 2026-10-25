# Hearthloom for iOS

The native mobile companion for [Hearthloom](https://github.com/metavert-io/hearthloom)
— a local-first personal knowledge graph served by the `hearthloom-daemon` Rust
daemon.

It is built for self-hosting first: you pair it with a Hearthloom node you run
(see [Connecting to your Hearthloom](#connecting-to-your-hearthloom)). Hosted
providers are an optional extra, never the default.

**Governing architecture:** the phone is an *authenticated client + on-device
adapter host* — never a peer, never a copy of the substrate. It holds no SQLite
file, runs no daemon, and never joins `/v1/sync/*` peering. It talks to a node
exactly like the CLI or dashboard: HTTP + a scoped bearer PAT, with writes
carrying an actor identity and idempotency keys.

## What the iOS client uniquely adds to Hearthloom

Most of Hearthloom (CLI, dashboard, daemon peering) runs on servers and laptops.
The phone is the one place that can see a whole class of signal no other client
can reach — so the iOS app's distinct job is to be a **device-data ingest host**,
turning on-device sensors and system stores into graph observations:

| Source | Framework | What it contributes |
|---|---|---|
| **Apple Health** | HealthKit | steps, energy, heart rate/HRV, sleep, workouts → daily health episodes |
| **Photo locations** | PhotoKit | where/when photos were taken (never the images) → places + a personal map |
| **Contacts** | Contacts | your address book as a canonical Person directory that every other adapter resolves against |
| **Calendar** | EventKit | events, attendees, and places that link people ↔ times ↔ locations |
| **Reminders** | EventKit | reminders + due dates → tasks in the graph |
| **Motion & trips** | CoreMotion | walking/running/cycling/driving segments — how you move through a day |
| **Music & podcasts** | MediaPlayer | what you've played → a taste signal |
| **Location / Visits** | CoreLocation `CLVisit` | the flagship place-graph: arrivals/departures clustered server-side across sources |
| **Document scan** | VisionKit + Vision OCR | receipts, cards, and documents → recognized text (images never leave the device) |
| **Focus** | App Intents Focus Filter + `INFocusStatusCenter` | which Focus is active, recorded on background on/off (setup note below) |

> **Focus setup note:** iOS's public `INFocusStatusCenter` only exposes a boolean
> with no background notifications. For mode-aware, background-delivered capture,
> Hearthloom ships a **Focus Filter** App Intent (`HearthloomFocusFilter`, in the
> main app — no extension or App Group). Add it once under **Settings → Focus →
> (a Focus) → Focus Filters → Hearthloom**; the system then background-runs it on
> every activation/deactivation and the app streams the spans. `INFocusStatusCenter`
> remains a foreground reconcile backstop.

The app runs in **two coordinated roles**:

- **Track A — dashboard shell.** A native SwiftUI shell around a `WKWebView` of the
  node's existing dashboard (authenticated from the durable PAT on every launch).
  We deliberately do *not* re-implement the SPA natively.
- **Track B — device adapters.** The on-device ingest system described above,
  streaming to the node's `/v1/ingest/*` endpoints. This is the code that only a
  phone can run.

## Device-adapter architecture

Every adapter follows one shared pattern so new sources are cheap to add and
behave identically:

- **`DeviceAdapter` protocol** (`Views/AdapterView.swift`) — the contract each
  adapter exposes to the UI: `statusText`, `syncedCount`, `lastSyncedAt`,
  `lastError`, `busy`, `connected`, `connect()`, `forceResync()`.
- **App-level ownership** (`Services/DeviceAdapters.swift`) — all adapters are
  owned by `ShellView` for the whole authenticated session (not by their Settings
  screen), so ingest keeps running regardless of which screen is showing, and is
  re-kicked on launch and foreground for every source the user has enabled.
- **`IngestGate`** (`Services/IngestGate.swift`) — an actor that **serializes all
  device-ingest POSTs** through a single queue, so a full re-sync of one adapter
  can't flood the node or starve another.
- **`HearthAPI.postIngest`** (`Services/HearthAPI+PostIngest.swift`) — the shared
  `{actor, source, device, items}` POST with `{accepted, duplicates}` reply.
- **Incrementality + idempotency** — each adapter persists a marker/anchor
  (HealthKit anchors, a scanned-epoch, etc.) and sends a stable per-item `key`;
  the server dedups per source, and clusters LOCATION across sources.
- **Gating** — each adapter has a `…IngestConfig.streamingEnabled` flag so it can
  ship before its server endpoint is live; all current adapters are live.

### iOS Data Sources UI

Settings → **iOS Data Sources** is a checklist: every source shows its
connected/not state and an inline **Connect** button, so you can enable sources
straight down the list. Tapping a row opens the full detail screen (status,
"streaming to", last-synced, synced count, re-sync). Health and Photos have
bespoke rows (their authorization models differ); the five uniform adapters share
`AdapterChecklistRow` (`Views/DataSourcesChecklist.swift`).

### Ingest endpoints

RFC3339 times; per-source idempotency on your keys; the server dedups across
sources via visit clustering. Request bodies are in
[docs/node-api.md](docs/node-api.md#device-ingest).

| Endpoint | Adapter | State |
|---|---|---|
| `POST /v1/ingest/health` | HealthKitIngest | ✅ live |
| `POST /v1/ingest/photos` | PhotoLocationIngest (photo geotags) | ✅ live |
| `POST /v1/ingest/contacts` | ContactsIngest | ✅ live |
| `POST /v1/ingest/calendar` | CalendarIngest | ✅ live |
| `POST /v1/ingest/reminders` | RemindersIngest | ✅ live |
| `POST /v1/ingest/motion` | MotionIngest | ✅ live |
| `POST /v1/ingest/media` | MediaIngest | ✅ live |
| `POST /v1/ingest/location` | LocationVisitsIngest (`CLVisit`, source `ios-visits`) | ✅ live |
| `POST /v1/ingest/scan` | VisionScanIngest (document OCR, user-driven) | ✅ live |
| `POST /v1/ingest/focus` | FocusIngest (Focus Filter App Intent, `ios-focus`) | ✅ live |
| `POST /v1/ingest/capture` | Quick capture (`CaptureToHearthloomIntent` → `CaptureService`) | ✅ live on nodes newer than 0.5.60 (older ones answer 404; captures stay queued) |

### Quick capture

"Capture to Hearthloom" is an App Intent (`Services/CaptureIntent.swift`) exposed
to Siri, Shortcuts and — through a shortcut — the Action Button. It runs in the
background without opening the app, so it works on a locked phone: the text is
appended to an on-disk queue (`CaptureQueue`), then uploaded with a **capture-only
scoped key** (`CaptureKeyStore`, an after-first-unlock Keychain item kept separate
from the biometric-gated device token). The key is minted once per connection with
the device token (`POST /v1/keys {grants: {capture: true, own_device: true}}`) and
can only add captures — it cannot read the node. `own_device` marks it as one of
your own devices, so the node records captures as your own words rather than an
agent's. A node must let the device token mint that key; 0.5.71 refused (fixed
in later builds). Without the key, captures still queue and upload with the
device token the next time the app is unlocked. Items leave the queue on 200 or 400 only;
everything else keeps them for a later drain (after the next capture, on app
foreground, or **Settings → Quick capture → Upload now**).

The **Lock Screen / Control Center control** (iOS 18+, `HearthloomControls`
extension) can't take text — a control can only run a fixed action or open the
app — so it runs `OpenCaptureIntent` (`Sources/Shared`, compiled into both
targets), which brings the app forward on `QuickCaptureSheet` with the keyboard
up. On a locked phone iOS asks for Face ID first. The sheet sits above the app's
own lock screen because it only writes, using the capture key.

## Requirements

- macOS with **Xcode 16+** (built against a recent iOS SDK; deployment target
  **iOS 17.0**).
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) —
  the `.xcodeproj` is generated from `project.yml`, not checked in.
- A Hearthloom node to connect to: one you run yourself
  ([hearthloom](https://github.com/metavert-io/hearthloom)) on your home network
  or behind https, or one a [hosted provider](#hosted-providers) runs for you.

## Build & run

Generate the Xcode project with the wrapper script (it layers in any opt-in
feature overlays such as Sentry — see below — and is otherwise identical to
`xcodegen generate`):

```bash
# 1. Generate Hearthloom.xcodeproj from project.yml (+ any local overlays)
./Scripts/generate.sh

# 2a. Open in Xcode and run (⌘R):
open Hearthloom.xcodeproj

# 2b. Or build on the simulator from the CLI (any simulator listed by
#     `xcrun simctl list devices available` works)
xcodebuild -project Hearthloom.xcodeproj -scheme Hearthloom \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

**Signing.** The Simulator needs no setup. To run on a device, give the build
your own Apple team and bundle ID:

```bash
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
# then set DEVELOPMENT_TEAM and HEARTHLOOM_BUNDLE_ID in it (the file is gitignored)
```

`Config/Signing.xcconfig` (committed: no team, bundle ID `org.example.hearthloom`)
includes your local file last, and every target derives its bundle ID from
`HEARTHLOOM_BUNDLE_ID` (the extension and tests append `.controls`, `.tests`,
`.uitests`).

**Physical device (wireless install, phone unlocked + Developer Mode on):**

```bash
./Scripts/generate.sh
xcodebuild -project Hearthloom.xcodeproj -target Hearthloom -configuration Debug \
  -sdk iphoneos -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic CONFIGURATION_BUILD_DIR="$PWD/build/device" build
xcrun devicectl device install app --device <devicectl-id> build/device/Hearthloom.app
```

HealthKit needs its App-ID capability registered once via the Xcode GUI, and a
new device must be registered once in Xcode before CLI signing includes its UDID.
See `CLAUDE.md` for the full signing/entitlements gotchas.

> Face ID does not work in the Simulator by default. Use **Features → Face ID →
> Enrolled**, then **Matching/Non-matching Face** to exercise the unlock gates.

## Sentry APM (optional — OFF by default)

Sentry is an **opt-in build feature**. A default clone ships **no** Sentry
package and **no** Sentry code: `Services/Observability.swift` is guarded with
`#if canImport(Sentry)`, and Info.plist's `SENTRY_DSN` (`= "$(SENTRY_DSN)"`)
resolves to an empty string when the build setting is undefined, so
`Observability.start()` simply returns.

To **enable** Sentry for your own checkout:

```bash
# 1. Copy the template to the gitignored local overlay
cp project.sentry.yml.example project.sentry.yml

# 2. Paste your DSN into project.sentry.yml
#    (Sentry → Project → Settings → Client Keys (DSN); it is a client-side,
#     send-only key — kept out of git by convention, not because it's secret)

# 3. Regenerate — the script detects the overlay and layers Sentry in
./Scripts/generate.sh
```

The overlay (`project.sentry.yml`) adds the `sentry-cocoa` SPM package, the target
dependency, and the `SENTRY_DSN` build setting — which flows into Info.plist and
is read at launch by `HearthloomApp.init() → Observability.start()`. To **disable**
Sentry again, delete `project.sentry.yml` and re-run `./Scripts/generate.sh`.

### Crash reporting & readable stack traces (dSYM upload)

`sentry-cocoa` captures native crashes, unhandled exceptions, and app hangs
automatically. For the stack traces to be **symbolicated** (function names + line
numbers instead of hex addresses), Sentry needs the build's dSYM debug symbols.
The overlay handles this:

- It forces `DEBUG_INFORMATION_FORMAT = dwarf-with-dsym` for **Debug** too (Xcode's
  default is dwarf-only, so Debug builds you install to devices would otherwise
  produce no dSYM).
- A post-build phase uploads dSYMs via `sentry-cli`. It no-ops gracefully if the
  tooling isn't set up, so it never breaks a build.

To enable dSYM upload:

```bash
# 1. Install sentry-cli
brew install getsentry/tools/sentry-cli   # or: curl -sL https://sentry.io/get-cli/ | bash

# 2. Provide credentials (gitignored; the auth token is a real secret)
cp .sentryclirc.example .sentryclirc
#   Create an org auth token at Sentry → Settings → Auth Tokens with scopes
#   project:releases, project:write, org:read; fill in org/project slugs too.
```

Debug symbols upload on every build thereafter, so any crash the app reports
arrives fully symbolicated.

### Distributed tracing (phone → node)

Auto performance/network tracing is on, and every ingest POST is wrapped in a
Sentry transaction (`Observability.traced`). The SDK attaches `sentry-trace` /
`baggage` headers only to requests to the connected node: `tracePropagationTargets`
starts empty and is set to that node's origin when you connect or unlock
(`Observability.setNode`), so a hosted provider or any other host never receives
them. The `hearthloom-daemon` continues those headers into a server transaction,
so with both projects in one Sentry org the trace view shows a single end-to-end
phone→node trace.

> **Adding other optional features:** `Scripts/generate.sh` composes a root spec
> (`include: [project.yml, <overlays…>]`). Note that across xcodegen includes,
> array keys like `dependencies` concatenate but dict keys like `info.properties`
> do **not** deep-merge — route per-feature values through `settings.base` (which
> merges) plus a `$(VAR)` reference in the base Info.plist, as Sentry does.

## Connecting to your Hearthloom

The Connect screen leads with the self-hosted paths:

1. **Pair with your Hearthloom (QR)** — the fastest. In your node's dashboard
   open **Integrations → Pair a device** and tap *show pairing code*, then tap
   **Pair with your Hearthloom (QR)** on the phone and scan it. The code is
   `hearthloom://pair?url=…&pat=…`; the app checks that the node answers and
   that the token works, then keeps the token in the Keychain behind Face ID.
2. **Enter server address** — type the node's address
   (`https://node.example.com`, or on your home network
   `http://192.168.1.20:43278`) and tap **Continue**. Once the app has reached
   the node it asks for either
   - that node's **email and password** (the app signs in and mints a device
     token for this iPhone), or
   - a **device token** you minted on the node:
     ```bash
     hearthloom key mint --name "iPhone" --scopes read,ingest,notify
     ```

Every token the app holds appears in the dashboard's **API Keys** list and can
be revoked there at any time.

### Hosted providers

A hosted provider runs a Hearthloom node for you and has its own accounts.
The Connect screen lists one under **Hosted providers**, below the self-hosted
options, and never selects it for you. Choosing it signs you in to the provider
(or creates an account), handles a two-factor code if your account has one,
lets you pick a workspace and node (or creates one), and then connects to that
node directly, just like the paths above.

[Hearthlaunch](https://hearthlaunch.com) is one such provider and the default
listing. To list a different one, or hide the option, set
`HEARTHLOOM_PROVIDER_NAME` / `HEARTHLOOM_PROVIDER_URL` in your
`Config/Signing.local.xcconfig` (an empty URL hides it). The provider API the
app calls is described in [docs/node-api.md](docs/node-api.md#hosted-provider-api).

## Security posture

- Device PAT scoped **`read,ingest,notify`** only — never `write`/`admin`/`peer`.
- Stored in the Keychain with `.userPresence` (Face ID / passcode) access control,
  `WhenUnlockedThisDeviceOnly`.
- Face ID gate on app open, plus a separate Face ID gate on vault unlock
  (`POST /v1/vault`).
- No private (`scope='private'`) data is ever persisted on device. Vault unlock is
  a transient, Face ID-gated, time-boxed request to the node.
- Device adapters send **metadata only** where noted (e.g. photo *locations*,
  never the images; contact fields, not full histories).
- **App Transport Security.** A self-hosted node is often reached over plain
  `http` on a home network (e.g. `http://192.168.1.20:43278`), while a node
  reachable from anywhere should use TLS. The app sets only
  `NSAllowsLocalNetworking`: `http` works for local addresses (IP addresses,
  `.local` names, single-label host names) and every other host needs `https`.
  There is no `NSAllowsArbitraryLoads`.
- A privacy manifest (`Resources/PrivacyInfo.xcprivacy`) declares no tracking,
  no tracking domains, no collected data types, and one required-reason API:
  `UserDefaults`, read and written only by the app itself (`CA92.1`).

## Project layout

```
Sources/Hearthloom/
  App/        HearthloomApp (@main), AppState (launching/locked/needsConnection/connected)
  Models/     Connection
  Services/   KeychainStore, BiometricGate, LoginFlow (Connect screen engine),
              HostedProvider + HostedProviderClient (optional hosted sign-in),
              HearthAPI (node client) + Ingest / Notifications / Health / Photos /
                SyncStatus / Capture extensions,
              DeviceAdapters (app-level lifecycle), IngestGate (serializer),
              HealthKitIngest, PhotoLocationIngest, ContactsIngest, CalendarIngest,
              RemindersIngest, MotionIngest, MediaIngest, LocationVisitsIngest,
              VisionScanIngest, FocusIngest (+ FocusFilterIntent, FocusEventStore),
              CaptureIntent, CaptureQueue, CaptureService, CaptureKeyStore,
              HealthAnchorStore, HealthModels, PhotoModels, DeviceSync,
              PairingPayload, VaultStatus,
              Observability (Sentry bootstrap)
  Views/      RootView, LockView, ConnectView, ShellView, WebDashboardView,
              ReconnectSheet, NotificationsView, VaultView, SettingsView,
              DataSourcesChecklist, AdapterView, HealthView, PhotosView,
              ScanView, SyncHistoryView, CaptureView, QuickCaptureSheet,
              QRScannerView, HearthTheme
Sources/HearthloomControls/  Lock Screen / Control Center control (iOS 18+)
Sources/Shared/              OpenCaptureIntent (compiled into app + extension)
Resources/                   Asset catalog (app icon), PrivacyInfo.xcprivacy
Tests/HearthloomTests/       83 unit tests (API client, connection, notifications,
                             health, photos, adapter payloads, capture queue/key,
                             hosted-provider client, trace propagation); 2 of
                             them run only against a live node
Tests/HearthloomUITests/     7 UI tests: 5 offline (Connect screen, capture
                             control) + 2 live end-to-end Connect/capture tests
Config/                      Signing.xcconfig (+ your gitignored Signing.local.xcconfig)
design/app-icon/             Icon source: render-icon.swift → icon.svg + icon-1024.png
docs/
  node-api.md                The node (and hosted provider) API the app calls
project.yml                  xcodegen spec (source of truth for the .xcodeproj)
project.sentry.yml.example   Opt-in Sentry overlay template (copy to enable)
Scripts/generate.sh          Project generator (+ optional feature overlays)
```

## Testing

```bash
xcodebuild test -project Hearthloom.xcodeproj -scheme Hearthloom \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

The unit suite (83 tests) covers the API client, models, notifications,
HealthKit mapping, photo records, each adapter's payload builder, the capture
queue and capture key, the hosted-provider client and listing, and Sentry trace
propagation. The UI suite (7 tests) checks the Connect screen and the capture
control with no node at all (5 tests) and walks the real Connect and capture
flows against a node (2 tests).

Four tests need a live node and skip unless you point them at one — use a
throwaway node, since they create keys and captures there:
`TEST_RUNNER_HLIOS_CAPTURE_LIVE_URL` / `TEST_RUNNER_HLIOS_CAPTURE_LIVE_PAT` for
the two capture unit tests, and `TEST_RUNNER_HLIOS_BASE_URL` /
`TEST_RUNNER_HLIOS_PAT` for the two end-to-end UI tests.

## Privacy

The app talks only to the node you connect it to, plus Sentry if you build it
with the Sentry overlay and opt in with your own DSN (see above). If you choose
a hosted provider, the app also calls that provider's account API while you
sign in and pick your node. There is no analytics, advertising or tracking SDK,
and no server run by this project. Each device source sends data only after you
connect it, and only to your node.

## Security

Please report vulnerabilities privately through this repository's **Security**
tab (**Report a vulnerability**) rather than in a public issue.

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Metavert LLC.
