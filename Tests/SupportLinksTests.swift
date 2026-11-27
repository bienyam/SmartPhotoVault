import XCTest
@testable import SmartPhotoVault

/// Privacy and support live on tidyaway.app (C1), one constant each, with an email contact.
final class SupportLinksTests: XCTestCase {
    func testPrivacyAndSupportLiveOnTheWebsite() {
        XCTAssertEqual(SupportLinks.privacy.absoluteString, "https://tidyaway.app/privacy")
        XCTAssertEqual(SupportLinks.support.absoluteString, "https://tidyaway.app/support")
        XCTAssertEqual(SupportLinks.email, "hello@tidyaway.app")
    }

    @MainActor
    func testEveryPrivacyLinkUsesTheOneConstant() {
        XCTAssertEqual(ProPurchaseControls.privacyURL, SupportLinks.privacy)
    }

    func testEmailOpensANewMessageToSupportWithTheDetails() throws {
        let url = SupportLinks.emailURL(details: "TidyAway 1.0.2 (200), iPhone, iOS 26.1")
        XCTAssertEqual(url.scheme, "mailto")
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.path, "hello@tidyaway.app")
        XCTAssertEqual(parts.queryItems?.first { $0.name == "subject" }?.value, "TidyAway support")
        XCTAssertTrue(parts.queryItems?.first { $0.name == "body" }?.value?.contains("TidyAway 1.0.2 (200)") ?? false)
    }
}
