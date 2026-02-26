import Foundation

/// Schedules periodic sync at a fixed interval (default 5 minutes)
final class SyncScheduler: Sendable {
    private let interval: TimeInterval
    private let action: @Sendable () async -> Void
    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    private nonisolated(unsafe) var started = false

    /// - Parameters:
    ///   - interval: Seconds between syncs (default 300 = 5 minutes)
    ///   - action: Async closure to execute on each tick
    init(interval: TimeInterval = 300, action: @escaping @Sendable () async -> Void) {
        self.interval = interval
        self.action = action
    }

    func start() {
        guard !started else { return }
        started = true

        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .seconds(10)
        )
        timer.setEventHandler { [action] in
            Task {
                await action()
            }
        }
        timer.resume()
    }

    func stop() {
        guard started else { return }
        started = false
        timer.cancel()
    }

    deinit {
        if started {
            timer.cancel()
        }
    }
}
