import SwiftUI

/// Поповер «Темы и настройки» (как в Apple Books): масштаб A|A, тёмный вариант, темы 3×2, «Настроить».
/// Общий для сканов/PDF и EPUB — настройки в @AppStorage.
struct AppearancePopover: View {
    @AppStorage("theme") private var themeName = ReaderTheme.calm.name
    @AppStorage("darkVariant") private var darkVariant = false
    @AppStorage("textScale") private var textScale = 1.0
    /// Масштаб подбирается автоматически, пока читатель не изменил его сам.
    @AppStorage("textScaleAuto") private var textScaleAuto = true
    /// Текущий автоматический масштаб (окно читалки сообщает его сюда), для подписи и стартовой точки.
    @AppStorage("textScaleAutoValue") private var autoValue = 1.0

    private var effective: Double { textScaleAuto ? autoValue : textScale }
    private func setManual(_ v: Double) { textScale = TextScale.clamp(v); textScaleAuto = false }
    var onCustomize: () -> Void


    var body: some View {
        VStack(spacing: 12) {
            Text("Темы и настройки").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            Divider()
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    Button { setManual(TextScale.decreased(effective)) } label: {
                        Text("A").font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(effective <= TextScale.range.lowerBound).help("Уменьшить текст")
                    Divider().frame(height: 18)
                    Button { setManual(TextScale.increased(effective)) } label: {
                        Text("A").font(.system(size: 19, weight: .medium)).frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(effective >= TextScale.range.upperBound).help("Увеличить текст")
                }
                .frame(height: 36)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                Button { darkVariant.toggle() } label: {
                    Image(systemName: "sun.horizon").font(.system(size: 15))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(darkVariant ? Color.primary.opacity(0.18) : Color.primary.opacity(0.07)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).help("Тёмный вариант темы")
            }
            HStack(spacing: 8) {
                Slider(value: Binding(get: { effective }, set: { setManual($0) }), in: TextScale.range, step: TextScale.step)
                Text(TextScale.percent(effective)).font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
            }
            HStack {
                Text(textScaleAuto ? "Авто: под размер экрана" : "Задано вручную").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                if !textScaleAuto {
                    Button("Сбросить к автоматическому") { textScaleAuto = true }
                        .buttonStyle(.link).font(.system(size: 10)).focusEffectDisabled()
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(ReaderTheme.all) { t in themeCard(t) }
            }
            Button { onCustomize() } label: {
                Label("Настроить", systemImage: "gearshape")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 34)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 250)
        .noFocusRing()       // сегмент A/A, темы, «Настроить» — без синей рамки
    }

    private func themeCard(_ t: ReaderTheme) -> some View {
        let selected = t.name == themeName
        return Button { themeName = t.name } label: {
            VStack(spacing: 1) {
                Text("Aa").font(.custom(t.cardFont, size: 22).weight(t.cardBold ? .bold : .regular))
                Text(t.name).font(.custom(t.cardFont, size: 10).weight(t.cardBold ? .bold : .regular))
            }
            .foregroundStyle(Color(cgColor: t.ink))
            .frame(maxWidth: .infinity).frame(height: 62)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(cgColor: t.paper)))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(selected ? Color.primary : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .help(t.name)
    }

}

/// Лист «Настроить»: шрифт, интервал, поля, выключка, улучшение иллюстраций, языки распознавания.
struct CustomizeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lineSpacing") private var lineSpacing = 1.0
    @AppStorage("margins") private var margins = 1.0
    @AppStorage("justify") private var justify = false
    @AppStorage("fontChoice") private var fontChoice = "theme"
    @AppStorage("enhanceFigures") private var enhanceFigures = true
    @AppStorage("enhanceScans") private var enhanceScans = true
    @AppStorage("languages") private var languagesCSV = "ru-RU,en-US"

    static let allLanguages: [(String, String)] = [
        ("ru-RU", "Русский"), ("en-US", "English"), ("uk-UA", "Українська"), ("de-DE", "Deutsch"),
        ("fr-FR", "Français"), ("es-ES", "Español"), ("it-IT", "Italiano"), ("pt-BR", "Português"),
        ("zh-Hans", "中文 (упрощ.)"), ("zh-Hant", "中文 (трад.)"), ("ja-JP", "日本語"), ("ko-KR", "한국어"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Настроить").font(.headline).padding([.top, .horizontal], 20)
            Form {
                Section("Шрифт распознанного текста") {
                    Picker("Шрифт", selection: $fontChoice) {
                        Text("Как в теме").tag("theme")
                        Text("Как в книге").tag("original")
                        Text("Iowan").tag("iowan")
                        Text("Charter").tag("charter")
                        Text("Georgia").tag("georgia")
                    }
                }
                Section {
                    LabeledContent("Межстрочный интервал") {
                        Slider(value: $lineSpacing, in: 0.8...1.6, step: 0.1).frame(width: 180)
                    }
                    LabeledContent("Поля") {
                        Slider(value: $margins, in: 0.5...1.5, step: 0.1).frame(width: 180)
                    }
                    Toggle("Выравнивание по ширине", isOn: $justify)
                } header: { Text("Перекомпоновка") } footer: {
                    Text("Действует при масштабе текста не 100%; при 100% страница повторяет оригинал строка в строку.")
                }
                Section("Распознавание") {
                    Toggle("Улучшать иллюстрации", isOn: $enhanceFigures)
                    Toggle("Улучшать сканы страниц (при показе оригиналом)", isOn: $enhanceScans)
                    ForEach(CustomizeSheet.allLanguages, id: \.0) { code, name in
                        Toggle(name, isOn: Binding(
                            get: { languagesCSV.split(separator: ",").map(String.init).contains(code) },
                            set: { on in
                                var l = languagesCSV.split(separator: ",").map(String.init).filter { $0 != code }
                                if on { l.append(code) }
                                if !l.isEmpty { languagesCSV = l.joined(separator: ",") }
                            }))
                    }
                }
            }
            .formStyle(.grouped)
            HStack { Spacer(); Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction) }
                .padding(16)
        }
        .frame(width: 440, height: 560)
    }

}
