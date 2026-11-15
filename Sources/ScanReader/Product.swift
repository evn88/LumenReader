import Foundation

/// Название продукта в интерфейсе. Источник — product.env (попадает в Info.plist при сборке .app);
/// при запуске без бандла (swift run, тесты) — запасное значение ниже, его обновляет scripts/rename.sh.
enum Product {
    static let fallbackName = "Lumen Reader"

    static var name: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? fallbackName
    }

    static var bundleID: String { Bundle.main.bundleIdentifier ?? "io.github.evn88.lumenreader" }

    /// Папка данных в Application Support и Caches.
    static let dataFolder = "Lumen Reader"

    /// Прежние имена: при первом запуске под новым именем переносим данные и настройки,
    /// чтобы не терять кеш распознавания, модели, папку библиотеки и оформление.
    static let legacyFolders = ["ScanReader"]
    static let legacyDefaults = ["com.local.scanreader"]

    static func migrate() {
        let fm = FileManager.default
        for base in [FileManager.SearchPathDirectory.applicationSupportDirectory, .cachesDirectory] {
            guard let root = fm.urls(for: base, in: .userDomainMask).first else { continue }
            let new = root.appendingPathComponent(dataFolder)
            for old in legacyFolders.map({ root.appendingPathComponent($0) })
            where fm.fileExists(atPath: old.path) && !fm.fileExists(atPath: new.path) {
                try? fm.moveItem(at: old, to: new)
            }
        }
        let d = UserDefaults.standard
        guard Bundle.main.bundleIdentifier != nil, d.object(forKey: "migratedFrom") == nil else { return }
        for id in legacyDefaults where id != Bundle.main.bundleIdentifier {
            guard let old = UserDefaults(suiteName: id)?.persistentDomain(forName: id), !old.isEmpty else { continue }
            for (k, v) in old where d.object(forKey: k) == nil && !k.hasPrefix("NSWindow Frame") { d.set(v, forKey: k) }
            d.set(id, forKey: "migratedFrom")
        }
    }
}
