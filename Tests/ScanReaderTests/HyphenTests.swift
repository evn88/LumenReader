import XCTest
@testable import ScanReader

final class HyphenTests: XCTestCase {
    func testJoinsSplitWords() {
        XCTAssertEqual(Dehyphen.join("Единствен-", "ное").text, "Единственное")
        XCTAssertEqual(Dehyphen.join("укороче-", "нии,").text, "укорочении,")
        XCTAssertEqual(Dehyphen.join("помес-", "тить").text, "поместить")
        XCTAssertEqual(Dehyphen.join("program-", "ming").text, "programming")
    }

    func testKeepsRealHyphenatedWords() {
        XCTAssertEqual(Dehyphen.join("что-", "то").text, "что-то")
        XCTAssertEqual(Dehyphen.join("кто-", "нибудь").text, "кто-нибудь")
        XCTAssertEqual(Dehyphen.join("веб-", "приложений").text, "веб-приложений")
    }

    func testCandidateRules() {
        XCTAssertTrue(Dehyphen.isCandidate("слово-", "продолжение"))
        XCTAssertFalse(Dehyphen.isCandidate("слово-", "Новое"), "с прописной — не перенос")
        XCTAssertFalse(Dehyphen.isCandidate("слово", "далее"))
        XCTAssertTrue(Dehyphen.isCandidate("со\u{00AD}", "единение"))
    }

    // MARK: - перекомпоновка

    private func line(_ y: CGFloat, _ words: [String], align: LineAlignment = .justify) -> TextLine {
        var x: CGFloat = 50
        let ws = words.map { t -> Word in defer { x += CGFloat(t.count) * 9 + 8 }
            return Word(text: t, bounds: CGRect(x: x, y: y, width: CGFloat(t.count) * 9, height: 12)) }
        return TextLine(bounds: CGRect(x: 50, y: y, width: 500, height: 12), baseline: y + 12, xHeight: 7,
                        alignment: align, confidence: 1, words: ws)
    }

    /// Текст всех строк экранных страниц (через атрибутированные строки абзацев).
    private func reflowText(_ layout: PageLayout, carryIn: Bool = false, carryOut: String? = nil) -> String {
        let prepared = Reflow.prepare(layout, carryIn: carryIn, carryOut: carryOut)
        return prepared.paragraphs.map { p in
            var out = ""
            for (li, l) in p.lines.enumerated() {
                for (wi, w) in l.words.enumerated() {
                    var t = w.text
                    let last = wi == l.words.count - 1
                    if last, li + 1 < p.lines.count, let n = p.lines[li + 1].words.first?.text, Dehyphen.isCandidate(t, n) {
                        if !Dehyphen.join(t, n).keptHyphen { t.removeLast() }
                        out += t
                    } else {
                        out += t + " "
                    }
                }
            }
            return out.trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }

    func testHyphenatedLineIsNotParagraphEnd() {
        // «Единствен-» не дотягивает до правого края (alignment .left) — раньше это считалось концом абзаца
        let p = Paragraph(family: .serif, fontSize: 14, lines: [
            line(100, ["Это", "первая", "строка", "абзаца."]),
            line(120, ["Единствен-"], align: .left),
            line(140, ["ное", "изменение", "текста."], align: .left),
        ])
        let l = PageLayout(size: CGSize(width: 600, height: 800), figures: [], rules: [], paragraphs: [p])
        let screens = Reflow.paginate(l, palette: .original, ink: CGColor(gray: 0, alpha: 1), isDark: false,
                                      settings: ReflowSettings(scale: 1.4))
        let all = screens.flatMap(\.lineTexts).joined(separator: "|")
        XCTAssertTrue(all.contains("Единственное изменение"), all)
        XCTAssertFalse(all.contains("Единствен-"), all)
    }

    func testParagraphsSplitMidWordAreMerged() {
        let a = Paragraph(family: .serif, fontSize: 14, lines: [line(100, ["при", "укороче-"])])
        let b = Paragraph(family: .serif, fontSize: 14, lines: [line(120, ["нии", "строки"])])
        let l = PageLayout(size: CGSize(width: 600, height: 800), figures: [], rules: [], paragraphs: [a, b])
        XCTAssertEqual(reflowText(l), "при укорочении строки")
    }

    func testCarryAcrossPages() {
        let page1 = PageLayout(size: CGSize(width: 600, height: 800), figures: [], rules: [],
                               paragraphs: [Paragraph(family: .serif, fontSize: 14, lines: [line(700, ["нужно", "помес-"])])])
        let page2 = PageLayout(size: CGSize(width: 600, height: 800), figures: [], rules: [],
                               paragraphs: [Paragraph(family: .serif, fontSize: 14, lines: [line(100, ["тить", "текст"])])])
        XCTAssertTrue(Reflow.carry(from: page1, to: page2))
        XCTAssertEqual(reflowText(page1, carryOut: Reflow.firstBodyWord(page2)), "нужно поместить")
        XCTAssertEqual(reflowText(page2, carryIn: true), "текст")
    }

    func testRealHyphenWordSurvivesReflow() {
        let p = Paragraph(family: .serif, fontSize: 14, lines: [line(100, ["разработка", "веб-"]), line(120, ["приложений", "и", "что-"]),
                                                                line(140, ["то", "ещё"])])
        let l = PageLayout(size: CGSize(width: 600, height: 800), figures: [], rules: [], paragraphs: [p])
        XCTAssertEqual(reflowText(l), "разработка веб-приложений и что-то ещё")
    }

}
