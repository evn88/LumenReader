import XCTest
@testable import ScanReader

final class InstallationTests: XCTestCase {
    private let apps = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Users/u/Applications")]
    private func installed(_ path: String, readOnly: Bool = false) -> Bool {
        Installation.isInstalled(URL(fileURLWithPath: path), in: apps, isReadOnly: { _ in readOnly })
    }

    func testApplicationsFolders() {
        XCTAssertTrue(installed("/Applications/Lumen Reader.app"))
        XCTAssertTrue(installed("/Applications/Книги/Lumen Reader.app"))
        XCTAssertTrue(installed("/Users/u/Applications/Lumen Reader.app"))
    }

    func testNotInstalled() {
        XCTAssertFalse(installed("/Volumes/Lumen Reader 0.4/Lumen Reader.app"))
        XCTAssertFalse(installed("/Users/u/Downloads/Lumen Reader.app"))
        XCTAssertFalse(installed("/Applications/Lumen Reader.app", readOnly: true))
        XCTAssertFalse(installed("/private/var/folders/x/AppTranslocation/ABC/d/Lumen Reader.app"))
        XCTAssertFalse(installed("/Applications/Other.app/Contents/Lumen Reader.app"))
        XCTAssertFalse(installed("/Applications"))
    }
}
