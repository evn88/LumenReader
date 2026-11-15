import AppKit
import SwiftUI

/// Одна экранная страница: "чистая" версия (точная раскладка при 100% или перекомпоновка),
/// оригинал скана по кнопке «Оригинал» на панели и лупа с оригиналом строки при наведении с ⌥.
struct PageView: View {
    @ObservedObject var book: BookModel
    let index: Int
    var sub = 0
    let theme: ReaderTheme
    var settings = ReflowSettings()
    let showOriginal: Bool

    @State private var loupe: TextLine?
    @State private var hoverPoint: CGPoint = .zero
    @State private var slow = false
    // выделение и хайлайты
    @State private var selection: ClosedRange<Int>?
    @State private var dragStart: Int?
    @State private var menuShown = false
    @State private var menuRect: CGRect = .zero

    var body: some View {
        Group {
            if let page = book.pages[index] {
                content(page)
            } else if let error = book.failed[index] {
                // ошибка видна на странице, а не вечный спиннер
                placeholder {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 22))
                        Text(error).font(.caption).multilineTextAlignment(.center).frame(maxWidth: 280)
                        HStack {
                            Button("Повторить") { book.retry(index) }
                            Button("Показать скан") { book.setShowScan(index, true); book.retry(index) }
                        }
                        .controlSize(.small)
                    }
                    .foregroundStyle(Color(cgColor: theme.secondary))
                }
            } else {
                placeholder {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        if slow {
                            Text("Распознавание идёт дольше обычного…").font(.caption)
                                .foregroundStyle(Color(cgColor: theme.secondary))
                            Button("Показать скан") { book.setShowScan(index, true); book.retry(index) }.controlSize(.small)
                        }
                    }
                }
            }
        }
        .onAppear { book.request(index) }
        .onChange(of: index) { slow = false; book.request(index) }
        .task(id: index) {
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled, book.pages[index] == nil { slow = true }
        }
    }

    private func placeholder<V: View>(@ViewBuilder _ v: () -> V) -> some View {
        Color.clear.aspectRatio(1 / 1.414, contentMode: .fit).overlay(v())
    }

    private func content(_ page: AnalyzedPage) -> some View {
        if (showOriginal || book.showsScan(index) || page.scanOnly), book.wantsEnhancedScan(index), book.enhancedScans[index] == nil {
            DispatchQueue.main.async { book.requestEnhancedScan(index) }
        }
        return contentBody(page)
    }

    private func contentBody(_ page: AnalyzedPage) -> some View {
        let size = page.layout.size
        let asScan = book.showsScan(index) || page.scanOnly
        let original = showOriginal || asScan
        let reflowed = settings.reflows && !asScan
        let screen = reflowed ? book.screens(index, theme: theme, settings: settings).flatMap { $0.indices.contains(sub) ? $0[sub] : $0.last } : nil
        // слова для выделения: в точной раскладке (и на скане) — по исходным рамкам, в перекомпоновке — из экранной страницы
        let words: WordGeometry? = page.scanOnly ? nil : (screen.map { WordGeometry(screen: $0, layout: page.layout) } ?? WordGeometry(layout: page.layout))
        let notes = book.annotations.items(page: index)
        return GeometryReader { geo in
            let s = geo.size.width / size.width
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    ctx.withCGContext { cg in
                        cg.scaleBy(x: s, y: s)
                        let r = PageRenderer(palette: book.palette, theme: theme)
                        if let screen { r.draw(screen, of: page, in: cg) } else { r.draw(page, in: cg) }
                    }
                }
                .opacity(original ? 0 : 1)

                // скан под тему («уровни», как у иллюстраций): светлые — умножение на лист,
                // тёмные — инверсия, окраска в цвет текста и «экран» поверх листа
                Group {
                    // при «Оригинале» — как есть; при «показывать сканом» — с уровнями под тему
                    // улучшенный скан (чёткие линии, ровный фон) — когда готов; до этого обычный
                    let enhanced = book.wantsEnhancedScan(index) ? book.enhancedScans[index] : nil
                    let img = enhanced ?? (asScan && !showOriginal ? page.leveled : nil) ?? page.original
                    if theme.isDark {
                        Image(decorative: img, scale: 1).resizable()
                            .colorInvert().colorMultiply(Color(cgColor: theme.ink)).blendMode(.screen)
                    } else {
                        Image(decorative: img, scale: 1).resizable().blendMode(.multiply)
                    }
                }
                .opacity(original ? 1 : 0)

                if book.unreliable.contains(index), asScan, !book.showScan.contains(index), !showOriginal {
                    VStack {
                        Spacer()
                        Button { book.showTextAnyway(index) } label: {
                            Label("Распознавание ненадёжно — показать текст?", systemImage: "text.viewfinder")
                                .font(.system(size: 11))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(Color(cgColor: theme.paper).opacity(0.92)))
                                .overlay(Capsule().strokeBorder(Color(cgColor: theme.secondary).opacity(0.4)))
                        }
                        .buttonStyle(.plain).foregroundStyle(Color(cgColor: theme.secondary))
                        .padding(.bottom, 8)
                    }
                    .frame(maxWidth: .infinity)
                }

                if let words, showOriginal == false || !reflowed {
                    HighlightLayer(geometry: words, annotations: notes, selection: selection, scale: s, dark: theme.isDark)
                    // невидимая точка привязки меню выделения
                    // отступами, а не .offset: popover привязывается к раскладке, а offset её не меняет
                    Color.clear.frame(width: max(1, menuRect.width * s), height: max(1, menuRect.height * s))
                        .popover(isPresented: $menuShown, arrowEdge: .bottom) { selectionMenu(words) }
                        .padding(.leading, menuRect.minX * s).padding(.top, menuRect.minY * s)
                        .allowsHitTesting(false)
                }

                if let line = loupe, !original, !reflowed, !asScan { loupeView(page, line, scale: s, pageWidth: geo.size.width) }
            }
            .contentShape(Rectangle())
            // выделение мышью: от слова до слова; отпустили — меню как в Books
            .gesture(DragGesture(minimumDistance: 4).onChanged { v in
                guard let words else { return }
                let p = CGPoint(x: v.location.x / s, y: v.location.y / s)
                if dragStart == nil { dragStart = words.gid(at: CGPoint(x: v.startLocation.x / s, y: v.startLocation.y / s)) }
                guard let a = dragStart, let b = words.gid(at: p) else { return }
                selection = min(a, b)...max(a, b)
                menuShown = false
            }.onEnded { _ in
                dragStart = nil
                guard let words, let sel = selection else { return }
                menuRect = words.rows(sel).last ?? .zero
                menuShown = true
            })
            // клик по хайлайту — его меню; мимо — снять выделение
            .simultaneousGesture(SpatialTapGesture().onEnded { v in
                guard let words else { return }
                let p = CGPoint(x: v.location.x / s, y: v.location.y / s)
                if let g = words.gid(at: p), let a = notes.first(where: {
                    if case .scan(_, let st, let en) = $0.anchor { return (st...en).contains(g) }; return false
                }), case .scan(_, let st, let en) = a.anchor, words.rows(st...en).contains(where: { $0.insetBy(dx: -2, dy: -2).contains(p) }) {
                    selection = st...en
                    menuRect = words.rows(st...en).last ?? .zero
                    menuShown = true
                } else if selection != nil, !menuShown {
                    selection = nil
                }
            })
            .onContinuousHover { phase in
                if case .active(let p) = phase {
                    hoverPoint = CGPoint(x: p.x / s, y: p.y / s)
                    loupe = NSEvent.modifierFlags.contains(.option) ? page.layout.line(at: hoverPoint) : nil
                } else {
                    loupe = nil
                }
            }
            .contextMenu {
                if !reflowed, let block = page.layout.codeBlock(at: hoverPoint) {
                    Button("Скопировать код (\(block.language.title))") { copy(block.text) }
                }
                if !asScan { Button("Скопировать текст страницы") { copy(page.layout.plainText) } }
                Divider()
                Toggle("Улучшать скан", isOn: Binding(get: { book.wantsEnhancedScan(index) },
                                                      set: { book.setScanEnhance(index, $0) }))
                    .disabled(!book.enhanceScans)
                if asScan {
                    Button("Распознать заново") {
                        if book.showScan.contains(index) { book.setShowScan(index, false) } else { book.showTextAnyway(index) }
                    }
                } else {
                    Button("Показывать скан на этой странице") { book.setShowScan(index, true) }
                    Button("Распознать заново") { book.recognizeAgain(index) }
                }
            }
        }
        .aspectRatio(size, contentMode: .fit)
        .animation(.easeInOut(duration: 0.18), value: original)
        // подсказка про ⌥-лупу всплывала поверх текста при каждом наведении — убрана (лупа осталась)
    }

    /// Меню выделения: цвет/подчёркивание, заметка, копировать, удалить.
    private func selectionMenu(_ words: WordGeometry) -> some View {
        let sel = selection ?? 0...0
        let anchor = AnnotationAnchor.scan(page: index, start: sel.lowerBound, end: sel.upperBound)
        let existing = book.annotations.existing(overlapping: anchor)
        let text = words.string(sel)
        return HighlightMenu(text: text, existing: existing,
            onStyle: { st in
                var a = existing ?? Annotation(style: st, text: text, anchor: anchor)
                a.style = st
                if existing == nil { a.anchor = anchor; a.text = text }
                book.annotations.upsert(a)
                menuShown = false; selection = nil
            },
            onNote: { n in
                var a = existing ?? Annotation(style: .yellow, text: text, anchor: anchor)
                a.note = n.isEmpty ? nil : n
                book.annotations.upsert(a)
                menuShown = false; selection = nil
            },
            onCopy: { Pasteboard.copy(text); menuShown = false },
            onDelete: {
                if let existing { book.annotations.delete(existing.id) }
                menuShown = false; selection = nil
            })
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Оригинальный фрагмент строки над ней, увеличенный в 1.5 раза.
    @ViewBuilder
    private func loupeView(_ page: AnalyzedPage, _ line: TextLine, scale s: CGFloat, pageWidth: CGFloat) -> some View {
        let r = line.bounds.insetBy(dx: -8, dy: -8).integral
        if let crop = page.original.cropping(to: r) {
            let zoom: CGFloat = 1.5
            let w = r.width * s * zoom, h = r.height * s * zoom
            Image(decorative: crop, scale: 1)
                .resizable()
                .frame(width: w, height: h)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                .offset(x: min(max(0, r.midX * s - w / 2), max(0, pageWidth - w)),
                        y: max(0, r.minY * s - h - 6))
                .allowsHitTesting(false)
        }
    }
}
