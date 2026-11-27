import Foundation

/// Successful dashboard reads and the requests already fetching them. A
/// foreground selection can adopt a prefetch without restarting either leg.
@MainActor
final class RangeReadCache<Key: Hashable, Value> {
    private struct Entry {
        var value: Value?
        var succeeded: Date?
        var finished: Date
    }
    private var entries: [Key: Entry] = [:]
    private var pending: [Key: Task<Void, Never>] = [:]

    subscript(key: Key) -> Value? { entries[key]?.value }
    func inFlight(for key: Key) -> Task<Void, Never>? { pending[key] }

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

    func remove(where shouldRemove: (Key) -> Bool = { _ in true }) {
        entries = entries.filter { !shouldRemove($0.key) }
        for key in pending.keys.filter(shouldRemove) {
            pending.removeValue(forKey: key)?.cancel()
        }
    }
}
