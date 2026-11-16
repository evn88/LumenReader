import AppKit
import Foundation
import PDFKit
import OSLog
import UniformTypeIdentifiers

let libraryLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "io.github.evn88.lumenreader", category: "library")

/// Позиция чтения: страница скана/PDF или глава EPUB + доля внутри неё.
struct ReadingPosition: Codable, Equatable {
    var page: Int?
    var chapter: Int?
    var fraction: Double?
}

/// Метаданные книги рядом с файлом: `.scanreader/<файл>/meta.json` (синхронизируются вместе с книгой).
struct BookMeta: Codable, Equatable {
    var title: String?
    var author: String?
    var collections: [String]?
    var progress: Double?
    var position: ReadingPosition?
    var bookmarks: [Int]?
    var lastOpened: Date?
    /// Страницы, показываемые сканом вместо распознанного текста (выбор читателя).
    var pagesShowOriginal: [Int]?
    /// Ненадёжно распознанные страницы, на которых читатель всё же выбрал текст.
    var pagesForceText: [Int]?
    /// Страницы, на которых читатель выключил улучшение скана (по умолчанию оно включено).
    var pagesNoScanEnhance: [Int]?
    /// Фоновое распознавание книги остановлено читателем.
    var recognitionPaused: Bool?
    var importedFrom: String?
    var importedAt: Date?
    /// Перевод: язык, показ перевода, фоновый перевод всей книги.
    var translation: TranslationMeta?
}

enum Sidecar {
    /// Та же папка, что у кеша распознавания (LayoutCache).
    static func dir(for book: URL) -> URL {
        book.deletingLastPathComponent().appendingPathComponent(".scanreader/\(book.lastPathComponent)", isDirectory: true)
    }

    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()

    static func meta(_ book: URL) -> BookMeta {
        guard let data = SyncedFile.read(dir(for: book).appendingPathComponent("meta.json")),
              let m = try? decoder.decode(BookMeta.self, from: data) else { return BookMeta() }
        return m
    }

    static func update(_ book: URL, _ change: (inout BookMeta) -> Void) {
        var m = meta(book)
        change(&m)
        try? FileManager.default.createDirectory(at: dir(for: book), withIntermediateDirectories: true)
        if let data = try? encoder.encode(m) { SyncedFile.write(data, to: dir(for: book).appendingPathComponent("meta.json")) }
    }
}

enum BookKind: String, Hashable, Codable {
    case pdf, epub, scans, image
}

struct LibraryBook: Identifiable, Hashable, Codable {
    var id: String { url.lastPathComponent }
    var url: URL
    var kind: BookKind
    var title: String
    var author: String?
    var collections: [String]
    var progress: Double?
    var lastOpened: Date?
    var added: Date
    /// Есть распознанные страницы (кеш раскладок) — книга-скан.
    var recognized: Bool

    var isNew: Bool { lastOpened == nil && (progress ?? 0) == 0 }
    var finished: Bool { (progress ?? 0) >= 0.98 }
}

/// Отметки изменений книги: пока они те же, книгу при обновлении полки не перечитываем
/// (без открытия PDF/EPUB и координированного чтения meta.json — их сотни).
struct LibraryStamp: Codable, Equatable {
    var file: Date?
    var sidecar: Date?
    var meta: Date?
}

struct LibraryEntry: Codable {
    var book: LibraryBook
    var stamp: LibraryStamp
}

/// Снимок полки на диске этого Mac: при запуске книги видны сразу, пока папка перечитывается.
enum LibrarySnapshot {
    static func file(for folder: URL) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let key = folder.standardizedFileURL.path.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return base.appendingPathComponent("\(Product.dataFolder)/library-\(String(key, radix: 16)).json")
    }

    static func load(_ folder: URL) -> [LibraryEntry] {
        guard let data = try? Data(contentsOf: file(for: folder)) else { return [] }
        return (try? Sidecar.decoder.decode([LibraryEntry].self, from: data)) ?? []
    }

    static func save(_ entries: [LibraryEntry], for folder: URL) {
        let url = file(for: folder)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Sidecar.encoder.encode(entries) { try? data.write(to: url, options: .atomic) }
    }
}

/// Папка библиотеки (лучше общая папка iCloud Drive): книги, их обложки и метаданные.
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var folder: URL?
    @Published private(set) var books: [LibraryBook] = []
    @Published private(set) var collections: [String] = []
    @Published private(set) var covers: [String: NSImage] = [:]
    @Published private(set) var scanning = false
    /// Папка хоть раз прочитана с открытия (до этого пустая полка — ещё не «пустая библиотека»).
    @Published private(set) var loaded = false
    /// Прочитанные книги с отметками изменений: следующее обновление перечитывает только изменённые.
    private var entries: [String: LibraryEntry] = [:]
    private var refreshing = false
    private var refreshAgain = false

    private static let bookmarkKey = "libraryBookmark"
    private var watcher: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var coverJobs: Set<String> = []
    private var pendingReading: [URL: (Double, ReadingPosition)] = [:]
    private var readingTask: Task<Void, Never>?

    init() {
        // разработка: ScanReader --library <папка> — папка только на этот запуск, без сохранения
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--library"), args.count > i + 1 {
            open(URL(fileURLWithPath: args[i + 1]), remember: false)
            return
        }
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }
        var stale = false
        let url = (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale))
        if let url { open(url, remember: stale) }
    }

    /// Выбор папки: запоминаем security-scoped закладкой (переживает переименования и перезапуски).
    func open(_ url: URL, remember: Bool = true) {
        _ = url.startAccessingSecurityScopedResource()
        if remember {
            let data = (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
                ?? (try? url.bookmarkData())
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        }
        folder = url
        covers = [:]; coverJobs = []
        // снимок полки с прошлого запуска — мгновенно; папка перечитывается следом
        let snapshot = LibrarySnapshot.load(url)
        entries = Dictionary(snapshot.map { ($0.book.id, $0) }, uniquingKeysWith: { a, _ in a })
        books = snapshot.map(\.book)
        collections = Self.collectionNames(books, extra: [])
        loaded = !snapshot.isEmpty
        refresh()
        watch()
    }

    var libraryFile: URL? { folder?.appendingPathComponent(".scanreader/library.json") }

    // MARK: - содержимое папки

    func refresh() {
        guard let folder else { return }
        // обновления не накладываются: пока идёт одно, следующее только запоминается
        guard !refreshing else { refreshAgain = true; return }
        refreshing = true
        scanning = true
        let previous = entries
        Task.detached(priority: books.isEmpty ? .userInitiated : .utility) {
            let t0 = Date()
            let found = Self.scan(folder, previous: previous)
            let extra: [String] = SyncedFile.read(folder.appendingPathComponent(".scanreader/library.json"))
                .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            LibrarySnapshot.save(found, for: folder)
            libraryLog.info("полка: \(found.count) книг за \(String(format: "%.2f", Date().timeIntervalSince(t0)), privacy: .public) с")
            await MainActor.run {
                self.refreshing = false
                guard folder == self.folder else { return }
                self.entries = Dictionary(found.map { ($0.book.id, $0) }, uniquingKeysWith: { a, _ in a })
                let list = found.map(\.book)
                if list != self.books { self.books = list }
                let names = Self.collectionNames(list, extra: extra)
                if names != self.collections { self.collections = names }
                self.scanning = false
                self.loaded = true
                if self.refreshAgain { self.refreshAgain = false; self.refresh() }
            }
        }
    }

    nonisolated static func collectionNames(_ books: [LibraryBook], extra: [String]) -> [String] {
        Array(Set(books.flatMap(\.collections) + extra)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    nonisolated static func kind(of url: URL) -> BookKind? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if ext == "epub" { return .epub }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            return files.contains { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true } ? .scans : nil
        }
        return UTType(filenameExtension: ext)?.conforms(to: .image) == true ? .image : nil
    }

    nonisolated static func scan(_ folder: URL) -> [LibraryBook] { scan(folder, previous: [:]).map(\.book) }

    /// Отметки изменений книги: сам файл, папка sidecar (появились раскладки) и meta.json.
    nonisolated static func stamp(_ url: URL) -> LibraryStamp {
        let fm = FileManager.default
        func date(_ u: URL) -> Date? { (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date }
        let side = Sidecar.dir(for: url)
        return LibraryStamp(file: date(url), sidecar: date(side), meta: date(side.appendingPathComponent("meta.json")))
    }

    /// Книги папки. Неизменившиеся (те же отметки) берутся из previous, остальные читаются параллельно.
    nonisolated static func scan(_ folder: URL, previous: [String: LibraryEntry]) -> [LibraryEntry] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        var results = [LibraryEntry?](repeating: nil, count: items.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: items.count) { idx in
            let url = items[idx]
            let st = stamp(url)
            let entry: LibraryEntry?
            if let old = previous[url.lastPathComponent], old.stamp == st, old.book.url == url {
                entry = old
            } else {
                entry = readBook(url).map { LibraryEntry(book: $0, stamp: st) }
            }
            lock.lock(); results[idx] = entry; lock.unlock()
        }
        return results.compactMap { $0 }
    }

    nonisolated static func readBook(_ url: URL) -> LibraryBook? {
        let fm = FileManager.default
        guard let kind = kind(of: url) else { return nil }
        let meta = Sidecar.meta(url)
        var title = meta.title, author = meta.author
        if title == nil {
            switch kind {
            case .epub:
                if let e = try? EPUBBook(url) { title = e.title; author = author ?? e.author }
            case .pdf:
                if let d = PDFDocument(url: url) {
                    title = d.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
                    author = author ?? d.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String
                }
            default: break
            }
            if title?.isEmpty ?? true { title = url.deletingPathExtension().lastPathComponent }
        }
        let side = Sidecar.dir(for: url)
        let recognized = ((try? fm.contentsOfDirectory(atPath: side.path)) ?? []).contains { $0.hasPrefix("layouts-") }
        let added = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
        let resolved = BookMetadata.resolve(title: title, author: author, fileName: url.deletingPathExtension().lastPathComponent)
        return LibraryBook(url: url, kind: kind, title: resolved.title, author: resolved.author, collections: meta.collections ?? [],
                           progress: meta.progress, lastOpened: meta.lastOpened, added: added, recognized: recognized)
    }

    /// Слежение за папкой: книги, добавленные на другом устройстве (iCloud), появляются сами.
    private func watch() {
        watcher?.cancel(); timer?.invalidate()
        guard let folder else { return }
        let fd = Foundation.open(folder.path, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            src.setEventHandler { [weak self] in self?.refresh() }
            src.setCancelHandler { close(fd) }
            src.resume()
            watcher = src
        }
        // meta.json (прогресс, коллекции) меняется глубже — периодическая сверка
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: - обложки

    /// Обложка: из кеша `.scanreader/<книга>/cover.jpg`, иначе строим (EPUB — cover из OPF, PDF/сканы — 1-я страница).
    func cover(for book: LibraryBook) -> NSImage? {
        if let c = covers[book.id] { return c }
        guard !coverJobs.contains(book.id) else { return nil }
        coverJobs.insert(book.id)
        Task.detached(priority: .utility) {
            let image = Self.loadOrMakeCover(book)
            await MainActor.run {
                if let image { self.covers[book.id] = image }
            }
        }
        return nil
    }

    nonisolated static func loadOrMakeCover(_ book: LibraryBook) -> NSImage? {
        let file = Sidecar.dir(for: book.url).appendingPathComponent("cover.jpg")
        if let data = SyncedFile.read(file), let img = NSImage(data: data) { return img }
        var cg: CGImage?
        switch book.kind {
        case .epub:
            if let e = try? EPUBBook(book.url), let c = e.coverURL { cg = thumbnail(c) }
        case .pdf:
            if let page = PDFDocument(url: book.url)?.page(at: 0) {
                cg = page.thumbnail(of: NSSize(width: 400, height: 560), for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
        case .scans:
            let files = ((try? FileManager.default.contentsOfDirectory(at: book.url, includingPropertiesForKeys: nil)) ?? [])
                .filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            if let f = files.first { cg = thumbnail(f) }
        case .image:
            cg = thumbnail(book.url)
        }
        guard let cg else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        if let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            SyncedFile.write(jpg, to: file)
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    nonisolated static func thumbnail(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 600] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts)
    }

    // MARK: - коллекции и метаданные

    func addCollection(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !collections.contains(n), let file = libraryFile else { return }
        collections.append(n)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var list: [String] = []
        if let data = SyncedFile.read(file), let l = try? JSONDecoder().decode([String].self, from: data) { list = l }
        list.append(n)
        if let data = try? JSONEncoder().encode(list) { SyncedFile.write(data, to: file) }
    }

    func toggle(_ book: LibraryBook, in collection: String) {
        Sidecar.update(book.url) { m in
            var c = m.collections ?? []
            if let i = c.firstIndex(of: collection) { c.remove(at: i) } else { c.append(collection) }
            m.collections = c
        }
        refresh()
    }

    /// Прогресс и позиция из читалки.
    func recordReading(_ url: URL, progress: Double, position: ReadingPosition) {
        // запись в meta.json — с задержкой и не на главном потоке: при листании пишем только последнюю позицию
        pendingReading[url] = (progress, position)
        readingTask?.cancel()
        readingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            let batch = self.pendingReading
            self.pendingReading = [:]
            await Task.detached(priority: .utility) {
                for (u, r) in batch {
                    Sidecar.update(u) { m in
                        m.progress = min(1, max(0, r.0)); m.position = r.1; m.lastOpened = Date()
                    }
                }
            }.value
        }
        if let i = books.firstIndex(where: { $0.url == url }) {
            books[i].progress = progress; books[i].lastOpened = Date()
        }
    }

    // MARK: - импорт файлов

    /// Идёт импорт: сколько скопировано из скольких (индикатор в окне библиотеки).
    @Published private(set) var importProgress: (done: Int, total: Int)?

    /// Что из перетаскиваемого можно добавить: PDF, EPUB, картинки, папки со сканами
    /// (в том числе ещё не скачанные из iCloud — «.имя.pdf.icloud»).
    nonisolated static func importable(_ urls: [URL]) -> [URL] {
        urls.compactMap { u -> URL? in
            let real = iCloudPlaceholderTarget(u) ?? u
            return kind(of: real) != nil || ["pdf", "epub"].contains(real.pathExtension.lowercased()) ? real : nil
        }
    }

    /// «.Книга.pdf.icloud» (не скачанный файл iCloud) → «Книга.pdf» рядом.
    nonisolated static func iCloudPlaceholderTarget(_ u: URL) -> URL? {
        let n = u.lastPathComponent
        guard n.hasPrefix("."), n.hasSuffix(".icloud") else { return nil }
        return u.deletingLastPathComponent().appendingPathComponent(String(n.dropFirst().dropLast(7)))
    }

    /// Тот же файл уже в библиотеке: одинаковые размер и начало содержимого (имя может отличаться).
    nonisolated static func isDuplicate(_ src: URL, in folder: URL) -> Bool {
        let fm = FileManager.default
        let size = { (u: URL) -> Int64? in (try? fm.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? nil }
        var isDir: ObjCBool = false
        fm.fileExists(atPath: src.path, isDirectory: &isDir)
        let existing = folder.appendingPathComponent(src.lastPathComponent)
        if isDir.boolValue { return fm.fileExists(atPath: existing.path) }
        guard let s = size(src) else { return false }
        let head = { (u: URL) -> Data? in (try? FileHandle(forReadingFrom: u)).flatMap { h in defer { try? h.close() }; return try? h.read(upToCount: 65_536) } }
        let srcHead = head(src)
        for f in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        where f.pathExtension.lowercased() == src.pathExtension.lowercased() && size(f) == s {
            if head(f) == srcHead { return true }
        }
        return false
    }

    /// Копирование файлов в папку библиотеки (диалог «Файлы…» и перетаскивание).
    /// Дубликаты пропускаются; не скачанные из iCloud файлы сначала скачиваются (координированное чтение).
    /// collection — сразу добавить новые книги в коллекцию (сброс на коллекцию в сайдбаре).
    func importFiles(_ urls: [URL], collection: String? = nil) {
        guard let folder else { return }
        let items = Self.importable(urls).filter { $0.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL }
        guard !items.isEmpty else { return }
        importProgress = (0, items.count)
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var done = 0
            for src in items {
                defer { done += 1; let d = done; Task { @MainActor in self.importProgress = (d, items.count) } }
                try? fm.startDownloadingUbiquitousItem(at: src)
                var copied: URL?
                var readErr: NSError?
                // координированное чтение ждёт, пока iCloud докачает файл
                NSFileCoordinator().coordinate(readingItemAt: src, options: [], error: &readErr) { readable in
                    if Self.isDuplicate(readable, in: folder) { return }
                    var dst = folder.appendingPathComponent(src.lastPathComponent)
                    var n = 2
                    while fm.fileExists(atPath: dst.path) {
                        dst = folder.appendingPathComponent("\(src.deletingPathExtension().lastPathComponent) \(n)")
                            .appendingPathExtension(src.pathExtension); n += 1
                    }
                    var err: NSError?
                    NSFileCoordinator().coordinate(writingItemAt: dst, options: .forReplacing, error: &err) { url in
                        if (try? fm.copyItem(at: readable, to: url)) != nil { copied = dst }
                    }
                }
                if let copied, let collection {
                    Sidecar.update(copied) { m in
                        var c = m.collections ?? []
                        if !c.contains(collection) { c.append(collection) }
                        m.collections = c
                    }
                }
            }
            await MainActor.run {
                self.importProgress = nil
                self.refresh()
            }
        }
    }
}
