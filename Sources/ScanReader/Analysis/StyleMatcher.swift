import CoreGraphics
import Foundation

/// Подбор оформления абзаца по краске скана:
///  - гарнитура (serif/sans): рендерим слова кандидатами и сравниваем форму (IoU);
///  - кегль: такой, при котором ширина слова совпадает с оригиналом;
///  - жирность: толщина штриха относительно эталона страницы (сканер "раздувает"
///    весь текст одинаково, поэтому абсолютная толщина ничего не говорит);
///  - курсив: наклон вертикальных штрихов.
struct StyleMatcher {
    let ink: InkMask
    let palette: FontPalette
    /// Медиана (толщина штриха / x-height) по всей странице.
    let pageStem: Double

    static let boldRatio = 1.22
    static let italicSlant = 0.12

    static func stem(of word: Word, in line: TextLine, ink: InkMask) -> Double {
        guard line.xHeight > 0 else { return 0 }
        return ink.crop(word.bounds).meanStemWidth() / Double(line.xHeight)
    }

    static func pageStemReference(lines: [TextLine], ink: InkMask) -> Double {
        let values = lines.flatMap { l in
            l.words.filter { $0.text.count >= 3 }.map { stem(of: $0, in: l, ink: ink) }
        }.filter { $0 > 0 }.sorted()
        return values.isEmpty ? 0.2 : values[values.count / 2]
    }

    func fitSize(_ text: String, family: FontFamily, bold: Bool, italic: Bool, inkWidth: CGFloat) -> CGFloat {
        let f = palette.font(family, bold: bold, italic: italic, size: 100)
        let w = TextMetrics.inkBounds(TextMetrics.line(text, font: f)).width
        return w > 0 ? 100 * inkWidth / w : 0
    }

    private func shapeScore(_ word: Word, _ line: TextLine, family: FontFamily, italic: Bool) -> Double {
        let size = fitSize(word.text, family: family, bold: false, italic: italic, inkWidth: word.bounds.width)
        guard size > 2 else { return 0 }
        let rect = CGRect(x: word.bounds.minX, y: line.bounds.minY, width: word.bounds.width, height: line.bounds.height)
        let original = ink.crop(rect)
        let rendered = TextMetrics.mask(
            word.text, font: palette.font(family, bold: false, italic: italic, size: size),
            width: original.width, height: original.height, baselineRow: Int(line.baseline - rect.minY))
        return InkMask.iou(original.dilated(radius: 1), rendered.dilated(radius: 1))
    }

    /// Оформляет абзац на месте: жирность/курсив слов, гарнитура и кегль абзаца.
    func style(_ lines: inout [TextLine]) -> (FontFamily, CGFloat) {
        // 1. начертание слов
        for li in lines.indices {
            for wi in lines[li].words.indices {
                let word = lines[li].words[wi]
                let core = word.text.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
                if core.count < 3, wi > 0 {
                    // короткие слова шумные — наследуют оформление соседа
                    lines[li].words[wi].bold = lines[li].words[wi - 1].bold
                    lines[li].words[wi].italic = lines[li].words[wi - 1].italic
                    continue
                }
                let stem = Self.stem(of: word, in: lines[li], ink: ink)
                lines[li].words[wi].bold = pageStem > 0 && stem / pageStem > Self.boldRatio
                let slantRect = CGRect(x: word.bounds.minX, y: lines[li].bounds.minY,
                                       width: word.bounds.width, height: lines[li].baseline - lines[li].bounds.minY)
                lines[li].words[wi].italic = ink.crop(slantRect).slant() > Self.italicSlant
            }
        }

        // 2. гарнитура: голосование самыми длинными словами
        var samples: [(Word, TextLine)] = lines.flatMap { l in l.words.map { ($0, l) } }
            .filter { $0.0.text.count >= 3 }
        samples.sort { $0.0.text.count > $1.0.text.count }
        samples = Array(samples.prefix(14))
        if samples.isEmpty { samples = lines.flatMap { l in l.words.map { ($0, l) } } }
        // моноширинный — только если это подтверждает ровный шаг символов (или явный код):
        // иначе курсивный sans в колонтитуле («Глава 2») выигрывает голосование у mono
        let text = lines.map(\.text).joined(separator: "\n")
        let pv = CodeDetector.pitchVariation(lines)
        let monoConfirmed = pv < 0.045 || (pv >= 1 && CodeDetector.detectLanguage(text).score >= 3)
        let candidates = FontFamily.allCases.filter { $0 != .mono || monoConfirmed }
        let family = candidates.max { a, b in
            score(samples, a) < score(samples, b)
        } ?? .serif

        // 3. кегль: медиана по словам выбранной гарнитурой с их начертанием
        var sizes = samples.map { w, _ in
            fitSize(w.text, family: family, bold: w.bold, italic: w.italic, inkWidth: w.bounds.width)
        }.filter { $0 > 2 }.sorted()
        if sizes.isEmpty { sizes = [lines.first.map { $0.xHeight * 2.1 } ?? 12] }
        var size = sizes[sizes.count / 2]

        // 4. в выключенных строках пробелы не должны сжиматься меньше 0.75 обычного
        for line in lines where line.alignment == .justify && line.words.count > 1 {
            while size > 6 {
                let widths = line.words.reduce(CGFloat(0)) { acc, w in
                    let f = palette.font(family, bold: w.bold, italic: w.italic, size: size)
                    return acc + TextMetrics.inkBounds(TextMetrics.line(w.text, font: f)).width
                }
                let space = TextMetrics.advance(TextMetrics.line(" ", font: palette.font(family, bold: false, italic: false, size: size)))
                if (line.bounds.width - widths) / CGFloat(line.words.count - 1) >= 0.75 * space { break }
                size -= 0.5
            }
        }
        return (family, size)
    }

    private func score(_ samples: [(Word, TextLine)], _ family: FontFamily) -> Double {
        samples.reduce(0) { acc, s in
            acc + Double(s.0.text.count) * shapeScore(s.0, s.1, family: family, italic: s.0.italic)
        }
    }
}
