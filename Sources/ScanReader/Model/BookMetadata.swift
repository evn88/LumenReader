import Foundation

/// Нормализация названия и автора из разных источников (Apple Books, PDF, EPUB, имя файла).
enum BookMetadata {
    /// Заглушки «автор неизвестен»: Apple Books пишет «UnknownAuthor», PDF/EPUB — «Unknown», «unknown» и т. п.
    private static let placeholders: Set<String> = [
        "unknownauthor", "unknown author", "unknown", "anonymous", "author", "неизвестный автор", "неизвестен",
        "автор неизвестен", "n/a", "na", "none", "null", "-", "—",
    ]

    /// Автор или nil: пустые строки, заглушки и служебные символы — это «нет автора».
    static func author(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != "\u{FFFD}" }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "⍰?")))
        guard !cleaned.isEmpty, !placeholders.contains(cleaned.lowercased()) else { return nil }
        return cleaned
    }

    /// «Автор - Название - Год» (или «Автор - Название») в имени файла → (автор, название).
    /// Только при явном разделителе « - »: имена вроде «JavaScript. Полное руководство» не трогаем.
    static func fromFileName(_ name: String) -> (author: String, title: String)? {
        let parts = name.components(separatedBy: " - ").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 || parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        if parts.count == 3 {
            // третья часть — год (2020, [2018], 2018 г.)
            let year = parts[2].filter(\.isNumber)
            guard year.count == 4, parts[2].count <= 9 else { return nil }
        }
        let author = parts[0], title = parts[1]
        // автор похож на имена: есть буквы, нет «лишних» слов книжного названия
        guard author.count <= 60, author.rangeOfCharacter(from: .letters) != nil, title.count >= 2 else { return nil }
        return (author, title)
    }

    /// Итог для карточки: автор из метаданных, иначе из имени файла; название — из имени файла, если оно же
    /// было просто именем файла.
    static func resolve(title: String?, author: String?, fileName: String) -> (title: String, author: String?) {
        var t = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if t?.isEmpty ?? true { t = nil }
        let a = Self.author(author)
        // название, совпадающее с именем файла (так его заводит Apple Books), — тоже «из имени файла»
        let fromFile = t == nil || t == fileName || t.map(cleanFileName) == cleanFileName(fileName)
        if a == nil, fromFile, let parsed = fromFileName(cleanFileName(fileName)) {
            return (parsed.title, parsed.author)
        }
        return (fromFile ? cleanFileName(fileName) : t!, a)
    }

    /// Имя файла как название: «_» → пробелы, лишние пробелы схлопнуты.
    static func cleanFileName(_ s: String) -> String {
        s.replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Название и автор книги по файлу — одна функция для библиотеки, окна книги, поиска и «Заметок».
    static func display(for url: URL, title: String? = nil, author: String? = nil) -> (title: String, author: String?) {
        let m = Sidecar.meta(url)
        return resolve(title: title ?? m.title, author: author ?? m.author, fileName: url.deletingPathExtension().lastPathComponent)
    }

    /// Текст для заголовков карточек: переносы только по словам (без «математи-ка»): внутри слов — word joiner.
    static func unbreakableWords(_ s: String) -> String {
        s.split(separator: " ", omittingEmptySubsequences: false)
            .map { $0.map(String.init).joined(separator: "\u{2060}") }
            .joined(separator: " ")
    }
}
