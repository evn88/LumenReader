import Foundation

/// Локальная модель перевода (TranslateGemma) для языков, которых нет у системного переводчика.
/// Модель скачивается по кнопке в настройках перевода.
final class LocalModelTranslator: TranslationEngine, @unchecked Sendable {
    static let shared = LocalModelTranslator()
    let name = "TranslateGemma"

    var isInstalled: Bool { false }

    func canTranslate(from source: String, to target: String) async -> Bool { isInstalled }

    func translate(_ texts: [String], from source: String, to target: String) async throws -> [String] {
        throw TranslationProblem.unsupported(source: source, target: target)
    }
}
