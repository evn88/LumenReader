import Foundation
import PDFKit
import SQLite3

/// Книга из библиотеки Apple Books.
struct AppleBooksItem: Codable, Equatable {
    var title: String
    var author: String?
    var kind: String                    // "pdf" | "epub"
    var sourcePath: String?             // файл/пакет на диске, если доступен
    var collections: [String] = []
    var progress: Double?               // 0…1 из ZREADINGPROGRESS
    var storeID: String?
    var drmReason: String?              // не nil — купленная книга с защитой, не импортируем

    var importable: Bool { drmReason == nil && sourcePath != nil }
}

struct AppleBooksScan {
    var items: [AppleBooksItem] = []
    var collections: [String] = []
    /// База BKLibrary прочитана (коллекции, прогресс, авторы).
    var libraryReadable = false
    /// Что не удалось прочитать и какое разрешение нужно.
    var notes: [String] = []

    var importable: [AppleBooksItem] { items.filter(\.importable) }
    var drm: [AppleBooksItem] { items.filter { $0.drmReason != nil } }
    var unavailable: [AppleBooksItem] { items.filter { $0.drmReason == nil && $0.sourcePath == nil } }
}

/// Импорт собственных PDF/EPUB из Apple Books. Источники только читаются.
/// Контейнеры Books защищены TCC: без «Полного доступа к диску» для ScanReader
/// (Системные настройки → Конфиденциальность и безопасность → Полный доступ к диску)
/// доступна лишь папка iCloud Books — без коллекций и прогресса.
enum AppleBooksImporter {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let libraryDir = home.appendingPathComponent("Library/Containers/com.apple.iBooksX/Data/Documents/BKLibrary")
    static let iCloudBooks = home.appendingPathComponent("Library/Mobile Documents/iCloud~com~apple~iBooks/Documents")
    static let localBooks = home.appendingPathComponent("Library/Containers/com.apple.BKAgentService/Data/Documents/iBooks/Books")

    static var fullDiskAccessHint: String { "нужен «Полный доступ к диску» для \(Product.name) (Системные настройки → Конфиденциальность и безопасность → Полный доступ к диску)" }

    static func scan() -> AppleBooksScan {
        var result = AppleBooksScan()
        let fm = FileManager.default

        // 1. база библиотеки: названия, авторы, пути, коллекции, прогресс
        var dbItems: [AppleBooksItem] = []
        do {
            let files = try fm.contentsOfDirectory(at: libraryDir, includingPropertiesForKeys: nil)
            if let db = files.first(where: { $0.lastPathComponent.hasPrefix("BKLibrary-") && $0.pathExtension == "sqlite" }) {
                (dbItems, result.collections) = readLibrary(db, notes: &result.notes)
                result.libraryReadable = true
            } else {
                result.notes.append("база BKLibrary-*.sqlite не найдена")
            }
        } catch {
            result.notes.append("база библиотеки Books недоступна: \(fullDiskAccessHint)")
        }

        // 2. файлы: папка iCloud Books и локальная папка Books
        var files: [URL] = []
        for dir in [iCloudBooks, localBooks] {
            do {
                files += try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                    .filter { ["pdf", "epub"].contains($0.pathExtension.lowercased()) }
            } catch {
                result.notes.append("папка \(dir.lastPathComponent == "Books" ? "локальных книг Books" : "iCloud Books") недоступна"
                                    + (dir == localBooks ? ": \(fullDiskAccessHint)" : ""))
            }
        }

        // 3. сопоставление: запись базы ↔ файл (по пути или имени файла)
        var used = Set<URL>()
        for var item in dbItems {
            let name = item.sourcePath.map { URL(fileURLWithPath: $0).lastPathComponent }
            if let f = files.first(where: { $0.path == item.sourcePath || $0.lastPathComponent == name }) {
                item.sourcePath = f.path; used.insert(f)
            } else {
                item.sourcePath = nil
            }
            if item.drmReason == nil, let p = item.sourcePath { item.drmReason = drmReason(URL(fileURLWithPath: p)) }
            result.items.append(item)
        }
        for f in files where !used.contains(f) {
            var item = metadata(f)
            item.drmReason = drmReason(f)
            result.items.append(item)
        }
        return result
    }

    // MARK: - база

    private static func readLibrary(_ url: URL, notes: inout [String]) -> ([AppleBooksItem], [String]) {
        var db: OpaquePointer?
        let uri = "file:\(url.path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            notes.append("не удалось открыть базу Books"); return ([], [])
        }
        defer { sqlite3_close(db) }

        func columns(_ table: String) -> Set<String> {
            Set(rows(db, "PRAGMA table_info(\(table))").compactMap { $0["name"] ?? nil })
        }
        let assetCols = columns("ZBKLIBRARYASSET")
        guard !assetCols.isEmpty else { notes.append("в базе нет таблицы ZBKLIBRARYASSET"); return ([], []) }
        func col(_ name: String) -> String { assetCols.contains(name) ? name : "NULL" }

        // коллекции: ZBKCOLLECTIONMEMBER.ZASSETID → ZBKCOLLECTION.ZTITLE
        var collectionsByAsset: [String: [String]] = [:]
        var collectionTitles: [String] = []
        if !columns("ZBKCOLLECTION").isEmpty, !columns("ZBKCOLLECTIONMEMBER").isEmpty {
            for r in rows(db, "SELECT Z_PK, ZTITLE FROM ZBKCOLLECTION WHERE ZTITLE IS NOT NULL") {
                if let t = r["ZTITLE"] ?? nil { collectionTitles.append(t) }
            }
            for r in rows(db, "SELECT m.ZASSETID AS A, c.ZTITLE AS T FROM ZBKCOLLECTIONMEMBER m JOIN ZBKCOLLECTION c ON m.ZCOLLECTION = c.Z_PK") {
                if let a = r["A"] ?? nil, let t = r["T"] ?? nil { collectionsByAsset[a, default: []].append(t) }
            }
        }

        let sql = """
            SELECT \(col("ZASSETID")) AS ID, \(col("ZTITLE")) AS TITLE, \(col("ZAUTHOR")) AS AUTHOR,
                   \(col("ZPATH")) AS PATH, \(col("ZSTOREID")) AS STORE, \(col("ZREADINGPROGRESS")) AS PROGRESS,
                   \(col("ZISPROOF")) AS PROOF
            FROM ZBKLIBRARYASSET
            """
        var items: [AppleBooksItem] = []
        for r in rows(db, sql) {
            let path = r["PATH"] ?? nil
            let ext = path.map { URL(fileURLWithPath: $0).pathExtension.lowercased() } ?? ""
            // аудиокниги и прочее, кроме PDF/EPUB, не берём
            guard ["pdf", "epub", ""].contains(ext) else { continue }
            let store = (r["STORE"] ?? nil).flatMap { $0.isEmpty || $0 == "0" ? nil : $0 }
            var item = AppleBooksItem(title: (r["TITLE"] ?? nil) ?? "Без названия", author: r["AUTHOR"] ?? nil,
                                      kind: ext.isEmpty ? "epub" : ext, sourcePath: path,
                                      collections: (r["ID"] ?? nil).flatMap { collectionsByAsset[$0] } ?? [],
                                      progress: (r["PROGRESS"] ?? nil).flatMap(Double.init), storeID: store)
            if store != nil { item.drmReason = "куплена в Book Store" }
            items.append(item)
        }
        return (items, collectionTitles)
    }

    private static func rows(_ db: OpaquePointer?, _ sql: String) -> [[String: String?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [[String: String?]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: String?] = [:]
            for i in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, i))
                row[name] = sqlite3_column_text(stmt, i).map { String(cString: $0) }
            }
            out.append(row)
        }
        return out
    }

    // MARK: - файлы

    /// Признаки покупки с DRM: sinf.xml (FairPlay) или iTunesMetadata.plist с данными покупки.
    static func drmReason(_ url: URL) -> String? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        fm.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            if fm.fileExists(atPath: url.appendingPathComponent("META-INF/sinf.xml").path) { return "FairPlay (sinf.xml)" }
            let meta = url.appendingPathComponent("iTunesMetadata.plist")
            if let d = NSDictionary(contentsOf: meta),
               d["purchaseDate"] != nil || d["itemId"] != nil || d["storeId"] != nil || d["com.apple.iTunesStore.downloadInfo"] != nil {
                return "покупка (iTunesMetadata)"
            }
        } else if url.pathExtension.lowercased() == "epub", let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            // упакованный EPUB: имена в центральном каталоге zip хранятся несжатыми
            if data.range(of: Data("META-INF/sinf.xml".utf8)) != nil { return "FairPlay (sinf.xml)" }
        }
        return nil
    }

    static func metadata(_ url: URL) -> AppleBooksItem {
        let ext = url.pathExtension.lowercased()
        var title = url.deletingPathExtension().lastPathComponent
        var author: String?
        if ext == "pdf", let doc = PDFDocument(url: url) {
            if let t = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, !t.isEmpty { title = t }
            author = doc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String
        } else if ext == "epub", let opf = opfURL(url), let xml = try? String(contentsOf: opf, encoding: .utf8) {
            if let t = firstMatch(#"<dc:title[^>]*>([^<]+)</dc:title>"#, xml) { title = t }
            author = firstMatch(#"<dc:creator[^>]*>([^<]+)</dc:creator>"#, xml)
        }
        return AppleBooksItem(title: title, author: author, kind: ext, sourcePath: url.path)
    }

    private static func opfURL(_ epub: URL) -> URL? {
        guard let c = try? String(contentsOf: epub.appendingPathComponent("META-INF/container.xml"), encoding: .utf8),
              let path = firstMatch(#"full-path="([^"]+)""#, c) else { return nil }
        return epub.appendingPathComponent(path)
    }

    private static func firstMatch(_ pattern: String, _ s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - импорт

    /// Копирует одну книгу в папку библиотеки; метаданные (название, автор, коллекции, прогресс) —
    /// в `.scanreader/<файл>/meta.json` рядом с ней (синхронизируются вместе с книгой).
    static func importOne(_ item: AppleBooksItem, to library: URL) -> Bool {
        guard item.importable, let path = item.sourcePath else { return false }
        let fm = FileManager.default
        let src = URL(fileURLWithPath: path)
        // «.NET in Action» или пустое название дали бы скрытый файл — библиотека его не увидит
        var safe = item.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        if safe.isEmpty { safe = "Без названия" }
        var dst = library.appendingPathComponent("\(safe).\(item.kind)")
        var n = 2
        while fm.fileExists(atPath: dst.path) { dst = library.appendingPathComponent("\(safe) \(n).\(item.kind)"); n += 1 }
        var err: NSError?
        var ok = false
        NSFileCoordinator().coordinate(writingItemAt: dst, options: .forReplacing, error: &err) { url in
            ok = (try? fm.copyItem(at: src, to: url)) != nil
        }
        guard ok else { return false }
        Sidecar.update(dst) { m in
            m.title = item.title; m.author = item.author; m.collections = item.collections
            m.progress = item.progress; m.importedFrom = "Apple Books"; m.importedAt = Date()
        }
        return true
    }

    static func importBooks(_ items: [AppleBooksItem], to library: URL) -> (copied: [String], failed: [String]) {
        var copied: [String] = [], failed: [String] = []
        for item in items where item.importable {
            if importOne(item, to: library) { copied.append(item.title) } else { failed.append(item.title) }
        }
        return (copied, failed)
    }
}
