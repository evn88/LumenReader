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
