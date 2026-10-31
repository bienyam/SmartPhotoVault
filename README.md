# SmartPhotoVault

Native iOS photo inventory app, built with SwiftUI and PhotoKit. The selected strategy is full-resolution copies on iPhone, iCloud Photos, and Google Photos. See PROJECT_SPEC.md for the full scope.

## Current milestone

Read-only Apple Photos permission handling and metadata counts, with explicit limited-access messaging and unverified backup status. No photo uploads, edits, or deletions. Exact duplicate detection, SQLite persistence, and Google Photos are planned and are not yet implemented.

## Build on a Mac

Requires Xcode with iOS 17+ SDK and XcodeGen (`brew install xcodegen`). Run `xcodegen generate`, then open `SmartPhotoVault.xcodeproj`. Select the SmartPhotoVault scheme and an iPhone simulator, then Run or Test. The generated project is intentionally ignored by Git; project.yml is its source.

## Build from Windows using GitHub

Push this project to GitHub and open the repository's Actions tab. The iOS build and tests workflow generates the project and runs simulator tests on a hosted Mac. A successful simulator build does not produce an app installable on a physical iPhone. Apple Developer enrollment, signing, and TestFlight distribution will be configured separately. No signing credentials are needed for this workflow. GitHub runner usage is subject to your plan and billing settings.

## Device installation later

The initial project disables signing for simulator builds. A later signed device workflow must override CODE_SIGNING_ALLOWED and configure your Apple team, certificates, and provisioning profile. Never commit signing credentials or personal photo datasets.

## Manual checks before device release

- Try full, limited, denied, and restricted photo access.
- Change access in Settings, return, and rescan.
- Confirm displayed counts against the accessible library, including videos and favorites.
- Confirm iCloud-only assets are counted without claiming their originals are stored locally.
- Check VoiceOver and larger text sizes.

Windows cannot validate the SwiftUI/PhotoKit runtime; the first cloud build and later device testing are required before calling this foundation verified.
