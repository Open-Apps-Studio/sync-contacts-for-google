# free-contacts-sync-backend

Tiny privacy-first backend for **Free Contacts Sync for Google** (iOS, bundle id
`com.openappsstudio.contactssync`).

The app syncs iPhone contacts with Google Contacts **entirely on-device**. This
backend does exactly one thing: it stores APNs device tokens and periodically
sends **silent background pushes** (`content-available: 1`) so iOS wakes the app
to run its sync. It never sees contact data, Google tokens, or anything else.

- Single runtime dependency: `express`. APNs is implemented with `node:http2`
  and `node:crypto` (ES256 provider JWT, cached ~45 min).
- Storage behind a small `DeviceStore` interface: in-memory (optionally
  persisted to a JSON file) or Azure Table Storage via its REST API (no SDK).

## API

| Method | Path                | Description |
| ------ | ------------------- | ----------- |
| POST   | `/v1/device`        | Register/refresh a device. Body: `{"token": "<64+ hex chars>", "cadenceMinutes": 20}` (cadence optional, integer 15–240, default 20). Returns `204`. `400` on invalid input. |
| DELETE | `/v1/device/:token` | Unregister. Always `204` (idempotent). |
| GET    | `/healthz`          | `{"ok": true, "devices": <n>, "lastDispatchAt": <ISO string or null>}` |

JSON bodies are limited to 4 KB. Device tokens are normalized to lowercase and
never written to logs.

## Dispatcher

Every `PUSH_INTERVAL_MIN` minutes (default 20) the dispatcher scans the store
and, for each device whose own `cadenceMinutes` has elapsed since its last
push, POSTs `/3/device/{token}` to APNs with:

- `apns-topic: com.openappsstudio.contactssync`
- `apns-push-type: background`, `apns-priority: 5`
- payload `{"aps":{"content-available":1}}`

Responses: `200` updates `lastPushAt`; `410`/`Unregistered`/`BadDeviceToken`
deletes the device; `429`/`5xx`/transport errors are skipped and retried next
cycle. Sends run at most 10 at a time over a single HTTP/2 session that
reconnects on GOAWAY/errors.

## Run locally

```bash
cd backend
npm install
npm start          # listens on :8080; APNs unconfigured -> dispatcher no-ops
npm test           # node --test, no network needed
```

Register a fake device and check health:

```bash
curl -i -X POST localhost:8080/v1/device \
  -H 'content-type: application/json' \
  -d '{"token":"'"$(printf 'a%.0s' {1..64})"'","cadenceMinutes":30}'
curl localhost:8080/healthz
```

## Configuration (environment variables)

| Variable | Default | Notes |
| --- | --- | --- |
| `PORT` | `8080` | HTTP port (App Service sets this automatically). |
| `APNS_KEY_P8` | — | Contents of the `.p8` APNs auth key (PEM). Literal `\n` escapes are accepted, so it can be pasted as a single-line app setting. |
| `APNS_KEY_PATH` | — | Alternative: path to the `.p8` file. |
| `APNS_KEY_ID` | — | Key ID of the APNs auth key. |
| `APNS_TEAM_ID` | `TEAMID1234` | Apple Developer team ID (10 chars). |
| `APNS_TOPIC` | `com.openappsstudio.contactssync` | App bundle id. |
| `APNS_ENV` | `production` | `production` or `sandbox` (uses `api.sandbox.push.apple.com`). |
| `PUSH_INTERVAL_MIN` | `20` | Dispatcher scan interval in minutes. |
| `STORE` | `memory` | `memory` or `azure`. |
| `MEMORY_STORE_FILE` | — | Optional JSON file path so the memory store survives restarts (e.g. `/home/data/devices.json` on App Service — `/home` is persistent). |
| `AZURE_TABLES_ACCOUNT` | — | Storage account name (STORE=azure). |
| `AZURE_TABLES_KEY` | — | Storage account key (SharedKeyLite auth). |
| `AZURE_TABLES_SAS` | — | Alternative to the key: a table-service SAS. |
| `AZURE_TABLES_TABLE` | `devices` | Table name (created automatically). |

If the APNs key/key ID are missing, the server still starts; the dispatcher
logs `APNs not configured` once and no-ops, which makes local development
instant.

## Deploy to Azure App Service (Linux, Node 20, single instance)

See [azure-deploy.md](./azure-deploy.md) for copy-paste `az` CLI commands and
[deploy-workflow.yml.sample](./deploy-workflow.yml.sample) for a GitHub Actions
stub (copy it to `.github/workflows/deploy-backend.yml` at the repo root).

Minimum app settings for production:

```
STORE=azure
AZURE_TABLES_ACCOUNT=<account>
AZURE_TABLES_KEY=<key>
APNS_KEY_P8=<contents of AuthKey_XXXXXXXXXX.p8, \n-escaped>
APNS_KEY_ID=<key id>
APNS_ENV=production
WEBSITE_NODE_DEFAULT_VERSION=~20   # or use the NODE|20-lts runtime
```

Keep **Always On** enabled and the instance count at 1 — the dispatcher is a
simple in-process interval and assumes a single writer.

## Layout

```
src/server.js         entry point (wires config, store, APNs, dispatcher)
src/app.js            express app factory (routes, validation, headers, logging)
src/apns.js           ES256 JWT provider + http2 APNs client
src/dispatcher.js     periodic push loop (cadence, prune, retry, concurrency)
src/store/memory.js   MemoryDeviceStore (+ optional JSON file persistence)
src/store/azureTable.js  Azure Table Storage REST adapter (SharedKeyLite/SAS)
src/config.js         env parsing
test/                 node:test suites (no network required)
```
