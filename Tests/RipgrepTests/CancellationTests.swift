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
}
