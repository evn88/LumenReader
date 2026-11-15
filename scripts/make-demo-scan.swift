// Синтетический «скан» книжной страницы для демо и тестов (свой текст, без чужих книг):
// колонтитул с линейкой, заголовок, абзацы по ширине с переносом, иллюстрация-таблица, подпись.
// Затем «сканирование»: желтоватая бумага, шум, лёгкое размытие.
//   swiftc -O scripts/make-demo-scan.swift -o /tmp/mds && /tmp/mds demo/synthetic-page.png
import AppKit
import CoreImage

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "demo/synthetic-page.png"
let W: CGFloat = 1240, H: CGFloat = 1754
let ctx = CGContext(data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
NSGraphicsContext.current = ns
ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)

let ink = NSColor(white: 0.08, alpha: 1)
func font(_ name: String, _ size: CGFloat) -> NSFont { NSFont(name: name, size: size) ?? .systemFont(ofSize: size) }
func draw(_ s: String, _ r: CGRect, _ f: NSFont, align: NSTextAlignment = .natural, color: NSColor = ink, hyphen: Float = 0) {
    let p = NSMutableParagraphStyle(); p.alignment = align; p.lineSpacing = f.pointSize * 0.28; p.hyphenationFactor = hyphen
    (s as NSString).draw(with: r, options: [.usesLineFragmentOrigin], attributes: [.font: f, .foregroundColor: color, .paragraphStyle: p])
}
let L: CGFloat = 130, R: CGFloat = W - 130
// колонтитул
draw("52", CGRect(x: L, y: 70, width: 60, height: 40), font("Helvetica", 22))
draw("Глава 2", CGRect(x: L + 70, y: 70, width: 400, height: 40), font("Helvetica-Oblique", 22))
ctx.setFillColor(ink.cgColor); ctx.fill(CGRect(x: L, y: 112, width: R - L, height: 3))
// заголовок
draw("Как читать сканы на экране", CGRect(x: L, y: 160, width: R - L, height: 60), font("Times New Roman Bold", 38))
let serif = font("Times New Roman", 30)
let p1 = """
Отсканированная книга — это набор картинок: текст в ней нельзя выделить, найти или увеличить без потери чёткости. \
Читалка распознаёт строки, подбирает похожий шрифт и набирает текст заново на тех же местах, так что страница \
выглядит как оригинал, но остаётся текстом. Для этого нужна библиотека React или любой другой фреймворк? Нет — \
только встроенные модели системы.
"""
draw(p1, CGRect(x: L, y: 240, width: R - L, height: 330), serif, align: .justified)
// абзац, оборванный переносом посреди слова (проверка склейки при перекомпоновке)
draw("Иллюстрации, таблицы и схемы остаются картинками, но их тоже можно улучшить: выровнять фон, сделать линии чёткими. Единствен-",
     CGRect(x: L, y: 575, width: R - L, height: 90), serif, align: .justified)
draw("ное, что не меняется, — расположение элементов на странице.", CGRect(x: L, y: 655, width: R - L, height: 50), serif)
// иллюстрация: таблица в рамке
let fx: CGFloat = 250, fy: CGFloat = 760, fw: CGFloat = 740, fh: CGFloat = 520
ctx.setStrokeColor(NSColor(white: 0.35, alpha: 1).cgColor); ctx.setLineWidth(2); ctx.stroke(CGRect(x: fx, y: fy, width: fw, height: fh))
ctx.setFillColor(NSColor(white: 0.86, alpha: 1).cgColor); ctx.fill(CGRect(x: fx + 1, y: fy + 1, width: 230, height: fh - 2))
let names = ["Алиса Морозова", "Борис Ветров", "Вера Лунина", "Глеб Сорокин", "Дина Кравец", "Егор Тихий"]
for (i, n) in names.enumerated() {
    let y = fy + CGFloat(i) * fh / 6
    if i > 0 { ctx.setFillColor(NSColor(white: 0.55, alpha: 1).cgColor); ctx.fill(CGRect(x: fx, y: y, width: 230, height: 2)) }
    draw(n, CGRect(x: fx + 18, y: y + 30, width: 210, height: 34), font("Helvetica-Bold", 20), color: NSColor(white: 0.25, alpha: 1))
}
ctx.setFillColor(NSColor(white: 0.35, alpha: 1).cgColor); ctx.fill(CGRect(x: fx + 230, y: fy, width: 2, height: fh))
draw("Вера Лунина", CGRect(x: fx + 260, y: fy + 30, width: 460, height: 50), font("Helvetica-Bold", 34))
for (i, (k, v)) in [("Отдел:", "Каталог"), ("Город:", "Самара"), ("Код:", "40817")].enumerated() {
    let y = fy + 120 + CGFloat(i) * 52
    draw(k, CGRect(x: fx + 260, y: y, width: 120, height: 34), font("Helvetica", 20), color: NSColor(white: 0.5, alpha: 1))
    draw(v, CGRect(x: fx + 390, y: y, width: 300, height: 34), font("Helvetica", 22))
}
// подпись
let cap = NSMutableAttributedString(string: "Рис. 2.1. ", attributes: [.font: font("Helvetica-Bold", 20), .foregroundColor: ink])
cap.append(NSAttributedString(string: "Карточка сотрудника в демо-приложении", attributes: [.font: font("Helvetica", 20), .foregroundColor: ink]))
let cp = NSMutableParagraphStyle(); cp.alignment = .center
cap.addAttribute(.paragraphStyle, value: cp, range: NSRange(location: 0, length: cap.length))
cap.draw(in: CGRect(x: L, y: fy + fh + 24, width: R - L, height: 40))
draw("Распознанный текст можно выделять, копировать и отмечать цветом, как в обычной электронной книге.",
     CGRect(x: L, y: 1380, width: R - L, height: 120), serif, align: .justified)
NSGraphicsContext.current = nil

// «сканирование»
let clean = CIImage(cgImage: ctx.makeImage()!)
// лёгкое зерно бумаги (±2%) и желтоватый тон — как у сканера, а не «телевизионный снег»
let grain = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: clean.extent)
    .applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: 0.04, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0.04, y: 0, z: 0, w: 0),
        "inputBVector": CIVector(x: 0.04, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0.92, y: 0.91, z: 0.86, w: 1)])
let scanned = clean
    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.7]).cropped(to: clean.extent)
    .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: grain])
let ci = CIContext()
let cg = ci.createCGImage(scanned, from: clean.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())!
try! NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Готово:", out)
