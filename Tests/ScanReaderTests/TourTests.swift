import XCTest
@testable import ScanReader

@MainActor
final class TourTests: XCTestCase {
    private func center() -> TourCenter { TourCenter(defaults: UserDefaults(suiteName: "tour-\(UUID().uuidString)")!) }

    func testContentCoversRequestedTopics() {
        let lib = TourContent.steps(.library).map(\.id), book = TourContent.steps(.book).map(\.id)
        XCTAssertEqual(lib, ["folder", "import", "drop", "icloud"])
        XCTAssertEqual(book, ["turn", "original", "aa", "highlight", "notes", "pagemenu", "search"])
        for s in TourContent.steps(.library) + TourContent.steps(.book) {
            XCTAssertFalse(s.title(true).isEmpty || s.title(false).isEmpty || s.body(true).isEmpty || s.body(false).isEmpty)
        }
    }

    func testFirstLaunchThenDone() {
        let c = center()
        c.startIfNeeded(.library)
        XCTAssertEqual(c.part, .library); XCTAssertEqual(c.step?.id, "folder")
        c.next(); c.next(); c.back()
        XCTAssertEqual(c.step?.id, "import")
        while c.part != nil { c.next() }
        XCTAssertTrue(c.isDone(.library))
        XCTAssertFalse(c.isDone(.book), "часть про книгу — при первом открытии книги")
        c.startIfNeeded(.library)
        XCTAssertNil(c.part, "пройденную часть не показываем снова")
        c.startIfNeeded(.book)
        XCTAssertEqual(c.part, .book)
    }

    func testSkipMarksDoneAndOnePartAtATime() {
        let c = center()
        c.startIfNeeded(.library)
        c.startIfNeeded(.book)
        XCTAssertEqual(c.part, .library, "одна часть за раз")
        c.skip()
        XCTAssertTrue(c.isDone(.library)); XCTAssertNil(c.part)
    }

    func testRestartFromHelpMenu() {
        let c = center()
        c.startIfNeeded(.library); c.skip()
        c.startIfNeeded(.book); c.skip()
        c.restart(in: .book)
        XCTAssertEqual(c.part, .book); XCTAssertEqual(c.index, 0)
        XCTAssertFalse(c.isDone(.library), "после «Ознакомительного тура» библиотека тоже покажется снова")
    }
}
