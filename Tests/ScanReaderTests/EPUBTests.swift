import XCTest
@testable import ScanReader

final class EPUBTests: XCTestCase {
    static let demo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("demo/library")

    func testDirectoryPackage() throws {
        let book = try EPUBBook(Self.demo.appendingPathComponent("Заметки о чтении.epub"))
        XCTAssertEqual(book.title, "Заметки о чтении")
        XCTAssertEqual(book.author, "Демо-автор")
        XCTAssertEqual(book.language, "ru")
        XCTAssertEqual(book.spine.count, 3)
        XCTAssertEqual(book.toc.map(\.title).first, "Глава 1. Зачем перечитывать")
        XCTAssertTrue(FileManager.default.fileExists(atPath: book.coverURL?.path ?? ""))
        XCTAssertTrue(book.toc[1].href.hasSuffix("ch2.xhtml#c2"))
    }

    func testZippedPackage() throws {
        let book = try EPUBBook(Self.demo.appendingPathComponent("Заметки о чтении (zip).epub"))
        XCTAssertEqual(book.spine.count, 3)
        XCTAssertNotNil(book.coverURL)
    }

    func testDRMIsRejected() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("drm-\(UUID().uuidString).epub")
        try FileManager.default.copyItem(at: Self.demo.appendingPathComponent("Заметки о чтении.epub"), to: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("<sinf/>".utf8).write(to: dir.appendingPathComponent("META-INF/sinf.xml"))
        XCTAssertThrowsError(try EPUBBook(dir)) { XCTAssertEqual(($0 as? EPUBBook.Failure).map { "\($0)" }, "drm") }
    }

    func testBrokenEPUB() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("broken-\(UUID().uuidString).epub")
        try Data("not a zip".utf8).write(to: f)
        defer { try? FileManager.default.removeItem(at: f) }
        XCTAssertThrowsError(try EPUBBook(f))
    }
}
