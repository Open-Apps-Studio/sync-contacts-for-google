# App Store Screenshots — Sync Contacts for Google

Marketing screenshots (app UI mockups in iPhone frames on brand-blue backgrounds), rendered from HTML at `../marketing/screenshots/*.html`. Every folder holds the same 5 screenshots at an exact App Store Connect dimension.

| Folder | Dimensions | App Store slot |
|---|---|---|
| `6.9inch-1290x2796/` | 1290 × 2796 | iPhone 6.9"/6.7" Display — **primary required** (covers 6.7" too) |
| `6.9inch-1320x2868/` | 1320 × 2868 | iPhone 6.9" Display (16 Pro Max native) |
| `6.5inch-1284x2778/` | 1284 × 2778 | iPhone 6.5" Display |
| `6.5inch-1242x2688/` | 1242 × 2688 | iPhone 6.5" Display (alt) |

**Upload:** for a new submission Apple requires only the **6.9"** set (`6.9inch-1290x2796/`); it auto-scales to smaller slots. The others are provided so you can upload natively to any slot. The app is iPhone-only (`TARGETED_DEVICE_FAMILY = 1`), so no iPad screenshots are required.

The 5 screenshots, in order:
1. One List on iPhone and Google (dashboard, in-sync)
2. Sync your way (the three sync modes: two-way, iPhone→Google, Google→iPhone) — NOTE: this replaced the old "Free. No catch." price/competitor comparison, which was removed for App Store guideline 2.3.7. Do NOT reintroduce price figures or competitor comparisons.
3. Preview Before Sync (first-sync preview)
4. Backups and Deletion Guard (safety)
5. Private by Design (data-flow diagram)

Regenerate any size by re-running the render command in `../marketing/screenshots/` then `sips -z <h> <w>`.
