import Foundation

/// Язык интерфейса приложения.
enum AppLanguage {
    /// Локализация, которую macOS выбрала для бандла (CFBundleLocalizations ∩ языки системы).
    /// Без бандла (swift run, тесты) — русский: в нём написан интерфейс.
    static var code: String {
        if Bundle.main.bundleIdentifier != nil, let l = Bundle.main.preferredLocalizations.first { return l }
        return "ru"
    }

    static var isRussian: Bool { code.hasPrefix("ru") }
}
