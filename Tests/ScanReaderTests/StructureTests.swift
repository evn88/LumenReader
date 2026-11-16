import XCTest
@testable import ScanReader

final class StructureTests: XCTestCase {
    /// Строка из слов, начиная с x (ширина слова — 12 px на знак, пробел — 10 px).
    private func line(_ x: CGFloat, _ y: CGFloat, _ words: [String], gap: CGFloat = 10) -> TextLine {
        var cx = x
        let ws = words.map { t -> Word in
            defer { cx += CGFloat(t.count) * 12 + gap }
            return Word(text: t, bounds: CGRect(x: cx, y: y, width: CGFloat(t.count) * 12, height: 20))
        }
        let b = ws.map(\.bounds).reduce(ws[0].bounds) { $0.union($1) }
        return TextLine(bounds: b, baseline: y + 16, xHeight: 11, alignment: .left, confidence: 0.9, words: ws)
    }

    private let detector = StructureDetector(width: 1200, height: 1700)

    // MARK: оглавление

    func testTableOfContentsWithLeadersAndLevels() {
        var lines: [TextLine] = [line(130, 150, ["Оглавление"])]
        let entries: [(CGFloat, String, String)] = [
            (130, "Предисловие", "7"), (130, "Глава 1. Бумага", "11"), (180, "1.1. Формат листа", "12"),
            (180, "1.2. Шрифт", "18"), (130, "Глава 2. Скан", "31"),
        ]
        for (k, e) in entries.enumerated() {
            let y = 250 + CGFloat(k) * 50
            lines.append(line(e.0, y, e.1.split(separator: " ").map(String.init) + ["........"]))
            lines.append(line(1100 - CGFloat(e.2.count) * 12, y, [e.2]))   // номер — отдельной строкой OCR
        }
        let r = detector.detect(lines)
        XCTAssertEqual(r.toc.count, 1)
        let toc = r.toc[0]
        XCTAssertEqual(toc.entries.map { $0.page?.text }, ["7", "11", "12", "18", "31"])
        XCTAssertEqual(toc.entries.map(\.level), [0, 0, 1, 1, 0])
        XCTAssertTrue(toc.entries.allSatisfy(\.leader))
        XCTAssertEqual(toc.entries[2].title, "1.1. Формат листа", "точки-заполнители в название не попадают")
        XCTAssertEqual(r.lines.map(\.text), ["Оглавление"], "заголовок оглавления остаётся текстом")
    }

    func testTableOfContentsWithoutLeadersNeedsWideGap() {
        // номер сразу после текста — это не оглавление («Глава 1», «в 2019 году»)
        let lines = (0..<4).map { line(130, 200 + CGFloat($0) * 40, ["Строка", "номер", "\($0 + 1)"]) }
        XCTAssertTrue(detector.detect(lines).toc.isEmpty)
        // широкий пробел до номера у правого края — оглавление
        let toc = (0..<4).flatMap { k -> [TextLine] in
            let y = 200 + CGFloat(k) * 40
            return [line(130, y, ["Раздел", "\(k + 1)"]), line(1080, y, ["\(10 + k * 7)"])]
        }
        let r = detector.detect(toc)
        XCTAssertEqual(r.toc.first?.entries.count, 4)
        XCTAssertEqual(r.toc.first?.entries.first?.leader, false)
    }

    func testWrappedTitleAndUnreadableNumber() {
        let lines = [
            line(130, 200, ["Введение"]), line(1088, 200, ["5"]),
            // длинное название переносится, номер — на второй строке
            line(130, 250, ["Очень", "длинное", "название", "раздела", "которое", "не", "помещается", "в", "одну", "строку", "до"], gap: 20),
            line(160, 280, ["конца"]), line(1076, 280, ["17"]),
            line(130, 330, ["Заключение"]), line(1076, 330, ["2×"]),   // мусор вместо номера
            line(130, 380, ["Литература"]), line(1076, 380, ["40"]),
        ]
        let r = detector.detect(lines)
        let e = r.toc.first?.entries ?? []
        XCTAssertEqual(e.count, 4)
        XCTAssertEqual(e[1].lines.count, 2, "перенос названия — один пункт")
        XCTAssertEqual(e[1].page?.text, "17")
        XCTAssertEqual(e[2].page?.confidence, 0, "нечитаемый номер покажем фрагментом скана")
    }

    // MARK: таблицы

    func testBorderlessTable() {
        let rows = [["Разрешение", "Кегль", "Кегль"], ["150", "41,2", "18,5"], ["200", "17.8", "6,3"],
                    ["300", "4,9", "1,7"], ["600", "3,1", "1,2"]]
        var lines: [TextLine] = [line(130, 100, ["Обычный", "абзац", "текста", "над", "таблицей", "из", "многих", "слов"])]
        for (k, r) in rows.enumerated() {
            let y = 160 + CGFloat(k) * 40
            for (c, v) in r.enumerated() { lines.append(line(130 + CGFloat(c) * 300, y, [v])) }
        }
        let res = detector.detect(lines)
        XCTAssertEqual(res.tables.count, 1)
        let t = res.tables[0]
        XCTAssertEqual(t.columns.count - 1, 3)
        XCTAssertEqual(t.rows.count - 1, 5)
        XCTAssertTrue(t.text.contains("200\t17,8\t6,3"), "разделитель — как у большинства чисел колонки: \(t.text)")
        XCTAssertEqual(res.lines.count, 1)
    }

    func testRaggedRowsBecomeScanFragment() {
        // строки «с дырами», но колонки не сходятся — фрагмент скана, а не выдуманная таблица
        var lines: [TextLine] = []
        let xs: [[CGFloat]] = [[130, 500], [130, 300, 700], [400, 900], [130, 620]]
        for (k, row) in xs.enumerated() {
            for (i, x) in row.enumerated() { lines.append(line(x, 200 + CGFloat(k) * 40, ["слово\(k)\(i)", "ещё"])) }
        }
        // перекрывающиеся по x куски разных рядов не оставляют просветов
        lines.append(line(130, 360, ["длинная", "строка", "через", "всю", "ширину", "без", "просветов", "вообще", "совсем"], gap: 60))
        let r = detector.detect(lines)
        XCTAssertTrue(r.tables.isEmpty)
        XCTAssertEqual(r.scans.count, 1)
    }

    // MARK: колонки

    func testTwoColumnsReadColumnByColumn() {
        var lines = [line(130, 100, ["Заголовок", "на", "всю", "ширину", "страницы"])]
        for k in 0..<6 {
            let y = 200 + CGFloat(k) * 34
            lines.append(line(130, y, ["левая", "колонка", "строка", "\(k)", "текста"]))
            lines.append(line(640, y, ["правая", "колонка", "строка", "\(k)", "текста"]))
        }
        let r = detector.detect(lines)
        XCTAssertEqual(r.zones.count, 1)
        let order = r.lines.map(\.text)
        XCTAssertEqual(order.first, "Заголовок на всю ширину страницы")
        XCTAssertEqual(Array(order[1...6]), (0..<6).map { "левая колонка строка \($0) текста" })
        XCTAssertEqual(Array(order[7...12]), (0..<6).map { "правая колонка строка \($0) текста" })
    }

    // MARK: исправление OCR

    func testMixedScriptsAreUnified() {
        XCTAssertEqual(OCRCorrector.unifyScript("кoт"), "кот")             // латинская o
        XCTAssertEqual(OCRCorrector.unifyScript("Рython"), "Python")       // кириллическая Р
        XCTAssertEqual(OCRCorrector.unifyScript("SQL-зaпрос"), "SQL-запрос")
        XCTAssertEqual(OCRCorrector.unifyScript("жизнь"), "жизнь")
        XCTAssertEqual(OCRCorrector.unifyScript("Mixed"), "Mixed")
    }

    func testDigitLikeLettersInNumbers() {
        XCTAssertEqual(OCRCorrector.fixNumber("1O5"), "105")
        XCTAssertEqual(OCRCorrector.fixNumber("l9,"), "19,")
        XCTAssertEqual(OCRCorrector.fixNumber("З7"), "37")
        XCTAssertEqual(OCRCorrector.fixNumber("IO"), "IO", "без цифр — не число")
        XCTAssertEqual(OCRCorrector.fixNumber("3D"), "3D")
        XCTAssertEqual(OCRCorrector.fixNumber("Глава"), "Глава")
    }

    func testVisualDistance() {
        XCTAssertEqual(OCRCorrector.visualDistance("колопка", "колонка").cost, 0.5)
        XCTAssertTrue(OCRCorrector.visualDistance("колопка", "колонка").allConfusable)
        XCTAssertFalse(OCRCorrector.visualDistance("колодка", "колонка").allConfusable)
        XCTAssertEqual(OCRCorrector.visualDistance("Габлица", "Таблица").cost, 0.5)
    }

    func testDictionaryLanguages() {
        XCTAssertEqual(OCRCorrector.dictionaryLanguages(["ru-RU", "en-US"]).cyrillic, "ru")
        XCTAssertEqual(OCRCorrector.dictionaryLanguages(["ru-RU", "en-US"]).latin, "en")
        XCTAssertNil(OCRCorrector.dictionaryLanguages(["ru-RU", "sr-Cyrl"]).cyrillic, "два кириллических языка — по словарю не правим")
    }

    // MARK: раскладка и перекомпоновка

    private func structuredLayout() -> PageLayout {
        var lines: [TextLine] = []
        for (k, e) in [("Введение", "5"), ("Глава", "12"), ("Итоги", "30")].enumerated() {
            let y = 300 + CGFloat(k) * 50
            lines.append(line(130, y, [e.0, "......"])); lines.append(line(1076, y, [e.1]))
        }
        for k in 0..<3 {
            let y = 600 + CGFloat(k) * 40
            lines.append(line(130, y, ["a\(k)"])); lines.append(line(500, y, ["b\(k)"])); lines.append(line(900, y, ["c\(k)"]))
        }
        let r = detector.detect(lines)
        let p = Paragraph(family: .serif, fontSize: 20, lines: [line(130, 150, ["Абзац", "текста", "перед", "оглавлением", "страницы"])])
        return PageLayout(size: CGSize(width: 1200, height: 1700), figures: [], rules: [], paragraphs: [p],
                          tocBlocks: r.toc.map { var t = $0; for i in t.entries.indices { t.entries[i].fontSize = 20 }; return t },
                          tables: r.tables.map { var t = $0; t.fontSize = 20; return t })
    }

    func testPlainTextInReadingOrderAndCodable() throws {
        let l = structuredLayout()
        XCTAssertEqual(l.tocBlocks.count, 1)
        XCTAssertEqual(l.tables.count, 1)
        let text = l.plainText
        XCTAssertTrue(text.hasPrefix("Абзац текста"))
        XCTAssertTrue(text.contains("Введение\t5"))
        XCTAssertTrue(text.contains("a0\tb0\tc0"))
        XCTAssertLessThan(text.range(of: "Введение")!.lowerBound, text.range(of: "a0")!.lowerBound)
        // кеш: новые поля сохраняются, старые раскладки (без них) читаются
        let back = try JSONDecoder().decode(PageLayout.self, from: JSONEncoder().encode(l))
        XCTAssertEqual(back, l)
        let old = #"{"size":[100,100],"figures":[],"rules":[],"paragraphs":[]}"#
        XCTAssertNoThrow(try JSONDecoder().decode(PageLayout.self, from: Data(old.utf8)))
    }

    func testWordNumbersMatchSelectionGeometry() {
        var l = structuredLayout()
        l.numberWords()
        let gids = l.allLines.flatMap(\.words).compactMap(\.gid)
        XCTAssertEqual(gids, Array(0..<gids.count))
        let geo = WordGeometry(layout: l)
        XCTAssertEqual(geo.text[gids.last!], l.allLines.last?.words.last?.text)
    }

    func testReflowKeepsStructure() {
        let l = structuredLayout()
        let pages = Reflow.paginate(l, palette: .original, ink: CGColor(gray: 0, alpha: 1), isDark: false,
                                    settings: ReflowSettings(scale: 1.6))
        let items = pages.flatMap(\.items)
        XCTAssertTrue(items.contains { if case .leader = $0 { return true }; return false }, "точки-заполнители")
        let texts = pages.flatMap(\.lineTexts)
        XCTAssertTrue(texts.contains("Введение"))
        XCTAssertTrue(texts.contains("b2"))
        // все слова страницы доступны для выделения
        let boxes = Set(pages.flatMap(\.wordBoxes).map(\.gid))
        XCTAssertEqual(boxes.count, l.allLines.flatMap(\.words).count)
    }

    // MARK: заголовки и сложные блоки

    func testHeadingAlignmentFromItsOwnLines() {
        // заголовок по правому краю: первая строка во всю ширину раньше становилась «по ширине»
        let h = Paragraph(family: .sans, fontSize: 80, lines: [line(250, 300, ["Почему", "так", "важно", "изучать", "математику"]),
                                                                line(650, 400, ["искусственного", "интеллекта?"])])
        var hh = h
        // правый край обеих строк одинаковый
        let r0 = hh.lines[0].bounds.maxX, r1 = hh.lines[1].bounds.maxX
        hh.lines[1].bounds.origin.x += r0 - r1
        let body = (0..<6).map { k in line(130, 600 + CGFloat(k) * 40, ["обычная", "строка", "основного", "текста", "страницы"]) }
        var ps = [hh, Paragraph(family: .serif, fontSize: 30, lines: body)]
        Headings.refine(&ps, pageWidth: 1200)
        XCTAssertTrue(ps[0].lines.allSatisfy { $0.alignment == .right })
    }

    func testFormulasAndGarbageGoToScan() {
        XCTAssertTrue(ComplexBlocks.isGarbage(line(100, 100, ["5555555555555555"])))
        XCTAssertTrue(ComplexBlocks.isGarbage(line(100, 100, ["44884849444"])))
        XCTAssertFalse(ComplexBlocks.isGarbage(line(100, 100, ["Рис.", "3.16"])))
        XCTAssertTrue(ComplexBlocks.isFormula(line(100, 100, ["∑", "a", "=", "1"])))
        XCTAssertFalse(ComplexBlocks.isFormula(line(100, 100, ["если", "x", "=", "0,", "то", "функция", "дифференцируема"])))
        // выключная формула по центру колонки уходит в скан, проза и код — нет
        var lines = (0..<5).map { k in line(130, 100 + CGFloat(k) * 40, ["обычная", "строка", "основного", "текста", "страницы", "здесь"]) }
        lines.append(line(500, 330, ["f(x)", "=", "sign", "(w", "x)"]))
        lines.append(line(130, 380, ["let", "x", "=", "a", "+", "b;"]))
        let out = ComplexBlocks.split(&lines)
        XCTAssertEqual(out.map(\.text), ["f(x) = sign (w x)"])
        XCTAssertEqual(lines.count, 6)
    }
}

