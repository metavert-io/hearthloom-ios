# Node API used by the iOS app

What Hearthloom for iOS calls on a Hearthloom node, and the optional hosted
provider API it calls during sign-in. The server is
[metavert-io/hearthloom](https://github.com/metavert-io/hearthloom); its
authoritative client contract is
[`docs/mobile-client-contract.md`](https://github.com/metavert-io/hearthloom/blob/main/docs/mobile-client-contract.md),
and the routes live in
[`crates/hearthloom-daemon/src/http.rs`](https://github.com/metavert-io/hearthloom/blob/main/crates/hearthloom-daemon/src/http.rs).
When this page and the server disagree, the server wins.

The phone is an **authenticated client and on-device adapter host**, never a
peer. It holds no database, runs no daemon and never calls `/v1/sync/*`. It
talks to a node like the CLI or the dashboard does: HTTP plus a scoped bearer
token, with writes carrying an actor identity and idempotency keys.

## Base URL and transport

`<baseURL>` is the node's origin: `http://192.168.1.20:43278` for a node on
your home network, or `https://node.example.com` for one reachable from
anywhere. App Transport Security allows plain `http` only for local addresses
(IP addresses, `.local` names, single-label host names); everything else must
be `https`.

## Authentication

- A node with a user account is *locked*: every route except a short
  pre-auth list needs either `Authorization: Bearer <token>` or a live
  `hl_session` cookie. The pre-auth list includes `/health`, `/v1/auth/login`
  and `/v1/auth/me`.
- The app's long-lived credential is a **device token** scoped
  `read,ingest,notify` — never `write`, `admin`, `peer` or `mcp`. It is kept in
  the Keychain behind Face ID / the passcode.
- The dashboard web view uses an `hl_session` cookie, minted from the device
  token (see `session-from-key` below) or captured at sign-in.
- Scopes and scoped-key grants are defined in
  [`crates/hearthloom-core/src/store/api_keys.rs`](https://github.com/metavert-io/hearthloom/blob/main/crates/hearthloom-core/src/store/api_keys.rs).

## Connecting

### `GET /health` (pre-auth)
Reachability probe: `200 {"service":"hearthloom","status":"ok","version":"…"}`.
The app calls it before asking for credentials.

### `POST /v1/auth/login` (pre-auth)
Send `Accept: application/json` to get the JSON contract instead of the
browser redirect. Body, one of:
```jsonc
{ "email": "ada@example.com", "password": "…" }   // the node's own account
{ "issuer_token": "<base64url(payload)>.<base64url(hmac)>" }   // from a hosted provider
```
Success: `200 {"ok":true}` plus `Set-Cookie: hl_session=…; HttpOnly`.
Failure: `401 {"error":"…"}`. The app reads the cookie from this response and
uses it once, to mint the device token.

### `POST /v1/keys` — mint the device token (with the session cookie)
```json
{ "actor": "adapter:ios-<device>", "name": "<device> (Hearthloom iOS device PAT)",
  "scopes": ["read", "ingest", "notify"] }
```
Reply: `{"key": {…}, "secret": "hl_…"}`. The secret appears in this response
only. The key shows up in the dashboard's **API Keys** list, where it can be
revoked.

### Device token supplied by the user
A pasted or scanned token is checked with `GET /health`, then
`GET /v1/stats` with `Authorization: Bearer <token>` (not a pre-auth route,
so a `200` proves the token works).

### Pairing QR
The dashboard's **Integrations → Pair a device** card
([`assets/integrations.js`](https://github.com/metavert-io/hearthloom/blob/main/crates/hearthloom-daemon/assets/integrations.js))
mints a `read,ingest,notify` token and shows it as a QR code:
```
hearthloom://pair?url=<percent-encoded origin>&pat=<percent-encoded token>
```
The app parses it (`PairingPayload`) and connects exactly as with a pasted
token.

### `GET /v1/auth/me`
`{"auth":"required"|"open","user":<row|null>,"killswitch":<bool>}`. The app
uses it to tell whether the web view's session is signed in.

### `POST /v1/auth/session-from-key`
`Authorization: Bearer <device token>` (needs `read`) →
`200 {"ok":true}` + `Set-Cookie: hl_session=…`. Lets the web view sign in from
the stored token on every launch, with no password.

## Using the node

| Endpoint | Used for |
|---|---|
| `GET /v1/vault`, `POST /v1/vault {actor, action: "unlock"\|"lock", minutes}` | the Face ID-gated vault unlock (`minutes` 1–60) |
| `GET /v1/notifications`, `POST /v1/notifications/read-all`, `POST /v1/notifications/{id}/read` | the Alerts tab (`notify` scope) |
| `GET /v1/ingest/status`, `GET /v1/ingest/recent?offset=&limit=` | Settings → Sync history |

### Device ingest
Every adapter posts with the device token (`ingest` scope), a body of
`{actor, source, device, …}` and gets `{"accepted": <int>, "duplicates": <int>}`
back. Re-sending is safe: each source deduplicates on its own key, and the
server clusters locations across sources. Times are RFC 3339 UTC.

| Endpoint | Adapter | `source` | Records |
|---|---|---|---|
| `POST /v1/ingest/health` | Apple Health | `apple-health` | `samples[]`, `workouts[]` (below) |
| `POST /v1/ingest/photos` | Photo locations | `photos` | `photos[{key, filename, taken_at, tz_offset_minutes, lat, lon}]` |
| `POST /v1/ingest/contacts` | Contacts | `contacts` | `items[{key, name, emails[], phones[], org?, postal[]}]` |
| `POST /v1/ingest/calendar` | Calendar | `calendar` | `items[{uid, title, start, end, location?, attendees[], tz_offset_minutes}]` |
| `POST /v1/ingest/reminders` | Reminders | `reminders` | `items[{uid, title, due?, completed, list}]` |
| `POST /v1/ingest/motion` | Motion | `ios-motion` | `items[{key, mode, start, end, tz_offset_minutes}]` |
| `POST /v1/ingest/media` | Music & podcasts | `ios-media` | `items[{key, kind: "song"\|"podcast", title, played_at, artist?, show?, album?, duration_s?}]` |
| `POST /v1/ingest/location` | Location & visits | `ios-visits` | `items[{key, lat, lon, t_start, t_end?, tz_offset_minutes, accuracy_m?}]` |
| `POST /v1/ingest/scan` | Document scan | `ios-scan` | `items[{key, kind: "receipt"\|"card"\|"document", ocr_text, captured_at, tz_offset_minutes}]` |
| `POST /v1/ingest/focus` | Focus | `ios-focus` | `items[{key, state, since, until?}]` |

The exact item shapes are in each adapter's payload builder (`Services/*Ingest.swift`,
`HealthModels.swift`, `PhotoModels.swift`) and their tests.

Apple Health samples are keyed by the HealthKit sample UUID:
```jsonc
{
  "actor": "adapter:ios-healthkit", "source": "apple-health", "device": "iPhone",
  "samples": [{
    "uuid": "<HKSample.uuid>", "metric": "StepCount", "value": 120.0, "unit": "count",
    "category": "AsleepDeep",            // category samples only
    "source": "Apple Watch",
    "start": "2026-07-24T08:00:00Z", "end": "2026-07-24T08:05:00Z",
    "tz_offset_minutes": -240
  }],
  "workouts": [{ "uuid": "…", "activity": "37", "start": "…", "end": "…",
                 "energy_kcal": 320.0, "distance_m": 5000.0,
                 "source": "Apple Watch", "tz_offset_minutes": -240 }]
}
```
Live samples update the node's health index straight away; the daily
`health_day` summary is written once the day has closed, never rewritten
during the day.

A `404` from an ingest endpoint means the node is older than the adapter; the
app keeps the data and tries again later.

### Quick capture: `POST /v1/ingest/capture`
```jsonc
{ "text": "call the plumber",            // required; empty or > 8,000 chars is a 400
  "captured_at": "2026-07-23T23:30:00Z", // when it was captured, not uploaded
  "client_ref": "<uuid>",                // the server dedupes on it
  "device": "iPhone",
  "lat": 12.5, "lon": -34.5 }            // optional, only with existing permission
```
Reply: `{"kind": "task"|"note", "id": "…", "duplicate": false}`; a repeated
`client_ref` returns the original id with `"duplicate": true`. The app leaves
`kind` out so the server decides. `401`/`403` keep the item queued and ask for
a reconnect, `404` (node too old) and `429` keep it queued, `400` drops it.

Captures from Siri, Shortcuts or the Lock Screen run with nobody unlocking the
app, so they use a **capture-only scoped key** rather than the device token.
The app mints it once per connection with the device token:
```json
POST /v1/keys
{ "actor": "adapter:ios-capture", "name": "iphone-capture-<device>",
  "grants": { "capture": true, "own_device": true } }
```
A scoped key takes `grants` and no `scopes`. `capture` lets it call this one
endpoint (and `/health`) and nothing else; it cannot read the node.
`own_device` marks it as one of the owner's own devices, so its captures are
recorded as the owner's own words rather than an agent's; it widens nothing the
key can reach. The node must let the owner's device token mint scoped keys
(`POST /v1/keys` with `grants` and no `scopes`). The app checks the reply
describes a capture-only key before storing it.

## Hosted provider API

Optional. Used only when you choose a provider under **Hosted providers** on
the Connect screen; the app never contacts one otherwise. A hosted provider
runs Hearthloom nodes for its users — [Hearthlaunch](https://hearthlaunch.com)
is one example. The app needs these routes on the provider's base URL
(`HostedProviderClient`):

| Route | Purpose |
|---|---|
| `POST /api/auth/login {email, password}` | sign in → `{accessToken, memberships[{tenantId, tenantName, tenantSlug, role, isRoot}]}`, or `{mfaRequired: true, mfaToken}` when the account has two-factor auth |
| `POST /api/auth/mfa/challenge {mfaToken, code}` | finish two-factor sign-in → same shape as login |
| `POST /api/auth/register {email, password, displayName}` | create an account → same shape as login |
| `GET /api/saas/instances` | the account's nodes → `[{id, name, url, ready, status}]` (or `{instances: […]}`) |
| `POST /api/saas/instances {name}` | create a node → `202 {id}`; poll `GET /api/saas/instances/{id}` until `ready` |
| `POST /api/saas/instances/{id}/open` | a short-lived login token for that node → `{url, issuerToken}` |

Calls under `/api/saas/` carry `Authorization: Bearer <accessToken>` and
`X-Tenant-ID: <tenantId>` (the workspace you picked). With `{url, issuerToken}`
the app signs in to the node itself (`POST /v1/auth/login {"issuer_token": …}`)
and mints its device token there; from then on it talks only to the node.

The node verifies the issuer token with a secret it shares with the provider
(`HEARTHLOOM_TRUSTED_ISSUER_SECRET`): `base64url(payload) "." base64url(HMAC-SHA256(secret, payload))`,
payload `{"sub": "<the node owner's email>", "exp": <unix seconds>}`. The app
only relays the token; it never signs one.
