# (Open Source) Sync Contacts for Google

Free, private, **two-way** contacts sync between an iPhone and a Google account — in the background, with no contact limits, no subscription, and no ads. By [Open Apps Studio](https://github.com/Open-Apps-Studio).

_iOS app — submitted to the App Store (in review)._

**Why it exists:** iOS's built-in Google account sync mirrors Google contacts as a *separate* address book — it never merges them with your iCloud/on-device contacts. The apps that fix this typically charge up to ~$1.99/week behind a ~40-contact free cap. This one is free, open source, and never sends your contacts to a server.

## What it does

- **True two-way merge** — keeps your on-device (`CNContactStore`) contacts and your Google contacts in sync, matching by identity and reconciling field-by-field, so an edit on either side lands on the other.
- **Runs in the background** — the app schedules background refreshes and is woken by silent push so it stays in sync without you opening it. It also syncs immediately whenever you open it.
- **Preview before the first sync** — see exactly what will be added, updated, or linked before anything is written.
- **Safety rails** — automatic vCard snapshots with one-tap restore, plus a *deletion guard* that pauses any sync that would wipe out a large chunk of either side.
- **Explore with no account** — a built-in preview mode walks the whole app on clearly-labeled sample data, writing nothing.

## How it's built

Contacts and Google tokens **never touch a server** — all reading, matching, merging, and writing happens on the phone.

- **On-device sync engine (`ios/SyncEngine/`, Swift)** — a standalone Swift package: PKCE OAuth for a Google iOS client (no client secret), a Google People API client, identity matching, a three-way merge engine, a deletion guard, SQLite-backed mapping/snapshot stores, and a sync orchestrator. Fully unit-tested and UI-independent.
- **iOS app (`ios/App/`, SwiftUI)** — the screens (welcome, connect, first-sync preview, dashboard, sync health, backups, activity log, settings) plus background-task scheduling and Keychain token storage.
- **Push-scheduler backend (`backend/`, Node.js 20 + Express)** — deliberately knows nothing about you. It only stores APNs device tokens and sends periodic **silent background pushes** (`content-available: 1`) so iOS wakes the app to run its own sync. One runtime dependency (`express`); APNs is spoken directly over `node:http2` with an ES256 provider JWT. Storage is pluggable: in-memory or Azure Table Storage.
- **Marketing / SEO site (`site/`)** — static site with the privacy policy and support pages (built for Azure Static Web Apps).

## Repository layout

```
ios/
  App/                 SwiftUI app (screens, background tasks, Keychain)
  SyncEngine/          Swift package: OAuth, People API, matching, merge, stores
  project.yml          XcodeGen project definition
backend/               Express push-scheduler API (+ tests, Azure deploy guide)
site/                  Static marketing/SEO site + privacy policy
marketing/             App icon + marketing screenshot generators (HTML → PNG)
appstore-screenshots/  Exported App Store screenshots at required sizes
```

## Build & run

**iOS** (requires macOS + Xcode 15+ and [XcodeGen](https://github.com/yonsson/XcodeGen)):

```bash
cd ios
xcodegen generate          # writes ContactsSync.xcodeproj from project.yml
open ContactsSync.xcodeproj # then build/run the ContactsSync scheme
```

Before a real Google sign-in, supply your own **Google iOS OAuth client ID** in `ios/App/Sources/Config.swift` (and the matching reversed-client-ID URL scheme in `Info.plist` / `project.yml`), and point `backendBaseURL` at your deployed backend.

**Backend:**

```bash
cd backend
npm install
npm start   # listens on :8080; with APNs unconfigured the dispatcher no-ops
npm test    # node:test suite, no network required
```

See [`backend/README.md`](backend/README.md) for the API and configuration, and [`backend/azure-deploy.md`](backend/azure-deploy.md) for a copy-paste Azure deployment.

## Privacy

Your contacts move directly between your device and your own Google account over HTTPS. The backend never receives contacts or Google tokens — only an opaque APNs device token used to schedule background wake-ups. Google sign-in uses Google's own OAuth flow on-device; the resulting tokens are stored only in the device Keychain and are never transmitted to us.

## Configuration note

This repository ships with **placeholder** identifiers only — the Google OAuth client ID, backend URL, and Apple Team ID are stubs (`YOUR_CLIENT_ID`, `YOUR_BACKEND.example.com`, `TEAMID1234`). No API keys, `.p8` certificates, or other secrets are included; every runtime secret is read from environment variables. Provide your own before building or deploying.

## License

[MIT](LICENSE). "Google", "Google Contacts", and related marks are trademarks of Google LLC; this project is independent and not endorsed by or affiliated with Google.
