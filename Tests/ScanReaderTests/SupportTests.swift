import XCTest
@testable import ScanReader

final class SupportTests: XCTestCase {
    func testOnlyHTTPSWithoutCredentials() {
        XCTAssertEqual(SupportConfiguration.pageURL(infoDictionary: ["SupportURL": "https://github.com/sponsors/evn88"])?.absoluteString,
                       "https://github.com/sponsors/evn88")
        XCTAssertNil(SupportConfiguration.pageURL(infoDictionary: ["SupportURL": "http://example.com"]))
        XCTAssertNil(SupportConfiguration.pageURL(infoDictionary: ["SupportURL": "https://user:pass@example.com"]))
        XCTAssertNil(SupportConfiguration.pageURL(infoDictionary: ["SupportURL": "  "]))
        XCTAssertNil(SupportConfiguration.pageURL(infoDictionary: nil), "без настройки раздел скрыт")
    }
}

final class UpdateConfigurationTests: XCTestCase {
    private let good: [String: Any] = [
        "SUFeedURL": "https://github.com/evn88/LumenReader/releases/latest/download/appcast.xml",
        "SUPublicEDKey": "5PjO4qHSCd4sQHY4Fzfd+/c3ZOLvNtJHdd/7NNCXU8o=",
        "SUVerifyUpdateBeforeExtraction": true, "SURequireSignedFeed": true,
    ]

    func testConfigured() { XCTAssertTrue(UpdateConfiguration.isConfigured(infoDictionary: good)) }

    func testRejectsUnsafe() {
        var a = good; a["SUFeedURL"] = "http://example.com/appcast.xml"
        XCTAssertFalse(UpdateConfiguration.isConfigured(infoDictionary: a), "только HTTPS")
        var b = good; b["SUPublicEDKey"] = "short"
        XCTAssertFalse(UpdateConfiguration.isConfigured(infoDictionary: b))
        var c = good; c["SURequireSignedFeed"] = false
        XCTAssertFalse(UpdateConfiguration.isConfigured(infoDictionary: c))
        XCTAssertFalse(UpdateConfiguration.isConfigured(infoDictionary: nil), "swift run / тесты — без обновлятора")
    }

    func testSiteHiddenWhenEmpty() {
        XCTAssertNil(SupportConfiguration.siteURL(infoDictionary: ["SiteURL": ""]))
        XCTAssertEqual(SupportConfiguration.siteURL(infoDictionary: ["SiteURL": "https://ai-soft.app"])?.host, "ai-soft.app")
    }
}
