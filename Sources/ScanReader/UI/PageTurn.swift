import AppKit
import SwiftUI

/// Перелистывание как в Apple Books на macOS: горизонтальный сдвиг с затуханием (~0.3 с, easeInOut)
/// и интерактивный свайп двумя пальцами — страница идёт за пальцем, доводка или откат по скорости.
@MainActor
final class PageTurner: ObservableObject {
    @Published var offset: CGFloat = 0
    @Published var opacity: Double = 1
    /// Снимок соседнего разворота, который держим поверх, пока WebView догружает его после доводки свайпа.
    @Published var held: NSImage?
    var width: CGFloat = 800
    private var busy = false

    /// Перелистнуть в сторону dir (+1 вперёд, −1 назад); perform меняет страницу и говорит, получилось ли.
    func turn(_ dir: Int, from start: CGFloat = 0, perform: @escaping () -> Bool) {
        guard !busy else { return }
        busy = true
        let out = -CGFloat(dir) * width * 0.28
        withAnimation(.easeIn(duration: start == 0 ? 0.13 : 0.1)) { offset = out; opacity = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + (start == 0 ? 0.13 : 0.1)) {
            guard perform() else {
                withAnimation(.easeOut(duration: 0.2)) { self.offset = 0; self.opacity = 1 }
                self.busy = false
                return
            }
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { self.offset = CGFloat(dir) * self.width * 0.28 }
            withAnimation(.easeOut(duration: 0.18)) { self.offset = 0; self.opacity = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { self.busy = false }
        }
    }

    // MARK: - свайп двумя пальцами

    /// fade = false — рядом едет снимок соседнего разворота (EPUB), гасить страницу не нужно.
    func drag(_ dx: CGFloat, fade: Bool = true) {
        guard !busy else { return }
        offset += dx
        opacity = fade ? 1 - min(0.7, Double(abs(offset) / max(1, width)) * 1.4) : 1
    }

    /// Доводка свайпа со снимком соседа: страница уезжает целиком, сосед встаёт на место.
    func slide(_ dir: Int, neighbor: NSImage, perform: @escaping () -> Bool) {
        guard !busy else { return }
        busy = true
        let remaining = max(0.12, 0.25 * Double(1 - abs(offset) / max(1, width)))
        withAnimation(.easeOut(duration: remaining)) { offset = -CGFloat(dir) * width }
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
            var t = Transaction(); t.disablesAnimations = true
            if perform() {
                withTransaction(t) { self.held = neighbor; self.offset = 0 }
                // WebView успевает перейти (в той же главе — мгновенно, в новой — после загрузки)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    withAnimation(.easeOut(duration: 0.12)) { self.held = nil }
                }
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { self.offset = 0 }
            }
            self.busy = false
        }
    }

    func endDrag(velocity: CGFloat, neighbors: ((Int) -> NSImage?)? = nil, perform: @escaping (Int) -> Bool) {
        guard !busy else { return }
        // пальцы влево (offset < 0) — вперёд; порог по пути или по скорости
        if abs(offset) > width * 0.12 || abs(velocity) > 700 {
            let dir = (abs(velocity) > 700 ? velocity : offset) < 0 ? 1 : -1
            if let img = neighbors?(dir) { slide(dir, neighbor: img) { perform(dir) }; return }
            turn(dir, from: offset) { perform(dir) }
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { offset = 0; opacity = 1 }
        }
    }
}

/// Ловит горизонтальные жесты трекпада (scrollWheel с фазами) в своём окне.
struct SwipeCatcher: NSViewRepresentable {
    var onDelta: (CGFloat) -> Void
    var onEnd: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.view = v
        context.coordinator.install()
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onDelta = onDelta; context.coordinator.onEnd = onEnd
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.remove() }
    func makeCoordinator() -> Coordinator { Coordinator(onDelta: onDelta, onEnd: onEnd) }

    final class Coordinator {
        weak var view: NSView?
        var onDelta: (CGFloat) -> Void
        var onEnd: (CGFloat) -> Void
        private var monitor: Any?
        private var active = false
        private var samples: [(TimeInterval, CGFloat)] = []

        init(onDelta: @escaping (CGFloat) -> Void, onEnd: @escaping (CGFloat) -> Void) { self.onDelta = onDelta; self.onEnd = onEnd }

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
                guard let self, let v = self.view, e.window === v.window, e.hasPreciseScrollingDeltas else { return e }
                if e.momentumPhase != [] { return self.active ? nil : e }      // инерцию не учитываем
                switch e.phase {
                case .began:
                    self.active = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY)
                    self.samples = []
                    if self.active { self.feed(e) }
                    return self.active ? nil : e
                case .changed:
                    guard self.active else { return e }
                    self.feed(e); return nil
                case .ended, .cancelled:
                    guard self.active else { return e }
                    self.active = false
                    let recent = self.samples.filter { e.timestamp - $0.0 < 0.08 }
                    let dt = max(0.016, (recent.last?.0 ?? 0) - (recent.first?.0 ?? 0))
                    self.onEnd(recent.reduce(0) { $0 + $1.1 } / CGFloat(dt))
                    return nil
                default:
                    return self.active ? nil : e
                }
            }
        }

        private func feed(_ e: NSEvent) {
            samples.append((e.timestamp, e.scrollingDeltaX))
            onDelta(e.scrollingDeltaX)
        }

        func remove() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}

/// Панель читалки скрывается при чтении и появляется при движении мыши (плавно), как в Books.
@MainActor
final class ChromeVisibility: ObservableObject {
    /// Мышь неподвижна внутри окна — через столько секунд панель гаснет.
    static let idleDelay: Double = 2.0
    /// Мышь ушла из окна — элементы остаются ещё столько секунд.
    static let exitDelay: Double = 1.5
    /// Длительность затухания/появления.
    static let fadeOut: Double = 0.3
    static let fadeIn: Double = 0.25

    @Published var visible = true
    private var hideTask: Task<Void, Never>?
    var pinned = false { didSet { if pinned { show() } else { scheduleHide() } } }

    func mouseMoved(y: CGFloat) {
        show()
        // у верхнего края панель не прячем
        if y > 70 { scheduleHide(after: Self.idleDelay) } else { hideTask?.cancel() }
    }

    func show() {
        if !visible { withAnimation(.easeOut(duration: Self.fadeIn)) { visible = true } }
    }

    func scheduleHide(after s: Double = ChromeVisibility.idleDelay) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(s))
            guard let self, !Task.isCancelled, !self.pinned else { return }
            withAnimation(.easeInOut(duration: Self.fadeOut)) { self.visible = false }
        }
    }
}

extension ChromeVisibility {
    /// Мышь ушла из окна: не сразу, а через exitDelay (вернулась раньше — mouseMoved отменит таймер).
    func mouseExited() { scheduleHide(after: Self.exitDelay) }
}

/// NSTrackingArea на всё окно: вход/движение мыши показывает панель, уход — прячет;
/// заодно гасит/показывает «светофор» окна вместе с панелью (как в Books).
struct ChromeTracker: NSViewRepresentable {
    @ObservedObject var chrome: ChromeVisibility

    final class TrackingView: NSView {
        var chrome: ChromeVisibility?
        private var area: NSTrackingArea?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                   owner: self, userInfo: nil)
            addTrackingArea(a); area = a
        }
        private var observers: [NSObjectProtocol] = []
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let w = window else { return }
            w.acceptsMouseMovedEvents = true
            TrafficLights.place(w)
            // AppKit возвращает кнопки на место при ресайзе, смене ключевого окна и выходе из полноэкранного режима
            for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didBecomeKeyNotification,
                         NSWindow.didResignKeyNotification, NSWindow.didExitFullScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { [weak w] _ in
                    if let w { TrafficLights.place(w) }
                })
            }
        }
        override func layout() { super.layout(); if let w = window { TrafficLights.place(w) } }
        private func y(_ e: NSEvent) -> CGFloat { bounds.height - convert(e.locationInWindow, from: nil).y }
        override func mouseMoved(with e: NSEvent) { MainActor.assumeIsolated { chrome?.mouseMoved(y: y(e)) } }
        override func mouseEntered(with e: NSEvent) { MainActor.assumeIsolated { chrome?.mouseMoved(y: y(e)) } }
        override func mouseExited(with e: NSEvent) { MainActor.assumeIsolated { chrome?.mouseExited() } }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }     // клики проходят насквозь
    }

    func makeNSView(context: Context) -> TrackingView { let v = TrackingView(); v.chrome = chrome; return v }

    func updateNSView(_ v: TrackingView, context: Context) {
        v.chrome = chrome
        let alpha: CGFloat = chrome.visible ? 1 : 0
        guard let w = v.window else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = chrome.visible ? ChromeVisibility.fadeIn : ChromeVisibility.fadeOut
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                w.standardWindowButton(b)?.animator().alphaValue = alpha
            }
        }
    }
}

/// «Светофор» как в Apple Books: полоса заголовка 52 pt, центр красной кнопки — 26 pt от левого и верхнего края,
/// шаг между кнопками 23 pt (замер по скриншоту Books).
enum TrafficLights {
    static let barHeight: CGFloat = 52
    static let firstCenter = CGPoint(x: 26, y: 26)
    static let step: CGFloat = 23

    @MainActor static func place(_ w: NSWindow) {
        guard !w.styleMask.contains(.fullScreen),
              let close = w.standardWindowButton(.closeButton), let bar = close.superview, let container = bar.superview else { return }
        var f = container.frame
        if f.height != barHeight {
            f.size.height = barHeight
            f.origin.y = (container.superview?.bounds.height ?? w.frame.height) - barHeight
            container.frame = f
            bar.frame = NSRect(x: 0, y: 0, width: f.width, height: barHeight)
        }
        for (i, t) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let b = w.standardWindowButton(t) else { continue }
            let o = NSPoint(x: firstCenter.x + CGFloat(i) * step - b.frame.width / 2,
                            y: barHeight - firstCenter.y - b.frame.height / 2)
            if b.frame.origin != o { b.setFrameOrigin(o) }
        }
    }
}

/// Полоса заголовка окна читалки (строки заголовка нет — .hiddenTitleBar): протяжка двигает окно,
/// двойной клик — системное действие из настроек (Дважды нажать заголовок окна → увеличить/свернуть/ничего).
/// Работает и когда панель скрыта: полоса прозрачная, но всегда принимает мышь.
struct TitleBarStrip: NSViewRepresentable {
    final class StripView: NSView {
        override func mouseDown(with e: NSEvent) {
            guard let w = window else { return }
            if e.clickCount == 2 { TitleBarStrip.performDoubleClickAction(w) } else { w.performDrag(with: e) }
        }
        override var mouseDownCanMoveWindow: Bool { false }
        // как у системного заголовка: клик по неактивному окну тоже считается (иначе двойной клик теряет первый)
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    func makeNSView(context: Context) -> StripView { StripView() }
    func updateNSView(_ nsView: StripView, context: Context) {}

    enum Action: Equatable { case zoom, minimize, none }

    /// Значение «AppleActionOnDoubleClick» из NSGlobalDomain (Maximize / Fill / Minimize / None);
    /// старые системы — «AppleMiniaturizeOnDoubleClick».
    static func action(_ defaults: UserDefaults = .standard) -> Action {
        switch defaults.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": return .minimize
        case "None": return .none
        case "Maximize", "Fill": return .zoom
        default: return defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick") ? .minimize : .zoom
        }
    }

    static func performDoubleClickAction(_ w: NSWindow) {
        switch action() {
        case .zoom: w.zoom(nil)
        case .minimize: w.miniaturize(nil)
        case .none: break
        }
    }
}

/// Без синей рамки фокуса (как в Books). Навигация с клавиатуры остаётся: Tab и пробел работают,
/// не рисуется только кольцо (при включённом «Полном доступе с клавиатуры» система подсветит фокус сама).
extension View {
    func noFocusRing() -> some View { focusEffectDisabled() }
}
