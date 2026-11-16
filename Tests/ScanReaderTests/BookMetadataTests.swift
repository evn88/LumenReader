import XCTest
@testable import ScanReader

final class BookMetadataTests: XCTestCase {
    func testPlaceholderAuthorsAreEmpty() {
        for a in ["UnknownAuthor", "Unknown", "unknown", "", "   ", "⍰UnknownAuthor", "\u{E83A}UnknownAuthor", "\u{200B}Unknown\u{FEFF}", "Неизвестный автор", nil] as [String?] {
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
        XCTAssertEqual(g.title, "React. Сборник рецептов"); XCTAssertEqual(g.author, "Гриффитс Д.")
    }

    func testNoBreaksInsideWords() {
        let s = BookMetadata.unbreakableWords("Базовая математика")
        XCTAssertEqual(s.replacingOccurrences(of: "\u{2060}", with: ""), "Базовая математика")
        XCTAssertEqual(s.split(separator: " ").count, 2, "переносы только по пробелам")
    }
}

final class AuthorDedupeTests: XCTestCase {
    func testDuplicatesCollapse() {
        XCTAssertEqual(BookMetadata.author("Гриффитс Д., Гриффитс Д."), "Гриффитс Д.")
        XCTAssertEqual(BookMetadata.author("Wathan A., Schoger S"), "Wathan A., Schoger S")
        XCTAssertEqual(BookMetadata.author("Бек А.; Фримен А.; Бек А."), "Бек А.; Фримен А.")
        XCTAssertEqual(BookMetadata.fromFileName("Гриффитс Д., Гриффитс Д. - React. Сборник рецептов - 2023")?.author, "Гриффитс Д.")
    }
}

/// Тесты не трогают настоящую библиотеку: всё, что они пишут, — во временной папке.
final class TestIsolationTests: XCTestCase {
    func testTestsWriteOnlyToTemporaryFolders() {
        let tmp = FileManager.default.temporaryDirectory.path
        XCTAssertFalse(tmp.contains("Mobile Documents"))
        // глобальная папка библиотеки приложения тестами не задаётся
        XCTAssertNil(UserDefaults(suiteName: "io.github.evn88.lumenreader.tests")?.data(forKey: "libraryBookmark"))
    }

    /// Реальная запись из Apple Books: автор — заглушка с символом частного использования, название — имя файла.
    func testAppleBooksPrivateUsePlaceholder() {
        let file = "Dzhim_Nayp_-_EMDR_polnoe_rukovodstvo_-_2020"
        let r = BookMetadata.resolve(title: file, author: "\u{E83A}UnknownAuthor", fileName: file)
        XCTAssertEqual(r.author, "Dzhim Nayp")
        XCTAssertEqual(r.title, "EMDR polnoe rukovodstvo")
    }
}
