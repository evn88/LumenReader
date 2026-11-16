import AppKit
import XCTest
@testable import ScanReader

/// Режим «оригинал», остановка фона и быстрое перечитывание полки.
final class OpenModeTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("om-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    /// Папка-книга из белых картинок (распознавать в ней нечего — в режиме оригинала и не пытаемся).
    private func scansBook(pages: Int) throws -> URL {
        let book = dir.appendingPathComponent("scans", isDirectory: true)
        try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 60, pixelsHigh: 80, bitsPerSample: 8, samplesPerPixel: 3,
                                   hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = rep.representation(using: .png, properties: [:])!
        for i in 1...pages { try png.write(to: book.appendingPathComponent(String(format: "%03d.png", i))) }
        return book
    }

    @MainActor
    func testOriginalModeShowsScansWithoutRecognition() async throws {
        let book = try XCTUnwrap(BookModel(url: try scansBook(pages: 3)))
        defer { book.close() }
        book.setOriginalMode(true)
        book.prefetch(visible: [0, 1])
        for _ in 0..<100 where book.pages[0] == nil || book.pages[1] == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(book.pages[0]?.scanOnly, true, "страница — скан, без OCR")
        XCTAssertEqual(book.pages[1]?.scanOnly, true)
        XCTAssertTrue(book.cached.isEmpty, "в режиме оригинала ничего не распознаётся")
        XCTAssertFalse(book.backgroundActive)

        // назад к тексту: страницы-сканы режима сбрасываются и распознаются заново
        book.setOriginalMode(false)
        XCTAssertNotEqual(book.pages[0]?.scanOnly, true)
    }

    @MainActor
    func testBackgroundStopIsRemembered() throws {
        let url = try scansBook(pages: 2)
        let book = try XCTUnwrap(BookModel(url: url))
        book.setBackgroundStopped(true)
        XCTAssertFalse(book.backgroundActive)
        book.close()
        XCTAssertEqual(Sidecar.meta(url).recognitionPaused, true, "остановка сохраняется рядом с книгой")
        let again = try XCTUnwrap(BookModel(url: url))
        XCTAssertTrue(again.backgroundStopped)
        again.setBackgroundStopped(false)
        XCTAssertNil(Sidecar.meta(url).recognitionPaused)
        again.close()
    }

    func testLibraryRescanReusesUnchangedBooks() throws {
        _ = try scansBook(pages: 1)
        try Data("x".utf8).write(to: dir.appendingPathComponent("note.txt"))
        let first = LibraryStore.scan(dir, previous: [:])
        XCTAssertEqual(first.map(\.book.title), ["scans"])

        // подменённая запись с теми же отметками берётся как есть — файл не перечитывается
        var fake = first[0]
        fake.book.title = "Из кеша"
        let again = LibraryStore.scan(dir, previous: [fake.book.id: fake])
        XCTAssertEqual(again.first?.book.title, "Из кеша")

        // meta.json изменился — книга перечитана
        Sidecar.update(fake.book.url) { $0.title = "Новое название" }
        let changed = LibraryStore.scan(dir, previous: [fake.book.id: fake])
        XCTAssertEqual(changed.first?.book.title, "Новое название")
    }

    func testSnapshotRoundTrip() throws {
        let entries = LibraryStore.scan(dir, previous: [:]) + [LibraryEntry(
            book: LibraryBook(url: dir.appendingPathComponent("a.pdf"), kind: .pdf, title: "А", author: nil, collections: ["К"],
                              progress: 0.5, lastOpened: nil, added: Date(timeIntervalSince1970: 0), recognized: true),
            stamp: LibraryStamp(file: Date(timeIntervalSince1970: 10), sidecar: nil, meta: nil))]
        LibrarySnapshot.save(entries, for: dir)
        defer { try? FileManager.default.removeItem(at: LibrarySnapshot.file(for: dir)) }
        let loaded = LibrarySnapshot.load(dir)
        XCTAssertEqual(loaded.map(\.book), entries.map(\.book))
        XCTAssertEqual(loaded.map(\.stamp), entries.map(\.stamp))
    }
}
