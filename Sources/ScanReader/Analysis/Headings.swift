import CoreGraphics
import Foundation

/// Заголовки: крупнее основного текста. Выравнивание — по их собственным строкам, а не по колонке набора
/// (иначе длинная строка заголовка «по правому краю» становится выключенной по ширине), без выключки.
enum Headings {
    /// Кегль основного текста страницы: медиана по строкам.
    static func bodySize(_ ps: [Paragraph]) -> CGFloat {
        let sizes = ps.flatMap { p in p.lines.map { _ in p.fontSize } }.sorted()
        return sizes.isEmpty ? 0 : sizes[sizes.count / 2]
    }

    static func isHeading(_ p: Paragraph, body: CGFloat) -> Bool {
        body > 0 && p.fontSize >= body * 1.25 && p.lines.count <= 4
    }

    static func refine(_ ps: inout [Paragraph], pageWidth W: CGFloat) {
        let body = bodySize(ps)
        let bodyLines = ps.filter { !isHeading($0, body: body) }.flatMap(\.lines)
        let lefts = bodyLines.map(\.bounds.minX).sorted(), rights = bodyLines.map(\.bounds.maxX).sorted()
        let colL = lefts.isEmpty ? W * 0.1 : lefts[lefts.count / 2]
        let colR = rights.isEmpty ? W * 0.9 : rights[min(rights.count - 1, Int(Double(rights.count) * 0.9))]
        for i in ps.indices where isHeading(ps[i], body: body) {
            let lines = ps[i].lines
            let tol = max(lines.map(\.xHeight).max() ?? 8, W * 0.01)
            let ls = lines.map(\.bounds.minX), rs = lines.map(\.bounds.maxX), ms = lines.map(\.bounds.midX)
            func spread(_ a: [CGFloat]) -> CGFloat { (a.max() ?? 0) - (a.min() ?? 0) }
            let align: LineAlignment
            if lines.count > 1 {
                if spread(rs) <= tol && spread(ls) > tol { align = .right }
                else if spread(ms) <= tol && spread(ls) > tol { align = .center }
                else { align = .left }
            } else {
                let b = lines[0].bounds
                if abs(b.maxX - colR) <= tol * 1.5 && b.minX > colL + tol * 2 { align = .right }
                else if abs(b.midX - (colL + colR) / 2) <= tol * 1.5 && b.minX > colL + tol * 2 { align = .center }
                else { align = .left }
            }
            for li in ps[i].lines.indices { ps[i].lines[li].alignment = align }
        }
    }
}

/// Блоки, которые текстом не воспроизвести: формулы, цифры и подписи внутри графиков, мусор распознавания.
enum ComplexBlocks {
    private static let mathOnly = Set("∑∫√∂∞≤≥≈∈∉⊂⊆∀∃∇∏±×÷→←↔⇒⇔′″αβγδεθλμσφψωΣΠΔΩ")
    private static let mathOps = Set("=+−-*/^_|<>()[]{}·∘")

    /// Строка похожа на формулу: однобуквенные «слова» вперемешку со знаками операций.
    static func isFormula(_ l: TextLine) -> Bool {
        let t = l.text
        let chars = t.filter { !$0.isWhitespace }
        guard !chars.isEmpty else { return false }
        let longWords = l.words.filter { $0.text.filter(\.isLetter).count >= 4 }.count
        if chars.contains(where: { mathOnly.contains($0) }) && longWords <= 2 { return true }
        let ops = chars.filter { mathOps.contains($0) }.count
        let short = l.words.filter { $0.text.count <= 2 }.count
        return ops >= 2 && longWords <= 1 && Double(short) >= 0.5 * Double(l.words.count)
    }

    /// Мусор: почти нет букв и повторяющиеся знаки («5555555», «44884849444»), или очень низкая уверенность.
    static func isGarbage(_ l: TextLine) -> Bool {
        let chars = Array(l.text.filter { !$0.isWhitespace })
        guard chars.count >= 3 else { return false }
        let letters = chars.filter(\.isLetter).count
        var run = 1, maxRun = 1
        for k in 1..<chars.count { run = chars[k] == chars[k - 1] ? run + 1 : 1; maxRun = max(maxRun, run) }
        let distinct = Set(chars).count
        if letters * 3 < chars.count && (maxRun >= 4 || Double(distinct) <= 0.35 * Double(chars.count)) { return true }
        return l.confidence < 0.3 && letters * 2 < chars.count
    }

    /// Строки-формулы и мусор забираем из текста. Строка без единого слова (из трёх букв и больше),
    /// набранная втрое крупнее основного текста, — тоже мусор: так распознаются цифры на рисунках.
    static func split(_ lines: inout [TextLine]) -> [TextLine] {
        let xs = lines.map(\.xHeight).sorted()
        let bodyX = xs.isEmpty ? 0 : xs[xs.count / 2]
        var out: [TextLine] = []
        // колонка набора: выключная формула стоит по центру, код — от левого края
        let lefts = lines.filter { $0.words.count > 3 }.map(\.bounds.minX).sorted()
        let rights = lines.filter { $0.words.count > 3 }.map(\.bounds.maxX).sorted()
        let colL = lefts.isEmpty ? nil : lefts[lefts.count / 2]
        let colR = rights.isEmpty ? nil : rights[min(rights.count - 1, Int(Double(rights.count) * 0.9))]
        func centeredFormula(_ l: TextLine) -> Bool {
            guard let a = colL, let b = colR, b - a > 0 else { return false }
            let w = b - a
            let centered = abs(l.bounds.midX - (a + b) / 2) < 0.06 * w && l.bounds.minX > a + 0.08 * w
            let ops = l.text.filter { "=+−<>≤≥≈".contains($0) }.count
            return centered && ops >= 1 && l.words.count <= 12
        }
        lines.removeAll { l in
            if centeredFormula(l) { out.append(l); return true }
            let text = l.text
            if CodeDetector.detectLanguage(text).score >= 2 || text.contains(";") { return false }
            let hasWord = l.words.contains { $0.text.filter(\.isLetter).count >= 3 }
            let huge = bodyX > 0 && l.xHeight > bodyX * 1.8 && !hasWord
            if isFormula(l) || isGarbage(l) || huge { out.append(l); return true }
            return false
        }
        return out
    }

    /// Абзац целиком из формул или мусора (короткая формула внутри прозы — не в счёт).
    static func isComplex(_ lines: [TextLine]) -> Bool {
        // код (тоже много знаков и коротких слов) показываем блоком кода, а не сканом
        let text = lines.map(\.text).joined(separator: "\n")
        if CodeDetector.detectLanguage(text).score >= 2 || text.contains(";") { return lines.allSatisfy(isGarbage) }
        let bad = lines.filter { isFormula($0) || isGarbage($0) }.count
        return bad > 0 && bad * 2 >= lines.count
    }
}
