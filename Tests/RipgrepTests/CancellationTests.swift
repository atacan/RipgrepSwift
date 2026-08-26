import Foundation
import Testing

@testable import Ripgrep

struct CancellationTests {
    @Test
    func breakingOutOfIterationCancelsSearch() async throws {
        let root = try TestFixture.make([
            "big.txt": String(repeating: "needle here\n", count: 200_000),
        ])
        defer { TestFixture.remove(root) }

        var received = 0
        for try await _ in Ripgrep.search("needle", in: root) {
            received += 1
            if received == 100 {
                break // must stop the native search, not just the loop
            }
        }

        #expect(received == 100)
    }

    @Test
    func cancellingConsumingTaskTerminatesSearch() async throws {
        let root = try TestFixture.make([
            "big.txt": String(repeating: "needle here\n", count: 500_000),
        ])
        defer { TestFixture.remove(root) }

        let consuming = Task<Int, Error> {
            var count = 0
            for try await _ in Ripgrep.search("needle", in: root) {
                count += 1
            }
            return count
        }

        // Give the search a moment to get going, then cancel it.
        try await Task.sleep(for: .milliseconds(50))
        consuming.cancel()

        // Must terminate promptly rather than hanging on the native call,
        // and cancellation must not surface as a thrown error.
        let count = try await consuming.value
        #expect(count >= 1)
    }

    @Test
    func nativeSearchStopsAtCancellationPoint() async throws {
        // 2,000,000 matching lines. A full scan would invoke the native
        // callback 2,000,000 times; breaking after 100 deliveries must stop
        // the native search almost immediately.
        let totalLines = 2_000_000
        let root = try TestFixture.make([
            "big.txt": String(repeating: "needle here\n", count: totalLines),
        ])
        defer { TestFixture.remove(root) }

        let (results, statistics) = Ripgrep.searchWithStatistics("needle", in: root)

        var received = 0
        for try await _ in results {
            received += 1
            if received == 100 {
                break
            }
        }

        // Explicit, deterministic cancellation: the parked native callback
        // unwinds instead of waiting for object lifetimes to settle.
        results.cancel()

        // Wait for the native side to fully unwind before reading counters.
        while !statistics.isFinished {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(received == 100)
        // Every delivered match crossed the native callback, and at most one
        // extra callback may have been in flight when cancellation landed:
        // with strict backpressure the search cannot advance without demand.
        #expect(statistics.deliveredMatchCount >= 100)
        #expect(statistics.deliveredMatchCount <= 102)
    }

    @Test
    func cancelMethodStopsNativeSearchWithoutIterating() async throws {
        let totalLines = 2_000_000
        let root = try TestFixture.make([
            "big.txt": String(repeating: "needle here\n", count: totalLines),
        ])
        defer { TestFixture.remove(root) }

        let (results, statistics) = Ripgrep.searchWithStatistics("needle", in: root)

        // Consume nothing at all, then cancel. The producer is parked on the
        // first delivery gate; cancellation must unwind it cleanly.
        results.cancel()

        while !statistics.isFinished {
            try await Task.sleep(for: .milliseconds(5))
        }

        // At most the single callback that parked on the empty-demand gate.
        #expect(statistics.deliveredMatchCount <= 1)
    }
}
