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
- Removal after archiving stays switched off until copy and restore are proven on a physical iPhone.
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
Porcelain Blue: ivory `#FCFAF5`, slate `#305270`, powder card `#E0EBF5`. Green only for safe/done, amber for cautions, no red. Calm, "rescue" tone.

## Build and CI
- Swift/SwiftUI, PhotoKit, SQLite (`InventoryStore`), XcodeGen (`project.yml`), iOS 17 target.
- `.github/workflows/ios.yml`: package checks and simulator tests including UI tests. One simulator step has a 5-minute timeout that sometimes flakes; re-run failed jobs.
- `.github/workflows/app-store.yml`: screenshots on PRs; `workflow_dispatch` with `upload: true` on main signs and uploads to App Store Connect.
- UI tests launch with `--skip-welcome`; `--demo` uses sample data; `--reset-welcome` shows the welcome screen.
- Work in small PRs, squash-merge when CI is green.

## Status
Merged: rename and icon, welcome screen and tabs, duplicate removal with sign-off, Archive tab filters and review, encryption declaration (#16, `ITSAppUsesNonExemptEncryption: false`), Archived tab with restore plus Ledger tab (#18).
Open: #9 and #10 are older PRs from a previous agent that overlap main; close only if confirmed superseded.

## Next
1. Clean tab: more categories (screenshots, GIFs, bursts, Live Photos, slo-mo/time-lapse, panoramas, chat/meme heuristic as review-only, a guide for Messages attachments).
2. Archive: album and place filters (the scan does not record these yet), video suggestions.
3. Pro upgrade placement.
4. App Store Connect: turn on automatic distribution for the internal TestFlight group (create a new internal group if the existing one cannot be edited).
5. Nothing has been tested on a physical iPhone yet: test deletion with throwaway duplicates, and archive copy and restore.

Owner to-dos: trademark clearance for the name, consider making the repo private, pick the Pro price.
