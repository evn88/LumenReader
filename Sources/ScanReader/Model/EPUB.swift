import CryptoKit
import Foundation

/// EPUB 2/3: распаковка, OPF (метаданные, manifest, spine), оглавление (nav.xhtml / toc.ncx), обложка, DRM.
struct EPUBBook {
    struct Item { var id: String; var href: String; var mediaType: String; var properties: String }
    struct TOCEntry: Identifiable, Hashable {
        var id = UUID()
        var title: String
        var href: String          // относительно корня пакета, с #фрагментом
        var level: Int
    }

    let source: URL               // .epub (папка-пакет или zip)
    let root: URL                 // распакованный пакет
    let opfDir: URL
    var title: String
    var author: String?
    var language: String?
    var manifest: [String: Item] = [:]
    var spine: [URL] = []         // файлы глав в порядке чтения
    var toc: [TOCEntry] = []
    var coverURL: URL?

    enum Failure: LocalizedError {
        case unreadable, drm
        var errorDescription: String? {
            switch self {
            case .unreadable: return "Не удалось прочитать EPUB"
            case .drm: return "Книга защищена DRM"
            }
        }
    }

    /// Папка распаковки zip-EPUB (кеш, по хешу пути и даты изменения).
    private static let unpackLock = NSLock()

    static func unpackedRoot(_ url: URL) throws -> URL {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue { return url }             // Apple Books хранит EPUB распакованными
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        let key = SHA256.hash(data: Data("\(url.path)|\(mtime.timeIntervalSince1970)".utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(Product.dataFolder)/epub/\(key)", isDirectory: true)
        // одновременно распаковывать могут библиотека, обложка и читалка: по очереди и атомарно
        // (во временную папку, затем rename) — недораспакованный пакет никто не увидит
        unpackLock.lock(); defer { unpackLock.unlock() }
        if FileManager.default.fileExists(atPath: cache.appendingPathComponent("META-INF/container.xml").path) { return cache }
        let tmp = cache.deletingLastPathComponent().appendingPathComponent(".\(key)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", url.path, tmp.path]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure.unreadable }
        try? FileManager.default.removeItem(at: cache)
        try FileManager.default.moveItem(at: tmp, to: cache)
        return cache
    }

    init(_ url: URL) throws {
        source = url
        root = try Self.unpackedRoot(url)
        let fm = FileManager.default
        // DRM: FairPlay (sinf.xml) или зашифрованное содержимое (encryption.xml, кроме обфускации шрифтов)
        if fm.fileExists(atPath: root.appendingPathComponent("META-INF/sinf.xml").path) { throw Failure.drm }
        if let enc = try? String(contentsOf: root.appendingPathComponent("META-INF/encryption.xml"), encoding: .utf8) {
            let algorithms = Self.matches(#"Algorithm="([^"]+)""#, enc)
            let obfuscation = ["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"]
            if algorithms.contains(where: { !obfuscation.contains($0) }) { throw Failure.drm }
        }
        guard let container = try? String(contentsOf: root.appendingPathComponent("META-INF/container.xml"), encoding: .utf8),
              let opfPath = Self.matches(#"full-path="([^"]+)""#, container).first else { throw Failure.unreadable }
        let opfURL = root.appendingPathComponent(opfPath)
        opfDir = opfURL.deletingLastPathComponent()
        guard let opf = try? String(contentsOf: opfURL, encoding: .utf8) else { throw Failure.unreadable }

        title = Self.matches(#"<dc:title[^>]*>([^<]+)</dc:title>"#, opf).first.map(Self.unescape) ?? url.deletingPathExtension().lastPathComponent
        author = Self.matches(#"<dc:creator[^>]*>([^<]+)</dc:creator>"#, opf).first.map(Self.unescape)
        language = Self.matches(#"<dc:language[^>]*>([^<]+)</dc:language>"#, opf).first

        for tag in Self.matches(#"(<item\s[^>]*>)"#, opf) {
            func attr(_ n: String) -> String { Self.matches(#"\b"# + n + #"="([^"]*)""#, tag).first ?? "" }
            let item = Item(id: attr("id"), href: attr("href").removingPercentEncoding ?? attr("href"),
                            mediaType: attr("media-type"), properties: attr("properties"))
            manifest[item.id] = item
        }
        spine = Self.matches(#"<itemref\s[^>]*idref="([^"]+)""#, opf).compactMap { manifest[$0] }
            .map { opfDir.appendingPathComponent($0.href) }

        // обложка: EPUB3 properties="cover-image", EPUB2 <meta name="cover" content="id">, иначе картинка с "cover" в имени
        if let c = manifest.values.first(where: { $0.properties.contains("cover-image") }) {
            coverURL = opfDir.appendingPathComponent(c.href)
        } else if let id = Self.matches(#"<meta\s[^>]*name="cover"[^>]*content="([^"]+)""#, opf).first
                    ?? Self.matches(#"<meta\s[^>]*content="([^"]+)"[^>]*name="cover""#, opf).first, let c = manifest[id] {
            coverURL = opfDir.appendingPathComponent(c.href)
        } else if let c = manifest.values.first(where: { $0.mediaType.hasPrefix("image/") && $0.href.lowercased().contains("cover") }) {
            coverURL = opfDir.appendingPathComponent(c.href)
        }

        // оглавление: EPUB3 nav, иначе NCX
        if let nav = manifest.values.first(where: { $0.properties.split(separator: " ").contains("nav") }) {
            let navURL = opfDir.appendingPathComponent(nav.href)
            if let html = try? String(contentsOf: navURL, encoding: .utf8) { toc = Self.parseNav(html, base: navURL, root: root) }
        }
        if toc.isEmpty, let ncx = manifest.values.first(where: { $0.mediaType == "application/x-dtbncx+xml" }) {
            let ncxURL = opfDir.appendingPathComponent(ncx.href)
            if let xml = try? String(contentsOf: ncxURL, encoding: .utf8) { toc = Self.parseNCX(xml, base: ncxURL, root: root) }
        }
    }

    /// Путь относительно корня пакета (для WKWebView и оглавления).
    func relative(_ url: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
    }

    // MARK: - разбор

    private static func parseNav(_ html: String, base: URL, root: URL) -> [TOCEntry] {
        // только <nav epub:type="toc">; уровень — глубина вложенности <ol>
        let navPart = matches(#"(?s)<nav[^>]*epub:type="toc"[^>]*>(.*?)</nav>"#, html).first ?? html
        var out: [TOCEntry] = []
        var level = 0
        guard let re = try? NSRegularExpression(pattern: #"(?s)(<ol[^>]*>)|(</ol>)|<a[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#) else { return [] }
        let ns = navPart as NSString
        for m in re.matches(in: navPart, range: NSRange(location: 0, length: ns.length)) {
            if m.range(at: 1).location != NSNotFound { level += 1; continue }
            if m.range(at: 2).location != NSNotFound { level -= 1; continue }
            let href = ns.substring(with: m.range(at: 3))
            let text = ns.substring(with: m.range(at: 4)).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            out.append(TOCEntry(title: unescape(text).trimmingCharacters(in: .whitespacesAndNewlines),
                                href: resolve(href, base: base, root: root), level: max(0, level - 1)))
        }
        return out.filter { !$0.title.isEmpty }
    }

    private static func parseNCX(_ xml: String, base: URL, root: URL) -> [TOCEntry] {
        var out: [TOCEntry] = []
        var level = 0
        guard let re = try? NSRegularExpression(pattern: #"(?s)(<navPoint[^>]*>)|(</navPoint>)|<text>(.*?)</text>|<content[^>]*src="([^"]+)""#) else { return [] }
        let ns = xml as NSString
        var pendingTitle: String?
        for m in re.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            if m.range(at: 1).location != NSNotFound { level += 1; continue }
            if m.range(at: 2).location != NSNotFound { level -= 1; continue }
            if m.range(at: 3).location != NSNotFound { pendingTitle = unescape(ns.substring(with: m.range(at: 3))); continue }
            if m.range(at: 4).location != NSNotFound, let t = pendingTitle {
                out.append(TOCEntry(title: t.trimmingCharacters(in: .whitespacesAndNewlines),
                                    href: resolve(ns.substring(with: m.range(at: 4)), base: base, root: root), level: max(0, level - 1)))
                pendingTitle = nil
            }
        }
        return out
    }

    private static func resolve(_ href: String, base: URL, root: URL) -> String {
        // «#» и «#id» дают пустую часть: split по умолчанию её выбрасывает → падение на parts[0]
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let file = (parts[0].removingPercentEncoding ?? parts[0])
        let url = file.isEmpty ? base : base.deletingLastPathComponent().appendingPathComponent(file)
        let rel = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
        return parts.count > 1 ? rel + "#" + parts[1] : rel
    }

    static func matches(_ pattern: String, _ s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 && $0.range(at: 1).location != NSNotFound ? ns.substring(with: $0.range(at: 1)) : nil
        }
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&apos;", with: "'")
    }
}
