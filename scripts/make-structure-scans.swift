// Синтетические «сканы» страниц со структурой (свой текст, без чужих книг) — для проверки разбора:
//   toc.png      — оглавление: два уровня, точки-заполнители, номера страниц по правому краю
//   table.png    — таблица без линеек (колонки по выравниванию) и таблица в сетке линеек
//   columns.png  — две колонки текста под общим заголовком
//   swiftc -O scripts/make-structure-scans.swift -o /tmp/mss && /tmp/mss demo/structure
import AppKit
import CoreImage

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "demo/structure"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let W: CGFloat = 1240, H: CGFloat = 1754
let ink = NSColor(white: 0.08, alpha: 1)
func font(_ name: String, _ size: CGFloat) -> NSFont { NSFont(name: name, size: size) ?? .systemFont(ofSize: size) }
let L: CGFloat = 130, R: CGFloat = W - 130

func page(_ name: String, _ body: (CGContext) -> Void) {
    let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)
    body(ctx)
    NSGraphicsContext.current = nil
    // «сканирование»: размытие, зерно, желтоватая бумага
    let clean = CIImage(cgImage: ctx.makeImage()!)
    let grain = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: clean.extent)
        .applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.04, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0.04, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0.04, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0.92, y: 0.91, z: 0.86, w: 1)])
    let scanned = clean.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.7]).cropped(to: clean.extent)
        .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: grain])
    let cg = CIContext().createCGImage(scanned, from: clean.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())!
    let path = "\(outDir)/\(name).png"
    try! NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("Готово:", path)
}

func draw(_ s: String, at p: CGPoint, _ f: NSFont, color: NSColor = ink) {
    (s as NSString).draw(at: p, withAttributes: [.font: f, .foregroundColor: color])
}
func width(_ s: String, _ f: NSFont) -> CGFloat { (s as NSString).size(withAttributes: [.font: f]).width }
func text(_ s: String, _ r: CGRect, _ f: NSFont, align: NSTextAlignment = .justified) {
    let p = NSMutableParagraphStyle(); p.alignment = align; p.lineSpacing = f.pointSize * 0.28; p.hyphenationFactor = 0.8
    (s as NSString).draw(with: r, options: [.usesLineFragmentOrigin], attributes: [.font: f, .foregroundColor: ink, .paragraphStyle: p])
}

// MARK: оглавление
page("toc") { _ in
    draw("Оглавление", at: CGPoint(x: L, y: 150), font("Times New Roman Bold", 44))
    let entries: [(Int, String, String)] = [
        (0, "Предисловие", "7"),
        (0, "Глава 1. Как устроена бумажная книга", "11"),
        (1, "1.1. Формат листа и поля", "12"),
        (1, "1.2. Шрифт, кегль и интерлиньяж", "18"),
        (1, "1.3. Колонтитулы и сноски", "25"),
        (0, "Глава 2. Сканирование и распознавание", "31"),
        (1, "2.1. Разрешение и цветность", "33"),
        (1, "2.2. Чем ошибается распознавание", "40"),
        (1, "2.3. Таблицы, формулы и схемы", "47"),
        (0, "Глава 3. Вёрстка заново", "55"),
        (1, "3.1. Подбор гарнитуры", "56"),
        (1, "3.2. Оглавления и указатели", "63"),
        (0, "Заключение", "71"),
        (0, "Предметный указатель", "74"),
    ]
    var y: CGFloat = 260
    for (level, title, num) in entries {
        let f = level == 0 ? font("Times New Roman Bold", 28) : font("Times New Roman", 28)
        let x = L + CGFloat(level) * 50
        draw(title, at: CGPoint(x: x, y: y), f)
        let nf = font("Times New Roman", 28)
        let nw = width(num, nf)
        draw(num, at: CGPoint(x: R - nw, y: y), nf)
        // точки-заполнители между названием и номером
        let dot = font("Times New Roman", 28)
        var dx = x + width(title, f) + 14
        while dx < R - nw - 18 { draw(".", at: CGPoint(x: dx, y: y), dot); dx += 14 }
        y += level == 0 ? 74 : 56
        if level == 0 { y += 6 }
    }
}

// MARK: таблицы
page("table") { ctx in
    let serif = font("Times New Roman", 28)
    text("Таблица 2.1 показывает, сколько ошибок распознавания приходится на тысячу знаков при разном разрешении скана. Разница между 300 и 600 точками на дюйм заметна только для мелкого кегля.",
         CGRect(x: L, y: 120, width: R - L, height: 160), serif)
    draw("Таблица 2.1. Ошибки на 1000 знаков", at: CGPoint(x: L, y: 300), font("Times New Roman Bold", 26))
    // без линеек: колонки по выравниванию
    let cols: [CGFloat] = [L, L + 360, L + 560, L + 780]
    let head = ["Разрешение", "Кегль 8", "Кегль 10", "Кегль 12"]
    let rows = [["150 dpi", "41,2", "18,5", "9,1"], ["200 dpi", "17,8", "6,3", "3,4"],
                ["300 dpi", "4,9", "1,7", "0,9"], ["600 dpi", "3,1", "1,2", "0,8"]]
    let hf = font("Helvetica-Bold", 24), cf = font("Helvetica", 24)
    for (c, h) in head.enumerated() { draw(h, at: CGPoint(x: cols[c], y: 360), hf) }
    for (r, row) in rows.enumerated() {
        for (c, v) in row.enumerated() {
            // числа — по правому краю колонки
            let x = c == 0 ? cols[c] : cols[c] + width(head[c], hf) - width(v, cf)
            draw(v, at: CGPoint(x: x, y: 410 + CGFloat(r) * 46), cf)
        }
    }
    text("Вторая таблица — в сетке линеек, как в справочниках. Ячейки в ней могут занимать несколько строк.",
         CGRect(x: L, y: 640, width: R - L, height: 100), serif)
    draw("Таблица 2.2. Языки распознавания", at: CGPoint(x: L, y: 760), font("Times New Roman Bold", 26))
    // в сетке
    let gx: [CGFloat] = [L, L + 250, L + 620, R]
    let gy: [CGFloat] = [820, 880, 980, 1040, 1140, 1200]
    ctx.setFillColor(ink.cgColor)
    for x in gx { ctx.fill(CGRect(x: x - 1, y: gy.first!, width: 2.5, height: gy.last! - gy.first!)) }
    for y in gy { ctx.fill(CGRect(x: gx.first!, y: y - 1, width: gx.last! - gx.first!, height: 2.5)) }
    let grid = [["Язык", "Письменность", "Особенности"],
                ["Русский", "Кириллица", "ё и е, мягкий знак\nпутается с «ь»"],
                ["Английский", "Латиница", "лигатуры fi, fl"],
                ["Сербский", "Кириллица и латиница", "оба алфавита\nв одной книге"],
                ["Немецкий", "Латиница", "ß и умлауты"]]
    for (r, row) in grid.enumerated() {
        for (c, v) in row.enumerated() {
            let f = r == 0 ? hf : cf
            for (k, part) in v.split(separator: "\n").enumerated() {
                draw(String(part), at: CGPoint(x: gx[c] + 16, y: gy[r] + 14 + CGFloat(k) * 36), f)
            }
        }
    }
    text("Если сетка не распознаётся надёжно, читалка показывает таблицу фрагментом скана.",
         CGRect(x: L, y: 1240, width: R - L, height: 100), serif)
}

// MARK: две колонки
page("columns") { ctx in
    draw("Две колонки", at: CGPoint(x: L, y: 130), font("Times New Roman Bold", 44))
    let serif = font("Times New Roman", 26)
    let gutter: CGFloat = 50, cw = (R - L - gutter) / 2
    let left = """
    В журналах и словарях текст часто набирают в две колонки: строки короче, глазу легче возвращаться к началу следующей строки. \
    Для распознавания это ловушка: если читать страницу просто сверху вниз, строки левой и правой колонок перемешаются. \
    Поэтому сначала нужно найти просвет между колонками и только потом собирать абзацы. \
    Просвет — это вертикальная полоса без краски, которая проходит через всю высоту текста.
    """
    let right = """
    Правая колонка продолжает мысль левой. Здесь текст читается после того, как закончилась левая колонка, \
    а не вперемешку с ней. При увеличении шрифта обе колонки перекомпонуются в одну: на экране телефона \
    или в узком окне так удобнее. При масштабе сто процентов страница остаётся такой, как в книге, \
    со своими колонками и просветом между ними.
    """
    text(left, CGRect(x: L, y: 230, width: cw, height: 1300), serif)
    text(right, CGRect(x: L + cw + gutter, y: 230, width: cw, height: 1300), serif)
    _ = ctx
}
