# Project: PhotoVault, Smart Photo Backup & Storage Manager

Build a native iOS application using Swift, SwiftUI, PhotoKit, and a local SQLite database.

## Objective

Create a personal photo management application for users who have photos stored across their iPhone, iCloud Photos, and Google Photos.

The application should identify duplicates, compare storage locations, monitor backup completeness, and recommend safe ways to reclaim storage.

The goal is to maintain one desired copy per storage destination, where supported, without accidentally deleting photos across synchronized services.

## Selected Storage Strategy: Option B

Maintain three desired full-resolution copies: one on the iPhone, one in iCloud Photos, and one in Google Photos.

- Treat the full-resolution original on the iPhone as a required copy; an optimized thumbnail or on-demand representation does not satisfy this requirement.
- Track each destination separately, including whether the full-resolution original has actually been verified there. Unknown or inaccessible provider state must remain unverified.
- Treat iPhone Photos and iCloud Photos as synchronized locations, not independent backups. Deleting an asset from the synchronized Photos library can affect both locations.
- Detect redundant copies within each destination without recommending removal of one of the three desired copies merely because another destination contains the same content.
- Recommendations must preserve the desired full-resolution copies, asset components, edits, and metadata. Account for synchronization effects before proposing any future cleanup.
- Report missing or unverified desired copies and insufficient local storage clearly. Do not claim the app can force system-managed original retention or verify an entire Google Photos library through limited API access.
- The MVP remains read-only: inventory accessible Apple Photos assets, identify exact duplicate candidates, and show available verification evidence. Full three-destination verification is a later milestone.

## Core Requirements

1. **Local Photo Discovery**
   - Request appropriate Apple Photos access.
   - Scan photo and video metadata.
   - Support iCloud-backed assets using PhotoKit.
   - Identify exact duplicates using content hashes.
   - Detect visually similar photos separately.
   - Preserve Live Photos, videos, originals, edits, and metadata.

2. **Google Photos Integration**
   - Implement Google OAuth authentication.
   - Integrate the supported Google Photos Picker API.
   - Support uploads using the available Library API permissions.
   - Never assume unrestricted access to existing Google Photos libraries.
   - Support an optional import of Google Photos export archives for cross-platform comparison.

3. **Backup Inventory**
   - Track each asset and its known storage locations.
   - Record verification status and synchronization relationships.
   - Distinguish verified original copies from cached or optimized local versions.
   - Identify missing backups.
   - Avoid treating iPhone Photos and iCloud Photos as independent backups when synchronization is enabled.

4. **Duplicate Management**
   - Group exact duplicates.
   - Separate visually similar photos from exact matches.
   - Recommend which duplicate copies to retain.
   - Estimate recoverable storage.
   - Never automatically delete photographs.

5. **Storage Dashboard**
   - Display photo counts by storage source.
   - Show duplicate candidates.
   - Show verified and unverified backup status.
   - Estimate recoverable space.
   - Clearly distinguish real provider-reported usage from calculated estimates.

6. **Safety and Privacy**
   - Default to read-only operations.
   - Require explicit user confirmation before every deletion batch.
   - Never delete the only verified surviving original.
   - Protect favorites and user-designated albums.
   - Keep metadata locally and credentials in secure platform storage.
   - Maintain a complete activity log.
   - Do not upload personal photos to a proprietary server for analysis.

## Development Approach

Start with a functional MVP that scans Apple Photos, identifies exact duplicates, and presents a storage dashboard.

Build the architecture using modular services so Google Photos integration and additional backup management features can be added later.

Include automated tests, simulated photo datasets, permission handling, and clear error reporting.

Do not implement destructive cleanup in the first release.

Provide the project structure, working SwiftUI screens, database schema, and instructions to build and test the application in Xcode.
