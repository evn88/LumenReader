import CoreGraphics
import Foundation
import ImageIO

/// Страница, готовая к показу: раскладка + картинки, которые берём из скана.
struct AnalyzedPage {
    var layout: PageLayout
    var original: CGImage
    /// Иллюстрации (улучшенные или после "уровней"), по индексам layout.figures.
    var figureImages: [CGImage?]
    /// Строки с низкой уверенностью OCR: показываем фрагмент оригинала.
    var fallbackLines: [Int: CGImage]
    /// Фрагменты скана на месте структуры, которую не удалось воссоздать (по индексам layout.scanRegions).
    var scanImages: [CGImage?] = []

    static let minConfidence: Float = 0.35
    /// Страница без распознавания: показывается сканом (выбор читателя).
    var scanOnly = false
    /// Скан с «уровнями» (бумага → белая, краска → чёрная): ложится на цвет листа без серой подложки.
    var leveled: CGImage?

    init(scanOnly image: CGImage) {
        layout = PageLayout(size: CGSize(width: image.width, height: image.height), figures: [], rules: [], paragraphs: [])
        original = image
        figureImages = []
        fallbackLines = [:]
        scanOnly = true
        leveled = Self.leveled(image)
    }

    /// Уровни для показа сканом (строится только для таких страниц: ~1 байт на пиксель).
    static func leveled(_ image: CGImage) -> CGImage? {
        GrayBitmap(cgImage: image).flatMap { $0.leveledImage(rect: CGRect(x: 0, y: 0, width: $0.width, height: $0.height)) }
    }

    init(layout: PageLayout, original: CGImage, gray: GrayBitmap, enhancer: FigureEnhancer?, store: FigureStore?,
         token: CancelToken? = nil) throws {
        self.layout = layout
        self.original = original
        figureImages = try layout.figures.enumerated().map { i, rect in
            try token?.check()      // отменённую страницу не дорабатываем (и не пишем в кеш недоделанных картинок)
            guard let enhancer else { return gray.leveledImage(rect: rect) }   // улучшение выключено
            if let cached = store?.load(i) { return cached }
            let labels = layout.figureLabels.filter { $0.figure == i }.map(\.line)
            let enhanced = enhancer.enhance(page: gray, rect: rect, labels: labels, token: token)
            try token?.check()          // отменили посреди улучшения — в кеш ничего не пишем
            let image = enhanced ?? gray.leveledImage(rect: rect)
            if let image { store?.save(image, i) }
            return image
        }
        var fb: [Int: CGImage] = [:]
        for (i, line) in layout.allLines.enumerated() where line.confidence < Self.minConfidence {
            fb[i] = gray.leveledImage(rect: line.bounds.insetBy(dx: -3, dy: -3))
        }
        fallbackLines = fb
        scanImages = layout.scanRegions.map { gray.leveledImage(rect: $0.rect) }
    }
}

/// Где лежат готовые картинки иллюстраций страницы (PNG рядом с раскладкой).
struct FigureStore {
    let dir: URL
    let page: Int

    private func url(_ i: Int) -> URL { dir.appendingPathComponent("page-\(page)-figure-\(i).png") }

    func load(_ i: Int) -> CGImage? {
        guard let data = SyncedFile.read(url(i)),
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    func save(_ image: CGImage, _ i: Int) {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return }
        SyncedFile.write(data as Data, to: url(i))
    }
}

struct LayoutAnalyzer {
    var palette: FontPalette = .original
    var languages: [String] = []
    var enhanceFigures = true
    /// Отмена: проверяется между этапами, останавливает запросы Vision.
    var token: CancelToken? = nil

    func analyze(_ image: CGImage, cached: PageLayout? = nil, store: FigureStore? = nil) throws -> AnalyzedPage {
        guard let gray = GrayBitmap(cgImage: image) else { throw CocoaError(.fileReadCorruptFile) }
        let layout = try cached ?? analyze(gray: gray, image: image)
        try token?.check()
        return try AnalyzedPage(layout: layout, original: image, gray: gray,
                                enhancer: enhanceFigures ? FigureEnhancer(palette: palette) : nil, store: store, token: token)
    }

    func analyze(gray: GrayBitmap, image: CGImage) throws -> PageLayout {
        let ocr = try OCREngine.recognize(image, languages: languages, token: token)
        try token?.check()
        return try build(gray: gray, image: image, ocr: ocr)
    }

    /// Строки OCR из готовой раскладки — повторный разбор страницы без распознавания
    /// (отладка разбора структуры; блоки кода восстанавливаются приблизительно).
    static func ocrLines(from layout: PageLayout) -> [OCRLine] {
        func ocr(_ l: TextLine) -> OCRLine {
            // рамка по краске захватывает выносные элементы соседних строк — сужаем к строке, как у Vision
            let tight = CGRect(x: l.bounds.minX, y: l.baseline - l.xHeight * 2.1, width: l.bounds.width, height: l.xHeight * 2.6)
                .intersection(l.bounds)
            return OCRLine(text: l.text, box: tight.isNull ? l.bounds : tight, confidence: l.confidence,
                           words: l.words.map { ($0.text, $0.bounds) })
        }
        var out = layout.allLines.map(ocr) + layout.figureLabels.map { ocr($0.line) }
        for b in layout.codeBlocks {
            for cl in b.lines {
                let x = b.bounds.minX + CGFloat(cl.indent) * b.pitch
                var words: [(String, CGRect)] = []
                var cx = x
                for w in cl.text.split(separator: " ") {
                    let wr = CGRect(x: cx, y: cl.baseline - b.pitch * 1.4, width: CGFloat(w.count) * b.pitch, height: b.pitch * 1.8)
                    words.append((String(w), wr)); cx = wr.maxX + b.pitch
                }
                guard !words.isEmpty else { continue }
                let box = words.map(\.1).reduce(words[0].1) { $0.union($1) }
                out.append(OCRLine(text: cl.text, box: box, confidence: 1, words: words))
            }
        }
        return out
    }

    func build(gray: GrayBitmap, image: CGImage, ocr: [OCRLine]) throws -> PageLayout {
        let W = CGFloat(gray.width), H = CGFloat(gray.height)
        var ink = InkMask(gray, threshold: gray.otsuThreshold())

        // 1. Всё, что не текст: убираем строки OCR и ищем крупные связные области.
        var nonText = ink
        for l in ocr { nonText.clear(l.box.insetBy(dx: -2, dy: -2)) }
        let f = 4
        let coarse = nonText.downsampled(f).dilated(radius: 3)
        var figures: [CGRect] = coarse.components().map {
            CGRect(x: $0.rect.minX * CGFloat(f), y: $0.rect.minY * CGFloat(f),
                   width: $0.rect.width * CGFloat(f), height: $0.rect.height * CGFloat(f))
                .insetBy(dx: CGFloat(3 * f) - 4, dy: CGFloat(3 * f) - 4)   // убираем запас от расширения
                .intersection(CGRect(x: 0, y: 0, width: W, height: H))
        }.filter { r in
            let big = r.width > 0.08 * W && r.height > 0.05 * H
            // тёмные края скана вдоль границы листа — не иллюстрация
            let edge = r.minX <= 2 || r.minY <= 2 || r.maxX >= W - 2 || r.maxY >= H - 2
            return big && !(edge && (r.width < 0.05 * W || r.height < 0.05 * H))
        }
        figures = mergeOverlapping(figures)
        func inFigure(_ r: CGRect) -> Bool { figures.contains { $0.contains(CGPoint(x: r.midX, y: r.midY)) } }

        // 2. Линейки: длинные тонкие горизонтальные штрихи вне иллюстраций.
        // Зерно/пыль скана рвёт линейку на куски: сначала сшиваем тонкие отрезки одного ряда с разрывами ≤ 8 px.
        let thin = max(3, 0.006 * H)
        var pieces = nonText.components().map(\.rect).filter { $0.height <= thin && $0.width > 0.03 * W }
            .sorted { $0.minX < $1.minX }
        var joined: [CGRect] = []
        while !pieces.isEmpty {
            var r = pieces.removeFirst()
            while let i = pieces.firstIndex(where: { abs($0.midY - r.midY) <= 2 && $0.minX - r.maxX <= 8 && $0.minX >= r.minX }) {
                r = r.union(pieces.remove(at: i))
            }
            joined.append(r)
        }
        var rules: [CGRect] = []
        for r in joined where r.width > 0.25 * W && r.height <= thin + 2 && !inFigure(r) {
            rules.append(r)
            ink.clear(r.insetBy(dx: -1, dy: -1))
        }

        // 2б. Краска, которую не распознали ни текстом, ни иллюстрацией, ни линейкой: формулы, схемки,
        // значки. Без этого такие места на странице просто пропадали — показываем их фрагментом скана.
        var leftovers: [CGRect] = []
        let lineHeights = ocr.map(\.box.height).sorted()
        let typical = lineHeights.isEmpty ? H * 0.015 : lineHeights[lineHeights.count / 2]
        var rest = nonText
        for r in rules { rest.clear(r.insetBy(dx: -3, dy: -3)) }
        for r in figures { rest.clear(r) }
        for c in rest.downsampled(f).dilated(radius: 3).components() {
            let r = CGRect(x: c.rect.minX * CGFloat(f), y: c.rect.minY * CGFloat(f),
                           width: c.rect.width * CGFloat(f), height: c.rect.height * CGFloat(f))
                .insetBy(dx: CGFloat(3 * f) - 4, dy: CGFloat(3 * f) - 4)
                .intersection(CGRect(x: 0, y: 0, width: W, height: H))
            guard !r.isNull else { continue }
            let edge = r.minX <= 4 || r.minY <= 4 || r.maxX >= W - 4 || r.maxY >= H - 4
            // настоящая краска, а не пыль: несколько знаков шириной и заметная высота
            guard !edge, r.width >= typical * 1.5, r.height >= typical * 0.6,
                  let inkR = rest.inkBounds(in: r), inkR.width >= typical * 1.2 else { continue }
            let dots = rest.crop(inkR).bits.reduce(0) { $0 + Int($1) }
            guard Double(dots) >= 0.04 * Double(inkR.width * inkR.height) else { continue }
            // хвосты букв над и под рамками строк OCR (рамка Vision чуть ниже строки) — не формула:
            // такая «краска» лежит в основном внутри строк и низкая
            let covered = ocr.reduce(CGFloat(0)) { acc, o in
                let x = o.box.intersection(inkR); return acc + (x.isNull ? 0 : x.width * x.height) }
            guard covered < 0.3 * inkR.width * inkR.height, inkR.height >= typical * 0.7 else { continue }
            leftovers.append(inkR.insetBy(dx: -4, dy: -4))
        }
        leftovers = mergeOverlapping(leftovers.map { $0.insetBy(dx: -typical * 0.9, dy: -typical * 0.4) })

        // 3a. Надписи внутри иллюстраций — для перерисовки при улучшении картинок.
        var figureLabels: [FigureLabel] = []
        for o in ocr {
            let c = CGPoint(x: o.box.midX, y: o.box.midY)
            if let fi = figures.firstIndex(where: { $0.contains(c) }), let line = buildLine(o, ink: ink) {
                figureLabels.append(FigureLabel(figure: fi, line: line))
            }
        }

        // 3. Строки текста вне иллюстраций; типичные ошибки распознавания — исправляем.
        var lines = ocr.filter { !inFigure($0.box) }.compactMap { buildLine($0, ink: ink) }
        // короткие строки внутри нераспознанной краски («min», «max» у формулы) — её часть
        var leftoverLines: [[TextLine]] = Array(repeating: [], count: leftovers.count)
        lines.removeAll { l in
            let longWords = l.words.filter { $0.text.filter(\.isLetter).count >= 4 }.count
            let c = CGPoint(x: l.bounds.midX, y: l.bounds.midY)
            // строка внутри нераспознанной краски (обрывки формулы) или короткая и задевает её
            guard let k = leftovers.firstIndex(where: { r in
                if r.contains(c) && l.bounds.width <= r.width * 1.3 { return true }
                if longWords <= 1 && r.intersects(l.bounds) { return true }
                // продолжение формулы в той же строке: рядом по горизонтали, почти без слов прозы
                let vOverlap = min(r.maxY, l.bounds.maxY) - max(r.minY, l.bounds.minY)
                let hGap = max(l.bounds.minX - r.maxX, r.minX - l.bounds.maxX)
                return vOverlap >= 0.5 * l.bounds.height && hGap <= typical * 2 && longWords <= 3
                    && l.words.count <= 8
            }) else { return false }
            leftovers[k] = leftovers[k].union(l.bounds.insetBy(dx: -4, dy: -4)); leftoverLines[k].append(l); return true
        }
        OCRCorrector.correct(&lines, languages: languages)
        for i in figureLabels.indices {
            var l = [figureLabels[i].line]
            OCRCorrector.correct(&l, languages: languages)
            figureLabels[i].line = l[0]
        }

        // 3б. Таблицы в сетке линеек: иллюстрация, в которой нет ничего, кроме сетки и текста в клетках.
        var tables: [TableBlock] = []
        for fi in figures.indices.reversed() {
            let labels = figureLabels.filter { $0.figure == fi }.map(\.line)
            guard let t = StructureDetector.ruledTable(in: figures[fi], labels: labels, nonText: nonText) else { continue }
            tables.insert(t, at: 0)
            figures.remove(at: fi)
            figureLabels = figureLabels.filter { $0.figure != fi }.map { var l = $0; if l.figure > fi { l.figure -= 1 }; return l }
        }

        // 3в. Колонки, оглавления, таблицы без линеек; остальное — обычный текст в порядке чтения.
        let structure = StructureDetector(width: W, height: H, ink: ink).detect(lines)
        lines = structure.lines
        tables += structure.tables

        // 4. Колонка и выравнивание (в многоколоночной зоне — по своей колонке).
        let groups = Dictionary(grouping: lines.indices) { StructureDetector.group(of: lines[$0].bounds, zones: structure.zones) }
        for idx in groups.values {
            var part = idx.map { lines[$0] }
            assignAlignment(&part, pageWidth: W)
            for (k, i) in idx.enumerated() { lines[i] = part[k] }
        }

        // 5. Абзацы и их оформление.
        let structureLines = structure.toc.flatMap { $0.entries.flatMap(\.allLines) } + tables.flatMap { $0.cells.flatMap(\.lines) }
        let matcher = StyleMatcher(ink: ink, palette: palette,
                                   pageStem: StyleMatcher.pageStemReference(lines: lines + structureLines, ink: ink))
        var toc = structure.toc
        for ti in toc.indices {
            for ei in toc[ti].entries.indices {
                var e = toc[ti].entries[ei]
                var group = e.allLines
                (e.family, e.fontSize) = matcher.style(&group)
                e.lines = Array(group.prefix(e.lines.count))
                if var page = group.last, e.page != nil {
                    // номер — начертанием названия (по одной-двум цифрам жирность и наклон не определить)
                    let words = e.lines.flatMap(\.words)
                    for wi in page.words.indices {
                        page.words[wi].bold = words.filter(\.bold).count * 2 > words.count
                        page.words[wi].italic = words.filter(\.italic).count * 2 > words.count
                    }
                    // число проверено по шаблону — одиночную цифру Vision отдаёт с низкой уверенностью
                    if page.confidence > 0 { page.confidence = max(page.confidence, AnalyzedPage.minConfidence + 0.1) }
                    e.page = page
                }
                toc[ti].entries[ei] = e
            }
        }
        for ti in tables.indices {
            var group = tables[ti].cells.flatMap(\.lines)
            guard !group.isEmpty else { continue }
            (tables[ti].family, tables[ti].fontSize) = matcher.style(&group)
            var k = 0
            for ci in tables[ti].cells.indices {
                for li in tables[ti].cells[ci].lines.indices { tables[ti].cells[ci].lines[li] = group[k]; k += 1 }
            }
        }
        var styled: [Paragraph] = []
        // формулы и «мусор» распознавания (цифры и подписи внутри графиков) — фрагментом скана
        var scans = structure.scans + zip(leftovers, leftoverLines).map { ScanRegion(rect: $0.0, lines: $0.1) }
        let complex = ComplexBlocks.split(&lines)
        for l in complex {
            let r = l.bounds.insetBy(dx: -6, dy: -6).intersection(CGRect(x: 0, y: 0, width: W, height: H))
            if let k = scans.firstIndex(where: { $0.rect.insetBy(dx: -l.xHeight * 2.5, dy: -l.xHeight * 2.5).intersects(r) }) {
                scans[k].rect = scans[k].rect.union(r); scans[k].lines.append(l)
            } else {
                scans.append(ScanRegion(rect: r, lines: [l]))
            }
        }
        // пересекающиеся фрагменты — одним
        var merged: [ScanRegion] = []
        for r in scans {
            if let k = merged.firstIndex(where: { $0.rect.intersects(r.rect) }) {
                merged[k].rect = merged[k].rect.union(r.rect); merged[k].lines += r.lines
            } else { merged.append(r) }
        }
        scans = merged
        // строки, оказавшиеся внутри фрагмента скана, — его часть (иначе текст рисуется поверх картинки)
        lines.removeAll { l in
            let c = CGPoint(x: l.bounds.midX, y: l.bounds.midY)
            guard let k = scans.firstIndex(where: { $0.rect.contains(c) }) else { return false }
            scans[k].lines.append(l); return true
        }
        for var group in groupParagraphs(lines) {
            let (family, size) = matcher.style(&group)
            styled.append(Paragraph(family: family, fontSize: size, lines: group))
        }
        Headings.refine(&styled, pageWidth: W)
        let bodySize = Headings.bodySize(styled)
        // гарнитура основного текста — по числу строк
        let bodyFamily = Dictionary(grouping: styled, by: \.family).max { a, b in
            a.value.reduce(0) { $0 + $1.lines.count } < b.value.reduce(0) { $0 + $1.lines.count } }?.key
        for i in styled.indices {
            StyleMatcher.unifyEmphasis(&styled[i].lines)
            // заголовок, эпиграф, подпись (кегль заметно отличается от основного): жирность — по плотности краски, целиком
            // подзаголовок того же кегля, но другой гарнитурой (рубленый среди антиквы) — тоже
            let otherFamily = styled[i].family != bodyFamily && styled[i].family != .mono && styled[i].lines.count <= 2
            let distinct = (bodySize > 0 && abs(styled[i].fontSize - bodySize) > bodySize * 0.15 && styled[i].lines.count <= 4)
                || otherFamily
            let heading = Headings.isHeading(styled[i], body: bodySize)
            if heading || distinct, let bold = matcher.headingIsBold(styled[i].lines, family: styled[i].family),
               bold || heading {
                // у подписи «Рис. 2.1.» жирное только начало: «не жирный» решаем по плотности лишь для заголовков
                for li in styled[i].lines.indices { for wi in styled[i].lines[li].words.indices { styled[i].lines[li].words[wi].bold = bold } }
            } else if distinct, matcher.headingIsBold(styled[i].lines, family: styled[i].family) == false {
                // эпиграф, подпись: по плотности не жирные — случайные «жирные» слова убираем,
                // кроме начала подписи с номером («Рис. 2.1.»)
                let words = styled[i].lines.flatMap(\.words)
                let lead = words.prefix { $0.bold }.prefix(3)
                let keep = lead.count <= 2 && lead.contains { $0.text.contains(where: \.isNumber) } ? lead.count : 0
                var k = 0
                for li in styled[i].lines.indices {
                    for wi in styled[i].lines[li].words.indices {
                        if k >= keep { styled[i].lines[li].words[wi].bold = false }
                        k += 1
                    }
                }
            }
        }

        // Код: абзацы-код + соседние с ними короткие куски (пустые строки в коде рвут абзац),
        // затем соседние куски склеиваем в один блок.
        var isCode = styled.map(CodeDetector.isCode)
        var changed = true
        while changed {
            changed = false
            for i in styled.indices where !isCode[i] {
                for j in [i - 1, i + 1] where styled.indices.contains(j) && isCode[j] {
                    let a = styled[i], b = styled[j]
                    let gap = abs(a.lines[0].baseline - b.lines[0].baseline)
                    let span = CGFloat(max(a.lines.count, b.lines.count) + 3) * (b.lines[0].xHeight * 2.4)
                    let aligned = a.lines.map(\.bounds.minX).min()! >= b.lines.map(\.bounds.minX).min()! - b.lines[0].xHeight
                    if (a.family == .mono || CodeDetector.symbolDensity(a.lines.map(\.text).joined()) > 0.05 || a.lines.count <= 2)
                        && aligned && gap < span {
                        isCode[i] = true; changed = true
                    }
                }
            }
        }
        var paragraphs: [Paragraph] = []
        var codeBlocks: [CodeBlock] = []
        var pending: Paragraph?
        func flush() {
            if let p = pending {
                if let block = codeBlock(p, image: image, ink: ink, occupied: ocr.map(\.box)) { codeBlocks.append(block) } else { paragraphs.append(p) }
            }
            pending = nil
        }
        for (p, code) in zip(styled, isCode) {
            if code {
                if var cur = pending { cur.lines += p.lines; pending = cur } else { pending = p }
            } else {
                flush()
                paragraphs.append(p)
            }
        }
        flush()
        return PageLayout(size: CGSize(width: W, height: H), figures: figures, rules: rules, paragraphs: paragraphs,
                          codeBlocks: codeBlocks, figureLabels: figureLabels, tocBlocks: toc, tables: tables,
                          scanRegions: scans, columnZones: structure.zones)
    }

    // MARK: - код

    /// Повторное распознавание блока кода без "исправления языка" (иначе `fooBar` станет `foo Bar`),
    /// восстановление отступов по шагу моноширинного шрифта, определение языка.
    private func codeBlock(_ p: Paragraph, image: CGImage, ink: InkMask, occupied: [CGRect]) -> CodeBlock? {
        var bounds = p.lines.map(\.bounds).reduce(p.lines[0].bounds) { $0.union($1) }
        let pad: CGFloat = 6
        let cropRect = bounds.insetBy(dx: -pad, dy: -pad).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var texts = p.lines.map(\.text)
        if let crop = image.cropping(to: cropRect),
           let again = try? OCREngine.recognize(crop, languages: ["en-US"], languageCorrection: false, token: token) {
            // сопоставляем по вертикали со строками абзаца
            for (i, line) in p.lines.enumerated() {
                let y = line.baseline - cropRect.minY - line.xHeight / 2
                if let m = again.min(by: { abs($0.box.midY - y) < abs($1.box.midY - y) }),
                   abs(m.box.midY - y) < line.xHeight * 1.5 {
                    texts[i] = m.text
                }
            }
        }
        // шаг символа: ширина краски строки / (число символов - 0.3), медиана
        let pitches = zip(p.lines, texts).compactMap { l, t -> CGFloat? in
            let n = t.trimmingCharacters(in: .whitespaces).count
            return n >= 4 ? l.bounds.width / (CGFloat(n) - 0.3) : nil
        }.sorted()
        guard !pitches.isEmpty else { return nil }
        let pitch = pitches[pitches.count / 2]
        let left = p.lines.map(\.bounds.minX).min() ?? bounds.minX
        var lines = zip(p.lines, texts).map { l, t in
            CodeLine(text: t.trimmingCharacters(in: .whitespaces),
                     indent: max(0, Int(((l.bounds.minX - left) / pitch).rounded())),
                     baseline: l.baseline)
        }

        // строки, которых нет в OCR (Vision пропускает одиночные `}` `)`): ряды краски в колонке блока
        let steps = zip(p.lines.dropFirst(), p.lines).map { $0.baseline - $1.baseline }.filter { $0 > 0 }.sorted()
        let xh = p.lines.map(\.xHeight).sorted()[p.lines.count / 2]
        let step = steps.isEmpty ? xh * 2.4 : steps[steps.count / 2]
        let search = CGRect(x: left - pitch, y: bounds.minY, width: bounds.width + 2 * pitch,
                            height: bounds.height + step * 1.3)
        var pendingLines: [(rect: CGRect, glyphs: Int)] = []
        if let (_, y0, _, _) = ink.clampRect(search) {
            let prof = ink.rowProfile(search)
            var r = 0
            while r < prof.count {
                guard prof[r] > 0 else { r += 1; continue }
                var e = r
                while e < prof.count, prof[e] > 0 { e += 1 }
                let band = CGRect(x: search.minX, y: CGFloat(y0 + r), width: search.width, height: CGFloat(e - r))
                r = e
                guard band.height >= xh * 0.6,
                      !occupied.contains(where: { $0.intersects(search) && $0.minY < band.maxY - 2 && $0.maxY > band.minY + 2 }),
                      !p.lines.contains(where: { $0.bounds.minY < band.maxY - 2 && $0.bounds.maxY > band.minY + 2 }),
                      let inkR = ink.inkBounds(in: band) else { continue }
                // число знаков: сегменты краски по столбцам
                let cols = ink.columnProfile(inkR)
                var glyphs = 0, inGlyph = false
                for v in cols { if v > 0 && !inGlyph { glyphs += 1 }; inGlyph = v > 0 }
                pendingLines.append((inkR, glyphs))
            }
        }
        let ref = p.lines[0].baseline
        for (rect, glyphs) in pendingLines {
            // базовая линия — на сетке строк блока
            let k = ((rect.maxY - ref) / step).rounded()
            let baseline = ref + k * step
            guard !lines.contains(where: { abs($0.baseline - baseline) < step * 0.4 }) else { continue }
            // сначала — отдельный OCR фрагмента с увеличением, без исправления языка
            var text = Self.recognizeFragment(image, rect: rect)
            if text == nil, rect.width <= CGFloat(glyphs) * pitch * 1.2 {
                text = String(repeating: "?", count: glyphs)   // скобки: определим по балансу ниже
            }
            guard let t = text else { continue }
            lines.append(CodeLine(text: t, indent: max(0, Int(((rect.minX - left) / pitch).rounded())), baseline: baseline))
            bounds = bounds.union(rect)
        }
        lines.sort { $0.baseline < $1.baseline }
        // скобки по шаблону: «?» — закрывающие для незакрытых открывающих выше
        for i in lines.indices where lines[i].text.allSatisfy({ $0 == "?" }) {
            var stack = CodeFixer.openStack(lines[..<i].map(\.text))
            var out = ""
            for _ in lines[i].text { if let o = stack.popLast() { out.append(CodeFixer.closer[o]!) } }
            lines[i].text = out
        }
        lines.removeAll { $0.text.isEmpty }

        // типичные ошибки OCR в коде (O/0, $o, JSoN)
        let fixed = CodeFixer.fix(lines.map(\.text))
        for i in lines.indices { lines[i].text = fixed[i] }
        let all = lines.map(\.text).joined(separator: "\n")
        return CodeBlock(bounds: bounds, language: CodeDetector.detectLanguage(all).language, pitch: pitch, lines: lines)
    }

    /// OCR маленького фрагмента: увеличение x3 и белые поля (Vision плохо видит одиночные знаки).
    static func recognizeFragment(_ image: CGImage, rect: CGRect) -> String? {
        let r = rect.insetBy(dx: -4, dy: -4).integral
        guard let crop = image.cropping(to: r) else { return nil }
        let s = 3, pad = 40
        let w = crop.width * s + 2 * pad, h = crop.height * s + 2 * pad
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(crop, in: CGRect(x: pad, y: pad, width: crop.width * s, height: crop.height * s))
        guard let big = ctx.makeImage(),
              let res = try? OCREngine.recognize(big, languages: ["en-US"], languageCorrection: false) else { return nil }
        let t = res.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    // MARK: - строки

    private func buildLine(_ o: OCRLine, ink: InkMask) -> TextLine? {
        let band = o.box.insetBy(dx: -4, dy: -o.box.height * 0.08)
        guard var inkBox = ink.inkBounds(in: band) else { return nil }
        let prof = ink.rowProfile(inkBox)
        // ряды подчёркивания (сплошная краска почти на всю ширину) не участвуют в поиске x-height
        var ruleRows = Set(prof.indices.filter { Double(prof[$0]) > 0.8 * Double(inkBox.width) })
        for r in ruleRows {   // сглаженные края линейки
            for n in [r - 1, r + 1] where prof.indices.contains(n) && Double(prof[n]) > 0.5 * Double(inkBox.width) {
                ruleRows.insert(n)
            }
        }
        guard let mx = prof.indices.filter({ !ruleRows.contains($0) }).map({ prof[$0] }).max(), mx > 0 else { return nil }
        // пояс строчных букв — самая «плотная» сплошная полоса рядов; рамка Vision бывает выше строки
        // и захватывает соседнюю: тогда first…last по всем рядам растягивался на две строки, базовая линия
        // уезжала вниз и строки на странице наезжали друг на друга
        var runs: [(Int, Int, Int)] = []          // начало, конец, сумма краски
        var r0: Int? = nil, sum = 0
        for i in prof.indices {
            let on = !ruleRows.contains(i) && Double(prof[i]) > 0.35 * Double(mx)
            if on { if r0 == nil { r0 = i; sum = 0 }; sum += prof[i] }
            if let a = r0, !on || i == prof.count - 1 {
                // разрыв в 1–2 ряда (тонкие штрихи) не рвёт пояс
                let end = on ? i : i - 1
                if let lastRun = runs.last, a - lastRun.1 <= 3 { runs[runs.count - 1] = (lastRun.0, end, lastRun.2 + sum) }
                else { runs.append((a, end, sum)) }
                r0 = nil
            }
        }
        guard let belt = runs.max(by: { $0.2 < $1.2 }) else { return nil }
        let first = belt.0, last = belt.1
        let baseline = inkBox.minY + CGFloat(last + 1)
        let xHeight = CGFloat(last - first + 1)
        // краска чужой строки по краям рамки не входит в рамку этой
        if runs.count > 1, ruleRows.isEmpty {
            let top = inkBox.minY + max(0, CGFloat(first) - xHeight * 1.6)
            let bottom = min(inkBox.maxY, baseline + xHeight * 0.9)
            if let tight = ink.inkBounds(in: CGRect(x: inkBox.minX, y: top, width: inkBox.width, height: bottom - top)) {
                inkBox = tight
            }
        }

        // слова: сегменты краски между пробелами; если число не совпало — рамки Vision
        // подчёркивание сливает слова — столбцы считаем только по рядам над ним
        var colRect = inkBox
        if let firstRule = ruleRows.min(), firstRule > last - Int(xHeight) / 2 {
            colRect.size.height = CGFloat(firstRule)
        }
        let cols = ink.columnProfile(colRect)
        let minGap = max(3, Int(0.28 * xHeight))
        var segments: [ClosedRange<Int>] = []
        var start: Int? = nil, gap = 0
        for (i, v) in cols.enumerated() {
            if v > 0 {
                if start == nil { start = i }
                else if gap >= minGap, let s = start { segments.append(s...(i - gap - 1)); start = i }
                gap = 0
            } else if start != nil { gap += 1 }
        }
        if let s = start { segments.append(s...(cols.count - 1 - gap)) }

        var words: [Word] = []
        if segments.count == o.words.count {
            for (seg, w) in zip(segments, o.words) {
                let r = CGRect(x: inkBox.minX + CGFloat(seg.lowerBound), y: inkBox.minY,
                               width: CGFloat(seg.count), height: inkBox.height)
                words.append(Word(text: w.text, bounds: ink.inkBounds(in: r) ?? r))
            }
        } else {
            for w in o.words {
                let r = w.box.intersection(inkBox)
                words.append(Word(text: w.text, bounds: (r.isNull ? nil : ink.inkBounds(in: r)) ?? w.box))
            }
        }
        return TextLine(bounds: inkBox, baseline: baseline, xHeight: xHeight,
                        alignment: .left, confidence: o.confidence, words: words)
    }

    private func assignAlignment(_ lines: inout [TextLine], pageWidth W: CGFloat) {
        let body = lines.filter { $0.words.count > 3 }
        guard !body.isEmpty else { return }
        let lefts = body.map(\.bounds.minX).sorted()
        let rights = body.map(\.bounds.maxX).sorted()
        let colL = lefts[lefts.count / 2]
        let colR = rights[min(rights.count - 1, Int(Double(rights.count) * 0.9))]
        let tol = 0.012 * W
        for i in lines.indices {
            let b = lines[i].bounds
            let atR = abs(b.maxX - colR) < tol
            let nearL = b.minX < colL + 4 * tol          // с учётом абзацного отступа
            let centered = abs(b.midX - (colL + colR) / 2) < tol && b.minX > colL + 3 * tol
            if atR && nearL && lines[i].words.count > 1 { lines[i].alignment = .justify }
            else if centered { lines[i].alignment = .center }
            else if atR { lines[i].alignment = .right }
            else { lines[i].alignment = .left }
        }
    }

    /// Соседние строки с близкой высотой и нормальным интервалом — один абзац.
    private func groupParagraphs(_ lines: [TextLine]) -> [[TextLine]] {
        var groups: [[TextLine]] = []
        for line in lines {
            if let prev = groups.last?.last {
                let similar = abs(line.xHeight - prev.xHeight) / max(prev.xHeight, 1) < 0.18
                let pitch = line.baseline - prev.baseline
                let close = pitch > 0 && pitch < prev.xHeight * 3.2
                let overlap = line.bounds.minX < prev.bounds.maxX && line.bounds.maxX > prev.bounds.minX
                if similar && close && overlap && prev.alignment != .center && line.alignment != .center {
                    groups[groups.count - 1].append(line)
                    continue
                }
            }
            groups.append([line])
        }
        return groups
    }

    private func mergeOverlapping(_ rects: [CGRect]) -> [CGRect] {
        var out = rects
        var merged = true
        while merged {
            merged = false
            outer: for i in out.indices {
                for j in out.indices where j > i && out[i].intersects(out[j]) {
                    out[i] = out[i].union(out[j]); out.remove(at: j); merged = true
                    break outer
                }
            }
        }
        return out
    }
}
