import Foundation

/// Cancelling one screen must release its wait without cancelling a download shared with another.
final class AssetDownloadWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?

    func value(of task: Task<URL, Error>) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                    return
                }
                self.continuation = continuation
                lock.unlock()

                Task { finish(await task.result) }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
