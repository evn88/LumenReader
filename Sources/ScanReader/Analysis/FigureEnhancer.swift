import CoreGraphics
import CoreImage
import CoreML
import CoreText
import Foundation
import Vision

/// Улучшение иллюстраций (скриншоты, схемы, таблицы):
///  1. увеличение x2: модель Core ML на Neural Engine, если установлена, иначе Lanczos + шумоподавление;
///  2. ровные заливки фона вместо зерна и полутона скана;
///  3. прямые линии (рамки, разделители, подчёркивания) перерисовываются чёткими;
///  4. уверенно распознанные надписи стираются и набираются шрифтом того же цвета;
///     нераспознанное остаётся пикселями (почищенными).
struct FigureEnhancer {
    var palette: FontPalette
    var scale = 2

    // MARK: - Core ML (Neural Engine)

    /// Модель super-resolution (напр. Real-ESRGAN, сконвертированная coremltools):
    /// ~/Library/Application Support/ScanReader/Models/SuperResolution.mlmodelc
    /// Вход и выход — изображения; тайлы размера входа модели.
    static let superResolution: VNCoreMLModel? = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(Product.dataFolder)/Models/SuperResolution.mlmodelc")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let config = MLModelConfiguration()
        config.computeUnits = .all            // Neural Engine + GPU + CPU, приоритет у ANE
        guard let model = try? MLModel(contentsOf: url, configuration: config) else { return nil }
        return try? VNCoreMLModel(for: model)
    }()

    private static let ciContext = CIContext(options: [.workingColorSpace: CGColorSpaceCreateDeviceGray()])

    private func upscale(_ image: CGImage) -> GrayBitmap? {
        if let model = Self.superResolution, let out = upscaleWithModel(image, model) { return out }
        let ci = CIImage(cgImage: image)
        let scaled = ci.applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": scale, "inputAspectRatio": 1])
            .applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.03, "inputSharpness": 0.5])
        return render(scaled, width: image.width * scale, height: image.height * scale)
    }

    private func render(_ ci: CIImage, width: Int, height: Int) -> GrayBitmap? {
        guard width > 0, height > 0 else { return nil }
        var px = [UInt8](repeating: 255, count: width * height)
        px.withUnsafeMutableBytes { buf in
            Self.ciContext.render(ci, toBitmap: buf.baseAddress!, rowBytes: width,
                                  bounds: CGRect(x: 0, y: 0, width: width, height: height),
                                  format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        }
        return GrayBitmap(width: width, height: height, pixels: px)
    }

    /// Тайловый прогон модели: каждый тайл = размеру входа, результат склеиваем.
    private func upscaleWithModel(_ image: CGImage, _ model: VNCoreMLModel) -> GrayBitmap? {
        let tile = 256
        let outW = image.width * scale, outH = image.height * scale
        var canvas = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: outW, height: outH))
        let src = CIImage(cgImage: image)
        for ty in stride(from: 0, to: image.height, by: tile) {
            for tx in stride(from: 0, to: image.width, by: tile) {
                let rect = CGRect(x: tx, y: ty, width: min(tile, image.width - tx), height: min(tile, image.height - ty))
                guard let tileImage = Self.ciContext.createCGImage(src, from: rect) else { return nil }
                let request = VNCoreMLRequest(model: model)
                request.imageCropAndScaleOption = .scaleFill
                try? VNImageRequestHandler(cgImage: tileImage).perform([request])
                guard let obs = request.results?.first as? VNPixelBufferObservation else { return nil }
                let out = CIImage(cvPixelBuffer: obs.pixelBuffer)
                let target = CGRect(x: rect.minX * CGFloat(scale), y: rect.minY * CGFloat(scale),
                                    width: rect.width * CGFloat(scale), height: rect.height * CGFloat(scale))
                let fitted = out.transformed(by: CGAffineTransform(scaleX: target.width / out.extent.width,
                                                                   y: target.height / out.extent.height))
                    .transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
                canvas = fitted.composited(over: canvas)
            }
        }
        return render(canvas, width: outW, height: outH)
    }

    // MARK: - основной проход

    /// - Parameters:
    ///   - rect: рамка иллюстрации на странице; labels: строки OCR внутри (координаты страницы).
    /// - Returns: картинка в `scale` раз больше рамки (на Retina выглядит чётче).
    /// Крупнее этого (пикселей скана) полное улучшение не делаем: после ×2 вышли бы десятки мегапикселей
    /// и гигабайт памяти на страницу (заливки/размытия в Double) — оставляем «уровни».
    static let maxEnhanceArea: CGFloat = 3_000_000

    func enhance(page gray: GrayBitmap, rect: CGRect, labels: [TextLine], token: CancelToken? = nil) -> CGImage? {
        let r = rect.integral
        if r.width * r.height > Self.maxEnhanceArea { return gray.leveledImage(rect: r) }
        guard token?.isCancelled != true,
              let crop = gray.leveledImage(rect: r, black: 0, white: 255), let up = upscale(crop) else { return nil }
        let W = up.width, H = up.height, s = CGFloat(scale)
        // фотографии (полутона, сплошные тёмные массивы) — только увеличиваем: детектор линий и заливок
        // рассчитан на скриншоты/схемы и рисует на фото вертикальные полосы
        if Self.isPhotographic(up) { return GrayBitmap.makeImage(width: W, height: H, pixels: up.pixels) }
        let thr = up.otsuThreshold()
        let ink = InkMask(up, threshold: thr)
        func local(_ b: CGRect) -> CGRect {
            CGRect(x: (b.minX - r.minX) * s, y: (b.minY - r.minY) * s, width: b.width * s, height: b.height * s)
        }
        let localLabels = labels.map { l -> TextLine in
            var l = l
            l.bounds = local(l.bounds)
            l.baseline = (l.baseline - r.minY) * s
            l.xHeight *= s
            l.words = l.words.map { var w = $0; w.bounds = local(w.bounds); return w }
            return l
        }

        // 1. линии
        let segments = detectLines(ink, gray: up, labels: localLabels)
        var lineMask = InkMask(width: W, height: H, bits: [UInt8](repeating: 0, count: W * H))
        for seg in segments { lineMask.fill(seg.rect.insetBy(dx: -2, dy: -2)) }

        // 2. фон (самый тяжёлый этап — перед ним проверяем отмену)
        guard token?.isCancelled != true else { return nil }
        let bg = backgroundTones(up, ink: ink)
        guard token?.isCancelled != true else { return nil }

        // 3. что стираем: линии и уверенные надписи
        var erase = lineMask
        let confident = localLabels.filter { $0.confidence >= 0.5 && !$0.words.isEmpty }
        for l in confident {
            var box = l.bounds
            // рамка Vision часто обрезает последний знак («ID:» без двоеточия): захватываем краску справа,
            // пока разрыв меньше трети x-height (дальше — уже соседнее слово)
            let rows = Int(max(0, box.minY))..<Int(min(CGFloat(H), box.maxY))
            var x = Int(box.maxX), gap = 0
            let maxGap = max(3, Int(l.xHeight * 0.35)), limit = min(W, Int(box.maxX + l.xHeight * 1.2))
            while x < limit {
                if rows.contains(where: { ink.at(x, $0) != 0 }) { box.size.width = CGFloat(x + 1) - box.minX; gap = 0 }
                else { gap += 1; if gap > maxGap { break } }
                x += 1
            }
            erase.fill(box.insetBy(dx: -6 * s / 2, dy: -4 * s / 2))
        }

        var out = [UInt8](repeating: 255, count: W * H)
        let keep = ink.dilated(radius: 1)
        for i in 0..<(W * H) {
            if keep.bits[i] != 0 && erase.bits[i] == 0 {
                out[i] = UInt8(max(0, min(255, (Double(up.pixels[i]) - 10) * 255 / 235)))
            } else {
                out[i] = bg[i]
            }
        }

        // 4. рисуем линии и надписи вектором
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let base = GrayBitmap.makeImage(width: W, height: H, pixels: out) else { return nil }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: W, height: H))
        ctx.translateBy(x: 0, y: CGFloat(H))
        ctx.scaleBy(x: 1, y: -1)
        for seg in segments {
            ctx.setFillColor(CGColor(gray: CGFloat(seg.tone) / 255, alpha: 1))
            ctx.fill(seg.rect)
        }
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let boldLines = boldLabels(confident, ink: ink)
        for (li, l0) in confident.enumerated() {
            var l = l0
            // подчёркнутая надпись: «.» в конце — это обрывок подчёркивания, а не точка
            let underlined = segments.contains { seg in
                seg.rect.width > seg.rect.height && seg.rect.minY >= l.baseline - 2 && seg.rect.minY <= l.baseline + l.xHeight * 0.6
                    && min(seg.rect.maxX, l.bounds.maxX) - max(seg.rect.minX, l.bounds.minX) > 0.6 * l.bounds.width
            }
            if underlined, var last = l.words.last, last.text.count > 1, last.text.hasSuffix(".") {
                last.text.removeLast(); l.words[l.words.count - 1] = last
            }
            let bold = boldLines.contains(li)
            let tone = darkTone(up, ink: ink, rect: l.bounds)
            let color = CGColor(gray: CGFloat(tone) / 255, alpha: 1)
            // кегль строки: медиана подбора по ширине слов
            var sizes: [CGFloat] = []
            for w in l.words {
                let f = palette.font(.sans, bold: bold, italic: false, size: 100)
                let wInk = TextMetrics.inkBounds(TextMetrics.line(w.text, font: f)).width
                if wInk > 0 { sizes.append(100 * w.bounds.width / wInk) }
            }
            sizes.sort()
            let size = sizes.isEmpty ? l.xHeight * 1.9 : sizes[sizes.count / 2]
            let font = palette.font(.sans, bold: bold, italic: false, size: size)
            for w in l.words {
                let line = TextMetrics.line(w.text, font: font, color: color)
                let b = TextMetrics.inkBounds(line)
                ctx.textPosition = CGPoint(x: w.bounds.minX - b.minX, y: l.baseline)
                CTLineDraw(line, ctx)
            }
        }
        return ctx.makeImage()
    }

    // MARK: - помощники

    struct Segment { var rect: CGRect; var tone: UInt8 }

    /// Фото, а не схема/скриншот: много полутонов или много тёмного (по выборке пикселей).
    static func isPhotographic(_ g: GrayBitmap) -> Bool {
        let step = max(1, g.pixels.count / 40_000)
        var mid = 0, dark = 0, n = 0
        var i = 0
        while i < g.pixels.count {
            let v = g.pixels[i]
            if v > 50 && v < 200 { mid += 1 }
            if v <= 50 { dark += 1 }
            n += 1; i += step
        }
        guard n > 0 else { return false }
        return Double(mid) / Double(n) > 0.22 || Double(dark) / Double(n) > 0.3
    }

    /// Жирные надписи: толщина штриха / x-height по строкам, два кластера (1D k-means);
    /// верхний — жирный, если заметно толще нижнего.
    private func boldLabels(_ labels: [TextLine], ink: InkMask) -> Set<Int> {
        let stems: [(Int, Double)] = labels.enumerated().compactMap { i, l in
            guard l.xHeight > 0 else { return nil }
            // только над базовой линией: подчёркивание не должно утолщать штрих
            let r = CGRect(x: l.bounds.minX, y: l.bounds.minY, width: l.bounds.width, height: max(1, l.baseline - l.bounds.minY))
            let v = ink.crop(r).meanStemWidth() / Double(l.xHeight)
            return v > 0 ? (i, v) : nil
        }
        guard stems.count >= 4 else { return [] }
        let vals = stems.map(\.1).sorted()
        var lo = vals.first!, hi = vals.last!
        for _ in 0..<20 {
            let mid = (lo + hi) / 2
            let a = vals.filter { $0 <= mid }, b = vals.filter { $0 > mid }
            guard !a.isEmpty, !b.isEmpty else { break }
            lo = a.reduce(0, +) / Double(a.count); hi = b.reduce(0, +) / Double(b.count)
        }
        guard hi / lo > 1.25 else { return [] }
        let mid = (lo + hi) / 2
        var bold = Set(stems.filter { $0.1 > mid }.map(\.0))
        // строки одного столбца (общий левый край, близкий кегль) оформлены одинаково: решает большинство
        var done = Set<Int>()
        for i in labels.indices where !done.contains(i) {
            let col = labels.indices.filter { j in
                abs(labels[j].bounds.minX - labels[i].bounds.minX) < max(6, labels[i].xHeight * 0.4)
                    && abs(labels[j].xHeight - labels[i].xHeight) < labels[i].xHeight * 0.35
            }
            done.formUnion(col)
            guard col.count >= 3 else { continue }
            let n = col.filter { bold.contains($0) }.count
            if n * 2 > col.count { bold.formUnion(col) } else { bold.subtract(col) }
        }
        return bold
    }

    /// Горизонтальные и вертикальные серии краски длиннее minLen, склеенные по соседним рядам.
    private func detectLines(_ ink: InkMask, gray up: GrayBitmap, labels: [TextLine]) -> [Segment] {
        let minLen = max(60, ink.width / 20)
        var result: [CGRect] = []
        for horizontal in [true, false] {
            let outer = horizontal ? ink.height : ink.width
            let inner = horizontal ? ink.width : ink.height
            var open: [CGRect] = []
            for a in 0..<outer {
                var runs: [(Int, Int)] = []
                var start = -1
                for b in 0...inner {
                    let on = b < inner && (horizontal ? ink.at(b, a) : ink.at(a, b)) != 0
                    if on, start < 0 { start = b }
                    if !on, start >= 0 { if b - start >= minLen { runs.append((start, b)) }; start = -1 }
                }
                var next: [CGRect] = []
                for (s0, s1) in runs {
                    let rr = horizontal ? CGRect(x: s0, y: a, width: s1 - s0, height: 1)
                                        : CGRect(x: a, y: s0, width: 1, height: s1 - s0)
                    if let i = open.firstIndex(where: { o in
                        horizontal ? (o.maxY == CGFloat(a) && abs(o.minX - rr.minX) < 6 && abs(o.maxX - rr.maxX) < 6)
                                   : (o.maxX == CGFloat(a) && abs(o.minY - rr.minY) < 6 && abs(o.maxY - rr.maxY) < 6)
                    }) {
                        next.append(open[i].union(rr)); open.remove(at: i)
                    } else {
                        next.append(rr)
                    }
                }
                result += open                     // закончившиеся сегменты
                open = next
            }
            result += open
        }
        let words = labels.flatMap(\.words)
        return result.filter { r in
            guard min(r.width, r.height) <= 12 else { return false }   // толстое — не линия
            // штрихи крупных букв внутри слов — не линии
            return !words.contains { w in
                let box = w.bounds.insetBy(dx: -4, dy: -4)
                let span = r.width > r.height ? r.width : r.height
                return box.contains(r) && span < 0.6 * max(w.bounds.width, w.bounds.height)
                    || (r.height > r.width && box.contains(r))
            }
        }.map { r -> CGRect in
            // к линии могут прилипнуть нижние ряды букв над ней — оставляем только сплошные ряды
            guard r.width > r.height, r.height > 1 else { return r }
            let x0 = Int(r.minX), x1 = Int(r.maxX)
            let full = (Int(r.minY)..<Int(r.maxY)).filter { y in
                (x0..<x1).reduce(0) { $0 + Int(ink.at($1, y)) } >= Int(0.85 * Double(x1 - x0))
            }
            guard let f = full.first, let l = full.last else { return r }
            return CGRect(x: r.minX, y: CGFloat(f), width: r.width, height: CGFloat(l - f + 1))
        }.map { Segment(rect: $0, tone: darkTone(up, ink: ink, rect: $0, percentile: 0.3)) }
    }

    private func darkTone(_ g: GrayBitmap, ink: InkMask, rect: CGRect, percentile: Double = 0.1) -> UInt8 {
        let rr = rect.integral.intersection(CGRect(x: 0, y: 0, width: g.width, height: g.height))
        guard !rr.isNull, rr.width > 0, rr.height > 0 else { return 60 }
        var vals: [UInt8] = []
        for y in Int(rr.minY)..<Int(rr.maxY) {
            for x in Int(rr.minX)..<Int(rr.maxX) where ink.at(x, y) != 0 { vals.append(g.pixels[y * g.width + x]) }
        }
        guard !vals.isEmpty else { return 60 }
        vals.sort()
        return vals[min(vals.count - 1, Int(Double(vals.count) * percentile))]
    }

    /// Тона заливок: медианы фона по плиткам -> кластеры тонов -> каждому пикселю ближайший
    /// кластер по размытой оценке -> сглаживание карты классов.
    func backgroundTonesPublic(_ g: GrayBitmap, ink: InkMask) -> [UInt8] { backgroundTones(g, ink: ink) }

    /// ×2 моделью Core ML для страницы (если модель установлена).
    func upscaleForPage(_ image: CGImage) -> GrayBitmap? { upscale(image) }

    private func backgroundTones(_ g: GrayBitmap, ink: InkMask) -> [UInt8] {
        let W = g.width, H = g.height, T = 24
        let near = ink.dilated(radius: 3)
        // 1. оценка фона без краски
        var noInk = g.pixels
        let tw = (W + T - 1) / T, th = (H + T - 1) / T
        var tiles = [Double](repeating: 255, count: tw * th)
        for ty in 0..<th {
            for tx in 0..<tw {
                var vals: [UInt8] = []
                for y in (ty * T)..<min(H, ty * T + T) {
                    for x in (tx * T)..<min(W, tx * T + T) where near.bits[y * W + x] == 0 { vals.append(g.pixels[y * W + x]) }
                }
                if !vals.isEmpty { vals.sort(); tiles[ty * tw + tx] = Double(vals[vals.count / 2]) }
            }
        }
        // плитки целиком под краской (текст, иконки) не знают фона: берём от соседних, иначе — белые пятна
        var known = [Bool](repeating: false, count: tw * th)
        for ty in 0..<th {
            for tx in 0..<tw {
                var any = false
                for y in (ty * T)..<min(H, ty * T + T) where !any {
                    for x in (tx * T)..<min(W, tx * T + T) where near.bits[y * W + x] == 0 { any = true; break }
                }
                known[ty * tw + tx] = any
            }
        }
        var unknown = known.contains(false) && known.contains(true)
        while unknown {
            unknown = false
            var next = tiles, nextKnown = known
            for ty in 0..<th {
                for tx in 0..<tw where !known[ty * tw + tx] {
                    var acc = 0.0, n = 0.0
                    for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                        let x = tx + dx, y = ty + dy
                        if x >= 0, y >= 0, x < tw, y < th, known[y * tw + x] { acc += tiles[y * tw + x]; n += 1 }
                    }
                    if n > 0 { next[ty * tw + tx] = acc / n; nextKnown[ty * tw + tx] = true } else { unknown = true }
                }
            }
            tiles = next; known = nextKnown
        }
        for i in 0..<(W * H) where near.bits[i] != 0 { noInk[i] = UInt8(tiles[(i / W / T) * tw + (i % W) / T]) }
        // 2. кластеры тонов по плиткам
        var clusters: [Double] = []
        for t in tiles.sorted() {
            if let last = clusters.last, abs(t - last) < 7 { continue }
            clusters.append(t)
        }
        clusters = clusters.map { $0 > 236 ? 255 : (($0 / 4).rounded() * 4) }
        // 3. размытая оценка -> ближайший кластер
        let soft = boxBlur(noInk, W, H, radius: 12)
        var cls = [UInt8](repeating: 0, count: W * H)
        for i in 0..<(W * H) {
            var best = 0, bd = Double.infinity
            for (k, c) in clusters.enumerated() where abs(soft[i] - c) < bd { bd = abs(soft[i] - c); best = k }
            cls[i] = UInt8(best)
        }
        // 4. сглаживание: большинство в окне (через размытие индикаторов)
        var bestScore = [Double](repeating: -1, count: W * H)
        var out = [UInt8](repeating: 255, count: W * H)
        for (k, c) in clusters.enumerated() {
            let ind = boxBlur(cls.map { $0 == UInt8(k) ? 255 : 0 }, W, H, radius: 8)
            for i in 0..<(W * H) where ind[i] > bestScore[i] { bestScore[i] = ind[i]; out[i] = UInt8(c) }
        }
        return out
    }

    private func boxBlur(_ px: [UInt8], _ W: Int, _ H: Int, radius r: Int) -> [Double] {
        var tmp = [Double](repeating: 0, count: W * H)
        for y in 0..<H {
            var acc = 0.0, cnt = 0.0
            for x in 0..<min(W, r + 1) { acc += Double(px[y * W + x]); cnt += 1 }
            for x in 0..<W {
                tmp[y * W + x] = acc / cnt
                if x + r + 1 < W { acc += Double(px[y * W + x + r + 1]); cnt += 1 }
                if x - r >= 0 { acc -= Double(px[y * W + x - r]); cnt -= 1 }
            }
        }
        var out = [Double](repeating: 0, count: W * H)
        for x in 0..<W {
            var acc = 0.0, cnt = 0.0
            for y in 0..<min(H, r + 1) { acc += tmp[y * W + x]; cnt += 1 }
            for y in 0..<H {
                out[y * W + x] = acc / cnt
                if y + r + 1 < H { acc += tmp[(y + r + 1) * W + x]; cnt += 1 }
                if y - r >= 0 { acc -= tmp[(y - r) * W + x]; cnt -= 1 }
            }
        }
        return out
    }
}

extension InkMask {
    mutating func fill(_ rect: CGRect) {
        let r = rect.integral.intersection(bounds)
        guard !r.isNull, r.width > 0, r.height > 0 else { return }
        for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX) { bits[y * width + x] = 1 } }
    }
}

// MARK: - улучшение целой страницы-скана

extension FigureEnhancer {
    /// Скан страницы для показа «оригиналом»: уровни (бумага → белая), ровный фон по тонам,
    /// чёткие прямые линии (таблицы, рамки, линейки). Пиксели текста не трогаем — он не «плывёт».
    /// Тяжёлый расчёт фона — на копии ×1/4. Super-resolution (модель на ANE) — только для небольших страниц.
    func enhancePage(_ source: GrayBitmap, token: CancelToken? = nil) -> CGImage? {
        var gray = source
        if Self.superResolution != nil, source.width * source.height <= 2_500_000,
           let img = source.leveledImage(rect: CGRect(x: 0, y: 0, width: source.width, height: source.height), black: 0, white: 255),
           let up = upscaleForPage(img) {
            gray = up
        }
        guard token?.isCancelled != true else { return nil }
        let W = gray.width, H = gray.height
        guard W > 0, H > 0 else { return nil }
        // 1. уровни по гистограмме страницы: бумага (90-й перцентиль) → белая, краска (1-й) → чёрная.
        //    Жёсткие пороги съедали светло-серый текст и серые заливки.
        var hist = [Int](repeating: 0, count: 256)
        for p in gray.pixels { hist[Int(p)] += 1 }
        func percentile(_ q: Double) -> Int {
            let target = Int(Double(gray.pixels.count) * q)
            var acc = 0
            for (v, n) in hist.enumerated() { acc += n; if acc >= target { return v } }
            return 255
        }
        let paper = Double(percentile(0.90)), inkLevel = Double(percentile(0.01))
        let black = inkLevel, white = max(black + 60, paper - 2)
        let lv = gray.pixels.map { UInt8(max(0, min(255, (Double($0) - black) * 255 / (white - black)))) }
        let leveled = GrayBitmap(width: W, height: H, pixels: lv)
        // страница-фотография: только уровни, без «линий» и заливок
        if Self.isPhotographic(leveled) { return GrayBitmap.makeImage(width: W, height: H, pixels: lv) }
        guard token?.isCancelled != true else { return nil }

        // 2. фон: тона по копии ×1/4 (без неё — сотни мегабайт на страницу)
        let f = 4, sw = max(1, W / f), sh = max(1, H / f)
        var small = [UInt8](repeating: 255, count: sw * sh)
        for y in 0..<sh {
            for x in 0..<sw {
                var acc = 0, n = 0
                for dy in 0..<f where y * f + dy < H {
                    let row = (y * f + dy) * W
                    for dx in 0..<f where x * f + dx < W { acc += Int(lv[row + x * f + dx]); n += 1 }
                }
                small[y * sw + x] = UInt8(acc / max(1, n))
            }
        }
        let smallBitmap = GrayBitmap(width: sw, height: sh, pixels: small)
        let smallInk = InkMask(smallBitmap, threshold: smallBitmap.otsuThreshold())
        let bgSmall = backgroundTonesPublic(smallBitmap, ink: smallInk)
        @inline(__always) func bg(_ x: Int, _ y: Int) -> UInt8 { bgSmall[min(sh - 1, y / f) * sw + min(sw - 1, x / f)] }
        guard token?.isCancelled != true else { return nil }

        // 3. краска — всё, что заметно темнее своего фона (светлый текст тоже); линии — по маске «темнее на 40»
        var inkBits = [UInt8](repeating: 0, count: W * H)
        var lineBits = [UInt8](repeating: 0, count: W * H)
        for y in 0..<H {
            for x in 0..<W {
                let i = y * W + x, d = Int(bg(x, y)) - Int(lv[i])
                if d > 14 { inkBits[i] = 1 }
                if d > 40 { lineBits[i] = 1 }
            }
        }
        let ink = InkMask(width: W, height: H, bits: inkBits)
        let segments = detectPageLines(InkMask(width: W, height: H, bits: lineBits), gray: leveled)
        guard token?.isCancelled != true else { return nil }

        // 4. сборка: краска как есть, остальное — ровный тон фона; линии — заново, ровными, своим тоном
        let keep = ink.dilated(radius: 1)
        var out = [UInt8](repeating: 255, count: W * H)
        for y in 0..<H {
            for x in 0..<W {
                let i = y * W + x
                out[i] = keep.bits[i] != 0 ? lv[i] : bg(x, y)
            }
        }
        for seg in segments {
            let r = seg.rect.integral.intersection(CGRect(x: 0, y: 0, width: W, height: H))
            guard !r.isNull, r.width > 0, r.height > 0 else { continue }
            for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX) { out[y * W + x] = seg.tone } }
        }
        return GrayBitmap.makeImage(width: W, height: H, pixels: out)
    }

    /// Прямые линии на странице: длинные (≥ 1/12 ширины) и тонкие; буквы текста так длинно не тянутся.
    private func detectPageLines(_ ink: InkMask, gray: GrayBitmap) -> [Segment] {
        let minH = max(80, ink.width / 12), minV = max(80, ink.height / 14)
        var out: [Segment] = []
        // горизонтальные: серии в строке, склеенные по соседним строкам
        var open: [CGRect] = []
        for y in 0..<ink.height {
            var runs: [CGRect] = []
            var start = -1, last = -1
            // разрывы до 4 px (пыль, зерно бумаги) линию не рвут
            for x in 0...ink.width {
                let on = x < ink.width && ink.at(x, y) != 0
                if on { if start < 0 { start = x }; last = x; continue }
                if start >= 0, x - last > 4 || x == ink.width {
                    if last + 1 - start >= minH { runs.append(CGRect(x: start, y: y, width: last + 1 - start, height: 1)) }
                    start = -1
                }
            }
            var next: [CGRect] = []
            for r in runs {
                if let i = open.firstIndex(where: { $0.maxY == CGFloat(y) && abs($0.minX - r.minX) < 6 && abs($0.maxX - r.maxX) < 6 }) {
                    next.append(open[i].union(r)); open.remove(at: i)
                } else { next.append(r) }
            }
            out += open.filter { $0.height <= 6 }.map { Segment(rect: $0, tone: tone(gray, $0)) }
            open = next
        }
        out += open.filter { $0.height <= 6 }.map { Segment(rect: $0, tone: tone(gray, $0)) }
        // вертикальные
        open = []
        for x in 0..<ink.width {
            var runs: [CGRect] = []
            var start = -1, last = -1
            for y in 0...ink.height {
                let on = y < ink.height && ink.at(x, y) != 0
                if on { if start < 0 { start = y }; last = y; continue }
                if start >= 0, y - last > 4 || y == ink.height {
                    if last + 1 - start >= minV { runs.append(CGRect(x: x, y: start, width: 1, height: last + 1 - start)) }
                    start = -1
                }
            }
            var next: [CGRect] = []
            for r in runs {
                if let i = open.firstIndex(where: { $0.maxX == CGFloat(x) && abs($0.minY - r.minY) < 6 && abs($0.maxY - r.maxY) < 6 }) {
                    next.append(open[i].union(r)); open.remove(at: i)
                } else { next.append(r) }
            }
            out += open.filter { $0.width <= 6 }.map { Segment(rect: $0, tone: tone(gray, $0)) }
            open = next
        }
        out += open.filter { $0.width <= 6 }.map { Segment(rect: $0, tone: tone(gray, $0)) }
        return out
    }

    /// Тон линии: медиана пикселей на ней (тонкие серые рамки остаются серыми, а не чёрными).
    private func tone(_ g: GrayBitmap, _ r: CGRect) -> UInt8 {
        var vals: [UInt8] = []
        let x0 = max(0, Int(r.minX)), x1 = min(g.width, Int(r.maxX)), y0 = max(0, Int(r.minY)), y1 = min(g.height, Int(r.maxY))
        guard x1 > x0, y1 > y0 else { return 60 }
        for y in y0..<y1 { for x in stride(from: x0, to: x1, by: max(1, (x1 - x0) / 200)) { vals.append(g.pixels[y * g.width + x]) } }
        vals.sort()
        return vals[vals.count / 2]
    }
}
