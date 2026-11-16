import CoreGraphics
import Foundation

/// Разбор структуры страницы по строкам OCR (до сборки абзацев):
///  - колонки: вертикальный просвет через весь текст → порядок чтения колонка за колонкой;
///  - оглавление: название, точки-заполнители (или широкий пробел), номер страницы у правого края;
///  - таблица без линеек: строки из нескольких «ячеек», разделённых широкими пробелами, с общими просветами;
///  - таблица в сетке линеек: иллюстрация, в которой нет ничего, кроме линеек и текста в клетках.
/// Если структура похожа на таблицу, но надёжно её не собрать — место отдаётся фрагменту скана.
struct StructureDetector {
    let width: CGFloat
    let height: CGFloat
    /// Краска страницы: точки-заполнители оглавления распознавание часто теряет, их видно только по краске.
    var ink: InkMask? = nil

    struct Result {
        /// Строки обычного текста, в порядке чтения.
        var lines: [TextLine]
        var toc: [TOCBlock] = []
        var tables: [TableBlock] = []
        var scans: [ScanRegion] = []
        var zones: [ColumnZone] = []
    }

    // MARK: - вход

    func detect(_ input: [TextLine]) -> Result {
        let zones = columnZones(input)
        let keyLayout = PageLayout(size: CGSize(width: width, height: height), figures: [], rules: [], paragraphs: [],
                                   columnZones: zones)
        let sorted = input.sorted { a, b in
            let ka = keyLayout.readingKey(a.bounds), kb = keyLayout.readingKey(b.bounds)
            return ka.anchor != kb.anchor || ka.column != kb.column ? ka < kb : a.baseline < b.baseline
        }
        var rows = makeRows(sorted, keys: keyLayout)
        if ProcessInfo.processInfo.environment["SR_DEBUG_ROWS"] != nil {
            for r in rows { print("ряд g\(r.group) base \(Int(r.baseline)) xh \(Int(r.xHeight)): " + r.lines.map { "[\($0.text)]" }.joined(separator: " ")) }
        }
        var result = Result(lines: [], zones: zones)

        let (tocBlocks, tocUsed) = tableOfContents(rows)
        result.toc = tocBlocks
        rows = rows.enumerated().filter { !tocUsed.contains($0.offset) }.map(\.element)

        let (tables, scans, tableUsed) = borderlessTables(rows)
        result.tables = tables
        result.scans = scans
        rows = rows.enumerated().filter { !tableUsed.contains($0.offset) }.map(\.element)

        result.lines = rows.flatMap(\.lines)
        return result
    }

    // MARK: - ряды

    /// Строки OCR на одной базовой линии (Vision режет строку на куски по широким пробелам).
    struct Row {
        var lines: [TextLine]
        var group: Int
        var bounds: CGRect { lines.map(\.bounds).reduce(lines[0].bounds) { $0.union($1) } }
        /// По самой длинной строке ряда: у коротких (номер страницы «7») x-height и базовая линия по краске ненадёжны.
        var main: TextLine { lines.max { $0.text.count < $1.text.count }! }
        var xHeight: CGFloat { main.xHeight }
        var baseline: CGFloat { main.baseline }
        /// Слова ряда слева направо вместе с их строкой.
        var words: [(word: Word, line: TextLine)] {
            lines.flatMap { l in l.words.map { ($0, l) } }.sorted { $0.word.bounds.minX < $1.word.bounds.minX }
        }
    }

    private func makeRows(_ lines: [TextLine], keys: PageLayout) -> [Row] {
        func group(_ r: CGRect) -> Int { Self.group(of: r, zones: keys.columnZones) }
        var rows: [Row] = []
        for l in lines {
            let g = group(l.bounds)
            let lb = rows.last?.bounds ?? .null
            let overlap = min(lb.maxY, l.bounds.maxY) - max(lb.minY, l.bounds.minY)
            if var last = rows.last, last.group == g,
               abs(last.baseline - l.baseline) < max(last.xHeight, l.xHeight) * 0.45
                || overlap >= 0.6 * min(lb.height, l.bounds.height),
               !last.lines.contains(where: { $0.bounds.intersects(l.bounds.insetBy(dx: 1, dy: 1)) }) {
                last.lines.append(l)
                last.lines.sort { $0.bounds.minX < $1.bounds.minX }
                rows[rows.count - 1] = last
            } else {
                rows.append(Row(lines: [l], group: g))
            }
        }
        return rows
    }

    /// Группа строки: колонка многоколоночной зоны (1…) или «вне колонок» (0).
    static func group(of r: CGRect, zones: [ColumnZone]) -> Int {
        let mid = CGPoint(x: r.midX, y: r.midY)
        guard let zi = zones.firstIndex(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(mid) }) else { return 0 }
        return 1 + zi * 8 + zones[zi].column(of: r)
    }

    // MARK: - колонки

    func columnZones(_ lines: [TextLine]) -> [ColumnZone] {
        guard lines.count >= 8 else { return [] }
        let W = width
        let xh = lines.map(\.xHeight).sorted()[lines.count / 2]
        // число строк, пересекающих каждую вертикаль
        var cross = [Int](repeating: 0, count: Int(W) + 1)
        for l in lines {
            let a = max(0, Int(l.bounds.minX)), b = min(Int(W), Int(l.bounds.maxX))
            if a < b { for x in a...b { cross[x] += 1 } }
        }
        let maxCross = max(1, lines.count / 12)
        // полосы-кандидаты в средней части листа
        var candidates: [(x: CGFloat, width: CGFloat)] = []
        var x = Int(0.2 * W)
        while x < Int(0.8 * W) {
            guard cross[x] <= maxCross else { x += 1; continue }
            var e = x
            while e < Int(0.8 * W), cross[e] <= maxCross { e += 1 }
            // в полосе — самый «чистый» отрезок
            let minC = cross[x..<e].min() ?? 0
            let clean = (x..<e).filter { cross[$0] == minC }
            if let a = clean.first, let b = clean.last, CGFloat(b - a + 1) >= max(xh * 0.9, 0.01 * W) {
                candidates.append((CGFloat(a + b) / 2, CGFloat(b - a + 1)))
            }
            x = e + 1
        }
        var zones: [ColumnZone] = []
        for c in candidates {
            let split = c.x
            let left = lines.filter { $0.bounds.maxX < split }, right = lines.filter { $0.bounds.minX > split }
            let crossing = lines.filter { $0.bounds.minX <= split && $0.bounds.maxX >= split }.map(\.bounds)
            // зоны: по вертикали между пересекающими строками (заголовками на всю ширину)
            var cuts = crossing.map(\.midY).sorted()
            cuts.insert(-1, at: 0); cuts.append(height + 1)
            for (top, bottom) in zip(cuts, cuts.dropFirst()) {
                let L = left.filter { $0.bounds.midY > top && $0.bounds.midY < bottom }
                let R = right.filter { $0.bounds.midY > top && $0.bounds.midY < bottom }
                guard L.count >= 3, R.count >= 3, isTextColumn(L, from: L.map(\.bounds.minX).min()!, to: split),
                      isTextColumn(R, from: split, to: R.map(\.bounds.maxX).max()!) else { continue }
                // колонки рядом, а не одна под другой
                let lr = L.map(\.bounds).reduce(L[0].bounds) { $0.union($1) }
                let rr = R.map(\.bounds).reduce(R[0].bounds) { $0.union($1) }
                guard min(lr.maxY, rr.maxY) - max(lr.minY, rr.minY) > 0.5 * min(lr.height, rr.height) else { continue }
                let rect = lr.union(rr)
                if !zones.contains(where: { $0.rect.intersects(rect) }) {
                    zones.append(ColumnZone(rect: rect, splits: [split]))
                }
            }
        }
        return zones
    }

    /// Строки колонки похожи на набранный текст: длинные, по несколько слов (а не ячейки таблицы или номера).
    private func isTextColumn(_ lines: [TextLine], from a: CGFloat, to b: CGFloat) -> Bool {
        let colW = b - a
        guard colW > 0.15 * width else { return false }
        let widths = lines.map(\.bounds.width).sorted(), words = lines.map(\.words.count).sorted()
        return widths[widths.count / 2] >= 0.6 * colW && words[words.count / 2] >= 3
    }

    // MARK: - оглавление

    static let leaderChars: Set<Character> = [".", "·", "…", "‥", "_", "•", "-", "–", " "]

    /// Номер страницы в оглавлении: арабские цифры (с исправлением похожих букв) или римские.
    static func pageNumber(_ s: String) -> String? {
        var t = String(s.drop { leaderChars.contains($0) })
        t = OCRCorrector.fixNumber(t)
        while let l = t.last, ".,".contains(l) { t.removeLast() }
        if !t.isEmpty, t.count <= 4, t.allSatisfy(\.isNumber) { return t }
        if !t.isEmpty, t.count <= 7, t.allSatisfy({ "IVXLCDMivxlcdm".contains($0) }) { return t }
        return nil
    }

    private struct TOCRow {
        var title: [(word: Word, line: TextLine)]
        var page: (word: Word, line: TextLine)
        var leader: Bool
    }

    /// - Parameter numberRight: правый край номеров уже найденных пунктов: короткий «мусор» распознавания
    ///   на этом месте (вместо «18» — «1×») — тоже номер, его покажем фрагментом скана.
    private func tocRow(_ row: Row, numberRight: CGFloat? = nil) -> TOCRow? {
        var words = row.words
        guard words.count >= 2, let last = words.last else { return nil }
        var num = Self.pageNumber(last.word.text)
        var unreadable = false
        if num == nil, let nr = numberRight, last.word.text.count <= 4, abs(last.word.bounds.maxX - nr) <= 2 * row.xHeight,
           last.word.text.contains(where: { $0.isNumber }) {
            num = last.word.text; unreadable = true
        }
        guard let num else { return nil }
        // номер на правом краю, а не в середине строки
        guard last.word.bounds.maxX > row.bounds.minX + (row.bounds.width * 0.5) else { return nil }
        let xh = row.xHeight
        words.removeLast()
        var leader = last.word.text.first.map { Self.leaderChars.contains($0) } ?? false
        var page = last
        page.word.text = num
        if leader, let firstDigit = last.word.text.firstIndex(where: { !Self.leaderChars.contains($0) }) {
            // «.....12»: рамку номера — по его доле символов
            let frac = CGFloat(last.word.text.distance(from: firstDigit, to: last.word.text.endIndex)) / CGFloat(last.word.text.count)
            page.word.bounds = CGRect(x: last.word.bounds.maxX - last.word.bounds.width * frac, y: last.word.bounds.minY,
                                      width: last.word.bounds.width * frac, height: last.word.bounds.height)
        }
        // точки-заполнители: отдельные «слова» из точек и хвост последнего слова названия
        while let w = words.last, w.word.text.allSatisfy({ Self.leaderChars.contains($0) }) {
            words.removeLast(); leader = true
        }
        if var w = words.last {
            let core = w.word.text.reversed().drop { Self.leaderChars.contains($0) }
            let cut = w.word.text.count - core.count
            if cut >= 2 {
                let keep = CGFloat(core.count) / CGFloat(w.word.text.count)
                w.word.text = String(core.reversed())
                w.word.bounds.size.width *= keep
                words[words.count - 1] = w
                leader = true
            }
        }
        guard let titleEnd = words.last, words.contains(where: { $0.word.text.contains { $0.isLetter } }) else { return nil }
        let gap = page.word.bounds.minX - titleEnd.word.bounds.maxX
        guard leader || gap >= 3 * xh else { return nil }
        if !leader, let ink {
            // мелкие одинаковые пятна краски на базовой линии между названием и номером
            let band = CGRect(x: titleEnd.word.bounds.maxX + xh * 0.4, y: row.baseline - xh * 0.7,
                              width: gap - xh * 0.8, height: xh * 0.9)
            let cols = ink.columnProfile(band)
            var runs: [Int] = [], cur = 0
            for v in cols { if v > 0 { cur += 1 } else if cur > 0 { runs.append(cur); cur = 0 } }
            if cur > 0 { runs.append(cur) }
            if runs.count >= 3, runs.allSatisfy({ CGFloat($0) <= 0.7 * xh }) { leader = true }
        }
        // римская цифра без точек — скорее всего часть названия («Глава IV»)
        if !leader, !unreadable, !num.allSatisfy(\.isNumber) { return nil }
        if unreadable { page.line.confidence = 0 }
        return TOCRow(title: words, page: page, leader: leader)
    }

    private func line(from items: [(word: Word, line: TextLine)], alignment: LineAlignment = .left) -> TextLine {
        let b = items.map(\.word.bounds).reduce(items[0].word.bounds) { $0.union($1) }
        let src = items[0].line
        return TextLine(bounds: b, baseline: src.baseline, xHeight: src.xHeight, alignment: alignment,
                        confidence: items.map(\.line.confidence).min() ?? src.confidence, words: items.map(\.word))
    }

    private func tableOfContents(_ rows: [Row]) -> ([TOCBlock], Set<Int>) {
        var blocks: [TOCBlock] = []
        var used = Set<Int>()
        var i = 0
        while i < rows.count {
            guard tocRow(rows[i]) != nil else { i += 1; continue }
            // пункты подряд; ряды без номера между ними — перенос названия или заголовок раздела
            var run: [(Int, TOCRow?)] = []
            var j = i
            var numberLeft = CGFloat.greatestFiniteMagnitude
            var pending: [Int] = []
            while j < rows.count, rows[j].group == rows[i].group {
                let prevRow = rows[pending.last ?? run.last?.0 ?? i]
                let xh = rows[j].xHeight
                if j > i, rows[j].bounds.minY - prevRow.bounds.maxY > 5 * xh { break }
                let rightsSoFar = run.compactMap { $0.1?.page.word.bounds.maxX }.sorted()
                if let t = tocRow(rows[j], numberRight: rightsSoFar.isEmpty ? nil : rightsSoFar[rightsSoFar.count / 2]) {
                    run += pending.map { ($0, nil) }
                    pending = []
                    run.append((j, t))
                    numberLeft = min(numberLeft, t.page.word.bounds.minX)
                } else if !run.isEmpty, rows[j].bounds.maxX < numberLeft - xh, pending.count < 2 {
                    pending.append(j)
                } else {
                    break
                }
                j += 1
            }
            // ряды без номера прямо над первым пунктом (раздел, у которого распознавание потеряло номер)
            var k = i - 1
            while k >= 0, i - k <= 2, rows[k].group == rows[i].group, !used.contains(k),
                  rows[run[0].0].bounds.minY - rows[k].bounds.maxY <= 3 * rows[i].xHeight,
                  rows[k].bounds.maxX < numberLeft - rows[i].xHeight,
                  abs(rows[k].xHeight - rows[i].xHeight) <= 0.25 * rows[i].xHeight {
                run.insert((k, nil), at: 0); k -= 1
            }
            let numbered = run.compactMap(\.1)
            let leaders = numbered.filter(\.leader).count
            let rights = numbered.map(\.page.word.bounds.maxX)
            let xh = rows[i].xHeight
            guard numbered.count >= 3 || (numbered.count >= 2 && leaders == numbered.count),
                  (rights.max() ?? 0) - (rights.min() ?? 0) <= 6 * xh else {
                i += 1; continue
            }
            // пункты: ряд без номера перед пунктом — перенос, если он длинный и следующий не левее
            var entries: [TOCEntry] = []
            var carry: [TextLine] = []
            for (k, (ri, t)) in run.enumerated() {
                let row = rows[ri]
                if let t {
                    let titleLine = line(from: t.title)
                    var pageLine = line(from: [t.page], alignment: .right)
                    // номер — на базовой линии названия (у одиночных цифр она по краске неточна)
                    pageLine.baseline = titleLine.baseline
                    pageLine.xHeight = titleLine.xHeight
                    entries.append(TOCEntry(lines: carry + [titleLine], page: pageLine, level: 0, leader: t.leader))
                    carry = []
                } else {
                    let next = run[(k + 1)...].first { $0.1 != nil }
                    let nextX = next.flatMap { $0.1?.title.first?.word.bounds.minX } ?? 0
                    let wraps = row.bounds.maxX >= numberLeft - 10 * row.xHeight && nextX >= row.bounds.minX - row.xHeight
                    let l = line(from: row.words)
                    if wraps { carry.append(l) } else {
                        entries += carry.map { TOCEntry(lines: [$0], page: nil, level: 0, leader: false) }
                        carry = []
                        entries.append(TOCEntry(lines: [l], page: nil, level: 0, leader: false))
                    }
                }
                used.insert(ri)
            }
            // уровни — по отступу первой строки
            var lefts: [CGFloat] = []
            for x in entries.map({ $0.lines[0].bounds.minX }).sorted() where lefts.last.map({ x - $0 > 1.5 * xh }) ?? true {
                lefts.append(x)
            }
            for e in entries.indices {
                let x = entries[e].lines[0].bounds.minX
                entries[e].level = lefts.lastIndex { x >= $0 - 1.5 * xh } ?? 0
            }
            let all = entries.flatMap(\.allLines).map(\.bounds)
            blocks.append(TOCBlock(bounds: all.reduce(all[0]) { $0.union($1) }, right: rights.max() ?? 0, entries: entries))
            i = j
        }
        return (blocks, used)
    }

    // MARK: - таблицы без линеек

    private struct Segment {
        var items: [(word: Word, line: TextLine)]
        var bounds: CGRect { items.map(\.word.bounds).reduce(items[0].word.bounds) { $0.union($1) } }
    }

    /// Куски ряда между широкими пробелами (≥ 2 x-height — шире любого пробела в выключенной строке).
    private func segments(_ row: Row) -> [Segment] {
        let xh = row.xHeight
        var out: [Segment] = []
        for item in row.words {
            if let last = out.last?.items.last, item.word.bounds.minX - last.word.bounds.maxX < 2.2 * xh {
                out[out.count - 1].items.append(item)
            } else {
                out.append(Segment(items: [item]))
            }
        }
        return out
    }

    private func borderlessTables(_ rows: [Row]) -> ([TableBlock], [ScanRegion], Set<Int>) {
        var tables: [TableBlock] = []
        var scans: [ScanRegion] = []
        var used = Set<Int>()
        let segs = rows.map(segments)
        var i = 0
        while i < rows.count {
            guard segs[i].count >= 2 else { i += 1; continue }
            var run = [i]
            var j = i + 1
            var runRect = rows[i].bounds
            while j < rows.count, rows[j].group == rows[i].group {
                let xh = rows[j].xHeight
                guard rows[j].baseline - rows[run.last!].baseline <= 4.5 * xh else { break }
                if segs[j].count >= 2 || (segs[j][0].bounds.width <= 0.45 * runRect.width
                                          && segs[j][0].bounds.minX >= runRect.minX - xh && segs[j][0].bounds.maxX <= runRect.maxX + xh) {
                    run.append(j); runRect = runRect.union(rows[j].bounds)
                } else { break }
                j += 1
            }
            while let l = run.last, segs[l].count < 2 { run.removeLast() }
            let tabular = run.filter { segs[$0].count >= 2 }.count
            guard tabular >= 3, run.count >= 3 else { i += 1; continue }
            if let t = buildTable(run.map { rows[$0] }, run.map { segs[$0] }) {
                tables.append(t)
            } else {
                // похоже на таблицу, но колонки не сходятся — фрагмент скана
                let lines = run.flatMap { rows[$0].lines }
                let xh = rows[i].xHeight
                let r = lines.map(\.bounds).reduce(lines[0].bounds) { $0.union($1) }.insetBy(dx: -xh * 0.6, dy: -xh * 0.6)
                scans.append(ScanRegion(rect: r.intersection(CGRect(x: 0, y: 0, width: width, height: height)), lines: lines))
            }
            used.formUnion(run)
            i = run.last! + 1
        }
        return (tables, scans, used)
    }

    private func buildTable(_ rows: [Row], _ segs: [[Segment]]) -> TableBlock? {
        let xh = rows.map(\.xHeight).sorted()[rows.count / 2]
        let all = segs.flatMap { $0.map(\.bounds) }
        let x0 = Int(all.map(\.minX).min()!), x1 = Int(all.map(\.maxX).max()!)
        guard x1 > x0 else { return nil }
        var cover = [Bool](repeating: false, count: x1 - x0 + 1)
        for r in all { for x in Int(r.minX)...Int(r.maxX) where x >= x0 && x <= x1 { cover[x - x0] = true } }
        // просветы между колонками
        var gutters: [CGFloat] = []
        var x = 0
        while x < cover.count {
            if cover[x] { x += 1; continue }
            var e = x
            while e < cover.count, !cover[e] { e += 1 }
            if CGFloat(e - x) >= 1.2 * xh { gutters.append(CGFloat(x0) + CGFloat(x + e) / 2) }
            x = e
        }
        let nc = gutters.count + 1
        guard nc >= 2, nc <= 10 else { return nil }
        func col(_ r: CGRect) -> Int { gutters.filter { r.midX > $0 }.count }

        // ячейки по рядам
        var grid: [[Segment?]] = []
        for (ri, var rs) in segs.enumerated() {
            // базовая линия ряда — по самой длинной строке (у одиночных чисел она по краске неточна)
            for si in rs.indices { for k in rs[si].items.indices {
                rs[si].items[k].line.baseline = rows[ri].baseline; rs[si].items[k].line.xHeight = rows[ri].xHeight
            } }
            var cells = [Segment?](repeating: nil, count: nc)
            for s in rs {
                let c = col(s.bounds)
                if var ex = cells[c] { ex.items += s.items; cells[c] = ex } else { cells[c] = s }
            }
            grid.append(cells)
        }
        var rowRects = rows.map(\.bounds)
        // продолжения многострочных ячеек: пустая первая колонка и меньше заполненных ячеек, чем у ряда выше
        let gaps = zip(rows.dropFirst(), rows).map { $0.baseline - $1.baseline }.sorted()
        let medGap = gaps.isEmpty ? xh * 3 : gaps[gaps.count / 2]
        var r = 1
        while r < grid.count {
            let filled = grid[r].compactMap { $0 }.count, prevFilled = grid[r - 1].compactMap { $0 }.count
            if grid[r][0] == nil, grid[r - 1][0] != nil, filled < prevFilled,
               rows[r].baseline - rows[r - 1].baseline <= medGap * 1.15 {
                for c in 0..<nc {
                    if let s = grid[r][c] {
                        if var ex = grid[r - 1][c] { ex.items += s.items; grid[r - 1][c] = ex } else { grid[r - 1][c] = s }
                    }
                }
                rowRects[r - 1] = rowRects[r - 1].union(rowRects[r])
                grid.remove(at: r); rowRects.remove(at: r)
            } else { r += 1 }
        }
        // надёжность: каждая колонка заполнена хотя бы в двух рядах, таблица заполнена хотя бы наполовину
        let filled = grid.flatMap { $0 }.compactMap { $0 }.count
        guard grid.count >= 3, Double(filled) >= 0.5 * Double(grid.count * nc),
              (0..<nc).allSatisfy({ c in grid.filter { $0[c] != nil }.count >= 2 }) else { return nil }

        // десятичный разделитель в колонке — как у большинства чисел («17.8» среди «41,2» — ошибка распознавания)
        for c in 0..<nc {
            let nums = grid.compactMap { $0[c] }.flatMap(\.items).map(\.word.text)
                .filter { $0.range(of: #"^\d+[.,]\d+$"#, options: .regularExpression) != nil }
            let commas = nums.filter { $0.contains(",") }.count, dots = nums.count - commas
            guard nums.count >= 3, commas != dots else { continue }
            let (from, to): (Character, Character) = commas > dots ? (".", ",") : (",", ".")
            for r in grid.indices {
                guard var seg = grid[r][c] else { continue }
                for k in seg.items.indices where seg.items[k].word.text.range(of: #"^\d+[.,]\d+$"#, options: .regularExpression) != nil {
                    seg.items[k].word.text = String(seg.items[k].word.text.map { $0 == from ? to : $0 })
                }
                grid[r][c] = seg
            }
        }

        // выравнивание в колонке
        var colMin = [CGFloat](repeating: .greatestFiniteMagnitude, count: nc), colMax = [CGFloat](repeating: 0, count: nc)
        for row in grid { for (c, s) in row.enumerated() { if let s { colMin[c] = min(colMin[c], s.bounds.minX); colMax[c] = max(colMax[c], s.bounds.maxX) } } }
        var cells: [TableCell] = []
        for (ri, row) in grid.enumerated() {
            for (c, s) in row.enumerated() {
                guard let s else { continue }
                let b = s.bounds
                let align: LineAlignment
                if abs(b.maxX - colMax[c]) <= 0.6 * xh, b.minX - colMin[c] > xh { align = .right }
                else if abs(b.midX - (colMin[c] + colMax[c]) / 2) <= 0.6 * xh, b.minX - colMin[c] > xh { align = .center }
                else { align = .left }
                // строки ячейки — по базовым линиям исходных строк
                var lines: [TextLine] = []
                for item in s.items {
                    if let li = lines.firstIndex(where: { abs($0.baseline - item.line.baseline) < item.line.xHeight * 0.45 }) {
                        lines[li].words.append(item.word)
                        lines[li].bounds = lines[li].bounds.union(item.word.bounds)
                    } else {
                        lines.append(TextLine(bounds: item.word.bounds, baseline: item.line.baseline, xHeight: item.line.xHeight,
                                              alignment: align, confidence: item.line.confidence, words: [item.word]))
                    }
                }
                for li in lines.indices { lines[li].words.sort { $0.bounds.minX < $1.bounds.minX } }
                lines.sort { $0.baseline < $1.baseline }
                cells.append(TableCell(row: ri, column: c, lines: lines, alignment: align))
            }
        }
        let bounds = all.reduce(all[0]) { $0.union($1) }
        var ys = [rowRects[0].minY - xh * 0.5]
        for (a, b) in zip(rowRects, rowRects.dropFirst()) { ys.append((a.maxY + b.minY) / 2) }
        ys.append(rowRects.last!.maxY + xh * 0.5)
        return TableBlock(bounds: bounds, columns: [bounds.minX] + gutters + [bounds.maxX], rows: ys, ruled: false, cells: cells)
    }

    // MARK: - таблицы в сетке линеек

    /// Иллюстрация, в которой только линейки сетки и текст в клетках, → таблица; иначе nil (остаётся картинкой).
    static func ruledTable(in rect: CGRect, labels: [TextLine], nonText: InkMask) -> TableBlock? {
        guard labels.count >= 2, let (rx0, ry0, rx1, ry1) = nonText.clampRect(rect) else { return nil }
        let w = rx1 - rx0, h = ry1 - ry0
        // горизонтальные линейки: ряды, почти целиком закрашенные
        let rowProf = nonText.rowProfile(rect)
        var hLines: [(y: CGFloat, t: CGFloat)] = []
        var y = 0
        while y < rowProf.count {
            guard Double(rowProf[y]) >= 0.6 * Double(w) else { y += 1; continue }
            var e = y
            while e < rowProf.count, Double(rowProf[e]) >= 0.6 * Double(w) { e += 1 }
            hLines.append((CGFloat(ry0) + CGFloat(y + e) / 2, CGFloat(e - y)))
            y = e
        }
        guard hLines.count >= 2, hLines.allSatisfy({ $0.t <= 8 }) else { return nil }
        let top = hLines.first!.y, bottom = hLines.last!.y
        let span = CGRect(x: CGFloat(rx0), y: top, width: CGFloat(w), height: bottom - top)
        let colProf = nonText.columnProfile(span)
        var vLines: [(x: CGFloat, t: CGFloat)] = []
        var x = 0
        while x < colProf.count {
            guard Double(colProf[x]) >= 0.6 * Double(span.height) else { x += 1; continue }
            var e = x
            while e < colProf.count, Double(colProf[e]) >= 0.6 * Double(span.height) { e += 1 }
            vLines.append((CGFloat(rx0) + CGFloat(x + e) / 2, CGFloat(e - x)))
            x = e
        }
        // вертикальные линейки могут быть и неполными (объединённые ячейки): ищем и по половине высоты
        if vLines.count < 2 { return nil }
        let thick = max(1, (hLines.map(\.t) + vLines.map(\.t)).sorted()[(hLines.count + vLines.count) / 2])

        // кроме сетки и текста — ничего (иначе это схема или картинка)
        var residual = 0
        let near = Int(thick) + 3
        for yy in ry0..<ry1 {
            if hLines.contains(where: { abs(CGFloat(yy) - $0.y) <= CGFloat(near) }) { continue }
            for xx in rx0..<rx1 where nonText.at(xx, yy) != 0 {
                if vLines.contains(where: { abs(CGFloat(xx) - $0.x) <= CGFloat(near) }) { continue }
                residual += 1
            }
        }
        guard Double(residual) <= 0.004 * Double(w * h) else { return nil }

        let xs = vLines.map(\.x), ys = hLines.map(\.y)
        let nc = xs.count - 1, nr = ys.count - 1
        guard nc >= 1, nr >= 1 else { return nil }
        // внутренние вертикальные линейки по рядам: есть или нет (объединённые ячейки)
        func present(_ k: Int, row r: Int) -> Bool {
            let strip = CGRect(x: xs[k] - thick - 1, y: ys[r] + thick + 1, width: 2 * thick + 2, height: ys[r + 1] - ys[r] - 2 * thick - 2)
            guard strip.height > 2 else { return true }
            let prof = nonText.rowProfile(strip)
            return Double(prof.filter { $0 > 0 }.count) >= 0.7 * Double(prof.count)
        }
        var cells: [TableCell] = []
        var gridRules: [CGRect] = []
        for yv in ys { gridRules.append(CGRect(x: xs.first! - thick / 2, y: yv - thick / 2, width: xs.last! - xs.first! + thick, height: thick)) }
        var spans: [[(start: Int, span: Int)]] = []
        for r in 0..<nr {
            var row: [(Int, Int)] = []
            var start = 0
            for k in 1...nc {
                if k == nc || present(k, row: r) {
                    row.append((start, k - start)); start = k
                }
            }
            spans.append(row)
            for k in 0...nc where k == 0 || k == nc || present(k, row: r) {
                gridRules.append(CGRect(x: xs[k] - thick / 2, y: ys[r], width: thick, height: ys[r + 1] - ys[r]))
            }
        }
        // текст по клеткам: строка не должна пересекать линейку
        var content: [String: [TextLine]] = [:]
        for l in labels {
            let c = CGPoint(x: l.bounds.midX, y: l.bounds.midY)
            guard let r = (0..<nr).first(where: { c.y > ys[$0] && c.y < ys[$0 + 1] }),
                  let cell = spans[r].first(where: { c.x > xs[$0.start] && c.x < xs[$0.start + $0.span] }) else { return nil }
            let inner = CGRect(x: xs[cell.start], y: ys[r], width: xs[cell.start + cell.span] - xs[cell.start], height: ys[r + 1] - ys[r])
                .insetBy(dx: -2, dy: -2)
            guard inner.contains(l.bounds) else { return nil }
            content["\(r)|\(cell.start)", default: []].append(l)
        }
        for r in 0..<nr {
            for s in spans[r] {
                guard var lines = content["\(r)|\(s.start)"] else { continue }
                lines.sort { $0.baseline < $1.baseline }
                let cellRect = CGRect(x: xs[s.start], y: ys[r], width: xs[s.start + s.span] - xs[s.start], height: ys[r + 1] - ys[r])
                // выравнивание в клетке: поля слева и справа
                let lm = lines.map { $0.bounds.minX - cellRect.minX }.min() ?? 0
                let rm = lines.map { cellRect.maxX - $0.bounds.maxX }.min() ?? 0
                let xh = lines[0].xHeight
                let align: LineAlignment = abs(lm - rm) <= xh && lm > 2 * xh ? .center : (rm < lm - 2 * xh ? .right : .left)
                for li in lines.indices { lines[li].alignment = align }
                cells.append(TableCell(row: r, column: s.start, span: s.span, lines: lines, alignment: align))
            }
        }
        let bounds = CGRect(x: xs.first!, y: ys.first!, width: xs.last! - xs.first!, height: ys.last! - ys.first!)
        return TableBlock(bounds: bounds, columns: xs, rows: ys, ruled: true, ruleWidth: thick, gridRules: gridRules, cells: cells)
    }
}
