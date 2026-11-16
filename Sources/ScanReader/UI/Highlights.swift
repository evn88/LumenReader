import AppKit
import SwiftUI

/// Геометрия слов страницы для выделения: сквозной номер слова → рамка (координаты листа).
struct WordGeometry {
    var boxes: [(gid: Int, rect: CGRect)]
    var text: [Int: String]

    /// Точная раскладка (100%, скан): рамки слов по высоте их строки.
    init(layout: PageLayout) {
        var b: [(Int, CGRect)] = [], t: [Int: String] = [:]
        var gid = 0
        for line in layout.allLines {
            for w in line.words {
                b.append((gid, CGRect(x: w.bounds.minX, y: line.bounds.minY, width: max(2, w.bounds.width), height: line.bounds.height)))
                t[gid] = w.text
                gid += 1
            }
        }
        boxes = b; text = t
    }

    /// Перекомпоновка: рамки из экранной страницы, текст — из исходной раскладки.
    init(screen: ScreenPage, layout: PageLayout) {
        boxes = screen.wordBoxes
        text = WordGeometry(layout: layout).text
    }

    /// Слово под точкой; иначе ближайшее в той же строке; иначе ближайшее вообще (в пределах 60 pt).
    func gid(at p: CGPoint) -> Int? {
        if let hit = boxes.first(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(p) }) { return hit.gid }
        let row = boxes.filter { $0.rect.minY - 2 <= p.y && p.y <= $0.rect.maxY + 2 }
        if let near = row.min(by: { dist($0.rect, p) < dist($1.rect, p) }) { return near.gid }
        let near = boxes.min { dist($0.rect, p) < dist($1.rect, p) }
        return near.flatMap { dist($0.rect, p) < 60 ? $0.gid : nil }
    }

    private func dist(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Рамки диапазона, слитые по строкам (одна полоса на строку).
    func rows(_ range: ClosedRange<Int>) -> [CGRect] {
        var rows: [CGRect] = []
        for b in boxes where range.contains(b.gid) {
            if let i = rows.firstIndex(where: { abs($0.midY - b.rect.midY) < b.rect.height * 0.5 }) {
                rows[i] = rows[i].union(b.rect)
            } else {
                rows.append(b.rect)
            }
        }
        return rows
    }

    func string(_ range: ClosedRange<Int>) -> String {
        range.compactMap { text[$0] }.joined(separator: " ")
    }
}

/// Слой хайлайтов и текущего выделения поверх страницы (в любом режиме и теме).
struct HighlightLayer: View {
    let geometry: WordGeometry
    let annotations: [Annotation]
    let selection: ClosedRange<Int>?
    let scale: CGFloat
    let dark: Bool

    var body: some View {
        Canvas { ctx, _ in
            for a in annotations {
                guard case .scan(_, let s, let e) = a.anchor, s <= e else { continue }
                let (r, g, b) = a.style.rgb
                for row in geometry.rows(s...e) {
                    let rr = CGRect(x: row.minX * scale - 1, y: row.minY * scale, width: row.width * scale + 2, height: row.height * scale)
                    if a.style == .underline {
                        ctx.fill(Path(CGRect(x: rr.minX, y: rr.maxY - 2, width: rr.width, height: 2)),
                                 with: .color(Color(red: r, green: g, blue: b)))
                    } else {
                        ctx.fill(Path(roundedRect: rr, cornerRadius: 2),
                                 with: .color(Color(red: r, green: g, blue: b).opacity(dark ? 0.38 : 0.45)))
                    }
                    if a.note?.isEmpty == false, row == geometry.rows(s...e).last {
                        // заметка — маленький значок в конце хайлайта
                        ctx.fill(Path(ellipseIn: CGRect(x: rr.maxX + 2, y: rr.minY, width: 6, height: 6)),
                                 with: .color(Color(red: r, green: g, blue: b)))
                    }
                }
            }
            if let sel = selection {
                for row in geometry.rows(sel) {
                    let rr = CGRect(x: row.minX * scale - 1, y: row.minY * scale, width: row.width * scale + 2, height: row.height * scale)
                    ctx.fill(Path(rr), with: .color(Color.accentColor.opacity(0.28)))
                }
            }
        }
        .blendMode(dark ? .normal : .multiply)
        .allowsHitTesting(false)
    }
}

/// Меню выделения, как в Apple Books: цвета, подчёркивание, заметка, копировать, удалить.
struct HighlightMenu: View {
    let text: String
    let existing: Annotation?
    var onStyle: (HighlightStyle) -> Void
    var onNote: (String) -> Void
    var onCopy: () -> Void
    var onDelete: () -> Void
    /// Язык перевода для кнопки «Перевести» (nil — кнопки нет).
    var translateTo: String? = nil
    /// false — только копирование и перевод (например, на переведённом тексте хайлайты не ставятся).
    var allowsAnnotations = true

    @State private var editingNote = false
    @State private var translating = false
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if allowsAnnotations {
            HStack(spacing: 8) {
                ForEach(HighlightStyle.allCases) { st in
                    Button { onStyle(st) } label: {
                        Group {
                            if st == .underline {
                                Image(systemName: "underline").font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(st.color)
                                    .frame(width: 24, height: 24)
                                    .background(Circle().strokeBorder(Color.primary.opacity(0.25)))
                            } else {
                                Circle().fill(st.color).frame(width: 24, height: 24)
                            }
                        }
                        .overlay(existing?.style == st ? Circle().strokeBorder(Color.primary, lineWidth: 2) : nil)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain).help(st.title)
                }
            }
            Divider()
            }
            if editingNote {
                TextEditor(text: $note).font(.callout).frame(width: 240, height: 80)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
                HStack {
                    Spacer()
                    Button("Отмена") { editingNote = false }
                    Button("Сохранить") { onNote(note); editingNote = false }.keyboardShortcut(.defaultAction)
                }
                .controlSize(.small)
            } else {
                if allowsAnnotations {
                    Button { note = existing?.note ?? ""; editingNote = true } label: {
                        Label(existing?.note?.isEmpty == false ? "Изменить заметку" : "Добавить заметку", systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.plain)
                }
                Button { onCopy() } label: { Label("Копировать", systemImage: "doc.on.doc") }
                    .buttonStyle(.plain).keyboardShortcut("c")
                if let target = translateTo {
                    if translating {
                        Divider()
                        SnippetTranslation(text: text, target: target)
                    } else {
                        Button { translating = true } label: { Label("Перевести", systemImage: "translate") }
                            .buttonStyle(.plain).keyboardShortcut("t")
                    }
                }
                if existing != nil {
                    Button(role: .destructive) { onDelete() } label: { Label("Удалить хайлайт", systemImage: "trash") }
                        .buttonStyle(.plain).foregroundStyle(.red)
                }
            }
        }
        .padding(12)
        // с переводом — постоянная ширина: всплывающее окно не растёт вширь после открытия
        .frame(minWidth: 220, idealWidth: translateTo != nil ? 300 : nil, alignment: .leading)
        .frame(width: translateTo != nil ? 300 : nil, alignment: .leading)
    }
}

enum Pasteboard {
    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// Строка в панели «Заметки»: цветная полоса, выделенный текст, заметка, место в книге.
struct NoteRow: View {
    let annotation: Annotation
    let location: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(annotation.style.color).frame(width: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(annotation.text).font(.system(size: 12, design: .serif)).lineLimit(3)
                    .underline(annotation.style == .underline, color: annotation.style.color)
                if let n = annotation.note, !n.isEmpty {
                    Text(n).font(.system(size: 11)).italic().foregroundStyle(.secondary).lineLimit(3)
                }
                Text(location + " · " + annotation.modified.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}
