// Иконка Lumen Reader (macOS 26+, формат Icon Composer): книга в тёплом янтарном свечении.
// Книга по мотивам прежней (страница со строками и лист за ней), но своя: SF Symbols в иконках запрещены лицензией.
// Генерирует слои в Resources/AppIcon.icon/Assets — исходник, который можно дальше править в Icon Composer:
//   book.png — книга (слой Liquid Glass)
//   glow.png — янтарный круг света за книгой (без стекла)
// Фон (тёплая темнота) и материалы задаются в Resources/AppIcon.icon/icon.json.
// Флаг --flat <out.png> дополнительно рисует плоскую 1024-картинку (превью для README/сайта).
// Цвета — те же, что Brand.amber в приложении.
import AppKit

let args = CommandLine.arguments
let root = URL(fileURLWithPath: args.count > 1 && args[1] != "--flat" ? args[1] : "Resources/AppIcon.icon")
let assets = root.appendingPathComponent("Assets")
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

let S: CGFloat = 1024
// Слои .icon занимают весь холст фигуры; прежний рисунок жил в фигуре 824 pt — переводим масштаб.
let k: CGFloat = 1024 / 824
let center = NSPoint(x: S / 2, y: S / 2)
let amber = NSColor(red: 0.949, green: 0.639, blue: 0.227, alpha: 1)
let paper = NSColor(red: 1, green: 0.96, blue: 0.88, alpha: 1)

func bitmap(_ draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
func save(_ rep: NSBitmapImageRep, _ url: URL) throws {
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

func drawGlow() {
    NSGradient(colors: [amber.withAlphaComponent(0.85), amber.withAlphaComponent(0.25), amber.withAlphaComponent(0)])!
        .draw(fromCenter: center, radius: 0, toCenter: center, radius: 380 * k, options: [])
}
// Книга своя (не SF Symbols — их нельзя ставить в иконки): передняя страница со строками,
// за ней со сдвигом вправо-вниз второй лист; строки и зазор между листами вырезаны — сквозь них видно свечение.
func pagePath(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGPath {
    // y вниз; верх чуть поднимается вправо, низ справа загибается вверх
    let tilt: CGFloat = 30
    let tl = CGPoint(x: x, y: y + tilt), tr = CGPoint(x: x + w, y: y)
    let br = CGPoint(x: x + w, y: y + h - tilt), bl = CGPoint(x: x, y: y + h)
    let p = CGMutablePath()
    p.move(to: CGPoint(x: x, y: y + h / 2))
    p.addArc(tangent1End: tl, tangent2End: tr, radius: 40)
    p.addArc(tangent1End: tr, tangent2End: br, radius: 40)
    p.addArc(tangent1End: br, tangent2End: bl, radius: 70)
    p.addArc(tangent1End: bl, tangent2End: tl, radius: 40)
    p.closeSubpath()
    return p
}
func drawBook() {
    let c = NSGraphicsContext.current!.cgContext
    c.saveGState()
    c.translateBy(x: 0, y: S); c.scaleBy(x: 1, y: -1)              // дальше y вниз
    let w: CGFloat = 300, h: CGFloat = 500
    let x = S / 2 - (w + 44) / 2, y = S / 2 - (h + 24) / 2
    let front = pagePath(x, y, w, h), back = pagePath(x + 44, y + 24, w, h)
    c.setFillColor(paper.blended(withFraction: 0.08, of: amber)!.cgColor)
    c.addPath(back); c.fillPath()
    c.setBlendMode(.clear)                                           // зазор между листами
    c.addPath(front); c.setLineWidth(30); c.strokePath()
    c.setBlendMode(.normal)
    c.setFillColor(paper.cgColor)
    c.addPath(front); c.fillPath()
    c.setBlendMode(.clear)                                           // строки
    c.setLineCap(.round); c.setLineWidth(26)
    for (i, len) in [1.0, 1.0, 1.0, 0.55].enumerated() {
        let ly = y + 112 + CGFloat(i) * 74
        let x0 = x + 52, x1 = x0 + (w - 104) * CGFloat(len)
        let rise = (x1 - x0) / w * 30                                 // строки идут вдоль наклона верха
        c.move(to: CGPoint(x: x0, y: ly + 8)); c.addQuadCurve(to: CGPoint(x: x1, y: ly + 8 - rise),
                                                              control: CGPoint(x: (x0 + x1) / 2, y: ly + 2 - rise / 2))
        c.strokePath()
    }
    c.restoreGState()
}

try save(bitmap(drawGlow), assets.appendingPathComponent("glow.png"))
let book = bitmap(drawBook)
try save(book, assets.appendingPathComponent("book.png"))

// ── плоское превью (без Liquid Glass) ──
if let i = args.firstIndex(of: "--flat"), i + 1 < args.count {
    let flat = bitmap {
        let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
        let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
        NSGradient(starting: NSColor(red: 0.20, green: 0.16, blue: 0.12, alpha: 1),
                   ending: NSColor(red: 0.08, green: 0.065, blue: 0.05, alpha: 1))!.draw(in: bg, angle: -90)
        bg.addClip()
        let c = NSGraphicsContext.current!.cgContext
        c.translateBy(x: 100, y: 100)
        c.scaleBy(x: 1 / k, y: 1 / k)
        drawGlow()
        book.draw(in: NSRect(x: 0, y: 0, width: S, height: S), from: .zero, operation: .sourceOver,
                  fraction: 1, respectFlipped: false, hints: nil)   // слоем: вырезы в книге не должны пробивать фон
    }
    try save(flat, URL(fileURLWithPath: args[i + 1]))
}
