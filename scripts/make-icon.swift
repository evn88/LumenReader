// Иконка ScanReader: книга на тёплом фоне в форме скруглённого квадрата macOS. Вывод — PNG 1024×1024.
import AppKit

let out = CommandLine.arguments[1]
let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
let bg = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(red: 0.98, green: 0.62, blue: 0.22, alpha: 1),
           ending: NSColor(red: 0.93, green: 0.40, blue: 0.13, alpha: 1))!.draw(in: bg, angle: -90)
let cfg = NSImage.SymbolConfiguration(pointSize: 470, weight: .regular)
    .applying(.init(paletteColors: [.white]))
if let sym = NSImage(systemSymbolName: "book.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let sz = sym.size
    sym.draw(in: NSRect(x: (S - sz.width) / 2, y: (S - sz.height) / 2 - 10, width: sz.width, height: sz.height))
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
