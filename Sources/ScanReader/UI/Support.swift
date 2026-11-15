import AppKit
import SwiftUI

/// Поддержка разработки (как в PangoZip): ссылка — только из Info.plist (`SupportURL`, задаётся в product.env).
enum SupportConfiguration {
    static var pageURL: URL? { pageURL(infoDictionary: Bundle.main.infoDictionary) }

    /// Без настроенной HTTPS-страницы раздел скрыт; адреса с учётными данными отклоняются.
    static func pageURL(infoDictionary: [String: Any]?) -> URL? {
        guard let value = infoDictionary?["SupportURL"] as? String,
              let c = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              c.scheme?.lowercased() == "https", let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil else { return nil }
        return c.url
    }

    @MainActor static func open() -> Bool {
        guard let url = pageURL else { return false }
        return NSWorkspace.shared.open(url)
    }
}

/// Раздел «Поддержать проект» в настройках.
struct DevelopmentSupportSection: View {
    let pageURL: URL
    @State private var showingOpenError = false

    var body: some View {
        Section("Поддержать \(Product.name)") {
            Text("Если \(Product.name) вам полезен, вы можете поддержать его разработку добровольным донатом.")
                .font(.callout)
            Button {
                showingOpenError = !NSWorkspace.shared.open(pageURL)
            } label: {
                Label("Поддержать проект…", systemImage: "heart")
            }
            .help("Открыть страницу поддержки в браузере")
            Text("Страница поддержки (GitHub Sponsors) откроется в браузере.").font(.caption).foregroundStyle(.secondary)
        }
        .alert("Не удалось открыть страницу поддержки", isPresented: $showingOpenError) {
            Button("ОК", role: .cancel) {}
        } message: {
            Text("Проверьте, что в macOS выбран браузер по умолчанию, и попробуйте ещё раз.")
        }
    }
}

/// Окно «О программе»: версия, ссылка на исходники, кнопка поддержки.
struct AboutView: View {
    var body: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        VStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().scaledToFit().frame(width: 80, height: 80).accessibilityHidden(true)
            Text(Product.name).font(.title).fontWeight(.semibold)
            if !version.isEmpty { Text("Версия \(version)").font(.callout).foregroundStyle(.secondary) }
            Divider()
            Link("github.com/evn88", destination: URL(string: "https://github.com/evn88")!)
            if let url = SupportConfiguration.pageURL {
                Link(destination: url) { Label("GitHub Sponsors", systemImage: "heart") }
                    .buttonStyle(.borderedProminent)
                    .help("Открыть страницу поддержки в браузере")
            }
            Text("Свободная программа под лицензией MIT").font(.caption).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 340)
    }
}
