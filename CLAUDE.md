# TidyAway — project notes for Claude

iPhone app for phone and cloud storage cleanup and archiving. Display name **TidyAway**; the repo, bundle id (`com.bienyam.SmartPhotoVault`) and IAP id (`com.bienyam.SmartPhotoVault.storagepro`) keep the old name on purpose.

## Product
- Goal: small versions on the phone, full resolution in iCloud, and a third-party store as a true archive that can be pulled back on demand.
- Archive destinations: Google Drive first (through Files), home file server, iCloud Drive, other Files locations. More "plugins" later, by demand.
- Tabs: Home, Clean, Archive, Archived, Ledger.
- Pricing (owner, 2026-11-21): generous free tier; Pro is $7.99 a month (com.bienyam.SmartPhotoVault.pro.monthly, group "TidyAway Pro") or $39.99 lifetime (com.bienyam.SmartPhotoVault.storagepro), both with Family Sharing. Never weekly subscriptions.
- Owner prefers brief, direct updates and iterating in small steps.

## Simplify redesign (approved by the owner 2026-11-21)
Plan: `TidyAway_Simplify_Plan.html`. All ★ recommendations approved:
- Three tabs: **Free up** (launch tab: one "Free up space" button, then Large videos, Duplicates, Screenshots, More types), **Archive** (Move out / Get back), **More** (Activity, Analyze storage, TidyAway Pro, Tips, Help & privacy). One route to each screen, one word per thing ("Duplicates").
- Headlines are actions, never instruction pages. Extra detail goes behind an (i) popover.
- Rescue flow: list sorted by size, Select all, one short sign-off and one Apple confirmation per batch, then a result screen explaining Recently Deleted (3 picture steps; no undocumented `photos-redirect://` link). Never say "freed" until space is actually back.
- "Analyze storage & cost" becomes "Analyze storage" under More; cost stays one quiet line. The cost wizard is a Pro extra.
- Free: scan, all cleanup, restore, Activity, first 5 GB of archiving. Pro ($7.99 a month or $39.99 lifetime, Family Sharing on): unlimited archiving, archive-then-remove (once proven), archive filters, multi-file iCloud Drive download removal, storage comparisons, Activity export. Prompt only quietly under More and inline when an archive passes 5 GB.
- Archive destinations in order: drive plugged into the iPhone (format/read-only/space checks, NTFS explained, iOS 18 Files Erase → ExFAT), Google Drive via Google sign-in with the `drive.file` scope, then a free "TidyAway Receiver" desktop app (Windows first) paired by a 6-digit code. NAS only via Files "Connect to Server" for now. No storage brand recommendations, one neutral (i) tip.
- Archive destinations are write-only: TidyAway never deletes or changes anything there.

## Rules that must hold
- Sign-off before any copy, removal or restore: an unchecked acknowledgment and a disabled button. Wording comes from `ACTION_AUTHORIZATION.md` (short line, disclosure v2, full text behind (i)); do not reword it casually. One sign-off may cover a whole batch.
- Removal after archiving stays switched off until copy and restore are proven on a physical iPhone (see `PHONE_TEST_CHECKLIST.md`).
- Category removal: nothing pre-selected (Select all is fine, the user taps it), favorites can't be picked, bursts stay review-only.
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
- TestFlight: internal group **TidyAway Testers** has automatic distribution for Xcode builds, so every upload reaches testers.
- The Photos-permission UI tests (`testPrepareFullPhotoAccess`, `testDeniedPhotosAccessShowsSettings`) occasionally time out on the system dialog; re-run before investigating.
- UI tests launch with `--skip-welcome`; `--demo` uses sample data; `--reset-welcome` shows the welcome screen.
- Work in small PRs, squash-merge when CI is green.

## Status
Merged: rename and icon, welcome screen and tabs, duplicate removal with sign-off, Archive tab filters and review, encryption declaration (#16, `ITSAppUsesNonExemptEncryption: false`), Archived tab with restore plus Ledger tab (#18), Clean tab categories by type (#21: screenshots, GIFs, bursts, Live Photos, slo-mo, time-lapse, panoramas; review-only), "Maybe saved from chats or the web" heuristic and Messages attachments guide (#22), Sweep app icon (#23), TidyAway Pro on Home and Ledger (#24), Archive album and place filters, video suggestions and single-file video archiving (#25), category removal with sign-off (#26), brand colours and refined icon (#27).
Simplify redesign merged 2026-11-21:
- #31 scan results survive library changes; batch duplicate removal; honest Recently Deleted wording.
- #32 three tabs (Free up, Archive, More), cleanup lists with Select all and the short sign-off, result screen; redundant screens removed.
- #33 ProStore (app-wide, launch-time update listener), 5 GB free archive, Pro gates on album/place filters, Advanced analysis and saved comparisons. StoreKit calls hang headless in CI, so the purchase is tested only on a device.
- #34 archive folder check on pick (NTFS, FAT32, read-only, free space, test write); a drive plugged into the iPhone is the first destination.
- #35 progressive scan: biggest items first, partial results every ~1.5 s, deleting allowed during a check.
Open: #9 and #10 are older PRs from a previous agent that overlap main; close only if confirmed superseded.

Scans saved before #21 or #25 show "Scan again" for categories or album/place filters. Location is stored rounded to about 1 km; the privacy text says so.

## Next
1. Owner runs `PHONE_TEST_CHECKLIST.md` on a physical iPhone with throwaway items, including a USB-C drive and the Pro sandbox purchase.
2. Owner: add a bank account and W-9 in App Store Connect so the Paid Apps Agreement goes active (needed even for sandbox purchases). Both Pro products exist; each needs a review screenshot and goes to review with the first app version.
3. Google Drive connection built (Google Cloud project `tidyaway`, iOS OAuth client for com.bienyam.SmartPhotoVault, `drive.file` scope, consent screen in Testing with the owner as the only test user). Before public launch: publish the consent screen (needs a privacy policy URL and app home page on the Branding page) and verify with Google. Uploads stage a verified local copy first, so a nearly full iPhone may not fit a large video: stream uploads later.
4. TidyAway Receiver desktop app (Windows first): prototype after phone testing.
5. Fix whatever phone testing finds; only then consider removal after archiving. Promo stays parked.

Owner to-dos: trademark clearance for the name, consider making the repo private, counsel review of the `ACTION_AUTHORIZATION.md` wording (including disclosure v2).
