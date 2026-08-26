import Foundation

/// The public entry point for ripgrep-style searches.
///
/// Searches are executed in-process against ripgrep's Rust search
/// infrastructure — no `rg` executable is required. Results stream to the
/// caller as they are discovered; nothing is accumulated up front.
public enum Ripgrep {
    /// Searches `directory` recursively for `pattern` and streams every
    /// individual regular-expression match.
    ///
    /// A line containing several matches yields one ``RipgrepMatch`` per
    /// match. Matches arrive serially, on a background task; the calling
    /// thread or actor is never blocked by the native search.
    ///
    /// Stopping iteration early (for example with `break`) or cancelling the
    /// consuming task stops the native search as soon as practical; this is
    /// not reported as an error. Thrown errors are ``RipgrepError`` values.
    ///
    /// ```swift
    /// for try await match in Ripgrep.search("TODO|FIXME", in: projectURL) {
    ///     print("\(match.fileURL.path):\(match.lineNumber):\(match.line)")
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - pattern: A Rust `regex` syntax pattern (ripgrep's default engine).
    ///   - directory: Root of the traversal. Absolute paths are recommended;
    ///     paths must be representable as UTF-8.
    ///   - options: Traversal and matching configuration.
    public static func search(
        _ pattern: String,
        in directory: URL,
        options: RipgrepOptions = .init()
    ) -> AsyncThrowingStream<RipgrepMatch, Error> {
        AsyncThrowingStream { continuation in
            let context = SearchContext(continuation: continuation)

            let searchTask = Task.detached(priority: .utility) {
                do {
                    try SearchBridge.run(
                        pattern: pattern,
                        root: directory,
                        options: options,
                        context: context
                    )
                    context.finish()
                } catch {
                    context.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                // Stop the native search whether the consumer broke out of
                // iteration or the consuming task was cancelled outright.
                context.requestCancellation()
                searchTask.cancel()
            }
        }
    }
}
