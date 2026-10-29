import Foundation

// Unstructured cancellation is deliberate: a stalled framework call must not
// force its caller to join an unresponsive task after the deadline has elapsed.
@MainActor enum AsyncDeadline {
    static func run<T>(seconds: Double, operation: @escaping @MainActor () async throws -> T) async -> Result<T, Error>? {
        let gate = DeadlineGate<T>()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                gate.continuation = continuation
                guard !Task.isCancelled else { gate.finish(nil); return }
                gate.work = Task {
                    do { gate.finish(.success(try await operation())) }
                    catch { gate.finish(.failure(error)) }
                }
                gate.timer = Task {
                    do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
                    gate.finish(nil)
                }
            }
        }, onCancel: { Task { @MainActor in gate.finish(nil) } })
    }
}
@MainActor private final class DeadlineGate<T> {
    var continuation: CheckedContinuation<Result<T, Error>?, Never>?
    var work: Task<Void, Never>?
    var timer: Task<Void, Never>?
    func finish(_ result: Result<T, Error>?) {
        guard let continuation else { return }; self.continuation = nil
        timer?.cancel(); timer = nil
        if result == nil { work?.cancel() }; work = nil
        continuation.resume(returning: result)
    }
}
