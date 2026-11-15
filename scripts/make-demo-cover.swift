import AppKit
let out = CommandLine.arguments[1]
let W: CGFloat = 600, H: CGFloat = 900
let img = NSImage(size: NSSize(width: W, height: H)); img.lockFocus()
NSGradient(starting: NSColor(red: 0.16, green: 0.29, blue: 0.42, alpha: 1), ending: NSColor(red: 0.07, green: 0.13, blue: 0.22, alpha: 1))!.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)
let p = NSMutableParagraphStyle(); p.alignment = .center
("Заметки\nо чтении" as NSString).draw(in: NSRect(x: 40, y: 380, width: W - 80, height: 260), withAttributes: [.font: NSFont(name: "Iowan Old Style Bold", size: 76) ?? NSFont.boldSystemFont(ofSize: 76), .foregroundColor: NSColor.white, .paragraphStyle: p])
("Демо-автор" as NSString).draw(in: NSRect(x: 40, y: 120, width: W - 80, height: 60), withAttributes: [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor(white: 1, alpha: 0.75), .paragraphStyle: p])
img.unlockFocus()
try! NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
