import Foundation

/// Successful dashboard reads and the requests already fetching them. A
/// foreground selection can adopt a prefetch without restarting either leg.
@MainActor
final class RangeReadCache<Key: Hashable, Value> {
    private struct Entry {
        var value: Value?
        var succeeded: Date?
        var finished: Date
        var lastReadSucceeded = false
    }
    private var entries: [Key: Entry] = [:]
    private var pending: [Key: Task<Void, Never>] = [:]

    subscript(key: Key) -> Value? { entries[key]?.value }
    func inFlight(for key: Key) -> Task<Void, Never>? { pending[key] }
    func lastReadSucceeded(for key: Key) -> Bool { entries[key]?.lastReadSucceeded == true }

    func read(_ key: Key, reuseFor interval: TimeInterval, debounceFailure: Bool = false,
              now: @escaping () -> Date, fetch: @escaping @MainActor () async throws -> Value,
              finished: @escaping (Value?) -> Void) -> Task<Void, Never>? {
        if let task = pending[key] { return task }
        let last = debounceFailure ? entries[key]?.finished : entries[key]?.succeeded
        if let last, now().timeIntervalSince(last) < interval { return nil }

        let task = Task {
            guard !Task.isCancelled else { return }
            let result = try? await fetch()
            guard !Task.isCancelled else { return }
            let time = now()
            var entry = entries[key] ?? Entry(finished: time)
            entry.finished = time
            entry.lastReadSucceeded = result != nil
            if let result {
                entry.value = result
                entry.succeeded = time
            }
            entries[key] = entry
            pending[key] = nil
            finished(entry.value)
        }
        pending[key] = task
        return task
    }

    /// Keep the figures for instant display, but let the next selection refresh
    /// them. A request started before the sync cannot make them fresh again.
    func markStale(asOf cutoff: Date, where matches: (Key) -> Bool) {
        for (key, var entry) in entries where matches(key) {
            entry.succeeded = entry.succeeded.map { min($0, cutoff) }
            entry.finished = min(entry.finished, cutoff)
            entries[key] = entry
        }
        cancelPending(where: matches)
    }

    func remove(where shouldRemove: (Key) -> Bool = { _ in true }) {
        entries = entries.filter { !shouldRemove($0.key) }
        cancelPending(where: shouldRemove)
    }

    private func cancelPending(where matches: (Key) -> Bool) {
        for key in pending.keys.filter(matches) {
            pending.removeValue(forKey: key)?.cancel()
        }
    }
}
