# Test SmartPhotoVault on an iPhone from Windows

Paid Apple Developer enrollment is not the only testing option. AltServer can personally sign an app using a regular Apple Account and install it from Windows. This is optional; simulator testing and future TestFlight setup remain available.

## What you need

- An iPhone running iOS 17 or newer, a USB cable, and your Windows PC.
- Your own Apple Account, with any account verification or developer terms completed by you.
- AltServer for Windows and its Apple software prerequisites, installed using the official Windows guide below.
- The `SmartPhotoVault-unsigned.ipa` file from a successful GitHub Actions run's `iphone-unsigned` artifact. The artifact also includes a package report showing arm64/iPhoneOS and the minimum iOS version.

The IPA is a physical-device build, not the simulator app. It cannot be opened on the phone until AltServer signs it. Personal signing and installation have not been verified on your phone yet.

## Setup and installation

1. Follow AltStore's official Windows setup guide for AltServer and the required Apple components: https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows . Use the official downloads linked there. This requires installing software on the PC; we will do that only with your agreement.
2. Connect your unlocked iPhone by USB and approve the Trust prompt on the phone when appropriate.
3. Download and extract the `iphone-unsigned` artifact from this repository's successful Actions run.
4. AltServer supports direct IPA installation: hold **Shift** while clicking its Windows system-tray icon, choose **Sideload .ipa…**, and select `SmartPhotoVault-unsigned.ipa`.
5. Enter your Apple Account details in AltServer yourself and complete any Apple verification. Do not send passwords or two-factor codes in chat.
6. Follow the device's prompts to trust your personal developer profile and enable Developer Mode if required. Launch SmartPhotoVault and choose Photos access when you start a scan.

AltServer's direct-IPA feature is described in its official release notes: https://faq.altstore.io/release-notes/altserver . Follow the current software's labels if they differ from this guide.

## Limits of free personal signing

Directly sideloaded apps need to be re-signed/reinstalled every seven days. Apple also limits free-account app installations and App IDs. AltStore Classic can automate refreshing when set up with AltServer, but it is not required for the direct-IPA path above. This route is for personal testing; it does not publish the app in the App Store or create a TestFlight build.

## First device checks

Start with selected photos if preferred. Verify counts, inspect a duplicate group and its thumbnails, deny access and confirm Settings guidance, then rescan after a library change. Cloud-only and Live Photo behavior still need actual-device testing. Keep iCloud downloads off for the first scan unless you want original resources downloaded. This version has no edit, upload, or deletion operations.

## Official references

- Windows setup: https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows
- Direct IPA installation and seven-day refresh: https://faq.altstore.io/release-notes/altserver
- Signing architecture: https://github.com/altstoreio/AltStore
