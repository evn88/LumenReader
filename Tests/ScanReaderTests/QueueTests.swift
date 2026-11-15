import XCTest
@testable import ScanReader

final class QueueTests: XCTestCase {
    func testPriorityAndLimit() {
        let q = RecognitionQueue(maxRunning: 1)
        let owner = UUID()
        let gate = DispatchSemaphore(value: 0)
        var order: [Int] = []
        let lock = NSLock()
        let done = expectation(description: "all")
        done.expectedFulfillmentCount = 3
        q.submit(owner: owner, page: 0, priority: .ahead) { _ in gate.wait(); lock.lock(); order.append(0); lock.unlock(); done.fulfill() }
        q.submit(owner: owner, page: 1, priority: .background) { _ in lock.lock(); order.append(1); lock.unlock(); done.fulfill() }
        q.submit(owner: owner, page: 2, priority: .visible) { _ in lock.lock(); order.append(2); lock.unlock(); done.fulfill() }
        XCTAssertEqual(q.stats(owner: owner).running, 1)
        gate.signal()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(order, [0, 2, 1], "видимая страница раньше фоновой")
    }

    func testCancelOwnerResumesPendingAndStopsRunning() {
        let q = RecognitionQueue(maxRunning: 1)
        let a = UUID(), b = UUID()
        let started = DispatchSemaphore(value: 0)
        let finished = expectation(description: "finished")
        finished.expectedFulfillmentCount = 3
        var cancelled: [Int] = []
        let lock = NSLock()
        q.submit(owner: a, page: 0, priority: .visible) { token in
            started.signal()
            while !token.isCancelled { usleep(1000) }        // «долгий Vision», который останавливается отменой
            lock.lock(); cancelled.append(0); lock.unlock(); finished.fulfill()
        }
        q.submit(owner: a, page: 1, priority: .visible) { token in
            lock.lock(); if token.isCancelled { cancelled.append(1) }; lock.unlock(); finished.fulfill()
        }
        var otherRan = false
        q.submit(owner: b, page: 0, priority: .ahead) { token in otherRan = !token.isCancelled; finished.fulfill() }
        started.wait()
        q.cancel(owner: a)
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(Set(cancelled), [0, 1], "идущая остановлена, ждущая завершена с отменой")
        XCTAssertTrue(otherRan, "задачи другой книги не трогаем")
        XCTAssertEqual(q.stats(owner: a).pending + q.stats(owner: a).running, 0)
    }

    func testTokenCancelsAttachedRequest() {
        let t = CancelToken()
        XCTAssertNoThrow(try t.check())
        t.cancel()
        XCTAssertThrowsError(try t.check())
    }

    @MainActor
    func testClosedBookStopsWork() async throws {
        let demo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("demo/library/React для всех (сканы)")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("close-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: demo, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let book = try XCTUnwrap(BookModel(url: tmp))
        book.prefetch(visible: [0, 1])
        try await Task.sleep(for: .milliseconds(300))
        book.close()
        try await Task.sleep(for: .seconds(2))
        let after = book.cached.count
        try await Task.sleep(for: .seconds(4))
        XCTAssertEqual(book.cached.count, after, "после закрытия новые страницы не распознаются")
        XCTAssertTrue(book.pages.isEmpty)
    }
}
