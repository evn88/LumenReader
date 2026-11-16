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

final class DisplayNameTests: XCTestCase {
    func testUnderscoresAndAppleBooksTitles() {
        let a = BookMetadata.resolve(title: "Базовая_математика_для_искусственного_интеллекта_2024", author: "UnknownAuthor",
                                     fileName: "Базовая_математика_для_искусственного_интеллекта_2024")
        XCTAssertEqual(a.title, "Базовая математика для искусственного интеллекта 2024"); XCTAssertNil(a.author)
        let g = BookMetadata.resolve(title: "Гриффитс Д., Гриффитс Д. - React. Сборник рецептов - 2023", author: "UnknownAuthor",
                                     fileName: "Гриффитс Д., Гриффитс Д. - React. Сборник рецептов - 2023")
        XCTAssertEqual(g.title, "React. Сборник рецептов"); XCTAssertEqual(g.author, "Гриффитс Д., Гриффитс Д.")
    }

    func testNoBreaksInsideWords() {
        let s = BookMetadata.unbreakableWords("Базовая математика")
        XCTAssertEqual(s.replacingOccurrences(of: "\u{2060}", with: ""), "Базовая математика")
        XCTAssertEqual(s.split(separator: " ").count, 2, "переносы только по пробелам")
    }
}
