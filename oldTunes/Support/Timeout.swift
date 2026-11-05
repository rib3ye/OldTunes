import Foundation
import os

struct TimeoutError: LocalizedError {
    var seconds: Double
    var errorDescription: String? { "Timed out after \(seconds) s" }
}

/// Runs `body` but returns at the deadline even if `body` never finishes.
///
/// Some MusicKit calls hang forever when the app is not authorized (RESEARCH.md §3.6, §5.6), so
/// every MusicKit await goes through this: 5 s for small calls, 30 s for the full library request.
///
/// A task group cannot do this: it always waits for every child, so a call that ignores
/// cancellation would still block the caller (measured: a 0.3 s group timeout returned after
/// 2.1 s). Here the body runs in an unstructured task; at the deadline the caller gets a
/// `TimeoutError` and the stuck task is cancelled and abandoned. Cancelling the caller also
/// returns at once with `CancellationError`.
func withTimeout<T: Sendable>(_ seconds: Double,
                              _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    let race = TimeoutRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            let timer = Task {
                try? await Task.sleep(for: .seconds(seconds))
                if !Task.isCancelled { race.finish(.failure(TimeoutError(seconds: seconds))) }
            }
            let work = Task {
                do { race.finish(.success(try await body())) } catch { race.finish(.failure(error)) }
            }
            race.start(continuation, cancelling: [timer, work])
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// The first of body, timer and caller-cancellation to finish wins, exactly once. A result can
/// arrive before the continuation is installed (cancellation, or a body that returns at once),
/// so it is held until `start`.
private final class TimeoutRace<T: Sendable>: Sendable {
    private enum State {
        case pending(Result<T, any Error>?)
        case waiting(CheckedContinuation<T, any Error>, [Task<Void, Never>])
        case finished
    }

    private let state = OSAllocatedUnfairLock<State>(uncheckedState: .pending(nil))

    func start(_ continuation: CheckedContinuation<T, any Error>, cancelling tasks: [Task<Void, Never>]) {
        let early = state.withLockUnchecked { state -> Result<T, any Error>? in
            switch state {
            case .pending(let result?):
                state = .finished
                return result
            case .pending(nil):
                state = .waiting(continuation, tasks)
                return nil
            case .waiting, .finished:
                return nil
            }
        }
        if let early {
            tasks.forEach { $0.cancel() }
            continuation.resume(with: early)
        }
    }

    func finish(_ result: Result<T, any Error>) {
        let waiter = state.withLockUnchecked { state -> (CheckedContinuation<T, any Error>, [Task<Void, Never>])? in
            switch state {
            case .pending(nil):
                state = .pending(result)
                return nil
            case .waiting(let continuation, let tasks):
                state = .finished
                return (continuation, tasks)
            case .pending, .finished:
                return nil
            }
        }
        guard let (continuation, tasks) = waiter else { return }
        // The loser stops: a finished body cancels its timer, a timeout cancels the stuck body.
        tasks.forEach { $0.cancel() }
        continuation.resume(with: result)
    }
}
