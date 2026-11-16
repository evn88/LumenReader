// Иконка Lumen Reader: тёплый свет лампы над раскрытой книгой (янтарь на тёплой темноте).
// Выход — PNG 1024×1024. Цвета — те же, что Brand.amber в приложении.
import AppKit

let out = CommandLine.arguments[1]
let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(red: 0.20, green: 0.16, blue: 0.12, alpha: 1),
           ending: NSColor(red: 0.08, green: 0.065, blue: 0.05, alpha: 1))!.draw(in: bg, angle: -90)
bg.addClip()
// круг света
let amber = NSColor(red: 0.949, green: 0.639, blue: 0.227, alpha: 1)
NSGradient(colors: [amber.withAlphaComponent(0.85), amber.withAlphaComponent(0.25), amber.withAlphaComponent(0)])!
    .draw(fromCenter: NSPoint(x: S / 2, y: S * 0.43), radius: 0, toCenter: NSPoint(x: S / 2, y: S * 0.43), radius: 380, options: [])
func symbol(_ name: String, _ size: CGFloat, _ color: NSColor, _ center: NSPoint) {
    let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .regular).applying(.init(paletteColors: [color]))
    guard let s = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
    s.draw(in: NSRect(x: center.x - s.size.width / 2, y: center.y - s.size.height / 2, width: s.size.width, height: s.size.height))
}
symbol("book.pages.fill", 340, NSColor(red: 1, green: 0.96, blue: 0.88, alpha: 1), NSPoint(x: S / 2, y: S * 0.38))
symbol("lightbulb.max.fill", 190, amber, NSPoint(x: S / 2, y: S * 0.70))
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
