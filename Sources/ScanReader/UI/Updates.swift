import AppKit
import Sparkle
import SwiftUI

/// Автообновление через Sparkle 2 (как в PangoZip): лента и публичный ключ — из Info.plist (product.env).
/// Без настроенной ленты/ключа (swift run, тесты) обновлятор не запускается и пункты меню скрыты.
@MainActor
final class ApplicationUpdater: ObservableObject {
    static let shared = ApplicationUpdater()

    @Published private(set) var canCheckForUpdates = false
    @Published var automaticallyChecksForUpdates = true {
        didSet { if started { controller?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates } }
    }

    private var controller: SPUStandardUpdaterController?
    private var started = false
    private var observation: NSKeyValueObservation?

    var isConfigured: Bool { UpdateConfiguration.isConfigured(infoDictionary: Bundle.main.infoDictionary) }

    func start() {
        guard !started, isConfigured else { return }
        let c = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        do {
            try c.updater.start()
        } catch {
            NSLog("Sparkle: %@", error.localizedDescription)
            return
        }
        controller = c
        started = true
        automaticallyChecksForUpdates = c.updater.automaticallyChecksForUpdates
        canCheckForUpdates = c.updater.canCheckForUpdates
        observation = c.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] u, _ in
            let can = u.canCheckForUpdates
            Task { @MainActor in self?.canCheckForUpdates = can }
        }
        // проверка при запуске (через 5 с), не дожидаясь суточного расписания Sparkle
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.automaticallyChecksForUpdates, let c = self.controller, !c.updater.sessionInProgress else { return }
            c.updater.checkForUpdatesInBackground()
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }
}

enum UpdateConfiguration {
    /// Лента — HTTPS, ключ — 32 байта Ed25519, проверка подписи ленты и архива включена.
    static func isConfigured(infoDictionary: [String: Any]?) -> Bool {
        guard let info = infoDictionary,
              let feed = info["SUFeedURL"] as? String, let url = URL(string: feed), url.scheme == "https", url.host != nil,
              let key = info["SUPublicEDKey"] as? String, Data(base64Encoded: key)?.count == 32,
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
              info["SURequireSignedFeed"] as? Bool == true
        else { return false }
        return true
    }
}

/// Раздел «Обновления» в настройках.
struct UpdatesSection: View {
    @ObservedObject var updater = ApplicationUpdater.shared

    var body: some View {
        Section("Обновления") {
            Toggle("Автоматически проверять обновления", isOn: $updater.automaticallyChecksForUpdates)
            Button("Проверить обновления…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
    }
}
