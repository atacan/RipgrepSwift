import Foundation
import Testing

@testable import Ripgrep

/// Regression tests for the producer lifecycle: lazy startup, strict
/// backpressure, and native cancellation that does not depend on match
/// callbacks. Every "absence of activity" assertion is structural (the
/// producer can only start through iterator creation); bounded waits are
/// used only to await observable unwind, never to assert inactivity.
struct CancellationTests {
    // MARK: Break without explicit cancel()

    /// Consuming 100 results and breaking — *without* ever calling
    /// `cancel()` — must stop the native search. Dropping the live
    /// iterator at loop exit cancels the session deterministically.
    @Test
    func breakAloneStopsNativeSearch() async throws {
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
                break // no cancel() afterwards on purpose
            }
        }

        // The iterator died with the loop; the producer must unwind on its
        // own instead of scanning the remaining ~2M matches.
        let finished = try await waitUntil { statistics.isFinished }
        #expect(finished)

        #expect(received == 100)
        // Every delivered match crossed the native callback; with strict
        // backpressure the search cannot advance past one extra in-flight
        // callback. A full scan would show millions here.
        #expect(statistics.deliveredMatchCount >= 100)
        #expect(statistics.deliveredMatchCount <= 102)
        #expect(statistics.producerStartCount == 1)
    }

    // MARK: Explicit cancel() before iteration

    /// `cancel()` before any iterator exists must prevent the producer
    /// from starting at all (lazy startup), and later iteration must end
    /// immediately and cleanly.
    @Test
    func cancelBeforeIterationPreventsStartupAndEndsInstantly() async throws {
        let root = try TestFixture.make([
            "big.txt": String(repeating: "needle here\n", count: 500_000),
        ])
        defer { TestFixture.remove(root) }

        let (results, statistics) = Ripgrep.searchWithStatistics("needle", in: root)

        results.cancel()

        let iterator = results.makeAsyncIterator()
        let first = try await iterator.next()
        #expect(first == nil)

        // Structural: startup happens only inside makeAsyncIterator, and
        // cancellation there suppresses it.
        #expect(statistics.producerStartCount == 0)
        #expect(statistics.deliveredMatchCount == 0)
        #expect(!statistics.isFinished) // never ran, so never finished

        // Cancel is idempotent.
        results.cancel()
        results.cancel()
        #expect(try await iterator.next() == nil)
        #expect(statistics.producerStartCount == 0)
    }

    /// Calling `cancel()` after creating an iterator but before requesting
    /// any element stops the search before more than the single parked
    /// callback can occur.
    @Test
    func cancelAfterIterationStartButWithoutRequestsStopsNativeSearch() async throws {
        let totalLines = 2_000_000
        let root = try TestFixture.make([
            "big.txt": String(repeating: "needle here\n", count: totalLines),
        ])
        defer { TestFixture.remove(root) }

        let (results, statistics) = Ripgrep.searchWithStatistics("needle", in: root)

        let iterator = results.makeAsyncIterator()
        #expect(statistics.producerStartCount == 1)

        // Consume nothing at all, then cancel. The producer is parked on
        // the empty-demand gate; cancellation unwinds it cleanly.
        results.cancel()

        let finished = try await waitUntil { statistics.isFinished }
        #expect(finished)

        #expect(try await iterator.next() == nil)
        #expect(statistics.deliveredMatchCount <= 1)
    }

    // MARK: Dropped before iteration

    /// Creating the sequence and dropping it without iterating or calling
    /// `cancel()` must leave no native work behind: with lazy startup the
    /// producer cannot even exist unless an iterator was created.
    @Test
    func droppingResultsWithoutIterationNeverStartsNativeSearch() async throws {
        let root = try TestFixture.make([
            "big.txt": String(repeating: "needle here\n", count: 500_000),
        ])
        defer { TestFixture.remove(root) }

        for _ in 0..<25 {
            let statistics = SearchStatistics()
            do {
                _ = Ripgrep.makeSearchResults(
                    "needle",
                    in: root,
                    options: .init(),
                    statistics: statistics
                )
            } // dropped right here: no iterator, no cancel()
            #expect(statistics.producerStartCount == 0)
            #expect(statistics.deliveredMatchCount == 0)
            #expect(!statistics.isFinished)
        }
    }

    /// Dropping an iterator that was created but never consumed also
    /// cancels deterministically — no lingering thread, no parked
    /// producer.
    @Test
    func droppingCreatedButUnconsumedIteratorCancelsSearch() async throws {
        let totalLines = 2_000_000
        let root = try TestFixture.make([
            "big.txt": String(repeating: "needle here\n", count: totalLines),
        ])
        defer { TestFixture.remove(root) }

        var statisticsBox: SearchStatistics?
        do {
            let (results, statistics) = Ripgrep.searchWithStatistics("needle", in: root)
            statisticsBox = statistics
            _ = results.makeAsyncIterator()
            // Iterator dropped without a single next().
        }

        guard let statistics = statisticsBox else {
            Issue.record("statistics missing")
            return
        }

        let finished = try await waitUntil(timeout: .seconds(30)) { statistics.isFinished }
        #expect(finished)
        // The producer may have delivered at most the one callback it
        // could park on; it cannot have scanned the fixture.
        #expect(statistics.deliveredMatchCount <= 1)
    }

    // MARK: Task cancellation

    /// Cancelling the consuming task mid-iteration ends iteration without
    /// an error and provably stops the native search far from completion.
    @Test
    func cancellingConsumingTaskTerminatesSearchNatively() async throws {
        let totalLines = 2_000_000
        let root = try TestFixture.make([
            "big.txt": String(repeating: "needle here\n", count: totalLines),
        ])
        defer { TestFixture.remove(root) }

        let box = StatisticsBox()
        let consuming = Task<Int, Error> {
            let (results, statistics) = Ripgrep.searchWithStatistics("needle", in: root)
            box.statistics = statistics
            var count = 0
            for try await _ in results {
                count += 1
            }
            return count
        }

        // Let the consumer pull some matches, then cancel the task while
        // its next() suspension is pending.
        try await Task.sleep(for: .milliseconds(20))
        consuming.cancel()

        let count = try await consuming.value
        #expect(count >= 1)

        guard let statistics = box.statistics else {
            Issue.record("statistics missing")
            return
        }
        let finished = try await waitUntil { statistics.isFinished }
        #expect(finished)
        // Far fewer callbacks than a full scan would produce.
        #expect(statistics.deliveredMatchCount < 200_000)
    }

    // MARK: No-match cancellation (independent of match callbacks)

    /// A quarter-gigabyte file containing zero matches: the match callback
    /// can never fire, so only the native token observed between read
    /// chunks can stop this. Cancellation must land well before EOF.
    @Test
    func noMatchCancellationStopsReadingBeforeFileEnd() async throws {
        let sizeBytes = 256 << 20 // 256 MB
        let root = try TestFixture.makeLargeNoMatchFile(sizeBytes: sizeBytes)
        defer { TestFixture.remove(root) }

        let fileURL = root.appendingPathComponent("filler.txt")
        let fileSize = try FileManager.default.attributesOfItem(
            atPath: fileURL.path
        )[.size] as! Int

        let (results, statistics) = Ripgrep.searchWithStatistics(
            "zzz-pattern-nowhere-in-fixture-zzz",
            in: root
        )
        let iterator = results.makeAsyncIterator()
        #expect(statistics.producerStartCount == 1)

        // Wait until reading is demonstrably under way.
        let started = try await waitUntil(timeout: .seconds(30)) {
            statistics.bytesSearched >= 8_000_000
        }
        #expect(started)

        results.cancel()

        let finished = try await waitUntil(timeout: .seconds(30)) { statistics.isFinished }
        #expect(finished)

        // The scan stopped strictly inside the file: chunk-level
        // cancellation works even with no matches to carry it.
        #expect(statistics.filesVisited == 1)
        #expect(statistics.bytesSearched > 0)
        #expect(statistics.bytesSearched < fileSize)

        // The consumer observes a clean end, not an error.
        #expect(try await iterator.next() == nil)
    }

    // MARK: Single-consumer / multi-iterator safety

    /// A second iterator neither restarts nor corrupts the running search,
    /// and the first iterator keeps delivering afterwards.
    @Test
    func secondIteratorIsInertAndDoesNotDisturbFirst() async throws {
        let root = try TestFixture.make([
            "big.txt": String(repeating: "needle here\n", count: 5_000),
        ])
        defer { TestFixture.remove(root) }

        let (results, statistics) = Ripgrep.searchWithStatistics("needle", in: root)

        let first = results.makeAsyncIterator()
        var got = 0
        while got < 5, try await first.next() != nil {
            got += 1
        }
        #expect(got == 5)

        let second = results.makeAsyncIterator()
        #expect(try await second.next() == nil)
        #expect(statistics.producerStartCount == 1)

        let stillFlowing = try await first.next()
        #expect(stillFlowing != nil)

        results.cancel()
        let finished = try await waitUntil { statistics.isFinished }
        #expect(finished)
    }

    // MARK: Stress

    /// Mixed lifecycle stress: complete consumption, early break,
    /// immediate cancel, and abandoned sequences over many rounds plus a
    /// concurrent batch. Every iterated round must wind down natively;
    /// abandoned rounds must never have started anything.
    @Test
    func mixedLifecycleStressDoesNotLeakOrHang() async throws {
        let root = try TestFixture.make([
            "a.txt": String(repeating: "needle a\n", count: 3_000),
            "b.txt": String(repeating: "needle b\n", count: 3_000),
        ])
        defer { TestFixture.remove(root) }

        var abandonedRounds = 0
        for round in 0..<48 {
            switch round % 4 {
            case 0:
                let (results, statistics) = Ripgrep.searchWithStatistics("needle", in: root)
                let count = try await collectAll(results).count
                #expect(count == 6_000)
                #expect(try await waitUntil { statistics.isFinished })
                #expect(statistics.deliveredMatchCount == 6_000)

            case 1:
                let (results, statistics) = Ripgrep.searchWithStatistics("needle", in: root)
                var seen = 0
                for try await _ in results {
                    seen += 1
                    if seen == 7 { break }
                }
                #expect(try await waitUntil { statistics.isFinished })
                #expect(statistics.deliveredMatchCount <= 8)

            case 2:
                // Cancel before any iterator exists: the producer must
                // never start, so there is nothing to wait for — the
                // assertions are structural.
                let (results, statistics) = Ripgrep.searchWithStatistics("needle", in: root)
                results.cancel()
                results.cancel() // idempotent
                #expect(statistics.producerStartCount == 0)
                #expect(statistics.deliveredMatchCount == 0)
                #expect(!statistics.isFinished)

            default:
                let statistics = SearchStatistics()
                do {
                    _ = Ripgrep.makeSearchResults("needle", in: root, options: .init(), statistics: statistics)
                }
                abandonedRounds += 1
                #expect(statistics.producerStartCount == 0)
            }
        }
        #expect(abandonedRounds == 12)

        // Concurrent independent searches stay safe and correct.
        try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<8 {
                group.addTask {
                    if index % 2 == 0 {
                        return try await collectAll(Ripgrep.search("needle", in: root)).count
                    } else {
                        var seen = 0
                        for try await _ in Ripgrep.search("needle", in: root) {
                            seen += 1
                            if seen == 11 { break }
                        }
                        return seen
                    }
                }
            }
            var counts: [Int] = []
            for try await count in group {
                counts.append(count)
            }
            counts.sort()
            #expect(counts == [11, 11, 11, 11, 6000, 6000, 6000, 6000])
        }
    }
}

/// Sendable holder so a background task can hand its statistics back to
/// the test.
final class StatisticsBox: @unchecked Sendable {
    var statistics: SearchStatistics?
}
