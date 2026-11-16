import XCTest
@testable import ScanReader

final class BookMetadataTests: XCTestCase {
    func testPlaceholderAuthorsAreEmpty() {
        for a in ["UnknownAuthor", "Unknown", "unknown", "", "   ", "⍰UnknownAuthor", "Неизвестный автор", nil] as [String?] {
            XCTAssertNil(BookMetadata.author(a), "\(String(describing: a))")
        }
        XCTAssertEqual(BookMetadata.author("  Александр Швец "), "Александр Швец")
    }

    func testFileNamePattern() {
        let r = BookMetadata.fromFileName("Wathan A., Schoger S - Refactoring UI - 2020")
        XCTAssertEqual(r?.author, "Wathan A., Schoger S")
        XCTAssertEqual(r?.title, "Refactoring UI")
        XCTAssertEqual(BookMetadata.fromFileName("Бартлетт Д. - Рецепты TypeScript")?.title, "Рецепты TypeScript")
        XCTAssertNil(BookMetadata.fromFileName("JavaScript. Полное руководство"), "без « - » не разбираем")
        XCTAssertNil(BookMetadata.fromFileName("A - B - C - D"))
        XCTAssertNil(BookMetadata.fromFileName("Автор - Название - не год"))
    }

    func testResolve() {
        let name = "Wathan A., Schoger S - Refactoring UI - 2020"
        let r = BookMetadata.resolve(title: name, author: "UnknownAuthor", fileName: name)
        XCTAssertEqual(r.title, "Refactoring UI"); XCTAssertEqual(r.author, "Wathan A., Schoger S")
        let k = BookMetadata.resolve(title: "Своё название", author: "Автор", fileName: name)
        XCTAssertEqual(k.title, "Своё название"); XCTAssertEqual(k.author, "Автор", "явные метаданные не перетираем")
        let n = BookMetadata.resolve(title: nil, author: nil, fileName: "draft")
        XCTAssertEqual(n.title, "draft"); XCTAssertNil(n.author)
    }
}
