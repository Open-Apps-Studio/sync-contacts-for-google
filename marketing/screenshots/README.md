# App Store Marketing Screenshots — Free Contacts Sync for Google

Five App Store marketing screenshots for the iPhone 6.7-inch display slot, built as
self-contained HTML (no external requests, system font stack) and rendered to PNG with
headless Chrome.

## Files

| # | HTML source | Final PNG | Message |
|---|-------------|-----------|---------|
| 1 | `01-hero.html` | `01-hero.png` | "Your iPhone & Google contacts. One list." — dashboard, in-sync state, Sync Now |
| 2 | `02-free.html` | `02-free.png` | "Free. No catch." — factual comparison vs. the leading paid app, $0.00 forever |
| 3 | `03-preview.html` | `03-preview.png` | "See exactly what will happen." — First Sync Preview with counts and backup notice |
| 4 | `04-safety.html` | `04-safety.png` | "Impossible to lose a contact." — deletion guard alert + restorable snapshots |
| 5 | `05-private.html` | `05-private.png` | "Private by design." — direct iPhone ⇄ Google diagram, no servers, Data Not Collected |

All PNGs are exactly **1290 × 2796 px** (portrait).

## App Store Connect upload spec

- **Slot:** iOS App → (version) → App Previews and Screenshots → **iPhone 6.7" Display**
  (iPhone 15 Pro Max / 15 Plus / 14 Pro Max class).
- **Size:** 1290 × 2796 px portrait (these files match exactly; no resizing needed).
- **Format:** PNG, no transparency, RGB. ✔ as produced here.
- **Count:** up to 10 per localization; upload these 5 in the numbered order — the first
  2–3 are what most users see in search results, so keep `01-hero` and `02-free` first.
- Apple auto-scales the 6.7" set for smaller devices; supply a 12.9" iPad set separately
  only if the app ships for iPad.

## Regenerating

```bash
cd marketing/screenshots
for f in 01-hero 02-free 03-preview 04-safety 05-private; do
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
    --headless=new --disable-gpu --screenshot=$f.png \
    --window-size=1290,2796 --hide-scrollbars --force-device-scale-factor=1 \
    "file://$(pwd | sed 's/ /%20/g')/$f.html"
done
```

## Visual system

- Background: brand blue diagonal gradient `#3b82f6 → #1e40af` (135°).
- Headline: white, 106 px, weight 800, −0.02 em tracking, max 2 lines; subline 44 px at
  `rgba(255,255,255,.85)`. ~100 px side margins throughout.
- Device: hand-built CSS iPhone frame (104 px outer corner radius, thin dark bezel,
  Dynamic Island pill, 9:41 status bar) pinned at y = 640 and bleeding off the bottom edge.
- App screens: light iOS style — `#f2f2f7` grouped background, white cards (40 px radius
  ≈ 18 pt at ~2.3× scale), iOS blue `#2563eb` accents, green `#34c759`/`#28a745` success,
  amber deletion-guard card, SF-symbol-style icons rebuilt as inline SVG.
- App icon motif (white person silhouette inside circular sync arrows on blue) is rebuilt
  in SVG and used in every screen's header for brand continuity.
- Competitor in `02-free` is intentionally unnamed ("The leading paid app") and the
  comparison sticks to factual claims (40-contact free cap, $1.99/week, rating pop-ups).
