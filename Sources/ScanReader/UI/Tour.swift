import AppKit
import Combine
import SwiftUI

/// Ознакомительный тур (в стиле Apple): карточки поверх интерфейса со стрелкой к элементу,
/// «Далее» / «Пропустить», точки шагов. Часть про библиотеку — при первом запуске,
/// часть про книгу — при первом открытии книги; заново — «Справка → Ознакомительный тур».
/// Флаги «пройдено» — в UserDefaults этой машины (не в общей папке).
enum TourPart: String, CaseIterable {
    case library, book

    var doneKey: String { "tour.\(rawValue).done" }
}

struct TourStep: Identifiable, Equatable {
    var id: String
    /// Элемент интерфейса, к которому указывает стрелка (nil — карточка по центру).
    var anchor: String?
    /// Кнопка системной панели (toolbar): ищется по подписи в окне.
    var toolbarLabel: String? = nil
    var title: (ru: String, en: String)
    var body: (ru: String, en: String)

    static func == (a: TourStep, b: TourStep) -> Bool { a.id == b.id }

    func title(_ ru: Bool) -> String { ru ? title.ru : title.en }
    func body(_ ru: Bool) -> String { ru ? body.ru : body.en }
}

enum TourContent {
    static func steps(_ part: TourPart) -> [TourStep] {
        switch part {
        case .library: return [
            TourStep(id: "folder", anchor: "library.sidebar",
                     title: ("Ваша библиотека — это папка", "Your library is a folder"),
                     body: ("Книги, распознанный текст, обложки и прогресс хранятся в выбранной папке. Сменить её можно в Настройках (⌘,).",
                            "Books, recognized text, covers and progress live in the folder you chose. Change it in Settings (⌘,).")),
            TourStep(id: "import", anchor: nil, toolbarLabel: "Импорт книг в библиотеку",
                     title: ("Импорт", "Import"),
                     body: ("Кнопка «Импорт» вверху: PDF, EPUB и сканы из Файлов или свои книги из Apple Books вместе с коллекциями.",
                            "The Import button at the top: PDFs, EPUBs and scans from Files, or your own books from Apple Books with their collections.")),
            TourStep(id: "drop", anchor: "library.grid",
                     title: ("Перетащите файлы", "Drag files in"),
                     body: ("Перетащите книги или папку со сканами прямо в окно — они скопируются в библиотеку.",
                            "Drop books or a folder of scans onto the window — they are copied into the library.")),
            TourStep(id: "icloud", anchor: nil,
                     title: ("Общая папка iCloud", "Shared iCloud folder"),
                     body: ("Выберите общую папку iCloud Drive — и библиотека будет одинаковой на всех устройствах, даже с другим Apple ID: прогресс, закладки и хайлайты синхронизируются.",
                            "Pick a shared iCloud Drive folder and the library is the same on every device, even with another Apple ID: progress, bookmarks and highlights sync.")),
        ]
        case .book: return [
            TourStep(id: "turn", anchor: "book.next",
                     title: ("Листание", "Turning pages"),
                     body: ("Стрелки ← →, шевроны по краям или свайп двумя пальцами. Панель прячется, пока вы читаете, — подвиньте мышь, чтобы вернуть её.",
                            "Use ← →, the chevrons, or a two-finger swipe. The toolbar hides while you read — move the pointer to bring it back.")),
            TourStep(id: "original", anchor: "book.original",
                     title: ("Оригинал скана", "Original scan"),
                     body: ("Покажет страницу как в скане. А с зажатой ⌥ наведите на строку — лупа покажет её оригинал.",
                            "Shows the page as scanned. Hold ⌥ and hover a line to see the original in a loupe.")),
            TourStep(id: "aa", anchor: "book.aa",
                     title: ("Темы и размер текста", "Themes and text size"),
                     body: ("Aa — темы оформления, масштаб текста и «Настроить»: шрифт, интервалы, «Улучшать скан».",
                            "Aa — reading themes, text size and Customize: font, spacing, “Enhance scans”.")),
            TourStep(id: "highlight", anchor: "book.page",
                     title: ("Хайлайты и заметки", "Highlights and notes"),
                     body: ("Выделите текст мышью — выберите цвет, подчёркивание или добавьте заметку. Хайлайты видны в любой теме.",
                            "Select text to pick a color, underline or add a note. Highlights show in every theme.")),
            TourStep(id: "notes", anchor: "book.notes",
                     title: ("Панель «Заметки»", "Notes panel"),
                     body: ("Все хайлайты, заметки и закладки книги — с переходом к месту.",
                            "All highlights, notes and bookmarks of the book — click to jump there.")),
            TourStep(id: "pagemenu", anchor: "book.pagemenu",
                     title: ("Меню страницы", "Page menu"),
                     body: ("«Показывать скан на этой странице», если распознавание не удалось, и «Распознать заново».",
                            "“Show scan on this page” when recognition is off, and “Recognize again”.")),
            TourStep(id: "search", anchor: "book.search",
                     title: ("Поиск и закладки", "Search and bookmarks"),
                     body: ("Ищите по распознанному тексту всей книги (⌘F) и ставьте закладки справа.",
                            "Search the recognized text of the whole book (⌘F) and add bookmarks on the right.")),
        ]
        }
    }
}

/// Состояние тура: какая часть идёт, на каком шаге; флаги «пройдено» в UserDefaults.
@MainActor
final class TourCenter: ObservableObject {
    static let shared = TourCenter()

    @Published private(set) var part: TourPart?
    @Published private(set) var index = 0
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var steps: [TourStep] { part.map(TourContent.steps) ?? [] }
    var step: TourStep? { steps.indices.contains(index) ? steps[index] : nil }
    var isLast: Bool { index == steps.count - 1 }

    func isDone(_ p: TourPart) -> Bool { defaults.bool(forKey: p.doneKey) }

    /// Показать часть, если её ещё не проходили (и сейчас не идёт другая).
    func startIfNeeded(_ p: TourPart) {
        guard part == nil, !isDone(p) else { return }
        part = p; index = 0
    }

    func next() {
        guard let p = part else { return }
        if index + 1 < steps.count { index += 1 } else { finish(p) }
    }

    func back() { if index > 0 { index -= 1 } }

    /// «Пропустить» — часть считается пройденной.
    func skip() { if let p = part { finish(p) } }

    private func finish(_ p: TourPart) {
        defaults.set(true, forKey: p.doneKey)
        part = nil; index = 0
        // после библиотеки часть про книгу покажется при первом открытии книги
    }

    /// «Справка → Ознакомительный тур»: всё заново; сразу — та часть, где находится пользователь.
    func restart(in p: TourPart) {
        TourPart.allCases.forEach { defaults.removeObject(forKey: $0.doneKey) }
        part = p; index = 0
    }

    /// Язык тура = язык интерфейса приложения: тот, что macOS выбрала для бандла из CFBundleLocalizations
    /// (сейчас интерфейс только русский, поэтому и тур русский даже на английской системе).
    static var russian: Bool { AppLanguage.isRussian }
}

// MARK: - якоря: NSView-зонды → точные рамки в координатах окна

/// Реестр помеченных элементов: id → вид (слабо). Рамку берём из AppKit — так работают и элементы
/// тулбара, и области под строкой заголовка.
@MainActor
final class TourAnchors {
    static let shared = TourAnchors()
    private var views: [(id: String, view: WeakView)] = []
    final class WeakView { weak var view: NSView?; init(_ v: NSView) { view = v } }

    func register(_ id: String, _ v: NSView) {
        views.removeAll { $0.view.view == nil || $0.view.view === v }
        views.append((id, WeakView(v)))
    }

    /// Рамка элемента в окне (начало — левый верхний угол всего окна, включая заголовок).
    func rect(_ id: String, in window: NSWindow) -> CGRect? {
        let candidates = views.compactMap { $0.id == id ? $0.view.view : nil }.filter { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }
        if let v = candidates.first(where: { $0.bounds.width > 1 }) { return Self.windowRect(v, window) }
        return nil
    }

    /// Кнопка тулбара по подписи (элементы системной панели SwiftUI не помечаются модификатором).
    func toolbarRect(label: String, in window: NSWindow) -> CGRect? {
        guard let frameView = window.contentView?.superview else { return nil }
        func find(_ v: NSView) -> NSView? {
            // SwiftUI отдаёт подсказку (.help) элемента тулбара как accessibilityHelp группы
            if [v.accessibilityLabel(), v.accessibilityTitle(), v.accessibilityHelp(), v.toolTip].contains(label),
               v.bounds.width > 4 { return v }
            for s in v.subviews { if let f = find(s) { return f } }
            return nil
        }
        return find(frameView).map { Self.windowRect($0, window) }
    }

    static func windowRect(_ v: NSView, _ window: NSWindow) -> CGRect {
        let r = v.convert(v.bounds, to: nil)                         // окно, начало снизу слева
        return CGRect(x: r.minX, y: window.frame.height - r.maxY, width: r.width, height: r.height)
    }
}

private struct TourProbe: NSViewRepresentable {
    let id: String
    func makeNSView(context: Context) -> NSView {
        let v = ProbeView(); v.id = id; return v
    }
    func updateNSView(_ v: NSView, context: Context) { (v as? ProbeView)?.id = id }
    final class ProbeView: NSView {
        var id = "" { didSet { if window != nil { MainActor.assumeIsolated { TourAnchors.shared.register(id, self) } } } }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); MainActor.assumeIsolated { TourAnchors.shared.register(id, self) } }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Окно, в котором идёт эта часть тура.
private struct TourHostProbe: NSViewRepresentable {
    let part: TourPart
    func makeNSView(context: Context) -> NSView { let v = HostView(); v.part = part; return v }
    func updateNSView(_ v: NSView, context: Context) {}
    final class HostView: NSView {
        var part: TourPart = .library
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            MainActor.assumeIsolated { TourWindowController.shared.attach(part, to: w) }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    /// Пометить элемент для стрелки тура.
    func tourAnchor(_ id: String) -> some View { background(TourProbe(id: id)) }

    /// Окно, где показывается часть тура `part` (затемнение и карточка — в отдельном окне поверх, вместе с заголовком).
    func tourOverlay(_ part: TourPart) -> some View { background(TourHostProbe(part: part)) }
}

// MARK: - окно тура поверх окна приложения

@MainActor
final class TourWindowController {
    static let shared = TourWindowController()
    private var hosts: [TourPart: [WeakWindow]] = [:]
    private var panel: TourPanel?
    private var cancellable: Any?
    private var observers: [NSObjectProtocol] = []
    final class WeakWindow { weak var window: NSWindow?; init(_ w: NSWindow) { window = w } }

    func attach(_ part: TourPart, to window: NSWindow) {
        hosts[part, default: []].removeAll { $0.window == nil || $0.window === window }
        hosts[part, default: []].append(WeakWindow(window))
        if cancellable == nil {
            let c = TourCenter.shared
            cancellable = c.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refresh() }
    }

    /// Окно для текущей части: ключевое среди окон этой части, иначе любое видимое.
    private func hostWindow(_ part: TourPart) -> NSWindow? {
        let ws = (hosts[part] ?? []).compactMap(\.window).filter(\.isVisible)
        return ws.first(where: \.isKeyWindow) ?? ws.first(where: \.isMainWindow) ?? ws.last
    }

    func refresh() {
        let c = TourCenter.shared
        guard let part = c.part, let step = c.step, let host = hostWindow(part) else { close(); return }
        var target: CGRect?
        if let a = step.anchor { target = TourAnchors.shared.rect(a, in: host) }
        if target == nil, let label = step.toolbarLabel { target = TourAnchors.shared.toolbarRect(label: label, in: host) }
        if step.anchor != nil, target == nil, step.toolbarLabel == nil {
            // элемента в этом окне нет (у EPUB нет «оригинала скана») — следующий шаг
            c.next(); return
        }
        let p = panel ?? makePanel()
        if p.parent !== host {
            p.parent?.removeChildWindow(p)
            host.addChildWindow(p, ordered: .above)
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification].map {
                NotificationCenter.default.addObserver(forName: $0, object: host, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                }
            }
        }
        p.setFrame(host.frame, display: true)
        p.host.rootView = TourOverlayView(step: step, target: target, size: host.frame.size,
                                          index: c.index, count: c.steps.count, isLast: c.isLast,
                                          cornerRadius: Self.cornerRadius(host))
        p.orderFront(nil)
        p.makeKey()
    }

    /// Радиус углов окна — у системы (на macOS 26+ он больше и зависит от тулбара); в полноэкранном — 0.
    static func cornerRadius(_ w: NSWindow) -> CGFloat {
        if w.styleMask.contains(.fullScreen) { return 0 }
        let frame = w.contentView?.superview
        for (obj, key) in [(frame as NSObject?, "cornerRadius"), (w as NSObject?, "_cornerRadius")] {
            if let o = obj, o.responds(to: NSSelectorFromString(key)), let r = o.value(forKey: key) as? CGFloat, r >= 0 { return r }
        }
        return 16
    }

    private func makePanel() -> TourPanel {
        let p = TourPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.isReleasedWhenClosed = false
        p.host = NSHostingView(rootView: TourOverlayView(step: nil, target: nil, size: .zero, index: 0, count: 0, isLast: false, cornerRadius: 0))
        p.contentView = p.host
        panel = p
        return p
    }

    private func close() {
        guard let p = panel else { return }
        p.parent?.removeChildWindow(p)
        p.orderOut(nil)
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
    }
}

final class TourPanel: NSPanel {
    var host: NSHostingView<TourOverlayView>!
    override var canBecomeKey: Bool { true }
}

/// Затемнение всего окна (с заголовком), янтарный вырез вокруг элемента, карточка сбоку со стрелкой.
struct TourOverlayView: View {
    let step: TourStep?
    let target: CGRect?
    let size: CGSize
    let index: Int
    let count: Int
    let isLast: Bool
    /// Скругление затемнения = скруглению углов окна (углы не «торчат» за окно).
    let cornerRadius: CGFloat

    static let cardWidth: CGFloat = 320
    static let cardHeight: CGFloat = 176
    static let gap: CGFloat = 18

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let step {
                let hole = target?.insetBy(dx: -8, dy: -8)
                Color.black.opacity(0.42)
                    .mask {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).overlay {
                            if let h = hole {
                                RoundedRectangle(cornerRadius: 12).frame(width: h.width, height: h.height)
                                    .position(x: h.midX, y: h.midY).blendMode(.destinationOut)
                            }
                        }
                        .compositingGroup()
                    }
                    .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .onTapGesture {}
                if let h = hole {
                    // своя подсветка: янтарное свечение, без системного кольца фокуса
                    RoundedRectangle(cornerRadius: 12).strokeBorder(Brand.amber, lineWidth: 2)
                        .shadow(color: Brand.amber.opacity(0.9), radius: 10)
                        .frame(width: h.width, height: h.height).position(x: h.midX, y: h.midY)
                        .allowsHitTesting(false)
                }
                let placement = Self.place(target: hole, in: size)
                TourCard(step: step, index: index, count: count, isLast: isLast, arrow: placement.arrow, arrowOffset: placement.arrowOffset)
                    .frame(width: Self.cardWidth)
                    .position(placement.center)
            }
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)
    }

    enum Edge { case left, right, top, bottom, none }

    /// Карточка сбоку от элемента (справа → слева → снизу → сверху), целиком внутри окна, стрелка к элементу.
    static func place(target t: CGRect?, in size: CGSize) -> (center: CGPoint, arrow: Edge, arrowOffset: CGFloat) {
        let w = cardWidth, h = cardHeight, m: CGFloat = 12
        guard let t else { return (CGPoint(x: size.width / 2, y: size.height / 2), .none, 0) }
        // большая область (сетка книг): карточка внутри неё, в правом нижнем углу — область остаётся видна
        if t.width * t.height > size.width * size.height * 0.4 {
            return (CGPoint(x: min(t.maxX, size.width) - m - 12 - w / 2, y: min(t.maxY, size.height) - m - 12 - h / 2), .none, 0)
        }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, m + h / 2), size.height - m - h / 2) }
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, m + w / 2), size.width - m - w / 2) }
        if t.maxX + gap + w + m <= size.width {
            let c = CGPoint(x: t.maxX + gap + w / 2, y: clampY(t.midY))
            return (c, .left, t.midY - c.y)
        }
        if t.minX - gap - w - m >= 0 {
            let c = CGPoint(x: t.minX - gap - w / 2, y: clampY(t.midY))
            return (c, .right, t.midY - c.y)
        }
        if t.maxY + gap + h + m <= size.height {
            let c = CGPoint(x: clampX(t.midX), y: t.maxY + gap + h / 2)
            return (c, .top, t.midX - c.x)
        }
        let c = CGPoint(x: clampX(t.midX), y: max(m + h / 2, t.minY - gap - h / 2))
        return (c, .bottom, t.midX - c.x)
    }
}

private struct TourCard: View {
    let step: TourStep
    let index: Int
    let count: Int
    let isLast: Bool
    let arrow: TourOverlayView.Edge
    let arrowOffset: CGFloat
    private var ru: Bool { TourCenter.russian }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(step.title(ru)).font(.headline)
            Text(step.body(ru)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach(0..<count, id: \.self) { i in
                    Capsule().fill(i == index ? Brand.amber : Color.secondary.opacity(0.35))
                        .frame(width: i == index ? 14 : 6, height: 6)
                }
                Spacer()
                Button(ru ? "Пропустить" : "Skip") { withAnimation { TourCenter.shared.skip() } }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Button(isLast ? (ru ? "Готово" : "Done") : (ru ? "Далее" : "Next")) { withAnimation { TourCenter.shared.next() } }
                    .buttonStyle(.borderedProminent).tint(Brand.amber).foregroundStyle(.black)
                    .keyboardShortcut(.defaultAction)
            }
            .font(.callout)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.16)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Brand.amber.opacity(0.35)))
        .overlay(alignment: alignment) { arrowShape }
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        .focusEffectDisabled()
    }

    private var alignment: Alignment {
        switch arrow { case .left: .leading; case .right: .trailing; case .top: .top; case .bottom: .bottom; case .none: .center }
    }

    @ViewBuilder private var arrowShape: some View {
        if arrow != .none {
            Triangle().fill(Color(white: 0.16))
                .frame(width: 18, height: 10)
                .rotationEffect(.degrees(arrow == .top ? 0 : arrow == .bottom ? 180 : arrow == .left ? -90 : 90))
                .offset(x: arrow == .left ? -13 : arrow == .right ? 13 : max(-130, min(130, arrowOffset)),
                        y: arrow == .top ? -9 : arrow == .bottom ? 9 : max(-60, min(60, arrowOffset)))
        }
    }
}

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(); p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath(); return p
    }
}
