import XCTest
@testable import ScanReader

final class DropImportTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("lib"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func file(_ name: String, _ body: String = "x") throws -> URL {
        let u = dir.appendingPathComponent(name); try Data(body.utf8).write(to: u); return u
    }

    func testTypeFilter() throws {
        let pdf = try file("a.pdf"), epub = try file("b.epub"), png = try file("c.png"), txt = try file("d.txt"), zip = try file("e.zip")
        let scans = dir.appendingPathComponent("scans"); try FileManager.default.createDirectory(at: scans, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: scans.appendingPathComponent("001.jpg"))
        let empty = dir.appendingPathComponent("empty"); try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let ok = LibraryStore.importable([pdf, epub, png, txt, zip, scans, empty]).map(\.lastPathComponent)
        XCTAssertEqual(Set(ok), ["a.pdf", "b.epub", "c.png", "scans"])
    }

    func testICloudPlaceholder() {
        let u = dir.appendingPathComponent(".Книга.pdf.icloud")
        XCTAssertEqual(LibraryStore.iCloudPlaceholderTarget(u)?.lastPathComponent, "Книга.pdf")
        XCTAssertEqual(LibraryStore.importable([u]).first?.lastPathComponent, "Книга.pdf", "не скачанный файл — тоже книга")
    }

    func testDuplicates() throws {
        let lib = dir.appendingPathComponent("lib")
        let src = try file("book.pdf", "same content")
        try Data("same content".utf8).write(to: lib.appendingPathComponent("Другое имя.pdf"))
        XCTAssertTrue(LibraryStore.isDuplicate(src, in: lib), "тот же файл под другим именем")
        let other = try file("other.pdf", "different!!!")
        XCTAssertFalse(LibraryStore.isDuplicate(other, in: lib))
    }
}
