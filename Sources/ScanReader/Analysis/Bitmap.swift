import CoreGraphics
import Foundation

/// 8-битное серое изображение (0 = чёрный). Строка 0 — верх страницы.
struct GrayBitmap {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    init?(cgImage: CGImage) {
        let w = cgImage.width, h = cgImage.height
        var px = [UInt8](repeating: 255, count: w * h)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        self.init(width: w, height: h, pixels: px)
    }

    /// Порог Оцу — разделяет краску и бумагу.
    func otsuThreshold() -> UInt8 {
        var hist = [Int](repeating: 0, count: 256)
        for p in pixels { hist[Int(p)] += 1 }
        let total = Double(pixels.count)
        var sum = 0.0
        for i in 0..<256 { sum += Double(i * hist[i]) }
        var sumB = 0.0, wB = 0.0, best = 0.0, threshold = 128
        for t in 0..<256 {
            wB += Double(hist[t])
            if wB == 0 { continue }
            let wF = total - wB
            if wF == 0 { break }
            sumB += Double(t * hist[t])
            let mB = sumB / wB, mF = (sum - sumB) / wF
            let between = wB * wF * (mB - mF) * (mB - mF)
            if between > best { best = between; threshold = t }
        }
        return UInt8(threshold)
    }

    /// Фрагмент с "уровнями": бумага скана -> белая, краска -> чёрная.
    /// Белое потом смешиваем с цветом листа (multiply), и иллюстрация "ложится" на страницу.
    func leveledImage(rect: CGRect, black: UInt8 = 20, white: UInt8 = 228) -> CGImage? {
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard r.width > 0, r.height > 0 else { return nil }
        let x0 = Int(r.minX), y0 = Int(r.minY), w = Int(r.width), h = Int(r.height)
        var out = [UInt8](repeating: 255, count: w * h)
        let scale = 255.0 / Double(max(1, Int(white) - Int(black)))
        for y in 0..<h {
            let src = (y0 + y) * width + x0
            for x in 0..<w {
                let v = (Double(pixels[src + x]) - Double(black)) * scale
                out[y * w + x] = UInt8(max(0, min(255, v)))
            }
        }
        return Self.makeImage(width: w, height: h, pixels: out)
    }

    static func makeImage(width: Int, height: Int, pixels: [UInt8]) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Двоичная маска (1 = краска).
struct InkMask {
    let width: Int
    let height: Int
    var bits: [UInt8]

    init(width: Int, height: Int, bits: [UInt8]) {
        self.width = width
        self.height = height
        self.bits = bits
    }

    init(_ gray: GrayBitmap, threshold: UInt8) {
        self.init(width: gray.width, height: gray.height, bits: gray.pixels.map { $0 < threshold ? 1 : 0 })
    }

    var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    /// Пиксель маски; за пределами — пусто (раньше выход за край был падением).
    @inline(__always) func at(_ x: Int, _ y: Int) -> UInt8 {
        x >= 0 && y >= 0 && x < width && y < height ? bits[y * width + x] : 0
    }

    func clampRect(_ rect: CGRect) -> (Int, Int, Int, Int)? {
        let r = rect.integral.intersection(bounds)
        guard !r.isNull, r.width > 0, r.height > 0 else { return nil }
        return (Int(r.minX), Int(r.minY), Int(r.maxX), Int(r.maxY))
    }

    mutating func clear(_ rect: CGRect) {
        guard let (x0, y0, x1, y1) = clampRect(rect) else { return }
        for y in y0..<y1 { for x in x0..<x1 { bits[y * width + x] = 0 } }
    }

    /// Уменьшение: клетка = 1, если в блоке factor×factor есть краска.
    func downsampled(_ f: Int) -> InkMask {
        let w = (width + f - 1) / f, h = (height + f - 1) / f
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<height {
            let row = y * width, orow = (y / f) * w
            for x in 0..<width where bits[row + x] != 0 { out[orow + x / f] = 1 }
        }
        return InkMask(width: w, height: h, bits: out)
    }

    /// Квадратное расширение радиуса r (разделимое: по строкам, затем по столбцам).
    func dilated(radius r: Int) -> InkMask {
        var tmp = [UInt8](repeating: 0, count: bits.count)
        for y in 0..<height {
            var last = -1_000_000
            for x in 0..<width { if bits[y * width + x] != 0 { last = x }; if x - last <= r { tmp[y * width + x] = 1 } }
            last = 1_000_000
            for x in stride(from: width - 1, through: 0, by: -1) {
                if bits[y * width + x] != 0 { last = x }
                if last - x <= r { tmp[y * width + x] = 1 }
            }
        }
        var out = [UInt8](repeating: 0, count: bits.count)
        for x in 0..<width {
            var last = -1_000_000
            for y in 0..<height { if tmp[y * width + x] != 0 { last = y }; if y - last <= r { out[y * width + x] = 1 } }
            last = 1_000_000
            for y in stride(from: height - 1, through: 0, by: -1) {
                if tmp[y * width + x] != 0 { last = y }
                if last - y <= r { out[y * width + x] = 1 }
            }
        }
        return InkMask(width: width, height: height, bits: out)
    }

    struct Component { var rect: CGRect; var pixelCount: Int }

    /// Связные области (8-связность), union-find в два прохода.
    func components() -> [Component] {
        var labels = [Int32](repeating: 0, count: bits.count)
        var parent: [Int32] = [0]
        func find(_ a: Int32) -> Int32 {
            var a = a
            while parent[Int(a)] != a { parent[Int(a)] = parent[Int(parent[Int(a)])]; a = parent[Int(a)] }
            return a
        }
        func union(_ a: Int32, _ b: Int32) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[Int(max(ra, rb))] = min(ra, rb) }
        }
        for y in 0..<height {
            for x in 0..<width where bits[y * width + x] != 0 {
                // соседи слева и сверху (8-связность), без аллокаций
                var first: Int32 = 0
                @inline(__always) func take(_ l: Int32) {
                    if l == 0 { return }
                    if first == 0 { first = l } else if l != first { union(first, l) }
                }
                if x > 0 { take(labels[y * width + x - 1]) }
                if y > 0 {
                    let up = (y - 1) * width
                    if x > 0 { take(labels[up + x - 1]) }
                    take(labels[up + x])
                    if x + 1 < width { take(labels[up + x + 1]) }
                }
                if first == 0 {
                    first = Int32(parent.count)
                    parent.append(first)
                }
                labels[y * width + x] = first
            }
        }
        var agg: [Int32: (Int, Int, Int, Int, Int)] = [:]
        for y in 0..<height {
            for x in 0..<width {
                let l = labels[y * width + x]
                if l == 0 { continue }
                let r = find(l)
                if var a = agg[r] {
                    a.0 = min(a.0, x); a.1 = min(a.1, y); a.2 = max(a.2, x); a.3 = max(a.3, y); a.4 += 1
                    agg[r] = a
                } else {
                    agg[r] = (x, y, x, y, 1)
                }
            }
        }
        return agg.values.map {
            Component(rect: CGRect(x: $0.0, y: $0.1, width: $0.2 - $0.0 + 1, height: $0.3 - $0.1 + 1), pixelCount: $0.4)
        }
    }

    /// Сумма краски по строкам прямоугольника.
    func rowProfile(_ rect: CGRect) -> [Int] {
        guard let (x0, y0, x1, y1) = clampRect(rect) else { return [] }
        return (y0..<y1).map { y in (x0..<x1).reduce(0) { $0 + Int(bits[y * width + $1]) } }
    }

    /// Сумма краски по столбцам прямоугольника.
    func columnProfile(_ rect: CGRect) -> [Int] {
        guard let (x0, y0, x1, y1) = clampRect(rect) else { return [] }
        return (x0..<x1).map { x in (y0..<y1).reduce(0) { $0 + Int(bits[$1 * width + x]) } }
    }

    /// Плотная рамка вокруг краски внутри rect.
    func inkBounds(in rect: CGRect) -> CGRect? {
        guard let (x0, y0, _, _) = clampRect(rect) else { return nil }
        let rows = rowProfile(rect), cols = columnProfile(rect)
        guard let top = rows.firstIndex(where: { $0 > 0 }), let bottom = rows.lastIndex(where: { $0 > 0 }),
              let left = cols.firstIndex(where: { $0 > 0 }), let right = cols.lastIndex(where: { $0 > 0 }) else { return nil }
        return CGRect(x: x0 + left, y: y0 + top, width: right - left + 1, height: bottom - top + 1)
    }

    func crop(_ rect: CGRect) -> InkMask {
        guard let (x0, y0, x1, y1) = clampRect(rect) else { return InkMask(width: 0, height: 0, bits: []) }
        var out = [UInt8](); out.reserveCapacity((x1 - x0) * (y1 - y0))
        for y in y0..<y1 { out.append(contentsOf: bits[(y * width + x0)..<(y * width + x1)]) }
        return InkMask(width: x1 - x0, height: y1 - y0, bits: out)
    }

    /// Средняя толщина вертикальных штрихов: длины горизонтальных серий краски,
    /// отбрасываем верхние 30% (горизонтальные штрихи, засечки, слипания).
    func meanStemWidth() -> Double {
        var runs: [Int] = []
        for y in 0..<height {
            var run = 0
            for x in 0..<width {
                if bits[y * width + x] != 0 { run += 1 } else if run > 0 { runs.append(run); run = 0 }
            }
            if run > 0 { runs.append(run) }
        }
        guard !runs.isEmpty else { return 0 }
        runs.sort()
        let kept = runs[0..<max(1, Int(Double(runs.count) * 0.7))]
        return Double(kept.reduce(0, +)) / Double(kept.count)
    }

    /// Наклон штрихов (курсив): перебираем сдвиг и ищем самую "резкую" вертикальную проекцию.
    func slant() -> Double {
        guard width > 0, height > 0 else { return 0 }
        var best = 0.0, bestScore = -1.0
        for i in 0...16 {
            let s = -0.05 + 0.025 * Double(i)
            var proj = [Double](repeating: 0, count: width + 2 * height)
            for y in 0..<height {
                // верх строки сдвигаем влево: правильный s "выпрямляет" курсив
                let shift = height - Int((s * Double(height - y)).rounded())
                for x in 0..<width where bits[y * width + x] != 0 {
                    let nx = x + shift
                    if nx >= 0, nx < proj.count { proj[nx] += 1 }
                }
            }
            let score = proj.reduce(0) { $0 + $1 * $1 }
            if score > bestScore { bestScore = score; best = s }
        }
        return best
    }

    func dilated3() -> InkMask { dilated(radius: 1) }

    static func iou(_ a: InkMask, _ b: InkMask) -> Double {
        guard a.width == b.width, a.height == b.height else { return 0 }
        var inter = 0, uni = 0
        for i in 0..<a.bits.count {
            let p = a.bits[i] != 0, q = b.bits[i] != 0
            if p && q { inter += 1 }
            if p || q { uni += 1 }
        }
        return uni == 0 ? 0 : Double(inter) / Double(uni)
    }
}
