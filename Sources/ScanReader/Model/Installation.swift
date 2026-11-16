import Foundation

/// Где запущено приложение (как FinderInstallation в PangoZip). Установленным считается .app
/// в «Программах» (/Applications или ~/Applications) на диске с правом записи, вне корзины и
/// вне App Translocation. Запуск прямо с DMG (том только для чтения) или из «Загрузок» — нет:
/// Sparkle не сможет заменить такое приложение при обновлении.
enum Installation {
    static let applicationDirectories: [URL] = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
    ]

    /// Подсказку «перетащите в Программы» показываем только собранному .app (не `swift run`).
    static var needsInstallation: Bool {
        let app = Bundle.main.bundleURL
        return app.pathExtension == "app" && !isInstalled(app)
    }

    static func isInstalled(_ applicationURL: URL,
                            in directories: [URL] = applicationDirectories,
                            isReadOnly: (URL) -> Bool = volumeIsReadOnly) -> Bool {
        guard applicationURL.isFileURL, applicationURL.pathExtension == "app" else { return false }
        let app = applicationURL.resolvingSymlinksInPath().standardizedFileURL
        let forbidden: Set<String> = [".Trash", ".Trashes", "AppTranslocation"]
        guard !app.pathComponents.contains(where: forbidden.contains) else { return false }
        let inApplications = directories.contains { dir in
            let root = dir.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            let path = app.pathComponents
            // сразу в папке или во вложенной (Программы/Утилиты), но не внутри другого .app
            return path.count > root.count && path.starts(with: root)
                && !path.dropFirst(root.count).dropLast().contains { $0.hasSuffix(".app") }
        }
        return inApplications && !isReadOnly(app)
    }

    static func volumeIsReadOnly(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
    }
}
