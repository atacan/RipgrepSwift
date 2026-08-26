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

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Collects an entire search into an array. Tests that need streaming or
/// cancellation semantics iterate manually instead.
func collectAll(_ stream: AsyncThrowingStream<RipgrepMatch, Error>) async throws -> [RipgrepMatch] {
    var results: [RipgrepMatch] = []
    for try await match in stream {
        results.append(match)
    }
    return results
}
