import CoreGraphics
import Foundation
import Vision

/// Строка, распознанная Vision (встроенные модели macOS; на macOS 27 — самые свежие).
struct OCRLine {
    var text: String
    var box: CGRect                     // пиксели, начало — левый верхний угол
    var confidence: Float
    var words: [(text: String, box: CGRect)]
}

enum OCREngine {
    /// - Parameter languages: подсказки языков (BCP-47, напр. "ru-RU", "en-US").
    ///   Пусто — Vision определяет язык сам. Поддерживаемые языки:
    ///   `VNRecognizeTextRequest().supportedRecognitionLanguages()`.
    static func recognize(_ image: CGImage, languages: [String], languageCorrection: Bool = true,
                          customWords: [String] = [], token: CancelToken? = nil) throws -> [OCRLine] {
        try token?.check()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = languageCorrection   // для кода выключаем: ломает идентификаторы
        if !customWords.isEmpty { request.customWords = customWords }
        request.automaticallyDetectsLanguage = languages.isEmpty
        if !languages.isEmpty {
            let supported = Set((try? request.supportedRecognitionLanguages()) ?? [])
            let wanted = languages.filter { supported.isEmpty || supported.contains($0) }
            if !wanted.isEmpty { request.recognitionLanguages = wanted }
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        // закрыли книгу / сменили настройки — запрос Vision останавливается сразу
        token?.attach(request)
        defer { token?.attach(nil) }
        do {
            try handler.perform([request])
        } catch {
            // отменённый VNRequest бросает свою ошибку Vision — это отмена, а не сбой страницы
            try token?.check()
            throw error
        }
        try token?.check()

        let W = CGFloat(image.width), H = CGFloat(image.height)
        func toPixels(_ n: CGRect) -> CGRect {
            // Vision: нормированные координаты, начало — левый НИЖНИЙ угол
            CGRect(x: n.minX * W, y: (1 - n.maxY) * H, width: n.width * W, height: n.height * H)
        }

        return (request.results ?? []).compactMap { obs in
            guard let cand = obs.topCandidates(1).first else { return nil }
            let s = cand.string
            var words: [(text: String, box: CGRect)] = []
            for token in s.split(whereSeparator: \.isWhitespace) {
                let range = token.startIndex..<token.endIndex
                let box = (try? cand.boundingBox(for: range))?.boundingBox ?? .zero
                words.append((String(token), toPixels(box)))
            }
            guard !words.isEmpty else { return nil }
            return OCRLine(text: s, box: toPixels(obs.boundingBox), confidence: cand.confidence, words: words)
        }
    }
}
