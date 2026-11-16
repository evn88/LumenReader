import Combine
import Foundation
import llama

/// Локальная модель перевода TranslateGemma 4B (GGUF, llama.cpp на Metal) — для языков, которых нет
/// у системного переводчика (сербский, чешский, хорватский…). Скачивается по кнопке в панели «Перевод».
final class LocalModelTranslator: TranslationEngine, @unchecked Sendable {
    static let shared = LocalModelTranslator()
    let name = "TranslateGemma"

    static let fileName = "translategemma-4b-it.Q4_K_M.gguf"
    static let downloadURL = URL(string: "https://huggingface.co/mradermacher/translategemma-4b-it-GGUF/resolve/main/translategemma-4b-it.Q4_K_M.gguf")!
    static let approximateSize: Int64 = 2_490_000_000

    static var file: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("\(Product.dataFolder)/Models/\(fileName)")
    }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: Self.file.path) }

    func canTranslate(from source: String, to target: String) async -> Bool {
        isInstalled && Self.languageName(source) != nil && Self.languageName(target) != nil
    }

    func translate(_ texts: [String], from source: String, to target: String) async throws -> [String] {
        guard isInstalled else { throw TranslationProblem.unsupported(source: source, target: target) }
        guard let sName = Self.languageName(source), let tName = Self.languageName(target) else {
            throw TranslationProblem.unsupported(source: source, target: target)
        }
        var out: [String] = []
        for t in texts {
            try Task.checkCancellation()
            let prompt = Self.prompt(t, source: (sName, LanguageGuess.base(source)), target: (tName, LanguageGuess.base(target)))
            out.append(try await LlamaRunner.shared.generate(prompt: prompt, model: Self.file, maxTokens: max(64, t.count * 2)))
        }
        return out
    }

    /// Название языка по-английски — так его ждёт шаблон TranslateGemma.
    static func languageName(_ code: String) -> String? {
        Locale(identifier: "en").localizedString(forLanguageCode: LanguageGuess.base(code))
    }

    /// Промпт из шаблона чата TranslateGemma (chat_template.jinja модели), без BOS — его добавит токенизатор.
    static func prompt(_ text: String, source: (String, String), target: (String, String)) -> String {
        "<start_of_turn>user\nYou are a professional \(source.0) (\(source.1)) to \(target.0) (\(target.1)) translator. "
            + "Your goal is to accurately convey the meaning and nuances of the original \(source.0) text while adhering to "
            + "\(target.0) grammar, vocabulary, and cultural sensitivities.\n"
            + "Produce only the \(target.0) translation, without any additional explanations or commentary. "
            + "Please translate the following \(source.0) text into \(target.0):\n\n\n"
            + text.trimmingCharacters(in: .whitespacesAndNewlines)
            + "<end_of_turn>\n<start_of_turn>model\n"
    }
}

/// llama.cpp: модель держится в памяти, пока ей пользуются, и выгружается через 2 минуты простоя (~3 ГБ).
/// Все вызовы llama — на одной последовательной очереди; при выходе из приложения модель выгружается
/// синхронно (иначе Metal-бэкенд ggml падает на ассерте в деструкторах).
final class LlamaRunner: @unchecked Sendable {
    static let shared = LlamaRunner()
    private let queue = DispatchQueue(label: "lumen.llama", qos: .userInitiated)
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var loadedPath: String?
    private var lastUse = Date()
    private var unloadItem: DispatchWorkItem?
    private static let contextSize: Int32 = 4096

    enum Failure: LocalizedError {
        case load, context, tooLong, decode
        var errorDescription: String? {
            switch self {
            case .load: "Не удалось загрузить модель перевода"
            case .context: "Не хватает памяти для модели перевода"
            case .tooLong: "Абзац слишком длинный для модели перевода"
            case .decode: "Модель перевода вернула ошибку"
            }
        }
    }

    /// Выгрузить модель сейчас (выход из приложения, удаление модели).
    func shutdown() { queue.sync { unload() } }

    func generate(prompt: String, model url: URL, maxTokens: Int) async throws -> String {
        let cancelled = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<String, Error>) in
                queue.async {
                    k.resume(with: Result { try self.run(prompt: prompt, url: url, maxTokens: maxTokens, cancelled: cancelled) })
                }
            }
        } onCancel: { cancelled.set() }
    }

    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func ensureLoaded(_ url: URL) throws {
        if loadedPath == url.path, model != nil, ctx != nil { return }
        unload()
        llama_backend_init()
        var mp = llama_model_default_params()
        mp.n_gpu_layers = 99
        guard let m = llama_model_load_from_file(url.path, mp) else { throw Failure.load }
        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(Self.contextSize)
        cp.n_batch = UInt32(Self.contextSize)
        cp.n_threads = Int32(max(2, ProcessInfo.processInfo.activeProcessorCount - 2))
        cp.n_threads_batch = cp.n_threads
        guard let c = llama_init_from_model(m, cp) else { llama_model_free(m); throw Failure.context }
        model = m; ctx = c; loadedPath = url.path
    }

    private func unload() {
        unloadItem?.cancel(); unloadItem = nil
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
        ctx = nil; model = nil; loadedPath = nil
    }

    private func scheduleUnload() {
        unloadItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, Date().timeIntervalSince(self.lastUse) >= 110 else { return }
            self.unload()
        }
        unloadItem = item
        queue.asyncAfter(deadline: .now() + 120, execute: item)
    }

    private func run(prompt: String, url: URL, maxTokens: Int, cancelled: CancelFlag) throws -> String {
        if cancelled.isSet { throw CancellationError() }
        try ensureLoaded(url)
        defer { lastUse = Date(); scheduleUnload() }
        guard let model, let ctx, let vocab = llama_model_get_vocab(model) else { throw Failure.load }
        llama_memory_clear(llama_get_memory(ctx), true)

        // токены промпта (BOS добавляет токенизатор, служебные <start_of_turn> разбираются как токены)
        let utf8 = Array(prompt.utf8CString)
        var tokens = [llama_token](repeating: 0, count: utf8.count + 8)
        let n = llama_tokenize(vocab, prompt, Int32(utf8.count - 1), &tokens, Int32(tokens.count), true, true)
        guard n > 0 else { throw Failure.decode }
        tokens = Array(tokens.prefix(Int(n)))
        let budget = min(maxTokens, Int(Self.contextSize) - tokens.count - 8)
        guard budget > 16 else { throw Failure.tooLong }

        let decodeOK = tokens.withUnsafeMutableBufferPointer { buf in
            llama_decode(ctx, llama_batch_get_one(buf.baseAddress, Int32(buf.count))) == 0
        }
        guard decodeOK else { throw Failure.decode }

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        var bytes: [CChar] = []
        var piece = [CChar](repeating: 0, count: 256)
        for _ in 0..<budget {
            if cancelled.isSet { throw CancellationError() }
            var tok = llama_sampler_sample(sampler, ctx, -1)
            if llama_vocab_is_eog(vocab, tok) { break }
            let len = llama_token_to_piece(vocab, tok, &piece, Int32(piece.count), 0, false)
            if len > 0 { bytes += piece.prefix(Int(len)) }
            if llama_decode(ctx, llama_batch_get_one(&tok, 1)) != 0 { break }
        }
        var text = String(decoding: bytes.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        // на всякий случай: служебные метки, если модель их напечатала текстом
        for mark in ["<end_of_turn>", "<start_of_turn>"] {
            if let r = text.range(of: mark) { text = String(text[..<r.lowerBound]) }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Скачивание и удаление модели (панель «Перевод»).
@MainActor
final class LocalModelStore: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = LocalModelStore()

    enum State: Equatable { case notInstalled, downloading(Double), installed, failed(String) }
    @Published private(set) var state: State = .notInstalled

    private var task: URLSessionDownloadTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    override init() {
        super.init()
        state = LocalModelTranslator.shared.isInstalled ? .installed : .notInstalled
    }

    func download() {
        guard task == nil else { return }
        state = .downloading(0)
        task = session.downloadTask(with: LocalModelTranslator.downloadURL)
        task?.resume()
    }

    func cancel() { task?.cancel(); task = nil; state = .notInstalled }

    func remove() {
        LlamaRunner.shared.shutdown()
        try? FileManager.default.removeItem(at: LocalModelTranslator.file)
        state = .notInstalled
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : LocalModelTranslator.approximateSize
        let p = Double(totalBytesWritten) / Double(total)
        MainActor.assumeIsolated { if case .downloading = state { state = .downloading(min(1, p)) } }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // файл во временной папке живёт только до конца этого вызова — переносим сразу
        let dest = LocalModelTranslator.file
        let fm = FileManager.default
        var error: String?
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            error = "сервер ответил \(http.statusCode)"
        } else {
            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: location, to: dest)
                // проверка: GGUF начинается с «GGUF»
                let h = try FileHandle(forReadingFrom: dest)
                let magic = try h.read(upToCount: 4)
                try h.close()
                if magic != Data("GGUF".utf8) { try? fm.removeItem(at: dest); error = "файл модели повреждён" }
            } catch let e { error = e.localizedDescription }
        }
        let err = error
        MainActor.assumeIsolated {
            task = nil
            state = err.map { .failed("Не удалось скачать модель: \($0)") } ?? .installed
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        let m = error.localizedDescription
        MainActor.assumeIsolated { self.task = nil; state = .failed("Не удалось скачать модель: \(m)") }
    }
}
