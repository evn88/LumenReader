import CoreGraphics
import Foundation

/// Результат анализа одной отсканированной страницы.
/// Все координаты в пикселях исходного скана, начало координат — левый верхний угол.
/// Codable: раскладку кешируем на диске (позже — рядом с книгой в iCloud-папке),
/// чтобы повторное открытие книги не запускало OCR заново.
struct PageLayout: Codable, Equatable {
    var size: CGSize
    /// Иллюстрации: показываем фрагментом оригинала (текст внутри них не заменяем).
    var figures: [CGRect]
    /// Горизонтальные линейки (под колонтитулом, над сносками) — рисуем вектором.
    var rules: [CGRect]
    var paragraphs: [Paragraph]
    /// Блоки кода: моноширинный шрифт, отступы, подсветка синтаксиса.
    var codeBlocks: [CodeBlock] = []
    /// Надписи внутри иллюстраций (для перерисовки при улучшении картинок).
    var figureLabels: [FigureLabel] = []

    var allLines: [TextLine] { paragraphs.flatMap(\.lines) }
    var plainText: String {
        (paragraphs.map { $0.lines.map(\.text).joined(separator: "\n") } + codeBlocks.map(\.text))
            .joined(separator: "\n\n")
    }

    func codeBlock(at point: CGPoint) -> CodeBlock? {
        codeBlocks.first { $0.bounds.insetBy(dx: -8, dy: -8).contains(point) }
    }

    func line(at point: CGPoint) -> TextLine? {
        allLines.first { $0.bounds.insetBy(dx: -4, dy: -6).contains(point) }
    }
}

struct Paragraph: Codable, Equatable {
    var family: FontFamily
    /// Кегль в пикселях скана (не в pt): совпадает по ширине слов с оригиналом.
    var fontSize: CGFloat
    var lines: [TextLine]
}

struct TextLine: Codable, Equatable {
    /// Рамка по краске (без полей).
    var bounds: CGRect
    /// Базовая линия (y в пикселях скана).
    var baseline: CGFloat
    /// Высота строчных букв по проекции краски.
    var xHeight: CGFloat
    var alignment: LineAlignment
    /// Уверенность Vision. Если низкая — рисуем исходный фрагмент вместо текста,
    /// чтобы не показывать читателю мусор.
    var confidence: Float
    var words: [Word]

    var text: String { words.map(\.text).joined(separator: " ") }
}

struct Word: Codable, Equatable {
    var text: String
    /// Рамка по краске.
    var bounds: CGRect
    var bold: Bool = false
    var italic: Bool = false
    /// Порядковый номер слова на странице (в порядке allLines) — сквозной якорь выделений и хайлайтов.
    /// Проставляется при перекомпоновке, в кеш не пишется.
    var gid: Int? = nil

    enum CodingKeys: String, CodingKey { case text, bounds, bold, italic }
}

enum FontFamily: String, Codable, CaseIterable {
    case serif, sans, mono
}

struct FigureLabel: Codable, Equatable {
    var figure: Int
    var line: TextLine
}

struct CodeBlock: Codable, Equatable {
    var bounds: CGRect
    var language: CodeLanguage
    /// Шаг символа моноширинного шрифта в оригинале (пиксели скана).
    var pitch: CGFloat
    var lines: [CodeLine]

    /// Текст для копирования: отступы пробелами, пустые строки там, где был большой интервал.
    var text: String {
        let steps = zip(lines.dropFirst(), lines).map { $0.baseline - $1.baseline }.sorted()
        let step = steps.isEmpty ? 0 : steps[steps.count / 2]
        var out: [String] = []
        for (i, l) in lines.enumerated() {
            if i > 0, step > 0 {
                let gaps = Int(((l.baseline - lines[i - 1].baseline) / step).rounded()) - 1
                if gaps > 0 { out += Array(repeating: "", count: gaps) }
            }
            out.append(String(repeating: " ", count: l.indent) + l.text)
        }
        return out.joined(separator: "\n")
    }
}

struct CodeLine: Codable, Equatable {
    var text: String
    /// Отступ в символах.
    var indent: Int
    var baseline: CGFloat
}

enum LineAlignment: String, Codable {
    case left, right, center, justify
}
