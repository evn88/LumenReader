import AppKit
import Foundation
import SwiftUI

/// Стиль хайлайта — как в Apple Books.
enum HighlightStyle: String, Codable, CaseIterable, Identifiable {
    case yellow, green, blue, pink, purple, underline
    var id: String { rawValue }

    var title: String {
        switch self {
        case .yellow: return "Жёлтый"
        case .green: return "Зелёный"
        case .blue: return "Синий"
        case .pink: return "Розовый"
        case .purple: return "Фиолетовый"
        case .underline: return "Подчёркивание"
        }
    }

    /// Цвет маркера (для подчёркивания — цвет линии).
    var rgb: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .yellow: return (1.00, 0.84, 0.20)
        case .green: return (0.55, 0.85, 0.40)
        case .blue: return (0.45, 0.70, 1.00)
        case .pink: return (1.00, 0.50, 0.68)
        case .purple: return (0.72, 0.55, 0.95)
        case .underline: return (0.93, 0.35, 0.25)
        }
    }

    var color: Color { Color(red: rgb.0, green: rgb.1, blue: rgb.2) }

    /// CSS для EPUB (в тёмной теме — плотнее).
    func css(dark: Bool) -> String {
        let (r, g, b) = rgb
        let c = "rgba(\(Int(r * 255)), \(Int(g * 255)), \(Int(b * 255)), \(dark ? 0.45 : 0.42))"
        return self == .underline
            ? "background: transparent !important; border-bottom: 2px solid rgb(\(Int(r * 255)), \(Int(g * 255)), \(Int(b * 255)));"
            : "background: \(c) !important; border-radius: 2px;"
    }
}

/// Привязка хайлайта к тексту книги.
enum AnnotationAnchor: Codable, Hashable {
    /// Скан: страница и сквозные номера слов (Word.gid, порядок allLines), включительно.
    case scan(page: Int, start: Int, end: Int)
    /// EPUB: путь главы в пакете и смещения символов в textContent тела главы.
    case epub(chapter: String, start: Int, end: Int)

    var sortKey: (String, Int, Int) {
        switch self {
        case .scan(let p, let s, _): return (String(format: "%08d", p), s, 0)
        case .epub(let c, let s, _): return (c, s, 0)
        }
    }

    func overlaps(_ o: AnnotationAnchor) -> Bool {
        switch (self, o) {
        case let (.scan(p1, s1, e1), .scan(p2, s2, e2)): return p1 == p2 && s1 <= e2 && s2 <= e1
        case let (.epub(c1, s1, e1), .epub(c2, s2, e2)): return c1 == c2 && s1 < e2 && s2 < e1
        default: return false
        }
    }
}

struct Annotation: Codable, Identifiable, Equatable {
    var id = UUID()
    var style: HighlightStyle
    var note: String?
    /// Выделенный текст (для списка «Заметки» и поиска).
    var text: String
    var anchor: AnnotationAnchor
    var created = Date()
    /// Время последней правки — побеждает при слиянии с другим устройством.
    var modified = Date()
    /// Удалённый хайлайт остаётся «надгробием», чтобы удаление тоже синхронизировалось.
    var deleted = false
}

/// Слияние правок с нескольких устройств: объединение по id, при конфликте — последняя правка.
enum AnnotationMerge {
    static func merge(_ a: [Annotation], _ b: [Annotation]) -> [Annotation] {
        var byId: [UUID: Annotation] = [:]
        for x in a + b {
            if let y = byId[x.id] {
                // при равном времени удаление побеждает (иначе «воскресает» удалённое)
                if x.modified > y.modified || (x.modified == y.modified && x.deleted && !y.deleted) { byId[x.id] = x }
            } else {
                byId[x.id] = x
            }
        }
        return byId.values.sorted { $0.anchor.sortKey < $1.anchor.sortKey }
    }
}

/// Файл хайлайтов рядом с книгой: `.scanreader/<книга>/annotations.json`.
/// Чтение и запись через NSFileCoordinator, атомарно; конфликтные версии iCloud сливаются и закрываются.
enum AnnotationFile {
    struct Payload: Codable { var version = 1; var items: [Annotation] }

    static func url(for book: URL) -> URL { Sidecar.dir(for: book).appendingPathComponent("annotations.json") }

    static func decode(_ data: Data) -> [Annotation] {
        (try? Sidecar.decoder.decode(Payload.self, from: data))?.items ?? []
    }

    /// Текущее содержимое + все неразрешённые конфликтные версии (две учётки правили одновременно).
    static func read(_ book: URL) -> [Annotation] {
        let u = url(for: book)
        var items = SyncedFile.read(u).map(decode) ?? []
        for v in NSFileVersion.unresolvedConflictVersionsOfItem(at: u) ?? [] {
            if let data = try? Data(contentsOf: v.url) { items = AnnotationMerge.merge(items, decode(data)) }
        }
        return items
    }

    /// Слить с тем, что уже на диске (могло прийти с другого устройства), и записать.
    @discardableResult
    static func save(_ items: [Annotation], book: URL) -> [Annotation] {
        let u = url(for: book)
        let merged = AnnotationMerge.merge(read(book), items)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Sidecar.encoder.encode(Payload(items: merged)) { SyncedFile.write(data, to: u) }
        // конфликтные версии учтены — закрываем их, чтобы iCloud не держал копии
        if let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: u), !conflicts.isEmpty {
            conflicts.forEach { $0.isResolved = true }
            try? NSFileVersion.removeOtherVersionsOfItem(at: u)
        }
        return merged
    }
}

/// Хайлайты одной книги.
@MainActor
final class AnnotationStore: ObservableObject {
    let book: URL
    @Published private(set) var all: [Annotation] = []

    var items: [Annotation] { all.filter { !$0.deleted } }

    init(book: URL) {
        self.book = book
        reload()
    }

    /// Перечитать (например, файл обновился с другого устройства).
    func reload() {
        let b = book
        all = AnnotationFile.read(b)
    }

    func items(page: Int) -> [Annotation] {
        items.filter { if case .scan(let p, _, _) = $0.anchor { return p == page }; return false }
    }

    func items(chapter: String) -> [Annotation] {
        items.filter { if case .epub(let c, _, _) = $0.anchor { return c == chapter }; return false }
    }

    /// Хайлайт, который перекрывает выделение (для «Удалить хайлайт» и смены цвета).
    func existing(overlapping a: AnnotationAnchor) -> Annotation? { items.first { $0.anchor.overlaps(a) } }

    @discardableResult
    func upsert(_ a: Annotation) -> Annotation {
        var a = a
        a.modified = Date()
        if let i = all.firstIndex(where: { $0.id == a.id }) { all[i] = a } else { all.append(a) }
        persist()
        return a
    }

    func delete(_ id: UUID) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].deleted = true
        all[i].modified = Date()
        persist()
    }

    private func persist() {
        let snapshot = all, b = book
        Task.detached(priority: .utility) {
            let merged = AnnotationFile.save(snapshot, book: b)
            await MainActor.run { [weak self] in
                guard let self else { return }
                // правки с другого устройства, пришедшие за время записи, тоже показываем
                self.all = AnnotationMerge.merge(self.all, merged)
            }
        }
    }
}
