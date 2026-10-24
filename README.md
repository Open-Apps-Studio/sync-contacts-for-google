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

## Website SEO and publishing

The production website is https://sync.openappsstudio.com, hosted on Vercel in
`sync-contacts-for-google`. The production source is
`Open-Apps-Studio/sync-contacts-for-google`, branch `master`, deployed from `site/`
using the Vercel CLI. There is no automatic Git deployment integration.

The October 24, 2026 website update adds 20 distinct articles under `/blog/`, a
categorized guide hub and an editorial/about page. The four established guide
URLs are preserved and refreshed. Content covers setup/accounts, transfers and
imports, backups/recovery, and troubleshooting. These are intent-led topics,
not claims of measured keyword volume or guaranteed rankings. App Store title,
subtitle, keywords and screenshots are outside this website change.

Article sources are editable JSON files in `content/blog/`. Each includes the
search title, description, direct answer, sections, related guides, official
references, publication/update dates and a unique Apple campaign token.
Generated HTML is checked in so production needs no runtime or build service.
Edit a source file, update its date only for a substantive revision, and run:

```bash
python3 scripts/build_blog.py
python3 scripts/check_site.py
python3 -m http.server 8765 --directory site
```

The builder generates the 20 articles, guide hub, robots.txt and canonical
sitemap. Other existing pages remain hand-authored. The checker validates
internal links/fragments, metadata, article/breadcrumb JSON-LD, campaign links,
verification-tag preservation, redirects and exact sitemap coverage. It can
also compare every deployed page with the local source:

```bash
python3 scripts/check_site.py --base-url https://sync.openappsstudio.com
```

Deploy from the verified production checkout and its existing Vercel project
binding, using `vercel deploy --prod --yes` from `site/`. Check the custom domain,
the four original guide URLs, `/blog/`, the legacy App Store redirect, a genuine
404, and default-host redirects after release. Never deploy the separate
`deployment/azure-redirect/` retirement bundle to Vercel. Rebuild that bundle
with `python3 scripts/build_legacy_redirect.py` when canonical paths change.

Measurement: use the canonical custom-domain property in Search Console for
indexing, selected canonicals, queries, clicks, impressions and CTR. Compare
28-day periods by page and country; keep the older Vercel property as migration
context. Its observed three-month baseline on October 24 was 10 clicks, about
2,970 impressions, 0.3% CTR and average position 41.9. This is not a baseline for
the new articles or the custom domain. Preserve existing Apple campaign tokens;
new article tokens are in the content files. Apple may withhold campaign results
below its reporting thresholds, so missing campaign data does not prove zero
visits. No client-side analytics or tracking cookies were added.

Search Console verification and sitemap submission are account actions, not
something the build script can prove. Check the actual property status after
publishing. A submitted sitemap does not guarantee indexing or rankings.

Editorial basis: Google's people-first content and canonicalization guidance,
plus Apple/Google product documentation linked inside each guide. The site uses
static readable HTML, internal links, descriptive titles and accurate schema;
it does not use fabricated reviews, keyword stuffing, or duplicate city pages.
