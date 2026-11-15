import XCTest
@testable import ScanReader

final class StorageTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sr-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testLayoutCacheRoundTrip() throws {
        let book = dir.appendingPathComponent("book.pdf")
        try Data("x".utf8).write(to: book)
        let cache = LayoutCache(bookURL: book, palette: .original, languages: ["ru-RU"])
        XCTAssertTrue(cache.dir.path.contains(".scanreader/book.pdf"), "кеш рядом с книгой")
        let word = Word(text: "Привет", bounds: CGRect(x: 1, y: 2, width: 30, height: 10), bold: true)
        let line = TextLine(bounds: CGRect(x: 1, y: 2, width: 30, height: 10), baseline: 11, xHeight: 6,
                            alignment: .justify, confidence: 0.9, words: [word])
        let layout = PageLayout(size: CGSize(width: 100, height: 140), figures: [CGRect(x: 5, y: 5, width: 20, height: 20)],
                                rules: [], paragraphs: [Paragraph(family: .serif, fontSize: 12, lines: [line])])
        XCTAssertFalse(cache.has(3))
        cache.save(layout, 3)
        XCTAssertTrue(cache.has(3))
        XCTAssertEqual(cache.load(3), layout)
        XCTAssertNil(cache.load(4))
    }

    func testCacheKeyDoesNotDependOnPath() throws {
        let a = dir.appendingPathComponent("a/book.pdf"), b = dir.appendingPathComponent("b/book.pdf")
        for u in [a, b] {
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: u)
        }
        let ca = LayoutCache(bookURL: a, palette: .original, languages: ["ru-RU"])
        let cb = LayoutCache(bookURL: b, palette: .original, languages: ["ru-RU"])
        XCTAssertEqual(ca.dir.lastPathComponent, cb.dir.lastPathComponent, "ключ одинаков на всех устройствах")
    }

    func testMetaRoundTripAndOldFormat() throws {
        let book = dir.appendingPathComponent("book.epub")
        Sidecar.update(book) { $0.progress = 0.4; $0.pagesShowOriginal = [3, 7]; $0.collections = ["X"] }
        let m = Sidecar.meta(book)
        XCTAssertEqual(m.progress, 0.4)
        XCTAssertEqual(m.pagesShowOriginal, [3, 7])
        // старый meta.json (импорт из Books, без новых полей) читается
        let old = #"{"title":"T","collections":[],"importedFrom":"Apple Books","importedAt":"2026-11-15T10:00:00Z"}"#
        try Data(old.utf8).write(to: Sidecar.dir(for: book).appendingPathComponent("meta.json"))
        XCTAssertEqual(Sidecar.meta(book).title, "T")
        XCTAssertNil(Sidecar.meta(book).pagesShowOriginal)
    }
}
