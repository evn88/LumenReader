import Foundation
import OSLog
import Vision

let recognitionLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "io.github.evn88.lumenreader", category: "recognition")

/// Отмена распознавания страницы: проверяется между этапами и останавливает текущий запрос Vision.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    private var request: VNRequest?

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

    func cancel() {
        lock.lock()
        _cancelled = true
        let r = request
        lock.unlock()
        r?.cancel()
    }

    /// Запрос Vision, который сейчас выполняется (отменяется вместе с токеном).
    func attach(_ r: VNRequest?) {
        lock.lock()
        request = r
        let c = _cancelled
        lock.unlock()
        if c { r?.cancel() }
    }

    func check() throws { if isCancelled { throw CancellationError() } }
}

/// Одна очередь распознавания на всё приложение.
///
/// Раньше каждая книга запускала `Task.detached` с синхронным Vision внутри: задачи всех открытых окон
/// (и «старых поколений» после смены темы/шрифта) занимали потоки общего пула Swift concurrency,
/// и новые запросы видимых страниц не стартовали — вечный спиннер. Теперь: свои потоки,
/// глобальный лимит, приоритеты (видимые > упреждение > фон) и отмена по владельцу.
final class RecognitionQueue: @unchecked Sendable {
    static let shared = RecognitionQueue()

    enum Priority: Int, Comparable {
        case background = 0, ahead = 1, visible = 2
        static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
    }

    final class Job: @unchecked Sendable {
        let owner: UUID
        let page: Int
        var priority: Priority
        let token = CancelToken()
        let work: (CancelToken) -> Void
        let seq: Int
        init(owner: UUID, page: Int, priority: Priority, seq: Int, work: @escaping (CancelToken) -> Void) {
            self.owner = owner; self.page = page; self.priority = priority; self.seq = seq; self.work = work
        }
    }

    /// Сколько страниц распознаём одновременно (на все книги) и сколько из них может занять фон.
    let maxRunning: Int
    let maxBackground = 1

    private let lock = NSLock()
    private var pending: [Job] = []
    private var running: [Job] = []
    private var seq = 0
    private let threads = DispatchQueue(label: "scanreader.recognition", qos: .userInitiated, attributes: .concurrent)

    init(maxRunning: Int = 2) { self.maxRunning = maxRunning }

    /// Поставить страницу в очередь. `work` вызывается ровно один раз — в том числе после отмены
    /// (тогда токен уже отменён и work сразу завершается с CancellationError), чтобы ожидающие не зависали.
    @discardableResult
    func submit(owner: UUID, page: Int, priority: Priority, work: @escaping (CancelToken) -> Void) -> CancelToken {
        lock.lock()
        seq += 1
        let job = Job(owner: owner, page: page, priority: priority, seq: seq, work: work)
        pending.append(job)
        lock.unlock()
        pump()
        return job.token
    }

    /// Отменить задачи владельца (все или кроме перечисленных страниц): ждущие убираются, идущие останавливаются.
    func cancel(owner: UUID, keeping keep: Set<Int> = [], priorities: Set<Priority>? = nil) {
        lock.lock()
        func hit(_ j: Job) -> Bool { j.owner == owner && !keep.contains(j.page) && (priorities?.contains(j.priority) ?? true) }
        let dropped = pending.filter(hit)
        pending.removeAll(where: hit)
        let stopping = running.filter(hit)
        lock.unlock()
        if !dropped.isEmpty || !stopping.isEmpty {
            recognitionLog.info("отмена \(owner.uuidString.prefix(8), privacy: .public): ждущих \(dropped.count), идущих \(stopping.count)")
        }
        (dropped + stopping).forEach { $0.token.cancel() }
        // ждущие задачи всё равно «выполняются» — мгновенно, с отменённым токеном: продолжения не зависают
        for job in dropped { threads.async { job.work(job.token) } }
    }

    /// Для тестов и отладки: сколько задач владельца ждёт и выполняется.
    func stats(owner: UUID? = nil) -> (pending: Int, running: Int) {
        lock.lock(); defer { lock.unlock() }
        let p = pending.filter { owner == nil || $0.owner == owner }.count
        let r = running.filter { owner == nil || $0.owner == owner }.count
        return (p, r)
    }

    private func pump() {
        lock.lock()
        var start: [Job] = []
        while running.count < maxRunning {
            let bgRunning = running.filter { $0.priority == .background }.count
            let candidates = pending.enumerated().filter { $0.element.priority != .background || bgRunning < maxBackground }
            guard let next = candidates.max(by: { a, b in
                a.element.priority != b.element.priority ? a.element.priority < b.element.priority : a.element.seq > b.element.seq
            }) else { break }
            pending.remove(at: next.offset)
            running.append(next.element)
            start.append(next.element)
        }
        lock.unlock()
        for job in start {
            threads.async { [weak self] in
                let t0 = Date()
                recognitionLog.info("старт \(job.owner.uuidString.prefix(8), privacy: .public) стр. \(job.page + 1) [\(job.priority.rawValue)]")
                job.work(job.token)      // при отмене work сразу сообщает CancellationError
                recognitionLog.info("\(job.token.isCancelled ? "отменена" : "готово", privacy: .public) \(job.owner.uuidString.prefix(8), privacy: .public) стр. \(job.page + 1) за \(String(format: "%.2f", Date().timeIntervalSince(t0)), privacy: .public) с")
                guard let self else { return }
                self.lock.lock()
                self.running.removeAll { $0 === job }
                self.lock.unlock()
                self.pump()
            }
        }
    }
}
