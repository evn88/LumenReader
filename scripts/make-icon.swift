// Иконка Lumen Reader (macOS 26+, формат Icon Composer): книга в тёплом янтарном свечении.
// Рисунок прежний (книга book.pages.fill и круг света), лампа убрана, книга встала по центру.
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
func drawBook() {
    let cfg = NSImage.SymbolConfiguration(pointSize: 340 * k, weight: .regular).applying(.init(paletteColors: [paper]))
    guard let s = NSImage(systemSymbolName: "book.pages.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
    s.draw(in: NSRect(x: center.x - s.size.width / 2, y: center.y - s.size.height / 2, width: s.size.width, height: s.size.height))
}

try save(bitmap(drawGlow), assets.appendingPathComponent("glow.png"))
try save(bitmap(drawBook), assets.appendingPathComponent("book.png"))

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
        drawBook()
    }
    try save(flat, URL(fileURLWithPath: args[i + 1]))
}
