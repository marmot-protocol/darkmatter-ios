import Foundation
import Testing
@testable import whitenoise_ios

struct ProfileWebsitePresentationTests {
    @Test func acceptsBoundedPublicWebsites() throws {
        let website = try #require(
            ProfileWebsitePresentation.website(" https://example.com/profile ")
        )

        #expect(website.url == URL(string: "https://example.com/profile"))
        #expect(website.displayText == "https://example.com/profile")
    }

    @Test func rejectsCredentialsPrivateHostsAndNonWebSchemes() {
        #expect(ProfileWebsitePresentation.website("https://user:pass@example.com") == nil)
        #expect(ProfileWebsitePresentation.website("https://127.0.0.1/profile") == nil)
        #expect(ProfileWebsitePresentation.website("https://localhost/profile") == nil)
        #expect(ProfileWebsitePresentation.website("javascript:alert(1)") == nil)
    }

    @Test func stripsUnsafeDisplayFormattingWithoutChangingDestination() throws {
        let website = try #require(
            ProfileWebsitePresentation.website("https://example.com/ab\u{202E}cd")
        )

        #expect(website.url.absoluteString.contains("%E2%80%AE"))
        #expect(!website.displayText.contains("\u{202E}"))
    }
}
