import Foundation
@testable import Ripgrep

/// Helpers for creating throwaway filesystem fixtures.
enum TestFixture {
    /// Creates a temporary directory containing the given relative paths,
    /// plus an empty `.git` directory so that the `ignore` crate treats the
    /// tree as a git repository and honors `.gitignore` files (it requires
    /// a repository, exactly like `rg`).
    static func make(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RipgrepSwiftTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        for (relativePath, contents) in files {
            let fileURL = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: fileURL)
        }
        return root
    }

    /// Creates a temporary directory containing one very large text file
    /// whose contents never match typical patterns (no occurrence of
    /// "needle" or similar). Written in bulk blocks so generation stays
    /// fast even for hundreds of megabytes.
    static func makeLargeNoMatchFile(name: String = "filler.txt", sizeBytes: Int) throws -> URL {
        let root = try make([:])
        let chunkLine = "alpha beta gamma delta epsilon zeta eta theta iota kappa\n"
        // ~5 MB super-chunk, written repeatedly.
        let superChunk = Data(String(repeating: chunkLine, count: 170_000).utf8)
        precondition(superChunk.count > 1_000_000)
        let fileURL = root.appendingPathComponent(name)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        var written = 0
        while written < sizeBytes {
            try handle.write(contentsOf: superChunk)
            written += superChunk.count
        }
        return root
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Polls `predicate` until it holds or the timeout elapses. Used to wait
/// for *bounded* native-side events (producer unwinding); assertions about
/// absence of activity are always structural, never sleep-based.
@discardableResult
func waitUntil(
    timeout: Duration = .seconds(30),
    interval: Duration = .milliseconds(5),
    _ predicate: () -> Bool
) async throws -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if predicate() { return true }
        try await Task.sleep(for: interval)
    }
    return predicate()
}

/// Collects an entire search into an array. Tests that need streaming or
/// cancellation semantics iterate manually instead.
func collectAll(_ results: RipgrepSearchResults) async throws -> [RipgrepMatch] {
    var collected: [RipgrepMatch] = []
    for try await match in results {
        collected.append(match)
    }
    return collected
}
