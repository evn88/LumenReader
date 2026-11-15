import CoreGraphics
import CoreText
import Foundation

/// Шрифты, которыми заменяем текст скана. Кегль подбирается по ширине слов,
/// поэтому раскладка сохраняется при любой паре шрифтов.
struct FontPalette: Equatable, Hashable {
    var serifName: String
    var sansName: String
    var monoName: String = "Menlo"

    /// Ближе всего к типичной книжной вёрстке (Times / Helvetica).
    static let original = FontPalette(serifName: "Times New Roman", sansName: "Helvetica Neue")
    /// Как в Apple Books.
    static let books = FontPalette(serifName: "Iowan Old Style", sansName: "Helvetica Neue")
    static let charter = FontPalette(serifName: "Charter", sansName: "Avenir Next")
    static let georgia = FontPalette(serifName: "Georgia", sansName: "Helvetica Neue")
    /// Всё без засечек (темы «Акцент», «Фокус»).
    static let sans = FontPalette(serifName: "Helvetica Neue", sansName: "Helvetica Neue")

    func font(_ family: FontFamily, bold: Bool, italic: Bool, size: CGFloat) -> CTFont {
        let name: String
        switch family {
        case .serif: name = serifName
        case .sans: name = sansName
        case .mono: name = monoName
        }
        let base = CTFontCreateWithName(name as CFString, size, nil)
        var traits: CTFontSymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if traits.isEmpty { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
    }
}

enum TextMetrics {
    static func line(_ text: String, font: CTFont, color: CGColor? = nil) -> CTLine {
        var attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        if let color { attrs[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color }
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    }

    /// Рамка контуров глифов относительно точки базовой линии (y вверх).
    static func inkBounds(_ line: CTLine) -> CGRect {
        CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    }

    static func advance(_ line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Растр слова для сравнения со сканом: левый край краски в x=0,
    /// базовая линия на строке `baselineRow` (считая сверху).
    static func mask(_ text: String, font: CTFont, width w: Int, height h: Int, baselineRow: Int) -> InkMask {
        guard w > 0, h > 0 else { return InkMask(width: 0, height: 0, bits: []) }
        var px = [UInt8](repeating: 0, count: w * h)
        px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            let white = CGColor(gray: 1, alpha: 1)
            let ln = line(text, font: font, color: white)
            let ink = inkBounds(ln)
            ctx.textPosition = CGPoint(x: -ink.minX, y: CGFloat(h - baselineRow))
            CTLineDraw(ln, ctx)
        }
        return InkMask(width: w, height: h, bits: px.map { $0 > 110 ? 1 : 0 })
    }
}
