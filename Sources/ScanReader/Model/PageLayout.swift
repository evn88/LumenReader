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
    /// Оглавления: название, точки-заполнители, номер страницы по правому краю.
    var tocBlocks: [TOCBlock] = []
    /// Таблицы: ячейки по колонкам и строкам (в сетке линеек или по выравниванию).
    var tables: [TableBlock] = []
    /// Места, где вёрстку надёжно воссоздать не удалось: показываем фрагментом скана.
    var scanRegions: [ScanRegion] = []
    /// Участки страницы, набранные в несколько колонок (порядок чтения: колонка за колонкой).
    var columnZones: [ColumnZone] = []

    enum CodingKeys: String, CodingKey {
        case size, figures, rules, paragraphs, codeBlocks, figureLabels, tocBlocks, tables, scanRegions, columnZones
    }

    init(size: CGSize, figures: [CGRect], rules: [CGRect], paragraphs: [Paragraph], codeBlocks: [CodeBlock] = [],
         figureLabels: [FigureLabel] = [], tocBlocks: [TOCBlock] = [], tables: [TableBlock] = [],
         scanRegions: [ScanRegion] = [], columnZones: [ColumnZone] = []) {
        self.size = size; self.figures = figures; self.rules = rules; self.paragraphs = paragraphs
        self.codeBlocks = codeBlocks; self.figureLabels = figureLabels; self.tocBlocks = tocBlocks
        self.tables = tables; self.scanRegions = scanRegions; self.columnZones = columnZones
    }

    // раскладки из прежних версий кеша — без новых полей
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        size = try c.decode(CGSize.self, forKey: .size)
        figures = try c.decode([CGRect].self, forKey: .figures)
        rules = try c.decode([CGRect].self, forKey: .rules)
        paragraphs = try c.decode([Paragraph].self, forKey: .paragraphs)
        codeBlocks = try c.decodeIfPresent([CodeBlock].self, forKey: .codeBlocks) ?? []
        figureLabels = try c.decodeIfPresent([FigureLabel].self, forKey: .figureLabels) ?? []
        tocBlocks = try c.decodeIfPresent([TOCBlock].self, forKey: .tocBlocks) ?? []
        tables = try c.decodeIfPresent([TableBlock].self, forKey: .tables) ?? []
        scanRegions = try c.decodeIfPresent([ScanRegion].self, forKey: .scanRegions) ?? []
        columnZones = try c.decodeIfPresent([ColumnZone].self, forKey: .columnZones) ?? []
    }

    /// Строки оглавлений, таблиц и фрагментов скана — после строк абзацев (так нумеруются слова и запасные фрагменты).
    var structureLines: [TextLine] {
        tocBlocks.flatMap { $0.entries.flatMap(\.allLines) } + tables.flatMap { $0.cells.flatMap(\.lines) }
            + scanRegions.flatMap(\.lines)
    }
    var allLines: [TextLine] { paragraphs.flatMap(\.lines) + structureLines }

    /// Текст страницы в порядке чтения: абзацы, код, оглавление, таблицы (ячейки через табуляцию).
    var plainText: String {
        var blocks: [(CGRect, String)] = []
        for p in paragraphs { blocks.append((p.bounds, p.lines.map(\.text).joined(separator: "\n"))) }
        for c in codeBlocks { blocks.append((c.bounds, c.text)) }
        for t in tocBlocks { blocks.append((t.bounds, t.text)) }
        for t in tables { blocks.append((t.bounds, t.text)) }
        for s in scanRegions { blocks.append((s.rect, s.lines.map(\.text).joined(separator: "\n"))) }
        return blocks.sorted { readingKey($0.0) < readingKey($1.0) }.map(\.1).joined(separator: "\n\n")
    }

    /// Ключ порядка чтения блока: в многоколоночной зоне — колонка за колонкой, иначе сверху вниз.
    func readingKey(_ r: CGRect) -> ReadingKey {
        if let z = columnZones.first(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(CGPoint(x: r.midX, y: r.midY)) }) {
            return ReadingKey(anchor: z.rect.minY, column: z.column(of: r), y: r.minY)
        }
        return ReadingKey(anchor: r.minY, column: 0, y: r.minY)
    }

    /// Сквозные номера слов (Word.gid) в порядке allLines.
    mutating func numberWords() {
        var gid = 0
        func number(_ l: inout TextLine) { for wi in l.words.indices { l.words[wi].gid = gid; gid += 1 } }
        for pi in paragraphs.indices { for li in paragraphs[pi].lines.indices { number(&paragraphs[pi].lines[li]) } }
        for ti in tocBlocks.indices {
            for ei in tocBlocks[ti].entries.indices {
                for li in tocBlocks[ti].entries[ei].lines.indices { number(&tocBlocks[ti].entries[ei].lines[li]) }
                if tocBlocks[ti].entries[ei].page != nil { number(&tocBlocks[ti].entries[ei].page!) }
            }
        }
        for ti in tables.indices {
            for ci in tables[ti].cells.indices { for li in tables[ti].cells[ci].lines.indices { number(&tables[ti].cells[ci].lines[li]) } }
        }
        for si in scanRegions.indices { for li in scanRegions[si].lines.indices { number(&scanRegions[si].lines[li]) } }
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

    var bounds: CGRect { lines.map(\.bounds).reduce(lines.first?.bounds ?? .zero) { $0.union($1) } }
}

struct ReadingKey: Comparable {
    var anchor: CGFloat, column: Int, y: CGFloat
    static func < (a: ReadingKey, b: ReadingKey) -> Bool {
        (a.anchor, a.column, a.y) < (b.anchor, b.column, b.y)
    }
}

/// Участок страницы в несколько колонок: границы колонок по x (просветы между ними).
struct ColumnZone: Codable, Equatable {
    var rect: CGRect
    /// Середины просветов между колонками, по возрастанию.
    var splits: [CGFloat]

    func column(of r: CGRect) -> Int { splits.filter { r.midX > $0 }.count }
}

/// Пункт оглавления: строки названия (с переносами), номер страницы, уровень вложенности.
struct TOCEntry: Codable, Equatable {
    var lines: [TextLine]
    /// Номер страницы (одна «строка» из одного слова), у заголовков разделов его может не быть.
    var page: TextLine?
    var level: Int
    /// В оригинале между названием и номером были точки-заполнители.
    var leader: Bool
    var family: FontFamily = .serif
    var fontSize: CGFloat = 0

    var allLines: [TextLine] { lines + (page.map { [$0] } ?? []) }
    var title: String { lines.map(\.text).joined(separator: " ") }
}

struct TOCBlock: Codable, Equatable {
    var bounds: CGRect
    /// Правый край номеров страниц.
    var right: CGFloat
    var entries: [TOCEntry]

    var text: String {
        entries.map { String(repeating: "  ", count: $0.level) + $0.title + ($0.page.map { "\t" + $0.text } ?? "") }
            .joined(separator: "\n")
    }
}

struct TableCell: Codable, Equatable {
    var row: Int
    var column: Int
    var span: Int = 1
    var lines: [TextLine]
    var alignment: LineAlignment = .left
}

/// Таблица. Границы колонок и строк — по просветам (без линеек) или по линейкам сетки.
struct TableBlock: Codable, Equatable {
    var bounds: CGRect
    /// Границы колонок по x: колонок на одну меньше.
    var columns: [CGFloat]
    /// Границы строк по y.
    var rows: [CGFloat]
    /// Сетка нарисована линейками (толщина — `ruleWidth`).
    var ruled: Bool
    var ruleWidth: CGFloat = 2
    /// Линейки сетки, как в оригинале (у объединённых ячеек внутренней линейки нет).
    var gridRules: [CGRect] = []
    var family: FontFamily = .sans
    var fontSize: CGFloat = 12
    var cells: [TableCell]

    var text: String {
        let nr = rows.count - 1, nc = columns.count - 1
        guard nr > 0, nc > 0 else { return "" }
        return (0..<nr).map { r in
            (0..<nc).compactMap { c -> String? in
                if let cell = cells.first(where: { $0.row == r && $0.column == c }) {
                    return cell.lines.map(\.text).joined(separator: " ")
                }
                return cells.contains { $0.row == r && $0.column < c && $0.column + $0.span > c } ? nil : ""
            }.joined(separator: "\t")
        }.joined(separator: "\n")
    }
}

/// Фрагмент скана вместо текста: вёрстку не удалось воссоздать надёжно.
/// Строки OCR сохраняем для поиска и копирования.
struct ScanRegion: Codable, Equatable {
    var rect: CGRect
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
