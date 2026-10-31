# SmartPhotoVault

Native iOS photo inventory app, built with SwiftUI and PhotoKit. The selected strategy is full-resolution copies on iPhone, iCloud Photos, and Google Photos. See PROJECT_SPEC.md for the full scope.

## Current milestone

Read-only Apple Photos permissions, metadata counts, streamed SHA-256 resource hashing, exact duplicate groups, sample data, scan progress and cancellation, a SQLite inventory, and a local activity log. No photo uploads, edits, or deletions. Google Photos and visually similar matching are later milestones.

Duplicate matching requires identical resource types, byte counts, and SHA-256 hashes for every resource. This includes paired Live Photo videos and available edit resources. A failed resource read excludes the entire asset from exact matching. This intentionally favors missed matches over unsafe suggestions. Asset-level metadata such as album membership is not part of the content fingerprint; matching content never authorizes deletion. Favorites are labeled for preservation. No keep/delete recommendation is made for other assets until protected albums and full destination evidence are available.

Cloud downloads are disabled by default. Unreadable/cloud-only assets are listed as unverified. Even a successful resource read is evidence at scan time, not a guarantee of permanent local retention or an independent iCloud backup. Snapshot results must be refreshed after library changes. Google and iCloud destination counts and usage remain unknown, rather than invented. Candidate bytes are calculated resource totals, not provider-reported usage or guaranteed reclaimable space. Cancellation stops after the current resource request completes; large resources or enabled cloud downloads may delay it.

Explore sample results without granting Photos access. Synthetic data stays in memory and is clearly labeled; it does not replace the saved real inventory. Automated tests exercise multi-resource matching, unreadable assets, favorite ordering, resource multiplicity, and SQLite persistence.

## Local database schema

`snapshot(id INTEGER PRIMARY KEY CHECK(id=1), payload TEXT NOT NULL)` stores the latest completed scan as a version-one JSON document containing asset identifiers, names, dates, favorite flags, resource hashes and byte counts, access scope, download policy, and read errors. Incomplete/cancelled scans never replace the saved snapshot. `activity(id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp REAL NOT NULL, message TEXT NOT NULL)` records scan events. Both tables live in Application Support/SmartPhotoVault/inventory.sqlite. Save and completion-log updates share a transaction. The log UI shows the latest 100 events; older events remain in SQLite. No photo data or credentials are stored in this database.

## Build on a Mac

Requires Xcode with iOS 17+ SDK and XcodeGen (`brew install xcodegen`). Run `xcodegen generate`, then open `SmartPhotoVault.xcodeproj`. Select the SmartPhotoVault scheme and an iPhone simulator, then Run or Test. The generated project is intentionally ignored by Git; project.yml is its source.

## Build from Windows using GitHub

Push this project to GitHub and open the repository's Actions tab. The iOS build and tests workflow generates the project and runs unit tests and a sample-data UI test on a hosted Mac. Download dashboard-preview for a screenshot of the app and simulator-test-results for the Xcode result bundle. A successful simulator build does not produce an app installable on a physical iPhone. Apple Developer enrollment, signing, and TestFlight distribution will be configured separately. No signing credentials are needed for this workflow. GitHub runner usage is subject to your plan and billing settings.

## Device installation later

The initial project disables signing for simulator builds. A later signed device workflow must override CODE_SIGNING_ALLOWED and configure your Apple team, certificates, and provisioning profile. Never commit signing credentials or personal photo datasets.

## Manual checks before device release

- Try full, limited, denied, and restricted photo access.
- Change access in Settings, return, and rescan.
- Confirm displayed counts against the accessible library, including videos and favorites.
- Confirm iCloud-only assets are counted without claiming their originals are stored locally.
- Check VoiceOver and larger text sizes.

Windows cannot validate the SwiftUI/PhotoKit runtime; the first cloud build and later device testing are required before calling this foundation verified.
