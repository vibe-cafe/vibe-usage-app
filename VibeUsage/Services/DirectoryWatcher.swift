import Foundation

/// Watches one directory for entry changes (create / rename / delete) via a
/// kqueue-backed DispatchSource, with a short debounce.
///
/// Used to live-refresh the Claude quota card while the popover is open: the
/// statusline wrapper replaces `claude-rate-limits.json` atomically (mktemp +
/// mv), so watching the *file's* vnode would break on the first rewrite — the
/// directory is the stable observation point. The debounce absorbs bursts
/// (Claude Code can re-render its statusline several times per second during
/// an active turn, and other writers share `~/.vibe-usage`).
@MainActor
final class DirectoryWatcher {
    private let onChange: @MainActor () -> Void
    private var source: (any DispatchSourceFileSystemObject)?
    private var debounce: Task<Void, Never>?

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    @discardableResult
    func start(directory: URL) -> Bool {
        stop()
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            debugLog("[watcher] cannot open \(directory.path) — live refresh disabled")
            return false
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            // Handler runs on the main queue (see `queue:` above), so hopping
            // into the main actor is a no-op assertion, not a dispatch.
            MainActor.assumeIsolated {
                self?.scheduleChange()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        return true
    }

    func stop() {
        debounce?.cancel()
        debounce = nil
        source?.cancel()
        source = nil
    }

    private func scheduleChange() {
        debounce?.cancel()
        debounce = Task { [onChange] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            onChange()
        }
    }
}
