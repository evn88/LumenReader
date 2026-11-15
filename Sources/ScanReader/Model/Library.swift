import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

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
    var importedFrom: String?
    var importedAt: Date?
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

enum BookKind: String, Hashable {
    case pdf, epub, scans, image
}

struct LibraryBook: Identifiable, Hashable {
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

/// Папка библиотеки (лучше общая папка iCloud Drive): книги, их обложки и метаданные.
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var folder: URL?
    @Published private(set) var books: [LibraryBook] = []
    @Published private(set) var collections: [String] = []
    @Published private(set) var covers: [String: NSImage] = [:]
    @Published private(set) var scanning = false

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
        refresh()
        watch()
    }

    var libraryFile: URL? { folder?.appendingPathComponent(".scanreader/library.json") }

    // MARK: - содержимое папки

    func refresh() {
        guard let folder else { return }
        scanning = true
        Task.detached(priority: .utility) {
            let found = Self.scan(folder)
            var extra: [String] = []
            if let data = SyncedFile.read(folder.appendingPathComponent(".scanreader/library.json")),
               let list = try? JSONDecoder().decode([String].self, from: data) { extra = list }
            await MainActor.run {
                guard folder == self.folder else { return }
                self.books = found
                self.collections = Array(Set(found.flatMap(\.collections) + extra)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                self.scanning = false
            }
        }
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

    nonisolated static func scan(_ folder: URL) -> [LibraryBook] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        return items.compactMap { url -> LibraryBook? in
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
            return LibraryBook(url: url, kind: kind, title: title!, author: author, collections: meta.collections ?? [],
                               progress: meta.progress, lastOpened: meta.lastOpened, added: added, recognized: recognized)
        }
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

    /// Копирование файлов в папку библиотеки (диалог «Файлы…» и перетаскивание).
    func importFiles(_ urls: [URL]) {
        guard let folder else { return }
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            for src in urls where Self.kind(of: src) != nil && src.deletingLastPathComponent() != folder {
                var dst = folder.appendingPathComponent(src.lastPathComponent)
                var n = 2
                while fm.fileExists(atPath: dst.path) {
                    dst = folder.appendingPathComponent("\(src.deletingPathExtension().lastPathComponent) \(n)")
                        .appendingPathExtension(src.pathExtension); n += 1
                }
                var err: NSError?
                NSFileCoordinator().coordinate(writingItemAt: dst, options: .forReplacing, error: &err) { url in
                    try? fm.copyItem(at: src, to: url)
                }
            }
            await MainActor.run { self.refresh() }
        }
    }
}
