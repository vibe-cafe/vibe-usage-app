import Foundation
import Testing
@testable import VibeUsage

/// `DateOrder.swift` declares `Date`'s `<=` / `>=` for the app module (AGENTS.md,
/// Known Constraints). This test module sees Foundation's operators as well, so
/// a date comparison written here is ambiguous on the macOS 27.2 SDK; the tests
/// exercise the app's own uses instead, which are compiled against that file.
struct DateOrderTests {
    /// `<=` in `normalizedCustomRange`: ascending bounds keep the picker's
    /// order, reversed ones are swapped.
    @Test(arguments: [-86_400.0, -0.000_001, 0.000_001, 86_400.0])
    @MainActor
    func customRangeBoundsSwapOnlyWhenReversed(offset: TimeInterval) {
        let state = AppState(loadConfig: { nil })
        let first = Date(timeIntervalSinceReferenceDate: 815_000_000)
        let second = first.addingTimeInterval(offset)
        state.customRangeFrom = first
        state.customRangeTo = second

        let bounds = state.normalizedCustomRange
        let ascending = offset > 0
        #expect(bounds.from == (ascending ? first : second))
        #expect(bounds.to == (ascending ? second : first))
    }

    /// `>=` in the login-launch proxy wait: it gives up on the round whose
    /// clock reads exactly the deadline, not one round later.
    @Test
    func loginProxyWaitStopsOnTheRoundThatReachesTheDeadline() async {
        let clock = SteppingClock()
        let rounds = RoundCounter()
        let up = await LoginLaunch.waitForProxy(
            urls: [URL(string: "https://vibefriends.com/")!],
            limit: 3,
            interval: 1,
            routes: { urls in urls.map { _ in .http(host: "127.0.0.1", port: 7890) } },
            accepts: { _, _ in
                rounds.increment()
                return false
            },
            now: { clock.now },
            sleep: { clock.advance($0) }
        )
        #expect(!up)
        #expect(clock.elapsed == 3)
        #expect(rounds.value == 4) // t = 0, 1, 2, 3
    }
}

private final class SteppingClock: @unchecked Sendable {
    private let lock = NSLock()
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private var seconds: TimeInterval = 0
    var elapsed: TimeInterval { lock.withLock { seconds } }
    var now: Date { start.addingTimeInterval(elapsed) }
    func advance(_ by: TimeInterval) { lock.withLock { seconds += by } }
}

private final class RoundCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
