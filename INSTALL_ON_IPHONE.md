# Installing SmartPhotoVault on your iPhone

The GitHub simulator workflow validates the code on a cloud Mac. Its output is not an iPhone installation package. The planned device delivery path is TestFlight.

## Keep testing before enrollment

No paid Apple Developer membership is needed for our GitHub simulator builds, synthetic Photos-library integration tests, UI tests, or screenshots. Work can continue while enrollment is being established. Paid membership is needed for the planned TestFlight distribution path. With access to a Mac and Xcode, Apple also supports limited personal-device testing using a free Apple Account; that is a separate path from this Windows/GitHub setup.

Apple account comparison: https://developer.apple.com/help/account/basics/about-your-developer-account/

## What you need to do

1. Enroll in the Apple Developer Program using your own Apple Account: https://developer.apple.com/programs/enroll/ . Apple handles identity verification, agreements, and membership payment. Confirm the current terms and fee directly with Apple before enrolling.
2. When Apple confirms enrollment, tell your coding collaborator that membership is active. Do not paste your Apple password or two-factor codes into this chat.
3. We will then register the app, choose a unique bundle identifier, configure signing credentials in GitHub Actions secrets, and build a signed archive. Setup details depend on the actual account and team, so they are intentionally not prefilled with guessed credentials.
4. Once a build is accepted and processed in App Store Connect, install Apple's TestFlight app on your iPhone and use the configured tester access to install SmartPhotoVault.

Enrollment does not automatically publish the app in the App Store. App Store release is a separate future step. Simulator results do not replace physical-device checks of permissions, full-resolution resources, iCloud-only assets, large videos, and Live Photos.

## What is already automated

The repository's Actions tab runs project generation, iOS compilation, safety and persistence tests, a sample-data UI test, and dashboard screenshot capture. These checks use synthetic data and do not require access to your personal photos or Apple account.

## Official references

- Apple Developer Program: https://developer.apple.com/programs/
- Enrollment: https://developer.apple.com/programs/enroll/
- App Store Connect API keys: https://developer.apple.com/documentation/AppStoreConnectAPI/creating-api-keys-for-app-store-connect-api
- GitHub Xcode signing: https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications
