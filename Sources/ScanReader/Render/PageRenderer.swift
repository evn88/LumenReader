import CoreGraphics
import CoreText
import Foundation

/// Темы как в Apple Books: фон, цвет текста и шрифты распознанного текста.
struct ReaderTheme: Equatable, Hashable, Identifiable {
    var id: String { name }
    var name: String
    var paper: CGColor
    var ink: CGColor
    var isDark: Bool
    /// Шрифты, которыми набирается распознанный текст в этой теме.
    var palette: FontPalette
    /// Шрифт карточки темы в «Темы и настройки».
    var cardFont: String
    var cardBold = false
    /// Вторичный цвет: название книги и номера страниц (как в Books).
    var secondary: CGColor = CGColor(gray: 0.5, alpha: 1)

    /// Явно sRGB: фон окна (SwiftUI) и лист (Canvas/CGContext) должны совпадать тон в тон.
    private static func rgb(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    // цвета сняты пипеткой с Apple Books (macOS 26/27); вторичный (номера, название) поднят до контраста WCAG AA ≥ 4.5:1
    static let original = ReaderTheme(name: "Оригинал", paper: rgb(0xFFFFFF), ink: rgb(0x000000), isDark: false,
                                      palette: .original, cardFont: "Helvetica Neue", secondary: rgb(0x747474))
    static let quiet = ReaderTheme(name: "Тишина", paper: rgb(0x4A4A4C), ink: rgb(0xA9A9A9), isDark: true,
                                   palette: .books, cardFont: "Iowan Old Style", secondary: rgb(0xBCBCBD))
    static let paperTheme = ReaderTheme(name: "Бумага", paper: rgb(0xEDEDED), ink: rgb(0x262626), isDark: false,
                                        palette: .charter, cardFont: "Charter", secondary: rgb(0x696969))
    static let bold = ReaderTheme(name: "Акцент", paper: rgb(0xFFFFFF), ink: rgb(0x000000), isDark: false,
                                  palette: .sans, cardFont: "Helvetica Neue", cardBold: true, secondary: rgb(0x747474))
    static let calm = ReaderTheme(name: "Покой", paper: rgb(0xEDDEC0), ink: rgb(0x2A2015), isDark: false,
                                  palette: .books, cardFont: "Iowan Old Style", secondary: rgb(0x6A6052))
    static let focus = ReaderTheme(name: "Фокус", paper: rgb(0xFFFBF2), ink: rgb(0x1E1B16), isDark: false,
                                   palette: .sans, cardFont: "Helvetica Neue", secondary: rgb(0x787268))
    static let all: [ReaderTheme] = [.original, .quiet, .paperTheme, .bold, .calm, .focus]

    // прежние имена (CLI, сохранённые настройки)
    static let sepia = calm
    static let night = original.darkVariant()

    /// Тёмный вариант (кнопка ☀︎ в «Темы и настройки»); тёмные темы не меняются.
    func darkVariant() -> ReaderTheme {
        guard !isDark else { return self }
        var t = self
        t.paper = Self.rgb(0x121212); t.ink = Self.rgb(0xB0B0B0); t.secondary = Self.rgb(0x7F7F7F); t.isDark = true
        return t
    }

    static func named(_ s: String) -> ReaderTheme {
        switch s.lowercased() {
        case "sepia", "calm", "покой": return .calm
        case "night", "dark", "ночь": return .night
        case "white", "original", "оригинал": return .original
        case "gray", "paper", "бумага": return .paperTheme
        case "quiet", "тишина": return .quiet
        case "bold", "акцент": return .bold
        case "focus", "фокус": return .focus
        default: return all.first { $0.name == s } ?? .calm
        }
    }
}

/// Рисует "чистую" страницу. Контекст уже масштабирован в пиксели скана
/// и перевёрнут (начало — левый верхний угол, y вниз), как в SwiftUI Canvas.
struct PageRenderer {
    var palette: FontPalette
    var theme: ReaderTheme

    func draw(_ page: AnalyzedPage, in cg: CGContext) {
        let layout = page.layout
        cg.setFillColor(theme.paper)
        cg.fill(CGRect(origin: .zero, size: layout.size))

        // иллюстрации: белое скана -> цвет листа (multiply); в ночной теме — инверсия
        for (rect, image) in zip(layout.figures, page.figureImages) {
            if let image { drawImage(image, in: rect.integral, cg: cg) }
        }
        // до любого CTLineDraw (в т.ч. в блоках кода): контекст перевёрнут, глифы — нет
        cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for block in layout.codeBlocks { draw(block, cg: cg) }

        cg.setFillColor(theme.ink)
        for r in layout.rules { cg.fill(r) }

        var lineIndex = 0
        for p in layout.paragraphs {
            for line in p.lines {
                if let crop = page.fallbackLines[lineIndex] {
                    drawImage(crop, in: line.bounds.insetBy(dx: -3, dy: -3).integral, cg: cg)
                } else {
                    draw(line, family: p.family, size: displaySize(p), cg: cg)
                }
                lineIndex += 1
            }
        }
    }

    /// Экранная страница перекомпонованного текста (масштаб ≠ 100%).
    func draw(_ screen: ScreenPage, of page: AnalyzedPage, in cg: CGContext) {
        let layout = page.layout
        cg.setFillColor(theme.paper)
        cg.fill(CGRect(origin: .zero, size: layout.size))
        cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        var lineStart: [Int] = []
        var acc = 0
        for p in layout.paragraphs { lineStart.append(acc); acc += p.lines.count }
        for item in screen.items {
            switch item {
            case .codeBackground(let r, let label):
                let radius = min(r.height / 2, layout.size.width * 0.012)
                cg.saveGState()
                cg.setFillColor(theme.isDark ? CGColor(gray: 1, alpha: 0.06) : CGColor(gray: 0, alpha: 0.045))
                cg.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
                cg.fillPath()
                cg.restoreGState()
                if let label {
                    let l = TextMetrics.line(label, font: palette.font(.sans, bold: false, italic: false, size: layout.size.width * 0.011),
                                             color: theme.ink.copy(alpha: 0.4) ?? theme.ink)
                    cg.textPosition = CGPoint(x: r.maxX - TextMetrics.advance(l) - radius, y: r.minY + layout.size.width * 0.016)
                    CTLineDraw(l, cg)
                }
            case .text(let line, let origin):
                cg.textPosition = origin
                CTLineDraw(line, cg)
            case .figure(let i, let rect):
                if page.figureImages.indices.contains(i), let image = page.figureImages[i] { drawImage(image, in: rect.integral, cg: cg) }
            case .rule(let r):
                cg.setFillColor(theme.ink); cg.fill(r)
            case .runningLine(let pi, let li):
                let p = layout.paragraphs[pi]
                if let crop = page.fallbackLines[lineStart[pi] + li] {
                    drawImage(crop, in: p.lines[li].bounds.insetBy(dx: -3, dy: -3).integral, cg: cg)
                } else {
                    draw(p.lines[li], family: p.family, size: displaySize(p), cg: cg)
                }
            case .fallback(let li, let rect):
                if let crop = page.fallbackLines[li] { drawImage(crop, in: rect.integral, cg: cg) }
            }
        }
    }

    /// Кегль абзаца для шрифта темы. Раскладка подобрана эталонной парой (FontPalette.original),
    /// а шрифт темы может быть шире (Iowan) или уже: подгоняем по ширине слов, чтобы слова не слипались.
    func displaySize(_ p: Paragraph) -> CGFloat {
        guard palette != .original else { return p.fontSize }
        let words = p.lines.flatMap(\.words).prefix(24)
        var ref: CGFloat = 0, disp: CGFloat = 0
        for w in words {
            ref += TextMetrics.inkBounds(TextMetrics.line(w.text, font: FontPalette.original.font(p.family, bold: w.bold, italic: w.italic, size: 100))).width
            disp += TextMetrics.inkBounds(TextMetrics.line(w.text, font: palette.font(p.family, bold: w.bold, italic: w.italic, size: 100))).width
        }
        guard ref > 0, disp > 0 else { return p.fontSize }
        return p.fontSize * ref / disp
    }

    private func drawImage(_ image: CGImage, in rect: CGRect, cg: CGContext) {
        cg.saveGState()
        cg.translateBy(x: 0, y: rect.minY + rect.maxY)
        cg.scaleBy(x: 1, y: -1)
        if theme.isDark {
            // инверсия: белый фон -> чёрный, штрихи -> светлые; затем screen с цветом листа
            cg.clip(to: rect)
            cg.draw(image, in: rect)
            cg.setBlendMode(.difference)
            cg.setFillColor(CGColor(gray: 1, alpha: 1))
            cg.fill(rect)
            cg.setBlendMode(.screen)
            cg.setFillColor(theme.paper)
            cg.fill(rect)
        } else {
            cg.setBlendMode(.multiply)
            cg.draw(image, in: rect)
        }
        cg.restoreGState()
    }

    /// Блок кода: подложка, моноширинный шрифт с шагом как в оригинале, отступы, подсветка.
    private func draw(_ block: CodeBlock, cg: CGContext) {
        let probe = palette.font(.mono, bold: false, italic: false, size: 100)
        let adv = TextMetrics.advance(TextMetrics.line("0", font: probe))
        let size = adv > 0 ? 100 * block.pitch / adv : 12
        let font = palette.font(.mono, bold: false, italic: false, size: size)

        let pad = block.pitch * 1.2
        let bg = block.bounds.insetBy(dx: -pad, dy: -pad * 0.8)
        cg.saveGState()
        cg.setFillColor(theme.isDark ? CGColor(gray: 1, alpha: 0.06) : CGColor(gray: 0, alpha: 0.045))
        cg.addPath(CGPath(roundedRect: bg, cornerWidth: pad * 0.6, cornerHeight: pad * 0.6, transform: nil))
        cg.fillPath()
        cg.restoreGState()

        if block.language != .plain {
            let label = TextMetrics.line(block.language.title,
                                         font: palette.font(.sans, bold: false, italic: false, size: size * 0.7),
                                         color: theme.ink.copy(alpha: 0.4) ?? theme.ink)
            let w = TextMetrics.advance(label)
            cg.textPosition = CGPoint(x: bg.maxX - w - pad * 0.5, y: bg.minY + size * 0.85)
            CTLineDraw(label, cg)
        }

        let left = block.bounds.minX
        for line in block.lines {
            let attr = NSMutableAttributedString(string: line.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): theme.ink,
            ])
            for (range, kind) in SyntaxHighlighter.tokens(line.text, block.language) {
                attr.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String),
                                  value: SyntaxHighlighter.color(kind, dark: theme.isDark, ink: theme.ink), range: range)
            }
            let ct = CTLineCreateWithAttributedString(attr)
            let ink = TextMetrics.inkBounds(ct)
            cg.textPosition = CGPoint(x: left + CGFloat(line.indent) * block.pitch - ink.minX, y: line.baseline)
            CTLineDraw(ct, cg)
        }
    }

    private func font(_ family: FontFamily, _ w: Word, _ size: CGFloat) -> CTFont {
        palette.font(family, bold: w.bold, italic: w.italic, size: size)
    }

    private func draw(_ line: TextLine, family: FontFamily, size: CGFloat, cg: CGContext) {
        let ctLines = line.words.map { TextMetrics.line($0.text, font: font(family, $0, size), color: theme.ink) }
        let inks = ctLines.map(TextMetrics.inkBounds)
        let space = TextMetrics.advance(TextMetrics.line(" ", font: palette.font(family, bold: false, italic: false, size: size)))

        // позиции левого края краски каждого слова
        var xs: [CGFloat] = []
        switch line.alignment {
        case .justify where line.words.count > 1:
            let total = inks.reduce(0) { $0 + $1.width }
            let gap = (line.bounds.width - total) / CGFloat(line.words.count - 1)
            var x = line.bounds.minX
            for ink in inks { xs.append(x); x += ink.width + gap }
        default:
            // естественные пробелы: advance слова + пробел
            var x: CGFloat = 0
            var rel: [CGFloat] = []
            for (l, ink) in zip(ctLines, inks) { rel.append(x + ink.minX); x += TextMetrics.advance(l) + space }
            let natural = (rel.last ?? 0) + (inks.last?.width ?? 0) - (rel.first ?? 0)
            let start: CGFloat
            switch line.alignment {
            case .center: start = line.bounds.midX - natural / 2
            case .right: start = line.bounds.maxX - natural
            default: start = line.bounds.minX
            }
            xs = rel.map { start + $0 - (rel.first ?? 0) }
        }

        for (i, l) in ctLines.enumerated() {
            cg.textPosition = CGPoint(x: xs[i] - inks[i].minX, y: line.baseline)
            CTLineDraw(l, cg)
        }
    }
}
