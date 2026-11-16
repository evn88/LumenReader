import XCTest
@testable import ScanReader

final class TranslationTests: XCTestCase {
    private func line(_ text: String, y: CGFloat, align: LineAlignment = .justify, bold: Bool = false) -> TextLine {
        let words = text.split(separator: " ").enumerated().map { i, w in
            Word(text: String(w), bounds: CGRect(x: 100 + CGFloat(i) * 60, y: y, width: 50, height: 20), bold: bold)
        }
        return TextLine(bounds: CGRect(x: 100, y: y, width: 800, height: 20), baseline: y + 16, xHeight: 10,
                        alignment: align, confidence: 0.9, words: words)
    }

    private func layout(_ paragraphs: [[TextLine]], size: CGFloat = 20) -> PageLayout {
        PageLayout(size: CGSize(width: 1000, height: 1400), figures: [], rules: [],
                   paragraphs: paragraphs.map { Paragraph(family: .serif, fontSize: size, lines: $0) })
    }

    /// Абзац — единица перевода: строки склеены, перенос «ком-»+«понент» убран.
    func testUnitsJoinLinesAndHyphens() {
        let l = layout([[line("Мы создадим простой ком-", y: 200), line("понент счетчика.", y: 230, align: .left)]])
        XCTAssertEqual(PageText.units(l), ["Мы создадим простой компонент счетчика."])
    }

    /// OCR разорвал предложение на два абзаца — переводчик получает его целиком.
    func testSentenceSplitByOCRIsMerged() {
        let l = layout([[line("нельзя создать закладку на", y: 200, align: .left)],
                        [line("вкладке Offices. Более того", y: 230)]])
        XCTAssertEqual(PageText.units(l).count, 1)
        // законченное предложение — граница абзаца
        let l2 = layout([[line("Первый абзац.", y: 200, align: .left)], [line("Второй абзац", y: 230)]])
        XCTAssertEqual(PageText.units(l2).count, 2)
    }

    /// Перевод раскладывается по исходным строкам: ни одно слово не теряется, жирность сохраняется.
    func testTranslatedLayoutKeepsAllWords() {
        let l = layout([[line("Заголовок главы", y: 100, align: .center, bold: true)],
                        [line("Первая строка абзаца", y: 200), line("и вторая строка.", y: 230, align: .left)]])
        let t: [String?] = ["Chapter title", "The first line of the paragraph and the second line."]
        let out = PageText.translatedLayout(l, t)
        XCTAssertEqual(out.paragraphs.count, 2)
        XCTAssertEqual(out.paragraphs[0].lines.flatMap(\.words).map(\.text).joined(separator: " "), "Chapter title")
        XCTAssertTrue(out.paragraphs[0].lines.flatMap(\.words).allSatisfy(\.bold))
        XCTAssertEqual(out.paragraphs[1].lines.flatMap(\.words).map(\.text).joined(separator: " "), t[1])
        XCTAssertEqual(out.paragraphs[1].lines.last?.alignment, .left)
        // перекомпоновка переведённой страницы не падает и даёт текст
        let screens = Reflow.paginate(out, palette: .original, ink: CGColor(gray: 0, alpha: 1), isDark: false,
                                      settings: ReflowSettings(scale: 1.0001))
        XCTAssertTrue(screens.flatMap(\.lineTexts).joined(separator: " ").contains("paragraph"))
    }

    /// Абзац без перевода (nil — уже на нужном языке) остаётся как был.
    func testUntranslatedParagraphStays() {
        let l = layout([[line("Hello world.", y: 200, align: .left)]])
        XCTAssertEqual(PageText.translatedLayout(l, [nil]).paragraphs[0].lines[0].text, "Hello world.")
    }

    func testLanguageDetection() {
        XCTAssertEqual(LanguageGuess.detect("Когда пользователь щелкнет по одной из вкладок, обновляется переменная"), "ru")
        XCTAssertEqual(LanguageGuess.detect("When the user clicks on one of the tabs, the variable is updated"), "en")
        // короткая подпись — язык страницы, а не случайная догадка
        XCTAssertEqual(LanguageGuess.detect("Offices People", hint: "ru"), "ru")
        XCTAssertNil(LanguageGuess.detect("42"))
        // соседние языки одной письменности на коротком тексте — язык книги, а не украинский/казахский
        XCTAssertEqual(LanguageGuess.detect("Глава 3. Хуки и состояние компонента", hint: "ru"), "ru")
        XCTAssertEqual(LanguageGuess.detect("Рис. 2.4. По умолчанию компонент OldAbout отображает подробную информацию о людях", hint: "ru"), "ru")
        // настоящий английский абзац в русской книге остаётся английским (другая письменность)
        XCTAssertEqual(LanguageGuess.detect("Welcome to your new Gatsby site. Now go build something great with React.", hint: "ru"), "en")
        XCTAssertEqual(LanguageGuess.script(of: "Привет, world"), .cyrillic)
        XCTAssertEqual(LanguageGuess.bookLanguage([[String(repeating: "Когда пользователь щелкнет по одной из вкладок, обновляется переменная. ", count: 6)]]), "ru")
        XCTAssertTrue(LanguageGuess.same("en-US", "en"))
        XCTAssertFalse(LanguageGuess.same("sr", "ru"))
    }

    /// Кеш перевода: отпечаток зависит от текста, запись читается обратно.
    func testStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let book = dir.appendingPathComponent("book.pdf")
        let store = TranslationStore(book: book, target: "en", engine: "apple")
        XCTAssertTrue(store.dir.path.contains(".scanreader/book.pdf/translations/apple/en"))
        XCTAssertNotEqual(TranslationStore(book: book, target: "en", engine: "gemma4").dir, store.dir, "модели не делят кеш")
        let units = ["Привет", "мир"]
        let e = TranslationStore.Entry(source: PageText.fingerprint(units), units: ["Hello", nil], engine: nil)
        store.save(e, "page-3")
        XCTAssertEqual(store.load("page-3"), e)
        XCTAssertEqual(store.keys(), ["page-3"])
        XCTAssertNotEqual(PageText.fingerprint(units), PageText.fingerprint(["Привет", "мир!"]))
    }
}
