import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Настройки, при которых текст перекомпонуется (масштаб ≠ 100%).
struct ReflowSettings: Hashable {
    /// Общий коэффициент кеглей: заголовки, текст, подписи, код — пропорции сохраняются.
    var scale: CGFloat = 1
    /// Множитель к межстрочному интервалу оригинала.
    var lineSpacing: CGFloat = 1
    /// Множитель к полям оригинала.
    var margins: CGFloat = 1
    var justify = true

    /// 100% — точная раскладка по исходным строкам, иначе — перекомпоновка.
    var reflows: Bool { abs(scale - 1) > 0.001 }
}

/// Экранная страница: элементы в координатах листа скана (пиксели, y вниз).
struct ScreenPage {
    enum Item {
        /// Строка CoreText; origin — точка базовой линии.
        case text(CTLine, origin: CGPoint)
        /// Иллюстрация `index` из layout.figures, вписанная в rect.
        case figure(index: Int, rect: CGRect)
        /// Подложка блока кода (на каждой экранной странице — своя часть блока).
        case codeBackground(CGRect, label: String?)
        case rule(CGRect)
        /// Колонтитул: исходная строка абзаца, рисуется на своём месте без масштаба.
        case runningLine(paragraph: Int, line: Int)
        /// Строка с низкой уверенностью OCR: фрагмент оригинала (глобальный индекс строки).
        case fallback(line: Int, rect: CGRect)
        /// Точки-заполнители оглавления от x0 до x1 на базовой линии.
        case leader(from: CGFloat, to: CGFloat, baseline: CGFloat, family: FontFamily, size: CGFloat, grid: CGFloat)
        /// Фрагмент скана на месте структуры, которую не удалось воссоздать (индекс layout.scanRegions).
        case scan(index: Int, rect: CGRect)
    }
    var items: [Item] = []
    /// Текст каждой строки перекомпоновки (копирование, поиск, тесты).
    var lineTexts: [String] = []
    /// Рамки слов на экранной странице (координаты листа) по сквозному номеру слова — выделение и хайлайты.
    var wordBoxes: [(gid: Int, rect: CGRect)] = []
}

/// Перекомпоновка страницы скана в 1…n экранных страниц того же формата.
enum Reflow {
    private enum Block {
        case paragraph(Int)
        case code(Int)
        case figure(Int)
        case rule(CGRect)
        case toc(Int)
        case table(Int)
        case scan(Int)
    }

    /// - Parameters:
    ///   - carryIn: первое слово страницы — окончание слова, перенесённого с предыдущей страницы (уже склеено там).
    ///   - carryOut: начало следующей страницы, если последнее слово этой оборвано переносом.
    static func paginate(_ layout: PageLayout, palette: FontPalette, ink: CGColor, isDark: Bool,
                         settings: ReflowSettings, carryIn: Bool = false, carryOut: String? = nil) -> [ScreenPage] {
        // строки оглавлений и таблиц идут в allLines после строк абзацев исходной раскладки
        let structureLineStart = layout.paragraphs.reduce(0) { $0 + $1.lines.count }
        let layout = prepare(layout, carryIn: carryIn, carryOut: carryOut)
        let W = layout.size.width, H = layout.size.height, s = settings.scale

        // 1. Колонтитул: строки над верхней линейкой (или в верхних 7% листа, короткие) — не перекомпонуем.
        let topRule = layout.rules.filter { $0.minY < H * 0.15 }.min { $0.minY < $1.minY }
        var running = Set<Int>()
        for (i, p) in layout.paragraphs.enumerated() {
            let b = p.lines.map(\.bounds).reduce(p.lines[0].bounds) { $0.union($1) }
            if let r = topRule, b.maxY <= r.maxY + 2 { running.insert(i) }
            else if topRule == nil, b.maxY < H * 0.07, p.lines.count == 1, p.lines[0].words.count <= 4 { running.insert(i) }
            else if b.minY > H * 0.94, p.lines.count == 1, p.lines[0].words.count <= 3 { running.insert(i) }   // номер внизу
        }

        // 2. Поток: абзацы, код, иллюстрации, линейки — по вертикали.
        var blocks: [(CGRect, Block)] = []
        for (i, p) in layout.paragraphs.enumerated() where !running.contains(i) {
            blocks.append((p.lines.map(\.bounds).reduce(p.lines[0].bounds) { $0.union($1) }, .paragraph(i)))
        }
        for (i, c) in layout.codeBlocks.enumerated() { blocks.append((c.bounds, .code(i))) }
        for (i, f) in layout.figures.enumerated() { blocks.append((f, .figure(i))) }
        for r in layout.rules where r != topRule { blocks.append((r, .rule(r))) }
        for (i, t) in layout.tocBlocks.enumerated() { blocks.append((t.bounds, .toc(i))) }
        for (i, t) in layout.tables.enumerated() { blocks.append((t.bounds, .table(i))) }
        for (i, r) in layout.scanRegions.enumerated() { blocks.append((r.rect, .scan(i))) }
        // порядок чтения: в многоколоночной зоне — колонка за колонкой
        blocks.sort { layout.readingKey($0.0) < layout.readingKey($1.0) }

        // 3. Колонка и поля (строки многоколоночных зон не в счёт: колонка экрана — во всю ширину набора).
        let inZone = { (l: TextLine) in layout.columnZones.contains { $0.rect.contains(CGPoint(x: l.bounds.midX, y: l.bounds.midY)) } }
        var body = layout.paragraphs.enumerated().filter { !running.contains($0.offset) }.flatMap { $0.element.lines }
        if body.contains(where: { !inZone($0) }) && body.filter({ !inZone($0) }).count >= 3 { body = body.filter { !inZone($0) } }
        else if !layout.columnZones.isEmpty {
            // вся страница в колонках: края набора — края зоны
            let z = layout.columnZones.map(\.rect).reduce(layout.columnZones[0].rect) { $0.union($1) }
            body = [TextLine(bounds: z, baseline: z.maxY, xHeight: 10, alignment: .left, confidence: 1, words: [])]
        }
        let lefts = body.map(\.bounds.minX).sorted(), rights = body.map(\.bounds.maxX).sorted()
        // оглавления и таблицы — тоже набор: колонка не уже их
        let structureRects = layout.tocBlocks.map(\.bounds) + layout.tables.map(\.bounds)
        var colL0 = lefts.isEmpty ? W * 0.08 : lefts[lefts.count / 2]
        if let m = structureRects.map(\.minX).min() { colL0 = lefts.isEmpty ? m : min(colL0, m) }
        var colR0 = rights.isEmpty ? W * 0.92 : rights[min(rights.count - 1, Int(Double(rights.count) * 0.9))]
        // код в книгах часто шире прозы: колонка — по самому широкому из них
        colR0 = max(colR0, (layout.codeBlocks.map(\.bounds) + structureRects).map(\.maxX).max() ?? 0)
        let colL = colL0 * settings.margins, colR = W - (W - colR0) * settings.margins
        let colW = max(W * 0.3, colR - colL)
        let headBottom = topRule.map { $0.maxY } ?? 0
        let firstTop = blocks.first?.0.minY ?? H * 0.08
        let top = max(headBottom + 12, min(firstTop, H * 0.1) * settings.margins)
        // нижнее поле — как верхнее (по низу последнего блока нельзя: неполная страница оборвёт поток)
        let bottom = H - max(H * 0.05, min(firstTop, H * 0.1)) * settings.margins

        // 4. Раскладка по экранным страницам.
        var pages = [ScreenPage()]
        var y = top
        var prevBottom: CGFloat?                     // низ предыдущего блока в оригинале
        func newPage() { pages.append(ScreenPage()); y = top }
        func add(_ item: ScreenPage.Item) { pages[pages.count - 1].items.append(item) }
        func gapBefore(_ r: CGRect, lineHeight: CGFloat) -> CGFloat {
            guard let pb = prevBottom else { return 0 }
            return min(max(0, r.minY - pb) * s, lineHeight * 1.6)
        }
        // строковые индексы для запасных фрагментов
        var lineStart: [Int] = []
        var acc = 0
        for p in layout.paragraphs { lineStart.append(acc); acc += p.lines.count }

        for (rect, block) in blocks {
            switch block {
            case .paragraph(let pi):
                let p = layout.paragraphs[pi]
                // левый край для абзацного отступа: в колонке многоколоночной зоны — край этой колонки
                var paraLeft = colL0
                if let z = layout.columnZones.first(where: { $0.rect.contains(CGPoint(x: rect.midX, y: rect.midY)) }) {
                    let col = z.column(of: rect)
                    let same = layout.paragraphs.flatMap(\.lines).filter {
                        z.rect.contains(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY)) && z.column(of: $0.bounds) == col
                    }
                    paraLeft = same.map(\.bounds.minX).sorted().dropFirst(same.count / 2).first ?? colL0
                }
                let pitches = zip(p.lines.dropFirst(), p.lines).map { $0.baseline - $1.baseline }.filter { $0 > 0 }.sorted()
                let pitch = pitches.isEmpty ? p.fontSize * 1.25 : pitches[pitches.count / 2]
                let lh = pitch * s * settings.lineSpacing
                y += gapBefore(rect, lineHeight: lh)
                if y > top, y + lh > bottom { newPage() }
                // ненадёжные строки — фрагментами оригинала, остальное — текстом
                var run: [TextLine] = []
                var runStartsParagraph = true      // false — продолжение после фрагмента оригинала
                func flushRun(first: Bool) {
                    guard !run.isEmpty else { return }
                    let (str, align, indent) = attributed(run, paragraph: p, colLeft: paraLeft, palette: palette, ink: ink,
                                                          settings: settings, indentFirst: first)
                    // отступ первой строки не больше 40% колонки: подпись у правого края иначе рвёт слово («Offi|ces»)
                    for t in typeset(str, width: colW, align: align, firstIndent: min(indent, colW * 0.4)) {
                        if y + t.baseline + t.descent > bottom, y > top { newPage() }
                        add(.text(t.line, origin: CGPoint(x: colL + t.x, y: y + t.baseline)))
                        pages[pages.count - 1].lineTexts.append(t.text)
                        pages[pages.count - 1].wordBoxes += t.words.map { w in
                            (w.0, CGRect(x: colL + t.x + w.1, y: y, width: max(1, w.2 - w.1), height: lh))
                        }
                        y += lh
                    }
                    run = []
                    runStartsParagraph = false
                }
                // в исходной раскладке соседние абзацы могли слиться: короткая невыключенная строка
                // посреди выключенного абзаца — его конец
                let hasJustify = p.lines.contains { $0.alignment == .justify }
                for (li, line) in p.lines.enumerated() {
                    // строка с переносом короче колонки, но это не конец абзаца
                    let prevHyphen = li > 0 && Dehyphen.isCandidate(p.lines[li - 1].words.last?.text ?? "", line.words.first?.text ?? "")
                    if hasJustify, li > 0, p.lines[li - 1].alignment == .left, !run.isEmpty, !prevHyphen {
                        flushRun(first: runStartsParagraph)
                        runStartsParagraph = true
                        y += lh * 0.35
                    }
                    if line.confidence < AnalyzedPage.minConfidence {
                        flushRun(first: runStartsParagraph)
                        let w = min(colW, line.bounds.width * s), h = line.bounds.height * w / max(1, line.bounds.width)
                        if y + h > bottom, y > top { newPage() }
                        add(.fallback(line: lineStart[pi] + li, rect: CGRect(x: colL, y: y, width: w, height: h)))
                        y += max(h, lh)
                    } else {
                        run.append(line)
                    }
                }
                flushRun(first: runStartsParagraph)
                prevBottom = rect.maxY

            case .code(let ci):
                let block = layout.codeBlocks[ci]
                let probe = palette.font(.mono, bold: false, italic: false, size: 100)
                let adv = TextMetrics.advance(TextMetrics.line("0", font: probe))
                let size = (adv > 0 ? 100 * block.pitch / adv : 12) * s
                let font = palette.font(.mono, bold: false, italic: false, size: size)
                let charW = TextMetrics.advance(TextMetrics.line("0", font: font))
                let steps = zip(block.lines.dropFirst(), block.lines).map { $0.baseline - $1.baseline }.filter { $0 > 0 }.sorted()
                // медиана, как в CodeBlock.text: минимум ломается на строках, разбитых OCR на два куска
                let step = steps.isEmpty ? block.pitch * 2.2 : steps[steps.count / 2]
                let lh = step * s * settings.lineSpacing
                let pad = block.pitch * 1.2 * s
                // дальше y — базовая линия текущей строки кода
                y += gapBefore(rect, lineHeight: lh) + pad
                if y + lh > bottom, y > top { newPage(); y += pad }
                y += lh * 0.75
                var segTop = y - pad * 0.8 - lh * 0.75
                var label: String? = block.language == .plain ? nil : block.language.title
                func closeSegment() {
                    // y уже на строку ниже последней: её низ ≈ y - lh + 0.3·lh
                    let r = CGRect(x: colL - pad, y: segTop, width: colW + 2 * pad, height: y - lh * 0.7 + pad * 0.8 - segTop)
                    pages[pages.count - 1].items.insert(.codeBackground(r, label: label), at: 0)
                    label = nil
                }
                var prev: CGFloat?
                for cl in block.lines {
                    // пустые строки кода, как в оригинале
                    if let pb = prev { y += max(0, ((cl.baseline - pb) / step).rounded() - 1) * lh }
                    prev = cl.baseline
                    let attr = NSMutableAttributedString(string: cl.text, attributes: [
                        NSAttributedString.Key(kCTFontAttributeName as String): font,
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink,
                    ])
                    for (range, kind) in SyntaxHighlighter.tokens(cl.text, block.language) {
                        attr.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String),
                                          value: SyntaxHighlighter.color(kind, dark: isDark, ink: ink), range: range)
                    }
                    // не помещается по ширине — перенос с отступом продолжения
                    let indentX = CGFloat(cl.indent) * charW
                    let typesetter = CTTypesetterCreateWithAttributedString(attr)
                    var start = 0
                    var first = true
                    while start < attr.length {
                        let x = indentX + (first ? 0 : 4 * charW)
                        var n = CTTypesetterSuggestLineBreak(typesetter, start, Double(max(charW * 8, colW - x)))
                        // перенос кода — по пробелу или после разделителя, а не посреди идентификатора
                        if start + n < attr.length {
                            let t = attr.string as NSString
                            let seps = Set(" ,([{.:=".utf16)
                            var k = start + n
                            while k > start + 1, !seps.contains(t.character(at: k - 1)) { k -= 1 }
                            if k > start + 1 { n = k - start }
                        }
                        let ct = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: max(1, n)))
                        if y + lh * 0.3 > bottom {
                            closeSegment(); newPage(); y += pad + lh * 0.75; segTop = y - pad * 0.8 - lh * 0.75
                        }
                        add(.text(ct, origin: CGPoint(x: colL + x, y: y)))
                        y += lh
                        start += max(1, n)
                        first = false
                    }
                }
                closeSegment()
                y += pad - lh * 0.75
                prevBottom = rect.maxY

            case .toc(let ti):
                let toc = layout.tocBlocks[ti]
                var lineIndex = structureLineStart + layout.tocBlocks[..<ti].reduce(0) { $0 + $1.entries.reduce(0) { $0 + $1.allLines.count } }
                var prevEntryBottom: CGFloat?
                for e in toc.entries {
                    let size = e.fontSize * s
                    let pitches = toc.entries.flatMap(\.lines).map(\.bounds.height).sorted()
                    let lh = max(size * 1.25, (pitches.isEmpty ? size : pitches[pitches.count / 2]) * s * 1.2) * settings.lineSpacing
                    let entryRect = e.allLines.map(\.bounds).reduce(e.allLines[0].bounds) { $0.union($1) }
                    if let pb = prevEntryBottom { y += min(max(0, entryRect.minY - pb) * s, lh * 1.4) } else { y += gapBefore(rect, lineHeight: lh) }
                    prevEntryBottom = entryRect.maxY
                    if y + lh > bottom, y > top { newPage() }
                    // номер страницы
                    var numberLine: CTLine?, nw: CGFloat = 0
                    if let p = e.page {
                        let str = wordsString(p.words, family: e.family, size: size, palette: palette, ink: ink)
                        let l = CTLineCreateWithAttributedString(str)
                        numberLine = l; nw = TextMetrics.advance(l)
                    }
                    let indent = min((e.lines[0].bounds.minX - toc.bounds.minX) * s, colW * 0.25)
                    let hang = size
                    let avail = colW - indent - (numberLine != nil ? nw + size * 1.6 : 0)
                    let title = wordsString(e.lines.flatMap(\.words), family: e.family, size: size, palette: palette, ink: ink)
                    let typeset = Self.typeset(title, width: max(size * 4, avail - hang), align: .natural, firstIndent: -hang)
                    var lastEnd = colL + indent, lastBaseline = y
                    for t in typeset {
                        if y + lh > bottom, y > top { newPage() }
                        let x = colL + indent + hang + t.x
                        add(.text(t.line, origin: CGPoint(x: x, y: y + t.baseline)))
                        pages[pages.count - 1].lineTexts.append(t.text)
                        pages[pages.count - 1].wordBoxes += t.words.map { w in (w.0, CGRect(x: x + w.1, y: y, width: max(1, w.2 - w.1), height: lh)) }
                        lastEnd = x + TextMetrics.advance(t.line) - CGFloat(CTLineGetTrailingWhitespaceWidth(t.line))
                        lastBaseline = y + t.baseline
                        y += lh
                    }
                    lineIndex += e.lines.count
                    if let numberLine, let p = e.page {
                        var nx = colL + colW - nw
                        if p.confidence < AnalyzedPage.minConfidence {
                            // нечитаемый номер — фрагментом скана, в масштабе текста
                            let k = size / max(e.fontSize, 1)
                            let r = p.bounds.insetBy(dx: -3, dy: -3)
                            nx = colL + colW - r.width * k
                            add(.fallback(line: lineIndex,
                                          rect: CGRect(x: nx, y: lastBaseline - (p.baseline - r.minY) * k, width: r.width * k, height: r.height * k)))
                        } else {
                            add(.text(numberLine, origin: CGPoint(x: nx, y: lastBaseline)))
                        }
                        if let g = p.words.first?.gid {
                            pages[pages.count - 1].wordBoxes.append((g, CGRect(x: nx, y: lastBaseline - lh * 0.8, width: nw, height: lh)))
                        }
                        if e.leader {
                            add(.leader(from: lastEnd, to: nx, baseline: lastBaseline, family: e.family, size: size, grid: colL))
                        }
                        lineIndex += 1
                    }
                }
                prevBottom = rect.maxY

            case .table(let ti):
                let t = layout.tables[ti]
                let tw = t.columns.last! - t.columns.first!
                // таблица масштабируется целиком (как картинка), но не шире колонки
                let k = min(s, colW / max(tw, 1))
                let ox = colL + min(max(0, (t.columns.first! - colL0) * k), max(0, colW - tw * k))
                y += gapBefore(rect, lineHeight: t.fontSize * k * 1.3)
                var lineIndex = structureLineStart + layout.tocBlocks.reduce(0) { $0 + $1.entries.reduce(0) { $0 + $1.allLines.count } }
                    + layout.tables[..<ti].reduce(0) { $0 + $1.cells.reduce(0) { $0 + $1.lines.count } }
                var cellStart: [Int] = []
                for c in t.cells { cellStart.append(lineIndex); lineIndex += c.lines.count }
                let rw = max(1, t.ruleWidth * k)
                for r in 0..<(t.rows.count - 1) {
                    let rowTop = t.rows[r], rowH = (t.rows[r + 1] - rowTop) * k
                    if y + rowH > bottom, y > top { newPage() }
                    func X(_ x: CGFloat) -> CGFloat { ox + (x - t.columns.first!) * k }
                    func Y(_ yy: CGFloat) -> CGFloat { y + (yy - rowTop) * k }
                    if t.ruled {
                        add(.rule(CGRect(x: X(t.columns.first!) - rw / 2, y: y - rw / 2, width: tw * k + rw, height: rw)))
                        add(.rule(CGRect(x: X(t.columns.first!) - rw / 2, y: y + rowH - rw / 2, width: tw * k + rw, height: rw)))
                        for g in t.gridRules where g.width < g.height && abs(g.minY - rowTop) < 2 {
                            add(.rule(CGRect(x: X(g.midX) - rw / 2, y: y, width: rw, height: rowH)))
                        }
                    }
                    for (ci, cell) in t.cells.enumerated() where cell.row == r {
                        for (li, l) in cell.lines.enumerated() {
                            let gi = cellStart[ci] + li
                            let box = CGRect(x: X(l.bounds.minX), y: Y(l.bounds.minY), width: l.bounds.width * k, height: l.bounds.height * k)
                            if l.confidence < AnalyzedPage.minConfidence {
                                add(.fallback(line: gi, rect: box.insetBy(dx: -3 * k, dy: -3 * k)))
                                continue
                            }
                            let str = wordsString(l.words, family: t.family, size: t.fontSize * k, palette: palette, ink: ink)
                            let ct = CTLineCreateWithAttributedString(str)
                            let w = TextMetrics.advance(ct)
                            let x: CGFloat
                            switch l.alignment {
                            case .right: x = box.maxX - w
                            case .center: x = box.midX - w / 2
                            default: x = box.minX
                            }
                            let base = Y(l.baseline)
                            add(.text(ct, origin: CGPoint(x: x, y: base)))
                            pages[pages.count - 1].lineTexts.append(l.text)
                            str.enumerateAttribute(wordKey, in: NSRange(location: 0, length: str.length)) { v, range, _ in
                                guard let gid = v as? Int else { return }
                                let x0 = CTLineGetOffsetForStringIndex(ct, range.location, nil)
                                let x1 = CTLineGetOffsetForStringIndex(ct, range.location + range.length, nil)
                                pages[pages.count - 1].wordBoxes.append((gid, CGRect(x: x + x0, y: box.minY, width: max(1, x1 - x0), height: box.height)))
                            }
                        }
                    }
                    y += rowH
                }
                prevBottom = rect.maxY

            case .scan(let si):
                let r = layout.scanRegions[si].rect
                var w = r.width * s, h = r.height * s
                if w > colW { h *= colW / w; w = colW }
                y += gapBefore(rect, lineHeight: 20 * s)
                if y + h > bottom, y > top { newPage() }
                add(.scan(index: si, rect: CGRect(x: colL + min(max(0, (r.minX - colL0) * s), colW - w), y: y, width: w, height: h)))
                y += h
                prevBottom = rect.maxY

            case .figure(let fi):
                let f = layout.figures[fi]
                var w = f.width * s, h = f.height * s
                if w > colW { h *= colW / w; w = colW }
                // подпись сразу под иллюстрацией держим на той же экранной странице
                var reserve: CGFloat = 0
                if let k = blocks.firstIndex(where: { $0.0 == rect }), k + 1 < blocks.count,
                   case .paragraph(let ci) = blocks[k + 1].1, blocks[k + 1].0.minY - rect.maxY < layout.paragraphs[ci].fontSize * 3 {
                    let cap = layout.paragraphs[ci]
                    let chars = cap.lines.reduce(0) { $0 + $1.text.count }
                    let perLine = max(10, Int(colW / (cap.fontSize * s * 0.5)))
                    reserve = CGFloat((chars + perLine - 1) / perLine) * cap.fontSize * s * 1.3 * settings.lineSpacing
                        + (blocks[k + 1].0.minY - rect.maxY) * s
                }
                reserve = min(reserve, (bottom - top) * 0.4)
                let maxH = max(bottom - top - reserve, (bottom - top) * 0.3)
                if h > maxH { w *= maxH / h; h = maxH }
                y += gapBefore(rect, lineHeight: 20 * s)
                if y + h + reserve > bottom, y > top { newPage() }
                add(.figure(index: fi, rect: CGRect(x: colL + (colW - w) / 2, y: y, width: w, height: h)))
                y += h
                prevBottom = rect.maxY

            case .rule(let r):
                y += gapBefore(rect, lineHeight: 20 * s)
                if y + r.height > bottom, y > top { newPage() }
                add(.rule(CGRect(x: colL, y: y, width: colW, height: r.height)))
                y += r.height
                prevBottom = rect.maxY
            }
        }
        // колонтитул — на каждой экранной странице
        let heads: [ScreenPage.Item] = running.sorted().flatMap { pi in
            layout.paragraphs[pi].lines.indices.map { ScreenPage.Item.runningLine(paragraph: pi, line: $0) }
        } + (topRule.map { [ScreenPage.Item.rule($0)] } ?? [])
        if pages.count > 1, pages.last?.items.isEmpty == true { pages.removeLast() }
        return pages.map { var p = $0; p.items = heads + p.items; return p }
    }

    /// Атрибут строки: сквозной номер слова (Word.gid) — для выделений в перекомпоновке.
    static let wordKey = NSAttributedString.Key("sr.word")

    /// Подготовка раскладки к перекомпоновке: сквозные номера слов, склейка абзацев, разорванных
    /// посреди перенесённого слова, и переносы через границу страниц.
    static func prepare(_ layout: PageLayout, carryIn: Bool, carryOut: String?) -> PageLayout {
        var l = layout
        l.numberWords()
        // абзац, оборванный на «Единствен-», и следующий, начинающийся со строчной, — один абзац
        var merged: [Paragraph] = []
        for p in l.paragraphs {
            if var prev = merged.last, let a = prev.lines.last?.words.last?.text, let b = p.lines.first?.words.first?.text,
               Dehyphen.isCandidate(a, b), abs(prev.fontSize - p.fontSize) < max(prev.fontSize, 1) * 0.25,
               let pb = prev.lines.last?.bounds, let nb = p.lines.first?.bounds, nb.minY > pb.minY,
               nb.minY - pb.maxY < pb.height * 3 {
                prev.lines += p.lines
                merged[merged.count - 1] = prev
            } else {
                merged.append(p)
            }
        }
        l.paragraphs = merged
        let H = l.size.height
        func isBody(_ p: Paragraph) -> Bool {
            guard let b = p.lines.first?.bounds else { return false }
            return !(p.lines.count == 1 && (p.lines[0].words.count <= 4) && (b.maxY < H * 0.09 || b.minY > H * 0.91))
        }
        // окончание слова с прошлой страницы уже приклеено там — здесь его убираем
        if carryIn, let pi = l.paragraphs.firstIndex(where: isBody), !l.paragraphs[pi].lines[0].words.isEmpty {
            l.paragraphs[pi].lines[0].words.removeFirst()
            if l.paragraphs[pi].lines[0].words.isEmpty { l.paragraphs[pi].lines.removeFirst() }
            if l.paragraphs[pi].lines.isEmpty { l.paragraphs.remove(at: pi) }
        }
        // начало следующей страницы приклеиваем к последнему слову этой
        if let next = carryOut, let pi = l.paragraphs.lastIndex(where: isBody),
           let li = l.paragraphs[pi].lines.indices.last, let wi = l.paragraphs[pi].lines[li].words.indices.last {
            let w = l.paragraphs[pi].lines[li].words[wi].text
            if Dehyphen.isCandidate(w, next) { l.paragraphs[pi].lines[li].words[wi].text = Dehyphen.join(w, next).text }
        }
        return l
    }

    /// Первое слово следующей страницы и признак «эта страница начинается с окончания переноса».
    static func carry(from prev: PageLayout?, to page: PageLayout) -> Bool {
        guard let a = lastBodyWord(prev), let b = firstBodyWord(page) else { return false }
        return Dehyphen.isCandidate(a, b)
    }

    static func lastBodyWord(_ l: PageLayout?) -> String? {
        guard let l else { return nil }
        let H = l.size.height
        return l.paragraphs.last { p in p.lines.first.map { !($0.bounds.minY > H * 0.91 && p.lines.count == 1) } ?? false }?
            .lines.last?.words.last?.text
    }

    static func firstBodyWord(_ l: PageLayout?) -> String? {
        guard let l else { return nil }
        let H = l.size.height
        return l.paragraphs.first { p in p.lines.first.map { !($0.bounds.maxY < H * 0.09 && p.lines.count == 1) } ?? false }?
            .lines.first?.words.first?.text
    }

    /// Слова одной строкой (начертания слов, сквозные номера для выделения).
    static func wordsString(_ words: [Word], family: FontFamily, size: CGFloat, palette: FontPalette, ink: CGColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let fg = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let fk = NSAttributedString.Key(kCTFontAttributeName as String)
        for (i, w) in words.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: " ", attributes: [fk: palette.font(family, bold: false, italic: false, size: size), fg: ink])) }
            var attrs: [NSAttributedString.Key: Any] = [fk: palette.font(family, bold: w.bold, italic: w.italic, size: size), fg: ink]
            if let gid = w.gid { attrs[wordKey] = gid }
            out.append(NSAttributedString(string: w.text, attributes: attrs))
        }
        return out
    }

    enum Align { case natural, justified, center, right }

    /// Абзац как строка CoreText: начертания слов, кегль × масштаб; выравнивание и отступ первой строки.
    private static func attributed(_ lines: [TextLine], paragraph p: Paragraph, colLeft: CGFloat, palette: FontPalette,
                                   ink: CGColor, settings: ReflowSettings,
                                   indentFirst: Bool) -> (NSAttributedString, Align, CGFloat) {
        let size = p.fontSize * settings.scale
        let out = NSMutableAttributedString()
        let fg = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let fk = NSAttributedString.Key(kCTFontAttributeName as String)
        for (li, line) in lines.enumerated() {
            for (wi, w) in line.words.enumerated() {
                var text = w.text
                let lastWord = wi == line.words.count - 1, lastLine = li == lines.count - 1
                // перенос в оригинале: «сло-» + «во» → «слово»
                var joinNext = false
                if lastWord, !lastLine, let next = lines[li + 1].words.first?.text, Dehyphen.isCandidate(text, next) {
                    // «Единствен-» + «ное» → «Единственное», но «что-» + «то» → «что-то» (по словарю)
                    if !Dehyphen.join(text, next).keptHyphen { text.removeLast() }
                    joinNext = true
                }
                var attrs: [NSAttributedString.Key: Any] = [
                    fk: palette.font(p.family, bold: w.bold, italic: w.italic, size: size), fg: ink]
                if let gid = w.gid { attrs[wordKey] = gid }
                out.append(NSAttributedString(string: text, attributes: attrs))
                if !(lastWord && (lastLine || joinNext)) {
                    out.append(NSAttributedString(string: " ", attributes: [
                        fk: palette.font(p.family, bold: false, italic: false, size: size), fg: ink]))
                }
            }
        }
        let align: Align
        let body = lines.count > 1 ? Array(lines.dropLast()) : lines
        if lines.allSatisfy({ $0.alignment == .center }) { align = .center }
        else if lines.allSatisfy({ $0.alignment == .right }) { align = .right }
        else if body.contains(where: { $0.alignment == .justify }) { align = settings.justify ? .justified : .natural }
        else { align = .natural }
        var indent: CGFloat = 0
        let first = lines[0]
        if indentFirst, align != .center, first.bounds.minX - colLeft > first.xHeight * 0.8 {
            indent = (first.bounds.minX - colLeft) * settings.scale
        }
        return (out, align, indent)
    }

    /// Разбивка абзаца на строки: CTTypesetter + переносы по словарю системы
    /// (CFStringGetHyphenationLocationBeforeIndex) + выключка CTLineCreateJustifiedLine.
    /// Возвращает строку, смещение базовой линии от верха строки, descent и x-сдвиг.
    static func typeset(_ str: NSAttributedString, width: CGFloat, align: Align,
                                firstIndent: CGFloat)
        -> [(line: CTLine, baseline: CGFloat, descent: CGFloat, x: CGFloat, text: String, words: [(Int, CGFloat, CGFloat)])] {
        let ns = str.string as NSString
        let length = ns.length
        guard length > 0 else { return [] }
        let ts = CTTypesetterCreateWithAttributedString(str)
        let isRussian = str.string.range(of: "[а-яА-ЯёЁ]", options: .regularExpression) != nil
        let locale = Locale(identifier: isRussian ? "ru" : "en") as CFLocale
        let canHyphenate = CFStringIsHyphenationAvailableForLocale(locale)
        var out: [(CTLine, CGFloat, CGFloat, CGFloat, String, [(Int, CGFloat, CGFloat)])] = []
        var start = 0
        var first = true
        while start < length {
            let avail = width - (first ? firstIndent : 0)
            var n = max(1, CTTypesetterSuggestLineBreak(ts, start, Double(avail)))
            var hyphen = false
            var end = start + n
            if end < length, canHyphenate {
                // следующее слово целиком не влезло — пробуем перенести его часть
                var ws = end
                while ws < length, ns.character(at: ws) == 32 { ws += 1 }
                var we = ws
                while we < length, ns.character(at: we) != 32 { we += 1 }
                var limit = we
                while limit > ws + 1 {
                    let h = CFStringGetHyphenationLocationBeforeIndex(str.string as CFString, limit,
                                                                      CFRange(location: ws, length: we - ws), 0, locale, nil)
                    guard h != kCFNotFound, h > ws + 1, we - h >= 2 else { break }
                    let piece = NSMutableAttributedString(attributedString: str.attributedSubstring(from: NSRange(location: start, length: h - start)))
                    piece.append(NSAttributedString(string: "-", attributes: str.attributes(at: h - 1, effectiveRange: nil)))
                    let l = CTLineCreateWithAttributedString(piece)
                    if CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)) <= avail { n = h - start; end = h; hyphen = true; break }
                    limit = h
                }
            }
            var line: CTLine
            var base = 0            // строка из кусочка (перенос/выключка) индексируется от start
            if hyphen {
                base = start
                let piece = NSMutableAttributedString(attributedString: str.attributedSubstring(from: NSRange(location: start, length: n)))
                piece.append(NSAttributedString(string: "-", attributes: str.attributes(at: end - 1, effectiveRange: nil)))
                line = CTLineCreateWithAttributedString(piece)
            } else {
                line = CTTypesetterCreateLine(ts, CFRange(location: start, length: n))
            }
            let last = end >= length
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
            var x: CGFloat = first ? firstIndent : 0
            switch align {
            case .justified where !last:
                // выключка только за счёт пробелов: CTLineCreateJustifiedLine разгоняет и межбуквенные интервалы
                let piece = NSMutableAttributedString(attributedString: str.attributedSubstring(from: NSRange(location: start, length: n)))
                while piece.length > 0, piece.string.hasSuffix(" ") { piece.deleteCharacters(in: NSRange(location: piece.length - 1, length: 1)) }
                if hyphen { piece.append(NSAttributedString(string: "-", attributes: str.attributes(at: end - 1, effectiveRange: nil))) }
                let spaces = (piece.string as NSString).components(separatedBy: " ").count - 1
                if spaces > 0, avail - w > 0 {
                    let extra = (avail - w) / CGFloat(spaces)
                    let pns = piece.string as NSString
                    for i in 0..<pns.length where pns.character(at: i) == 32 {
                        piece.addAttribute(NSAttributedString.Key(kCTKernAttributeName as String), value: extra,
                                           range: NSRange(location: i, length: 1))
                    }
                    line = CTLineCreateWithAttributedString(piece)
                    base = start
                }
            case .center: x += (avail - w) / 2
            case .right: x += avail - w
            default: break
            }
            var ascent: CGFloat = 0, descent: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            // слова строки: x-диапазоны по атрибуту sr.word
            var words: [(Int, CGFloat, CGFloat)] = []
            str.enumerateAttribute(wordKey, in: NSRange(location: start, length: end - start)) { v, r, _ in
                guard let gid = v as? Int else { return }
                let x0 = CTLineGetOffsetForStringIndex(line, r.location - base, nil)
                let x1 = CTLineGetOffsetForStringIndex(line, r.location + r.length - base, nil)
                if let i = words.firstIndex(where: { $0.0 == gid }) { words[i].2 = max(words[i].2, x1) }
                else { words.append((gid, x0, x1)) }
            }
            let text = ns.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespaces)
                + (hyphen ? "-" : "")
            out.append((line, ascent, descent, x, text, words))
            start = end
            while start < length, ns.character(at: start) == 32 { start += 1 }   // пробел в начале строки не нужен
            first = false
        }
        // высота строки фиксирована: базовая линия у всех строк на одном уровне от верха строки
        let base = out.map(\.1).max() ?? 0
        return out.map { ($0.0, base, $0.2, $0.3, $0.4, $0.5) }
    }
}
