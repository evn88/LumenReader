import Combine
import SwiftUI
import WebKit

/// Оформление EPUB из настроек читалки (тема, шрифт, масштаб, интервал, поля, выключка, разворот).
struct EPUBStyle: Equatable {
    var paper: String, ink: String, isDark: Bool
    var font: String?            // nil — издательский шрифт
    var size: Double             // px
    var lineHeight: Double
    var marginH: Double, marginV: Double
    var justify: Bool
    var columns: Int
    var lang: String

    /// JS-вызов, применяющий оформление и пересчитывающий разбивку.
    var js: String {
        let css = """
        html { background: \(paper) !important; height: 100vh; overflow: hidden; }
        body { color: \(ink) !important; background: \(paper) !important;
               margin: \(Int(marginV))px \(Int(marginH))px !important; padding: 0 !important;
               height: calc(100vh - \(Int(2 * marginV))px) !important; box-sizing: border-box;
               column-gap: \(Int(2 * marginH))px !important; column-fill: auto !important;
               font-size: \(Int(size))px !important; line-height: \(lineHeight) !important;
               \(font.map { "font-family: '\($0)', serif !important;" } ?? "")
               text-align: \(justify ? "justify" : "start") !important; hyphens: auto; -webkit-hyphens: auto;
               widows: 2; orphans: 2; }
        /* цвет текста — всегда темы (как в Apple Books): издательский CSS не должен давать чёрный текст на тёмном фоне */
        body *, a, a:link, a:visited { color: inherit !important; background-color: transparent !important; }
        \(font.map { "p, li, blockquote, dd, dt, td { font-family: '\($0)', serif !important; }" } ?? "")
        p, li, blockquote { font-size: inherit !important; line-height: inherit !important; }
        img, svg, video { max-width: 100% !important; max-height: calc(100vh - \(Int(2 * marginV + 30))px) !important;
                          object-fit: contain; break-inside: avoid; \(isDark ? "filter: brightness(0.88);" : "") }
        figure { break-inside: avoid; margin: 1em 0; text-align: center; }
        figcaption { font-size: 0.85em; opacity: 0.75; }
        /* заголовки как в Books: крупнее, с воздухом, без переносов */
        h1, h2, h3, h4, h5, h6 { break-after: avoid; hyphens: manual !important; -webkit-hyphens: manual !important;
                                 line-height: 1.25 !important; font-weight: normal; }
        h1 { font-size: 1.5em !important; margin: 1.2em 0 0.7em !important; }
        h2 { font-size: 1.35em !important; margin: 1.0em 0 0.55em !important; }
        h3 { font-size: 1.2em !important; margin: 0.9em 0 0.5em !important; }
        p { margin-top: 0; margin-bottom: 0.9em; }
        pre { white-space: pre-wrap !important; word-break: break-word; font-family: Menlo, monospace !important;
              font-size: 0.82em !important; line-height: 1.45 !important; text-align: left !important; hyphens: none;
              background: \(isDark ? "rgba(255,255,255,0.06)" : "rgba(0,0,0,0.045)") !important;
              border-radius: 8px; padding: 0.8em 1em; break-inside: auto; }
        code { font-family: Menlo, monospace !important; hyphens: none; }
        a { color: inherit; text-decoration-color: currentColor; }
        pre span.sr-k { color: \(isDark ? "#FF7AB2" : "#9B2393") !important; } pre span.sr-s { color: \(isDark ? "#FF8170" : "#C41A16") !important; }
        pre span.sr-c { color: \(isDark ? "#7F8C98" : "#5D6C79") !important; } pre span.sr-n { color: \(isDark ? "#D9C97C" : "#1C00CF") !important; }
        \(HighlightStyle.allCases.map { ".sr-hl.sr-\($0.rawValue) { \($0.css(dark: isDark)) }" }.joined(separator: " "))
        pre span.sr-t { color: \(isDark ? "#DABAFF" : "#3900A0") !important; } pre span.sr-f { color: \(isDark ? "#67B7A4" : "#326D74") !important; }
        """
        let escaped = css.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`")
        return "SR.apply(`\(escaped)`, \(columns), '\(lang)', \(Int(marginH)))"
    }
}

/// Скрипт в каждой главе: разбивка на страницы колонками, переход, подсветка кода, поиск.
private let epubScript = """
window.SR = {
  cols: 1, mh: 40,
  apply(css, cols, lang, mh) {
    let st = document.getElementById('sr-style');
    if (!st) { st = document.createElement('style'); st.id = 'sr-style'; document.head.appendChild(st); }
    st.textContent = css;
    if (!document.documentElement.lang) document.documentElement.lang = lang;
    this.cols = cols; this.mh = mh;
    const W = window.innerWidth;
    const colW = (W - 2*mh - (cols-1)*2*mh) / cols;
    document.body.style.setProperty('column-width', colW + 'px', 'important');
    document.body.style.setProperty('column-count', cols, 'important');
    this.highlight();
    return this.count();
  },
  count() {
    const W = window.innerWidth;
    const sw = document.documentElement.scrollWidth;
    return Math.max(1, Math.ceil((sw - 2) / W));
  },
  go(i) { document.documentElement.scrollLeft = i * window.innerWidth; document.body.scrollLeft = i * window.innerWidth; return i; },
  pageOfElement(el) {
    if (!el) return 0;
    const r = el.getBoundingClientRect();
    return Math.max(0, Math.floor((r.left + document.documentElement.scrollLeft) / window.innerWidth));
  },
  pageOfId(id) { return this.pageOfElement(document.getElementById(id)); },
  // --- выделение и хайлайты: смещения символов в тексте тела главы ---
  textNodes() { const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT); const a = []; let n; while ((n = w.nextNode())) a.push(n); return a; },
  offsetOf(node, off) { const r = document.createRange(); r.setStart(document.body, 0); r.setEnd(node, off); return r.toString().length; },
  posAt(o) { let acc = 0; for (const t of this.textNodes()) { if (acc + t.data.length >= o) return [t, o - acc]; acc += t.data.length; } return null; },
  rangeOf(s, e) { const a = this.posAt(s), b = this.posAt(e); if (!a || !b) return null; const r = document.createRange(); r.setStart(a[0], a[1]); r.setEnd(b[0], b[1]); return r; },
  pageOfOffset(o) { const r = this.rangeOf(o, o + 1); if (!r) return 0; const b = r.getBoundingClientRect(); return Math.max(0, Math.floor((b.left + document.documentElement.scrollLeft) / window.innerWidth)); },
  unpaint() { document.querySelectorAll('span.sr-hl').forEach(sp => { const p = sp.parentNode; while (sp.firstChild) p.insertBefore(sp.firstChild, sp); p.removeChild(sp); p.normalize(); }); },
  paint(list) {
    this.unpaint();
    for (const h of list) {
      const r = this.rangeOf(h.s, h.e); if (!r) continue;
      const nodes = this.textNodes().filter(t => r.intersectsNode(t));
      const sc = r.startContainer, so = r.startOffset, ec = r.endContainer, eo = r.endOffset;
      for (const t of nodes) {
        const s = (t === sc) ? so : 0, e = (t === ec) ? eo : t.data.length;
        if (e <= s || !t.data.slice(s, e).trim()) continue;
        let node = t; if (s > 0) node = node.splitText(s); if (e - s < node.data.length) node.splitText(e - s);
        const sp = document.createElement('span'); sp.className = 'sr-hl sr-' + h.style; sp.dataset.id = h.id;
        if (h.note) sp.title = h.note;
        node.parentNode.insertBefore(sp, node); sp.appendChild(node);
      }
    }
  },
  post(m) { try { window.webkit.messageHandlers.sr.postMessage(m); } catch (e) {} },
  find(q) {
    window.getSelection().removeAllRanges();
    if (!window.find(q, false, false, true)) return -1;
    const r = window.getSelection().getRangeAt(0).getBoundingClientRect();
    return Math.max(0, Math.floor((r.left + document.documentElement.scrollLeft) / window.innerWidth));
  },
  highlight() {
    const kw = new Set(['func','let','var','if','else','guard','return','struct','class','enum','protocol','extension',
      'import','for','in','while','switch','case','default','self','nil','true','false','init','private','public',
      'static','async','await','throws','try','where','def','fun','val','const','function','new','null','None',
      'True','False','int','void','char','bool','package','interface','fn','mut','pub','impl','use','from','as',
      'catch','throw','yield','lambda','elif','extends','implements','this','undefined','export','type']);
    document.querySelectorAll('pre').forEach(pre => {
      if (pre.dataset.sr) return; pre.dataset.sr = 1;
      const src = pre.textContent;
      const re = /(\\/\\/[^\\n]*|#[^\\n]*|\\/\\*[\\s\\S]*?\\*\\/)|("(?:\\\\.|[^"\\\\])*"|'(?:\\\\.|[^'\\\\])*')|\\b(\\d+(?:\\.\\d+)?)\\b|\\b([A-Za-z_][A-Za-z0-9_]*)\\b/g;
      let out = '', last = 0, m;
      const esc = s => s.replace(/&/g,'&amp;').replace(/</g,'&lt;');
      while ((m = re.exec(src))) {
        out += esc(src.slice(last, m.index)); last = re.lastIndex;
        let cls = null;
        if (m[1]) cls = (m[1][0] === '#' && /^#(include|!|define)/.test(m[1]) === false && /[a-z]/.test(src.slice(Math.max(0,m.index-1), m.index))) ? null : 'sr-c';
        else if (m[2]) cls = 'sr-s'; else if (m[3]) cls = 'sr-n';
        else if (kw.has(m[4])) cls = 'sr-k';
        else if (/^[A-Z]/.test(m[4])) cls = 'sr-t';
        else if (src[re.lastIndex] === '(') cls = 'sr-f';
        out += cls ? `<span class="${cls}">${esc(m[0])}</span>` : esc(m[0]);
      }
      out += esc(src.slice(last));
      const code = pre.querySelector('code') || pre;
      code.innerHTML = out;
    });
  }
};
document.addEventListener('mouseup', (ev) => { setTimeout(() => {
  const sel = window.getSelection();
  if (sel && !sel.isCollapsed && sel.rangeCount) {
    const r = sel.getRangeAt(0), rs = r.getClientRects(), last = rs[rs.length - 1] || r.getBoundingClientRect();
    SR.post({type: 'select', s: SR.offsetOf(r.startContainer, r.startOffset), e: SR.offsetOf(r.endContainer, r.endOffset),
             text: sel.toString(), x: last.left, y: last.top, w: last.width, h: last.height});
    return;
  }
  const hl = ev.target && ev.target.closest ? ev.target.closest('span.sr-hl') : null;
  if (hl) { const b = hl.getBoundingClientRect(); SR.post({type: 'tap', id: hl.dataset.id, x: b.left, y: b.top, w: b.width, h: b.height}); }
  else SR.post({type: 'clear'});
}, 0); });
"""

/// Позиция в EPUB: глава (индекс spine) и экранная страница в ней.
struct EPUBPos: Equatable { var chapter: Int; var page: Int }

@MainActor
final class EPUBController: NSObject, ObservableObject, WKNavigationDelegate {
    let book: EPUBBook
    @Published var pos = EPUBPos(chapter: 0, page: 0)
    @Published var chapterPages: Int = 1
    /// Страниц в каждой главе при текущем оформлении (подсчёт в фоне скрытым WebView).
    @Published var counts: [Int: Int] = [:]
    let web: WKWebView
    private let counter: WKWebView
    /// Снимки соседних разворотов для живого свайпа (рендерятся заранее в окне за экраном).
    @Published var nextSnap: NSImage?
    @Published var prevSnap: NSImage?
    private let peek: WKWebView
    private let peekWindow: NSWindow
    private var peekChapter = -1
    private var peekStyleJS = ""
    private var peekLoaded: CheckedContinuation<Void, Never>?
    private var neighborTask: Task<Void, Never>?
    private var style: EPUBStyle?
    private var pendingPage: Int?           // -1 — последняя страница главы
    private var pendingFragment: String?
    private var pendingFind: String?
    private var pendingOffset: Int?
    /// Хайлайты книги (annotations.json рядом с книгой).
    let annotations: AnnotationStore
    /// Текущее выделение в главе (смещения, текст, рамка в координатах WebView) или тап по хайлайту.
    struct Selection: Equatable { var start: Int; var end: Int; var text: String; var rect: CGRect; var existing: UUID? }
    @Published var selection: Selection?
    private var annotationsSink: AnyCancellable?
    var chapterPath: String { book.spine.indices.contains(pos.chapter) ? book.relative(book.spine[pos.chapter]) : "" }
    private var pendingFraction: Double?
    private var countQueue: [Int] = []
    private var countStyle: EPUBStyle?
    private var countSize: CGSize = .zero

    init(book: EPUBBook) {
        self.book = book
        func make() -> WKWebView {
            let cfg = WKWebViewConfiguration()
            cfg.userContentController.addUserScript(WKUserScript(source: epubScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1000), configuration: cfg)
            w.setValue(false, forKey: "drawsBackground")
            return w
        }
        web = make()
        counter = make()
        peek = make()
        annotations = AnnotationStore(book: book.source)
        // WKWebView рисует только в окне: держим его в невидимом окне далеко за экраном
        peekWindow = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 1000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        peekWindow.isReleasedWhenClosed = false
        peekWindow.contentView = peek
        peekWindow.orderBack(nil)
        super.init()
        web.navigationDelegate = self
        counter.navigationDelegate = self
        peek.navigationDelegate = self
        // сообщения из страницы (выделение, тап по хайлайту) — через слабую ссылку, без цикла удержания
        web.configuration.userContentController.add(WeakScriptHandler(self), name: "sr")
        annotationsSink = annotations.$all.sink { [weak self] _ in
            self?.objectWillChange.send()                 // панель «Заметки» обновляется сразу
            DispatchQueue.main.async { self?.paintHighlights() }
        }
    }

    // MARK: - хайлайты

    /// Нарисовать хайлайты текущей главы (после загрузки главы и при каждом изменении).
    func paintHighlights() {
        let list = annotations.items(chapter: chapterPath).compactMap { a -> [String: Any]? in
            guard case .epub(_, let s, let e) = a.anchor else { return nil }
            return ["id": a.id.uuidString, "s": s, "e": e, "style": a.style.rawValue, "note": a.note ?? ""]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: list), let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("SR.paint(\(json))")
    }

    func clearSelection() {
        selection = nil
        web.evaluateJavaScript("window.getSelection().removeAllRanges()")
    }

    fileprivate func handle(_ body: Any) {
        guard let m = body as? [String: Any], let type = m["type"] as? String else { return }
        func rect() -> CGRect {
            CGRect(x: m["x"] as? Double ?? 0, y: m["y"] as? Double ?? 0, width: max(1, m["w"] as? Double ?? 1), height: max(1, m["h"] as? Double ?? 1))
        }
        switch type {
        case "select":
            guard let s = m["s"] as? Int, let e = m["e"] as? Int, e > s else { return }
            let existing = annotations.existing(overlapping: .epub(chapter: chapterPath, start: s, end: e))?.id
            selection = Selection(start: s, end: e, text: m["text"] as? String ?? "", rect: rect(), existing: existing)
        case "tap":
            guard let ids = m["id"] as? String, let id = UUID(uuidString: ids),
                  let a = annotations.items.first(where: { $0.id == id }), case .epub(_, let s, let e) = a.anchor else { return }
            selection = Selection(start: s, end: e, text: a.text, rect: rect(), existing: id)
        default:
            if selection?.existing == nil { selection = nil }
        }
    }

    /// Перейти к хайлайту из панели «Заметки».
    func go(to a: Annotation) {
        guard case .epub(let path, let s, _) = a.anchor, let i = book.spine.firstIndex(where: { book.relative($0) == path }) else { return }
        if i == pos.chapter {
            web.evaluateJavaScript("SR.pageOfOffset(\(s))") { [weak self] r, _ in self?.show((r as? Int) ?? 0) }
        } else {
            pendingOffset = s
            load(i, page: 0)
        }
    }

    func load(_ chapter: Int, page: Int? = 0, fragment: String? = nil, fraction: Double? = nil) {
        guard book.spine.indices.contains(chapter) else { return }
        pendingPage = page; pendingFragment = fragment; pendingFraction = fraction
        pos = EPUBPos(chapter: chapter, page: max(0, page ?? 0))
        open(book.spine[chapter], in: web)
    }

    /// WebView, которым уже выдан доступ к папке книги (первый loadFileURL).
    private var granted: Set<ObjectIdentifier> = []
    private var reloadAsUTF8: [ObjectIdentifier: URL] = [:]

    /// XHTML в EPUB по умолчанию в UTF-8, но у .html без charset WebKit берёт Latin-1 («Â€¢»):
    /// такие главы грузим данными с явной кодировкой (файлы книги не меняем).
    private func open(_ url: URL, in w: WKWebView) {
        let id = ObjectIdentifier(w)
        if let data = try? Data(contentsOf: url), Self.needsUTF8(url, data) {
            if granted.contains(id) {
                let xml = data.prefix(400).range(of: Data("xmlns=\"http://www.w3.org/1999/xhtml\"".utf8)) != nil
                w.load(data, mimeType: xml ? "application/xhtml+xml" : "text/html", characterEncodingName: "utf-8", baseURL: url)
                return
            }
            reloadAsUTF8[id] = url          // после выдачи доступа перезагрузим этой же главой
        }
        w.loadFileURL(url, allowingReadAccessTo: book.root)
    }

    static func needsUTF8(_ url: URL, _ data: Data) -> Bool {
        guard url.pathExtension.lowercased() != "xhtml" else { return false }
        let head = String(decoding: data.prefix(1024), as: UTF8.self).lowercased()
        return !head.contains("charset") && !head.contains("encoding=")
    }

    func restyle(_ s: EPUBStyle, size: CGSize, force: Bool = false) {
        let changed = s != style || force
        style = s
        let fraction = chapterPages > 1 ? Double(pos.page) / Double(chapterPages) : 0
        web.evaluateJavaScript(s.js) { [weak self] r, _ in
            guard let self, let n = r as? Int else { return }
            self.chapterPages = n
            self.counts[self.pos.chapter] = n
            self.show(min(n - 1, Int((fraction * Double(n)).rounded())))
        }
        if changed || size != countSize { recount(size: size); nextSnap = nil; prevSnap = nil; refreshNeighbors() }
    }

    func show(_ page: Int) {
        pos.page = max(0, min(page, chapterPages - 1))
        web.evaluateJavaScript("SR.go(\(pos.page))")
        refreshNeighbors()
    }

    // MARK: - соседние развороты (для свайпа)

    private var nextPos: EPUBPos? {
        if pos.page + 1 < chapterPages { return EPUBPos(chapter: pos.chapter, page: pos.page + 1) }
        return pos.chapter + 1 < book.spine.count ? EPUBPos(chapter: pos.chapter + 1, page: 0) : nil
    }
    private var prevPos: EPUBPos? {
        if pos.page > 0 { return EPUBPos(chapter: pos.chapter, page: pos.page - 1) }
        return pos.chapter > 0 ? EPUBPos(chapter: pos.chapter - 1, page: -1) : nil    // −1 — последняя страница
    }

    func snapshot(_ dir: Int) -> NSImage? { dir > 0 ? nextSnap : prevSnap }

    /// Окно книги закрыто — убираем невидимое окно со скрытым WebView.
    func close() {
        neighborTask?.cancel()
        countQueue = []; countStyle = nil
        web.stopLoading(); counter.stopLoading(); peek.stopLoading()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "sr")
        peekLoaded?.resume(); peekLoaded = nil
        peekWindow.orderOut(nil); peekWindow.close()
    }

    private func refreshNeighbors() {
        neighborTask?.cancel()
        let n = nextPos, p = prevPos
        neighborTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))      // при быстром листании не рендерим лишнего
            guard let self, !Task.isCancelled else { return }
            let a = await self.render(n)
            guard !Task.isCancelled else { return }
            self.nextSnap = a
            let b = await self.render(p)
            guard !Task.isCancelled else { return }
            self.prevSnap = b
        }
    }

    private func render(_ p: EPUBPos?) async -> NSImage? {
        guard let p, let style, web.bounds.width > 50 else { return nil }
        if peekWindow.frame.size != web.bounds.size {
            peekWindow.setContentSize(web.bounds.size)
            peekChapter = -1
        }
        if peekChapter != p.chapter || peekStyleJS != style.js {
            await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                peekLoaded?.resume()        // прежнее ожидание (отменённый рендер) не должно висеть вечно
                peekLoaded = k
                open(book.spine[p.chapter], in: peek)
            }
            _ = try? await peek.evaluateJavaScript(style.js)
            peekChapter = p.chapter; peekStyleJS = style.js
        }
        let count = (try? await peek.evaluateJavaScript("SR.count()")) as? Int ?? 1
        let page = p.page < 0 ? count - 1 : min(p.page, count - 1)
        _ = try? await peek.evaluateJavaScript("SR.go(\(page))")
        try? await Task.sleep(for: .milliseconds(40))           // кадр после прокрутки
        return try? await peek.takeSnapshot(configuration: nil)
    }

    func next() -> Bool {
        if pos.page + 1 < chapterPages { show(pos.page + 1); return true }
        if pos.chapter + 1 < book.spine.count { load(pos.chapter + 1, page: 0); return true }
        return false
    }

    func prev() -> Bool {
        if pos.page > 0 { show(pos.page - 1); return true }
        if pos.chapter > 0 { load(pos.chapter - 1, page: -1); return true }
        return false
    }

    func open(tocHref href: String) {
        // «#» и «#id» дают пустую часть: split по умолчанию её выбрасывает → падение на parts[0]
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let i = book.spine.firstIndex(where: { book.relative($0) == parts[0] }) else { return }
        load(i, page: 0, fragment: parts.count > 1 ? parts[1] : nil)
    }

    /// Поиск: первая глава (с текущей) с совпадением в тексте, затем страница совпадения.
    func find(_ q: String) -> Bool {
        let order = Array(pos.chapter..<book.spine.count) + Array(0..<pos.chapter)
        for i in order {
            guard let html = try? String(contentsOf: book.spine[i], encoding: .utf8) else { continue }
            let text = EPUBBook.unescape(html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression))
            if text.localizedCaseInsensitiveContains(q) {
                if i == pos.chapter { runFind(q) } else { pendingFind = q; load(i, page: 0) }
                return true
            }
        }
        return false
    }

    private func runFind(_ q: String) {
        let js = "SR.find(\(String(reflecting: q)))"
        web.evaluateJavaScript(js) { [weak self] r, _ in if let p = r as? Int, p >= 0 { self?.show(p) } }
    }

    // MARK: - загрузка глав

    /// Глава не загрузилась (битый файл): не зависаем — скрытый WebView и подсчёт страниц идут дальше.
    // отменённая навигация (−999: мы сами начали новую загрузку) — не ошибка главы
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        MainActor.assumeIsolated { loadFailed(webView) }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        MainActor.assumeIsolated { loadFailed(webView) }
    }

    private func loadFailed(_ webView: WKWebView) {
        if webView === peek { peekLoaded?.resume(); peekLoaded = nil; peekChapter = -1 }
        else if webView === counter, let i = countQueue.first { counts[i] = 1; countQueue.removeFirst(); countNext() }
        else if webView === web { chapterPages = 1 }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            let id = ObjectIdentifier(webView)
            granted.insert(id)
            if let url = reloadAsUTF8.removeValue(forKey: id) { open(url, in: webView); return }
            if webView === counter { countLoaded(); return }
            if webView === peek { peekLoaded?.resume(); peekLoaded = nil; return }
            guard let style else { return }
            webView.evaluateJavaScript(style.js) { [weak self] r, _ in
                guard let self else { return }
                let n = (r as? Int) ?? 1
                self.chapterPages = n
                self.counts[self.pos.chapter] = n
                self.paintHighlights()
                if let o = self.pendingOffset {
                    self.pendingOffset = nil
                    webView.evaluateJavaScript("SR.pageOfOffset(\(o))") { r, _ in self.show((r as? Int) ?? 0) }
                } else if let f = self.pendingFragment {
                    self.pendingFragment = nil
                    webView.evaluateJavaScript("SR.pageOfId(\(String(reflecting: f)))") { r, _ in self.show((r as? Int) ?? 0) }
                } else if let q = self.pendingFind {
                    self.pendingFind = nil
                    self.runFind(q)
                } else if let f = self.pendingFraction {
                    self.pendingFraction = nil
                    self.show(Int((f * Double(n)).rounded(.down)))
                } else {
                    let p = self.pendingPage ?? 0
                    self.show(p < 0 ? n - 1 : p)
                }
                self.pendingPage = nil
            }
        }
    }

    // MARK: - подсчёт страниц по главам (для «N из M» по всей книге)

    private func recount(size: CGSize) {
        guard let style, size.width > 50 else { return }
        countSize = size
        countStyle = style
        counts = [pos.chapter: chapterPages]
        counter.frame = NSRect(origin: .zero, size: size)
        countQueue = Array(book.spine.indices)
        countNext()
    }

    private func countNext() {
        guard let i = countQueue.first else { return }
        open(book.spine[i], in: counter)
    }

    private func countLoaded() {
        guard let style = countStyle, let i = countQueue.first else { return }
        counter.evaluateJavaScript(style.js) { [weak self] r, _ in
            guard let self, self.countStyle == style, self.countQueue.first == i else { return }
            self.counts[i] = (r as? Int) ?? 1
            self.countQueue.removeFirst()
            self.countNext()
        }
    }

    /// Номер текущей страницы и общее число по всей книге (неподсчитанные главы — по 1).
    var number: (Int, Int) {
        var before = 0, total = 0
        for i in book.spine.indices {
            let c = counts[i] ?? 1
            if i < pos.chapter { before += c }
            total += c
        }
        return (before + pos.page + 1, max(total, before + pos.page + 1))
    }
}

struct EPUBWebView: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// Окно EPUB в стиле Apple Books: те же капсулы, темы, масштаб A|A; кнопки «Оригинал» нет.
struct EPUBReaderView: View {
    let url: URL
    @State private var controller: EPUBController?
    @State private var error: String?

    var body: some View {
        Group {
            if let controller {
                EPUBReaderContent(url: url, c: controller)
            } else if let error {
                VStack(spacing: 10) {
                    Image(systemName: "lock.doc").font(.system(size: 40, weight: .thin))
                    Text(error)
                }
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            do {
                let book = try await Task.detached { try EPUBBook(url) }.value
                controller = EPUBController(book: book)
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "Не удалось открыть EPUB"
            }
        }
    }
}

private struct EPUBReaderContent: View {
    let url: URL
    @ObservedObject var c: EPUBController

    @AppStorage("theme") private var themeName = ReaderTheme.calm.name
    @AppStorage("darkVariant") private var darkVariant = false
    @AppStorage("twoPages") private var twoPages = true
    @AppStorage("textScale") private var textScale = 1.0
    @AppStorage("textScaleAuto") private var textScaleAuto = true
    @AppStorage("textScaleAutoValue") private var autoValue = 1.0
    /// Автомасштаб EPUB: базовый кегль 21 pt приводится к комфортному на этом экране.
    private var scale: Double {
        textScaleAuto ? TextScale.auto(bodyPoints: 21, pointsPerInch: TextScale.pointsPerInch(NSApp.keyWindow?.screen ?? NSScreen.main))
                      : TextScale.clamp(textScale)
    }
    @AppStorage("lineSpacing") private var lineSpacing = 1.0
    @AppStorage("margins") private var margins = 1.0
    @AppStorage("justify") private var justify = false
    @AppStorage("fontChoice") private var fontChoice = "theme"

    @State private var size: CGSize = .zero
    @State private var showTOC = false
    @State private var showNotes = false
    @State private var showAppearance = false
    @State private var showCustomize = false
    @State private var showSearch = false
    @State private var query = ""
    @State private var searchStatus = ""
    @State private var bookmarks: [Int] = []
    @State private var restored = false
    @StateObject private var turner = PageTurner()
    @StateObject private var chrome = ChromeVisibility()

    private var theme: ReaderTheme {
        let t = ReaderTheme.named(themeName)
        return darkVariant ? t.darkVariant() : t
    }
    private var ink: Color { Color(cgColor: theme.ink) }
    private var secondary: Color { Color(cgColor: theme.secondary) }

    /// Номера страниц под каждой колонкой разворота («18», «19»), как в Books.
    private var pageNumbers: some View {
        let s = style
        let W = size.width, mh = s.marginH, cols = CGFloat(s.columns)
        let colW = (W - 2 * mh - (cols - 1) * 2 * mh) / cols
        let view = c.number.0 - 1
        return ZStack(alignment: .topLeading) {
            ForEach(0..<s.columns, id: \.self) { k in
                Text("\(view * s.columns + k + 1)").font(.system(size: 11)).foregroundStyle(secondary)
                    .frame(width: colW).offset(x: mh + CGFloat(k) * (colW + 2 * mh))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private func hex(_ c: CGColor) -> String {
        let comps = (c.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil) ?? c).components ?? [0, 0, 0]
        let rgb = comps.count >= 3 ? comps : [comps[0], comps[0], comps[0]]
        return String(format: "#%02X%02X%02X", Int(rgb[0] * 255), Int(rgb[1] * 255), Int(rgb[2] * 255))
    }

    private var style: EPUBStyle {
        let font: String?
        switch fontChoice {
        case "original": font = nil
        case "iowan": font = "Iowan Old Style"
        case "charter": font = "Charter"
        case "georgia": font = "Georgia"
        default: font = ReaderTheme.named(themeName).palette.serifName
        }
        return EPUBStyle(paper: hex(theme.paper), ink: hex(theme.ink), isDark: theme.isDark, font: font,
                         // как в Apple Books: ~21 px при 100%, интервал 1.45, широкие внешние поля, выключка влево
                         size: 21 * scale, lineHeight: 1.45 * lineSpacing,
                         // промежуток между колонками ≈ 8% окна (= 2 × внутреннее поле), внешнее поле ≈ 6% — как в Books
                         marginH: max(18, size.width * 0.041) * margins, marginV: 22, justify: justify,
                         columns: twoPages && size.width > 900 ? 2 : 1, lang: c.book.language ?? "ru")
    }

    /// Закладка: глава × 1000 + доля главы в тысячных (не зависит от кегля).
    private var bookmarkKey: Int {
        c.pos.chapter * 1000 + Int(Double(c.pos.page) / Double(max(1, c.chapterPages)) * 999)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color(cgColor: theme.paper).ignoresSafeArea()
            // страницы во всё окно: сверху — бледное название, снизу — номер под каждой страницей
            VStack(spacing: 0) {
                Color.clear.frame(height: 34)
                ZStack {
                    // соседний разворот едет рядом за пальцем (снимок из скрытого WebView)
                    if turner.offset < 0, let n = c.nextSnap {
                        Image(nsImage: n).resizable().frame(width: size.width, height: size.height)
                            .offset(x: turner.offset + size.width)
                    }
                    if turner.offset > 0, let p = c.prevSnap {
                        Image(nsImage: p).resizable().frame(width: size.width, height: size.height)
                            .offset(x: turner.offset - size.width)
                    }
                    EPUBWebView(web: c.web)
                        .offset(x: turner.offset)
                        .opacity(turner.opacity)
                        // меню выделения как в Books — у последней строки выделения
                        .overlay(alignment: .topLeading) {
                            if let sel = c.selection {
                                Color.clear.frame(width: sel.rect.width, height: sel.rect.height)
                                    .popover(isPresented: Binding(get: { c.selection != nil }, set: { if !$0 { c.clearSelection() } }),
                                             arrowEdge: .bottom) { epubMenu(sel) }
                                    .padding(.leading, max(0, sel.rect.minX)).padding(.top, max(0, sel.rect.minY))
                                    .allowsHitTesting(false)
                            }
                        }
                    if let h = turner.held {
                        Image(nsImage: h).resizable().frame(width: size.width, height: size.height)
                            .background(Color(cgColor: theme.paper))
                    }
                }
                .clipped()
                    .background(GeometryReader { g in
                        Color.clear.onAppear { size = g.size; turner.width = g.size.width }
                            .onChange(of: g.size) { size = g.size; turner.width = g.size.width }
                    })
                pageNumbers.frame(height: 34)
            }
            // WebView уже окна: внешнее поле больше половины промежутка между колонками (шаг страниц остаётся = ширине WebView)
            .padding(.horizontal, size.width * 0.024 * margins)
            .overlay(SwipeCatcher(onDelta: { turner.drag($0, fade: c.snapshot($0 < 0 ? 1 : -1) == nil) },
                                  onEnd: { v in turner.endDrag(velocity: v, neighbors: { c.snapshot($0) }) { $0 > 0 ? c.next() : c.prev() } })
                .allowsHitTesting(false))
            Text(c.book.title).font(.system(size: 12)).foregroundStyle(secondary).lineLimit(1)
                .frame(maxWidth: 520).frame(height: TrafficLights.barHeight)
            HStack {
                nav("chevron.left", key: .leftArrow) { turner.turn(-1) { c.prev() } }
                Spacer()
                nav("chevron.right", key: .rightArrow) { turner.turn(1) { c.next() } }
            }
            .frame(maxHeight: .infinity)
            .opacity(chrome.visible ? 1 : 0)
            // полоса заголовка: перетаскивание окна и системный двойной клик (и при скрытой панели)
            TitleBarStrip().frame(height: TrafficLights.barHeight)
            topBar.noFocusRing().opacity(chrome.visible ? 1 : 0)
            ChromeTracker(chrome: chrome).allowsHitTesting(false)
        }
        .ignoresSafeArea(edges: .top)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear {
            let meta = Sidecar.meta(url)
            bookmarks = meta.bookmarks ?? []
            if !restored {
                restored = true
                // позиция из meta.json: глава + доля (раскладка зависит от кегля и окна)
                let ch = min(max(0, meta.position?.chapter ?? 0), max(0, c.book.spine.count - 1))
                c.load(ch, page: 0, fraction: meta.position?.fraction)
            }
        }
        // после ресайза окна WKWebView получает новый размер чуть позже SwiftUI — пересчитываем с задержкой
        .onChange(of: size) { c.restyle(style, size: size); restyleSoon(); if textScaleAuto { autoValue = scale } }
        .onChange(of: textScaleAuto) { if textScaleAuto { autoValue = scale } }
        .onChange(of: style) { c.restyle(style, size: size) }
        .onChange(of: c.pos) { save() }
        .onDisappear { c.close() }
        .onChange(of: bookmarks) { let b = bookmarks; Sidecar.update(url) { $0.bookmarks = b } }
        .onChange(of: showTOC || showNotes || showAppearance || showSearch || showCustomize) { _, open in chrome.pinned = open }
        .onAppear { chrome.scheduleHide(after: 3) }
        .sheet(isPresented: $showCustomize) { CustomizeSheet() }
    }


    @State private var restyleTask: Task<Void, Never>?
    private func restyleSoon() {
        restyleTask?.cancel()
        restyleTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            c.restyle(style, size: size, force: true)
        }
    }

    private func save() {
        let (n, m) = c.number
        LibraryStore.shared.recordReading(url, progress: Double(n) / Double(max(1, m)),
                                          position: ReadingPosition(chapter: c.pos.chapter,
                                                                    fraction: Double(c.pos.page) / Double(max(1, c.chapterPages))))
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 74, height: 1)
            HStack(spacing: 2) {
                bar("list.bullet", "Оглавление") { showTOC.toggle() }
                    .popover(isPresented: $showTOC, arrowEdge: .bottom) { toc }
                bar(twoPages ? "book.pages" : "rectangle.portrait", twoPages ? "Одна страница" : "Разворот") { twoPages.toggle() }
                bar("note.text", "Заметки и закладки") { showNotes.toggle() }
                    .popover(isPresented: $showNotes, arrowEdge: .bottom) { notes }
            }
            .padding(.horizontal, 4).padding(.vertical, 3).modifier(GlassCapsule())
            Spacer(minLength: 12)
            Color.clear.frame(width: 200, height: 30)      // клики проходят к полосе заголовка под панелью
            Spacer(minLength: 12)
            HStack(spacing: 2) {
                Button { showAppearance.toggle() } label: {
                    HStack(alignment: .lastTextBaseline, spacing: 0) {
                        Text("A").font(.system(size: 12, weight: .medium))
                        Text("A").font(.system(size: 17, weight: .medium))
                    }
                    .frame(width: 36, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain).focusEffectDisabled().foregroundStyle(ink).help("Темы и настройки")
                .popover(isPresented: $showAppearance, arrowEdge: .bottom) {
                    AppearancePopover { showAppearance = false; showCustomize = true }
                }
                bar("magnifyingglass", "Поиск") { showSearch.toggle() }
                    .keyboardShortcut("f")
                    .popover(isPresented: $showSearch, arrowEdge: .bottom) { search }
            }
            .padding(.horizontal, 4).padding(.vertical, 3).modifier(GlassCapsule())
            Button {
                let k = bookmarkKey
                if let i = bookmarks.firstIndex(where: { $0 / 1000 == k / 1000 && abs($0 - k) < 15 }) { bookmarks.remove(at: i) }
                else { bookmarks.append(k); bookmarks.sort() }
            } label: {
                let on = bookmarks.contains { $0 / 1000 == bookmarkKey / 1000 && abs($0 - bookmarkKey) < 15 }
                Image(systemName: on ? "bookmark.fill" : "bookmark").font(.system(size: 15))
                    .frame(width: 36, height: 36).contentShape(Circle())
            }
            .buttonStyle(.plain).focusEffectDisabled().foregroundStyle(ink).modifier(GlassCircle()).help("Закладка")
        }
        .padding(.horizontal, 12).frame(height: 52)
    }

    private func bar(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15)).frame(width: 36, height: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusEffectDisabled().foregroundStyle(ink).help(help)
    }

    private func nav(_ symbol: String, key: KeyEquivalent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 30, weight: .ultraLight)).foregroundStyle(ink.opacity(0.7))
                .frame(width: 44, height: 120).contentShape(Rectangle())
        }
        .buttonStyle(.plain).keyboardShortcut(key, modifiers: [])
    }

    private var toc: some View {
        List(c.book.toc) { e in
            Button { c.open(tocHref: e.href); showTOC = false } label: {
                Text(e.title).lineLimit(1).padding(.leading, CGFloat(e.level) * 14)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 320, height: 420)
        .overlay { if c.book.toc.isEmpty { Text("В книге нет оглавления").foregroundStyle(.secondary) } }
    }

    private func epubMenu(_ sel: EPUBController.Selection) -> some View {
        let anchor = AnnotationAnchor.epub(chapter: c.chapterPath, start: sel.start, end: sel.end)
        let existing = sel.existing.flatMap { id in c.annotations.items.first { $0.id == id } }
        return HighlightMenu(text: sel.text, existing: existing,
            onStyle: { st in
                var a = existing ?? Annotation(style: st, text: sel.text, anchor: anchor)
                a.style = st
                c.annotations.upsert(a); c.clearSelection()
            },
            onNote: { n in
                var a = existing ?? Annotation(style: .yellow, text: sel.text, anchor: anchor)
                a.note = n.isEmpty ? nil : n
                c.annotations.upsert(a); c.clearSelection()
            },
            onCopy: { Pasteboard.copy(sel.text); c.clearSelection() },
            onDelete: { if let existing { c.annotations.delete(existing.id) }; c.clearSelection() })
    }

    private func chapterTitle(_ path: String) -> String {
        c.book.toc.first { $0.href.hasPrefix(path) }?.title
            ?? (c.book.spine.firstIndex { c.book.relative($0) == path }.map { "Глава \($0 + 1)" } ?? "")
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Заметки").font(.headline)
            let hl = c.annotations.items
            if hl.isEmpty && bookmarks.isEmpty {
                Text("Выделите текст, чтобы добавить хайлайт или заметку").font(.callout).foregroundStyle(.secondary)
            }
            if !hl.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(hl) { a in
                            if case .epub(let path, _, _) = a.anchor {
                                Button { c.go(to: a); showNotes = false } label: { NoteRow(annotation: a, location: chapterTitle(path)) }
                                    .buttonStyle(.plain)
                                    .contextMenu { Button("Удалить хайлайт", role: .destructive) { c.annotations.delete(a.id) } }
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
            if !bookmarks.isEmpty { Divider(); Text("Закладки").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary) }
            ForEach(bookmarks, id: \.self) { b in
                let ch = b / 1000, frac = Double(b % 1000) / 999
                let title = c.book.toc.first { e in
                    c.book.spine.indices.contains(ch) && e.href.hasPrefix(c.book.relative(c.book.spine[ch]))
                }?.title ?? "Глава \(ch + 1)"
                Button("\(title) · \(Int(frac * 100))%") {
                    c.load(ch, page: 0, fraction: frac); showNotes = false
                }.buttonStyle(.link)
            }
        }
        .padding(14).frame(width: 320, alignment: .leading)
    }

    private var search: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Поиск в книге", text: $query).textFieldStyle(.roundedBorder).frame(width: 260)
                .onSubmit { searchStatus = c.find(query) ? "" : "Не найдено" }
            if !searchStatus.isEmpty { Text(searchStatus).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(14)
    }
}

/// Приёмник сообщений JS со слабой ссылкой: userContentController держит обработчик сильно.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: EPUBController?
    init(_ t: EPUBController) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        MainActor.assumeIsolated { target?.handle(body) }
    }
}
