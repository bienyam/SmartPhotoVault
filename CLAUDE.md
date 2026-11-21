# TidyAway — project notes for Claude

iPhone app for phone and cloud storage cleanup and archiving. Display name **TidyAway**; the repo, bundle id (`com.bienyam.SmartPhotoVault`) and IAP id (`com.bienyam.SmartPhotoVault.storagepro`) keep the old name on purpose.

## Product
- Goal: small versions on the phone, full resolution in iCloud, and a third-party store as a true archive that can be pulled back on demand.
- Archive destinations: Google Drive first (through Files), home file server, iCloud Drive, other Files locations. More "plugins" later, by demand.
- Tabs: Home, Clean, Archive, Archived, Ledger.
- Pricing plan: free analysis plus a one-time Pro unlock ($4.99 or $7.99, undecided). Never weekly subscriptions.
- Owner prefers brief, direct updates and iterating in small steps.

## Rules that must hold
- Sign-off before any copy, removal or restore: an unchecked acknowledgment and a disabled button. Wording comes from `ACTION_AUTHORIZATION.md`; do not reword it casually.
- Removal after archiving stays switched off until copy and restore are proven on a physical iPhone (see `PHONE_TEST_CHECKLIST.md`).
- Category removal: nothing pre-selected, favorites can't be picked, bursts stay review-only.
- Never remove favorites; always keep one copy of a duplicate group.
- Activity log records approvals and outcomes without file names.
- Do not trigger a TestFlight upload unless the owner asks for a build.
- Only one agent changes the code at a time.

## Platform limits (already researched)
- Google Photos API cannot read an existing library; use Google Drive through Files.
- No API to toggle Optimize Storage.
- PhotoKit deletion syncs to iCloud, shows Apple's own confirmation, and items sit in Recently Deleted for 30 days.
- Messages "Large Attachments" and Apple's face groups are not available to apps; Photos does not record the source app (memes are a heuristic, review-only).

## Design
Brand set by the Sweep app icon (tangerine, photos swept up into a cloud, archive and restore arrows, iPhone-style storage bar). All colours live in `Sources/Brand.swift`: primary tangerine `#C8501F` (dark `#FF8A5C`), cream background `#FFF7EE`, peach surface `#FFE7D3`, green only for safe/done, amber for cautions, never red. Never add colour literals; add a `Brand` role instead. Wordmark is **TidyAway** (capital T and A). Calm, "rescue" tone. Icon source art lives outside the repo (`promo/`, untracked); export at 1024×1024 RGB with no alpha.

## Build and CI
- Swift/SwiftUI, PhotoKit, SQLite (`InventoryStore`), XcodeGen (`project.yml`), iOS 17 target.
- `.github/workflows/ios.yml`: package checks and simulator tests including UI tests. One simulator step has a 5-minute timeout that sometimes flakes; re-run failed jobs.
- `.github/workflows/app-store.yml`: screenshots on PRs; `workflow_dispatch` with `upload: true` on main signs and uploads to App Store Connect. Build number is `run_number.run_attempt`.
- TestFlight: internal group **TidyAway Testers** has automatic distribution for Xcode builds, so every upload reaches testers. The older "Internal iPhone Testing" group is manual and can be deleted.
- The Photos-permission UI tests (`testPrepareFullPhotoAccess`, `testDeniedPhotosAccessShowsSettings`) occasionally time out on the system dialog; re-run before investigating.
- UI tests launch with `--skip-welcome`; `--demo` uses sample data; `--reset-welcome` shows the welcome screen.
- Work in small PRs, squash-merge when CI is green.

## Status
Merged: rename and icon, welcome screen and tabs, duplicate removal with sign-off, Archive tab filters and review, encryption declaration (#16, `ITSAppUsesNonExemptEncryption: false`), Archived tab with restore plus Ledger tab (#18), Clean tab categories by type (#21: screenshots, GIFs, bursts, Live Photos, slo-mo, time-lapse, panoramas; review-only), "Maybe saved from chats or the web" heuristic and Messages attachments guide (#22), Sweep app icon (#23), TidyAway Pro on Home and Ledger (#24), Archive album and place filters, video suggestions and single-file video archiving (#25), category removal with sign-off (#26), brand colours and refined icon (#27).
Open: #9 and #10 are older PRs from a previous agent that overlap main; close only if confirmed superseded.

Scans saved before #21 or #25 show "Scan again" for categories or album/place filters. Location is stored rounded to about 1 km; the privacy text says so.

## Next
1. Owner runs `PHONE_TEST_CHECKLIST.md` on a physical iPhone with throwaway items: duplicate and category removal, archive copy/verify/restore including video, Pro sandbox purchase. The app has been installed on the owner's iPhone via TestFlight, but these flows haven't been checked there.
2. Fix whatever that finds; only then consider removal after archiving.
3. Promo page and marketing artwork are parked by the owner.

Owner to-dos: trademark clearance for the name, consider making the repo private, pick the Pro price, counsel review of the `ACTION_AUTHORIZATION.md` wording.
