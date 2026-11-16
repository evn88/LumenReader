// Иконка Lumen Reader (macOS 26+, формат Icon Composer): раскрытая книга и тёплое свечение от неё.
// Генерирует слои в Resources/AppIcon.icon/Assets — исходник, который можно дальше править в Icon Composer:
//   book.svg — страницы и обрез книги (слой Liquid Glass)
//   glow.png — янтарный ореол за книгой (без стекла)
// Фон (тёплая темнота) и материалы задаются в Resources/AppIcon.icon/icon.json.
// Флаг --flat <out.png> дополнительно рисует плоскую 1024-картинку (превью для README/сайта).
// Цвета — те же, что Brand.amber в приложении. SF Symbols в иконке не используются (запрещено лицензией).
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 && CommandLine.arguments[1] != "--flat"
               ? CommandLine.arguments[1] : "Resources/AppIcon.icon")
let assets = root.appendingPathComponent("Assets")
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

let S = 1024
let amber = (r: 0.949, g: 0.639, b: 0.227)

// ── книга: две страницы, расходящиеся от корешка, под ними обрез (толщина блока) ──
// Координаты SVG: y вниз, холст 1024×1024, книга чуть ниже центра — свет поднимается над ней.
func page(_ dx: Double, _ dy: Double, mirror: Bool) -> String {
    // левая страница: верх изгибается от корешка к внешнему краю, низ провисает к корешку
    let pts: [(Double, Double)] = [(498, 436), (452, 398), (338, 376), (226, 402),   // верх
                                   (226, 676),                                        // внешний край
                                   (338, 650), (452, 668), (498, 706)]               // низ
    let p = pts.map { (mirror ? 1024 - $0.0 - dx : $0.0 + dx, $0.1 + dy) }
    func f(_ v: (Double, Double)) -> String { String(format: "%.0f,%.0f", v.0, v.1) }
    return "M\(f(p[0])) C\(f(p[1])) \(f(p[2])) \(f(p[3])) L\(f(p[4])) C\(f(p[5])) \(f(p[6])) \(f(p[7])) Z"
}
let edge = "#E8A04A", paper = "#FFF5E3"
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" width="\(S)" height="\(S)" viewBox="0 0 \(S) \(S)">
<g transform="translate(512 545) scale(1.22) translate(-512 -545)">
  <path fill="\(edge)" d="\(page(-14, 26, mirror: false))"/>
  <path fill="\(edge)" d="\(page(-14, 26, mirror: true))"/>
  <path fill="\(paper)" d="\(page(0, 0, mirror: false))"/>
  <path fill="\(paper)" d="\(page(0, 0, mirror: true))"/>
</g>
</svg>

"""
try svg.write(to: assets.appendingPathComponent("book.svg"), atomically: true, encoding: .utf8)

// ── свечение: мягкий янтарный ореол, сильнее всего у корешка, растекается вверх и в стороны ──
func bitmap(_ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: S, pixelsHigh: S, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
func drawGlow(_ c: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    func color(_ a: Double) -> CGColor { CGColor(colorSpace: space, components: [amber.r, amber.g, amber.b, a])! }
    let g = CGGradient(colorsSpace: space, colors: [color(1.0), color(0.65), color(0.22), color(0)] as CFArray,
                       locations: [0, 0.3, 0.65, 1])!
    // CG: y вверх. Центр у корешка над книгой, ореол вытянут вверх (свет «поднимается» со страниц)
    c.saveGState()
    c.translateBy(x: 512, y: 1024 - 520)
    c.scaleBy(x: 1.15, y: 1.0)
    c.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 470, options: [])
    c.restoreGState()
}
let glow = bitmap(drawGlow)
try glow.representation(using: .png, properties: [:])!.write(to: assets.appendingPathComponent("glow.png"))

// ── плоское превью (без Liquid Glass) ──
if let i = CommandLine.arguments.firstIndex(of: "--flat"), i + 1 < CommandLine.arguments.count {
    let book = NSImage(data: svg.data(using: .utf8)!)!
    let flat = bitmap { c in
        let r = CGRect(x: 0, y: 0, width: S, height: S)
        let bg = CGPath(roundedRect: r.insetBy(dx: 100, dy: 100), cornerWidth: 185, cornerHeight: 185, transform: nil)
        c.addPath(bg); c.clip()
        let sp = CGColorSpace(name: CGColorSpace.sRGB)!
        let bgG = CGGradient(colorsSpace: sp, colors: [CGColor(colorSpace: sp, components: [0.20, 0.16, 0.12, 1])!,
                                                        CGColor(colorSpace: sp, components: [0.08, 0.065, 0.05, 1])!] as CFArray,
                             locations: [0, 1])!
        c.drawLinearGradient(bgG, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
        // слои .icon занимают весь холст фигуры; у плоской иконки фигура — 824 pt по сетке macOS
        c.translateBy(x: 100, y: 100)
        c.scaleBy(x: 824.0 / 1024, y: 824.0 / 1024)
        drawGlow(c)
        NSGraphicsContext.current!.imageInterpolation = .high
        book.draw(in: NSRect(x: 0, y: 0, width: S, height: S), from: .zero, operation: .sourceOver, fraction: 1)
    }
    try flat.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
}
