import XCTest
@testable import ScanReader

final class AnnotationTests: XCTestCase {
    var dir: URL!
    var book: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ann-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        book = dir.appendingPathComponent("book.pdf")
        try Data("x".utf8).write(to: book)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testSaveLoadRoundTrip() {
        let a = Annotation(style: .green, note: "заметка", text: "Чтение — это разговор", anchor: .scan(page: 3, start: 10, end: 14))
        let b = Annotation(style: .underline, text: "chapter", anchor: .epub(chapter: "OEBPS/ch2.xhtml", start: 5, end: 12))
        AnnotationFile.save([a, b], book: book)
        let loaded = AnnotationFile.read(book)
        XCTAssertEqual(Set(loaded.map(\.id)), [a.id, b.id])
        XCTAssertEqual(loaded.first { $0.id == a.id }?.note, "заметка")
        XCTAssertEqual(loaded.first { $0.id == b.id }?.anchor, b.anchor)
        XCTAssertTrue(FileManager.default.fileExists(atPath: Sidecar.dir(for: book).appendingPathComponent("annotations.json").path))
    }

    /// Два устройства правят одну книгу: объединение по id, при конфликте — последняя правка.
    func testMergeFromTwoDevices() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var shared = Annotation(style: .yellow, text: "общий", anchor: .scan(page: 1, start: 0, end: 2))
        shared.modified = t0
        AnnotationFile.save([shared], book: book)

        // устройство A: меняет цвет общего (позже) и добавляет свой
        var onA = shared; onA.style = .blue; onA.modified = t0.addingTimeInterval(20)
        var aOnly = Annotation(style: .pink, text: "A", anchor: .scan(page: 2, start: 0, end: 1)); aOnly.modified = t0.addingTimeInterval(5)
        // устройство B: меняет заметку общего (раньше A) и добавляет свой
        var onB = shared; onB.note = "от B"; onB.modified = t0.addingTimeInterval(10)
        var bOnly = Annotation(style: .purple, text: "B", anchor: .scan(page: 5, start: 3, end: 4)); bOnly.modified = t0.addingTimeInterval(7)

        AnnotationFile.save([onB, bOnly], book: book)       // B синхронизировался первым
        let final = AnnotationFile.save([onA, aOnly], book: book)
        XCTAssertEqual(Set(final.map(\.id)), [shared.id, aOnly.id, bOnly.id], "объединение по id")
        let s = final.first { $0.id == shared.id }!
        XCTAssertEqual(s.style, .blue, "побеждает последняя правка (A, +20 с)")
        XCTAssertNil(s.note, "правка B старше — целиком уступает")
    }

    func testDeletionSyncsAndDoesNotResurrect() {
        var a = Annotation(style: .yellow, text: "x", anchor: .scan(page: 0, start: 0, end: 0))
        a.modified = Date(timeIntervalSince1970: 100)
        var deleted = a; deleted.deleted = true; deleted.modified = Date(timeIntervalSince1970: 200)
        let merged = AnnotationMerge.merge([deleted], [a])          // старая копия с другого устройства
        XCTAssertEqual(merged.count, 1)
        XCTAssertTrue(merged[0].deleted)
        var same = a; same.deleted = true                            // одинаковое время — удаление побеждает
        XCTAssertTrue(AnnotationMerge.merge([a], [same])[0].deleted)
    }

    @MainActor
    func testStoreUpsertDeleteAndOverlap() async throws {
        let store = AnnotationStore(book: book)
        let a = store.upsert(Annotation(style: .yellow, text: "слово", anchor: .scan(page: 2, start: 5, end: 9)))
        XCTAssertEqual(store.items(page: 2).count, 1)
        XCTAssertNotNil(store.existing(overlapping: .scan(page: 2, start: 8, end: 12)))
        XCTAssertNil(store.existing(overlapping: .scan(page: 2, start: 10, end: 12)))
        XCTAssertNil(store.existing(overlapping: .scan(page: 3, start: 5, end: 9)))
        store.delete(a.id)
        XCTAssertTrue(store.items(page: 2).isEmpty)
        try await Task.sleep(for: .milliseconds(500))           // запись идёт в фоне
        XCTAssertTrue(AnnotationFile.read(book).first { $0.id == a.id }?.deleted ?? false)
        let reopened = AnnotationStore(book: book)
        XCTAssertTrue(reopened.items.isEmpty, "удалённый не возвращается после перезапуска")
    }
}

final class PageNumberTests: XCTestCase {
    /// Минимальный PDF из 3 страниц с /PageLabels: «C», «1», «2» (обложка без номера, дальше арабские).
    static func labeledPDF() throws -> URL {
        var objs = [
            "<< /Type /Catalog /Pages 2 0 R /PageLabels << /Nums [0 << /P (C) >> 1 << /S /D /St 1 >>] >> >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>",
        ]
        // PDFKit читает метки только у «настоящих» страниц — с ресурсами и потоком содержимого
        for _ in 0..<3 { objs.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 300] /Resources << >> /Contents 6 0 R >>") }
        objs.append("<< /Length 0 >>\nstream\n\nendstream")
        var pdf = "%PDF-1.4\n", offsets: [Int] = []
        for (i, o) in objs.enumerated() { offsets.append(pdf.utf8.count); pdf += "\(i + 1) 0 obj\n\(o)\nendobj\n" }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objs.count + 1)\n0000000000 65535 f \n"
        for o in offsets { pdf += String(format: "%010d 00000 n \n", o) }
        pdf += "trailer\n<< /Size \(objs.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("labels-\(UUID().uuidString).pdf")
        try Data(pdf.utf8).write(to: url)
        return url
    }

    @MainActor
    func testPDFPageLabelsEverywhere() throws {
        let url = try Self.labeledPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let book = try XCTUnwrap(BookModel(url: url))
        XCTAssertTrue(book.hasPrintedLabels)
        XCTAssertEqual((0..<3).map { book.displayNumber(for: $0) }, ["C", "1", "2"])
    }

    @MainActor
    func testUnlabeledPDFFallsBackToIndex() throws {
        let demo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("demo/library/Код на Swift.pdf")
        let book = try XCTUnwrap(BookModel(url: demo))
        XCTAssertFalse(book.hasPrintedLabels, "PDFKit отдаёт «1» для PDF без меток — это не печатный номер")
        XCTAssertEqual(book.displayNumber(for: 0), "1")
    }

    func testPrintedNumberFromRunningHead() {
        let w = Word(text: "52", bounds: CGRect(x: 50, y: 40, width: 20, height: 12))
        let head = TextLine(bounds: CGRect(x: 50, y: 40, width: 20, height: 12), baseline: 52, xHeight: 8, alignment: .left, confidence: 1, words: [w])
        let body = TextLine(bounds: CGRect(x: 50, y: 300, width: 400, height: 14), baseline: 312, xHeight: 8, alignment: .justify,
                            confidence: 1, words: [Word(text: "текст", bounds: CGRect(x: 50, y: 300, width: 40, height: 14))])
        let l = PageLayout(size: CGSize(width: 600, height: 900), figures: [], rules: [],
                           paragraphs: [Paragraph(family: .sans, fontSize: 10, lines: [head]), Paragraph(family: .serif, fontSize: 12, lines: [body])])
        XCTAssertEqual(BookModel.printedNumber(in: l), 52)
    }
}

final class TitleBarTests: XCTestCase {
    func testDoubleClickActionFromSystemSetting() {
        let d = UserDefaults(suiteName: "sr-test-\(UUID().uuidString)")!
        XCTAssertEqual(TitleBarStrip.action(d), .zoom, "по умолчанию — увеличить")
        d.set("Minimize", forKey: "AppleActionOnDoubleClick"); XCTAssertEqual(TitleBarStrip.action(d), .minimize)
        d.set("None", forKey: "AppleActionOnDoubleClick"); XCTAssertEqual(TitleBarStrip.action(d), .none)
        d.set("Fill", forKey: "AppleActionOnDoubleClick"); XCTAssertEqual(TitleBarStrip.action(d), .zoom)
        d.removeObject(forKey: "AppleActionOnDoubleClick")
        d.set(true, forKey: "AppleMiniaturizeOnDoubleClick"); XCTAssertEqual(TitleBarStrip.action(d), .minimize, "старая настройка")
    }
}

final class PrintedOffsetTests: XCTestCase {
    func testConsensus() {
        XCTAssertNil(BookModel.consensusOffset([0: 51]), "одной страницы мало")
        XCTAssertEqual(BookModel.consensusOffset([3: 10, 4: 10, 9: 10]), 10)
        XCTAssertNil(BookModel.consensusOffset([0: 51, 2: 49, 4: 47]), "одинаковый колонтитул на разных страницах — не нумерация")
        XCTAssertEqual(BookModel.consensusOffset([1: 2, 2: 2, 3: 2, 7: 40]), 2, "одна ошибка OCR не мешает")
    }
}
