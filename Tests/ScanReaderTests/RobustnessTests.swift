import XCTest
@testable import ScanReader

final class RobustnessTests: XCTestCase {
    func tmp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("rob-\(UUID().uuidString)-\(name)")
    }

    @MainActor
    func testBrokenAndEmptyPDFAreNotOpened() throws {
        let broken = tmp("broken.pdf")
        try Data("%PDF-1.4 garbage".utf8).write(to: broken)
        defer { try? FileManager.default.removeItem(at: broken) }
        XCTAssertNil(PageSource.load(broken), "битый PDF не открывается «картинкой»")
        XCTAssertNil(BookModel(url: broken))

        let emptyDir = tmp("empty")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyDir) }
        XCTAssertNil(BookModel(url: emptyDir), "папка без сканов — не книга")
    }

    func testInkMaskOutOfBoundsIsEmpty() {
        let m = InkMask(width: 2, height: 2, bits: [1, 1, 1, 1])
        XCTAssertEqual(m.at(0, 0), 1)
        XCTAssertEqual(m.at(-1, 0), 0)
        XCTAssertEqual(m.at(2, 1), 0)
        XCTAssertEqual(m.at(0, 99), 0)
    }

    func testLeveledImageSafeOnDegenerateInput() {
        let g = GrayBitmap(width: 4, height: 4, pixels: [UInt8](repeating: 128, count: 16))
        XCTAssertNotNil(g.leveledImage(rect: CGRect(x: 0, y: 0, width: 4, height: 4), black: 100, white: 100))
        XCTAssertNil(g.leveledImage(rect: CGRect(x: 10, y: 10, width: 4, height: 4)), "рамка вне картинки")
        XCTAssertEqual(GrayBitmap(width: 3, height: 3, pixels: [UInt8](repeating: 255, count: 9)).otsuThreshold(), 128)
    }

    func testGarbageWordsDetected() {
        let good = Array(repeating: ["разговор", "автором", "растянутый", "времени", "хорошая", "книга"], count: 3).flatMap { $0 }
        XCTAssertLessThan(PageQuality.garbageShare(good), 0.2)
        // латинские буквы внутри кириллических слов и мусор OCR
        let bad = Array(repeating: ["paзговор", "aвтором", "pacтянутый", "вpемени", "xopoшая", "кнuга"], count: 3).flatMap { $0 }
        XCTAssertGreaterThan(PageQuality.garbageShare(bad), 0.8)
    }

    func testUnreliableByConfidence() {
        let w = Word(text: "текст", bounds: .zero)
        let line = TextLine(bounds: .zero, baseline: 0, xHeight: 1, alignment: .left, confidence: 0.2, words: [w])
        let l = PageLayout(size: CGSize(width: 10, height: 10), figures: [], rules: [],
                           paragraphs: [Paragraph(family: .serif, fontSize: 10, lines: [line, line])])
        XCTAssertTrue(PageQuality.isUnreliable(l))
    }

    func testReflowOnEmptyLayout() {
        let l = PageLayout(size: CGSize(width: 100, height: 140), figures: [], rules: [], paragraphs: [])
        let s = Reflow.paginate(l, palette: .original, ink: CGColor(gray: 0, alpha: 1), isDark: false, settings: ReflowSettings(scale: 1.5))
        XCTAssertEqual(s.count, 1)
    }
}

final class ReviewFixTests: XCTestCase {
    /// Оглавление с href="#" раньше роняло разбор EPUB (а с ним — показ библиотеки).
    func testTOCWithBareHash() throws {
        let demo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("demo/library/Заметки о чтении.epub")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hash-\(UUID().uuidString).epub")
        try FileManager.default.copyItem(at: demo, to: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let nav = dir.appendingPathComponent("OEBPS/nav.xhtml")
        var html = try String(contentsOf: nav, encoding: .utf8)
        html = html.replacingOccurrences(of: "<ol>", with: ##"<ol><li><a href="#">Пусто</a></li><li><a href="#c2">Якорь</a></li>"##)
        try html.write(to: nav, atomically: true, encoding: .utf8)
        let book = try EPUBBook(dir)
        XCTAssertTrue(book.toc.contains { $0.title == "Пусто" })
        XCTAssertTrue(book.toc.first { $0.title == "Якорь" }?.href.hasSuffix("#c2") ?? false)
    }

    /// Отмена посреди OCR — это CancellationError, а не «ошибка страницы».
    func testCancelDuringOCRIsCancellation() throws {
        let img = try LayoutTests.image("synthetic-page.png")
        let token = CancelToken()
        var analyzer = LayoutAnalyzer(palette: .original, languages: ["ru-RU", "en-US"], enhanceFigures: false)
        analyzer.token = token
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { token.cancel() }
        do {
            _ = try analyzer.analyze(img)
            // успели раньше отмены — тоже допустимо, но тогда проверить нечего
        } catch {
            XCTAssertTrue(error is CancellationError, "получили \(error)")
        }
    }

    /// Большая «подпись» под иллюстрацией при 300% не даёт отрицательную высоту картинки.
    func testHugeCaptionReserveKeepsFigurePositive() {
        let words = (0..<40).map { Word(text: "слово\($0)", bounds: CGRect(x: 100 + $0 * 10, y: 610, width: 8, height: 10)) }
        let cap = TextLine(bounds: CGRect(x: 100, y: 600, width: 500, height: 14), baseline: 612, xHeight: 7,
                           alignment: .left, confidence: 1, words: words)
        let lines = (0..<12).map { k -> TextLine in var l = cap; l.bounds.origin.y += CGFloat(k) * 20; l.baseline += CGFloat(k) * 20; return l }
        let layout = PageLayout(size: CGSize(width: 800, height: 1100), figures: [CGRect(x: 100, y: 100, width: 600, height: 490)],
                                rules: [], paragraphs: [Paragraph(family: .serif, fontSize: 14, lines: lines)])
        let screens = Reflow.paginate(layout, palette: .original, ink: CGColor(gray: 0, alpha: 1), isDark: false,
                                      settings: ReflowSettings(scale: 3))
        for item in screens.flatMap(\.items) {
            if case .figure(_, let r) = item { XCTAssertGreaterThan(r.height, 0); XCTAssertGreaterThan(r.width, 0) }
        }
    }
}
