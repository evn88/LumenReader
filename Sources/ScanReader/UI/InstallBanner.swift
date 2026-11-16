import AppKit
import SwiftUI

/// Плашка над библиотекой, если приложение запущено не из «Программ» — например, прямо с DMG
/// (как баннер установки в PangoZip). Копирование не делаем за пользователя: только подсказка
/// и кнопка, открывающая «Программы», куда перетаскивается значок из окна образа.
struct InstallBanner: View {
    @State private var hidden = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if Installation.needsInstallation && !hidden {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "arrow.down.app")
                    .font(.title2)
                    .foregroundStyle(Brand.amberText(scheme))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lumen Reader не установлен").font(.headline)
                    Text("Перетащите Lumen Reader в «Программы», извлеките образ диска и откройте установленное приложение — иначе обновления не смогут установиться.")
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Показать «Программы»") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
                }
                .buttonStyle(.borderedProminent)
                Button { hidden = true } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Скрыть")
                    .accessibilityLabel("Скрыть подсказку")
            }
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
            .padding(.horizontal, 24)
            .padding(.top, 8)
        }
    }
}
