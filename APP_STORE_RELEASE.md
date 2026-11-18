# SmartPhotoVault App Store release

## One-time Apple account setup

1. Sign in to [App Store Connect](https://appstoreconnect.apple.com/). In **Business**, accept any pending agreement required to add an app.
2. In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list), register an explicit iOS App ID with bundle ID `com.bienyam.SmartPhotoVault`. Reuse it if it already exists for your team. Copy the Team ID from your Apple Developer membership details.
3. In **Apps → + → New App**, create an iOS record. Use **SmartPhotoVault** if available, English (U.S.) for the primary language, the bundle ID above, and `smartphotovault-ios` as the SKU. Reuse the record if it already exists.
4. In **Users and Access → Integrations → App Store Connect API → Team Keys**, request API access if prompted. Generate a team key for signing and uploading. Start with **App Manager** access. Record the Issuer ID and Key ID and download the private key when Apple offers it.
5. In the [GitHub repository’s Actions settings](https://github.com/bienyam/SmartPhotoVault/settings/secrets/actions), add a repository **secret** named `ASC_PRIVATE_KEY` with the full contents of the downloaded `.p8` file. On the Variables tab add repository **variables** named `APPLE_TEAM_ID`, `ASC_ISSUER_ID`, and `ASC_KEY_ID`. Put the corresponding values there. Keep the private key out of chat and Git.

Apple documents the [app record](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app) and [API access](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/).

## Upload and verify

Run **App Store Connect upload** from GitHub Actions on `main` and enable **Sign and upload to App Store Connect**. The workflow archives with automatic signing and uploads to Apple. Verify that the build processes successfully in **Apps → SmartPhotoVault → TestFlight**. Use internal TestFlight for the first iPhone check.

On the iPhone, check full, selected, and denied Photos access, counts and favorites, exact duplicates, Live Photos, cloud-only assets, and VoiceOver and larger text sizes. Check that sample data opens without Photos access and that the in-app Privacy Policy is accessible.

## App Store listing draft

- **Name** — SmartPhotoVault
- **Subtitle** — Photo inventory and duplicates
- **Primary category** — Photo & Video
- **Description** — See what’s in your Apple Photos library and review groups of exact duplicates. SmartPhotoVault counts the photos, videos, and favorites you give it access to. Duplicate matching runs on your device. Browse sample results before granting Photos access. Your latest completed scan stays on your device, and SmartPhotoVault never edits or deletes your photos.
- **Keywords** — photos,inventory,duplicates,library,videos,favorites
- **Support URL** — https://github.com/bienyam/SmartPhotoVault/issues
- **Privacy policy URL** — https://github.com/bienyam/SmartPhotoVault/blob/main/PRIVACY.md
- **Review notes** — No sign-in is required. On the dashboard tap Explore sample results, then Review duplicate groups to inspect synthetic results without granting Photos access. To use your own library, tap Scan Apple Photos and grant full or selected access. Find exact duplicates runs a separate content scan.

Complete App Privacy for the final build, the age rating questionnaire, export compliance, distribution availability, and review contact information. Review and upload the iPhone and 13-inch iPad screenshots from the workflow's `app-store-screenshots` artifact. Select the processed build in the iOS version record, choose manual release if you want to control when it goes live, and use **Add for Review**, then **Submit to App Review**. Confirm that the submission shows **Waiting for Review**.

See Apple’s [submission guidance](https://developer.apple.com/app-store/submitting/) and [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications).
