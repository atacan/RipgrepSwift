import Foundation

/// The public entry point for ripgrep-style searches.
///
/// Searches are executed in-process against ripgrep's Rust search
/// infrastructure — no `rg` executable is required. Delivery is strictly
/// pull-based: the native search cannot advance past its next match until
/// the consumer asks for another element, so results are never accumulated
/// and memory use stays constant regardless of tree size.
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
    /// The result supports exactly **one** consuming iterator (single pass).
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
    ) -> RipgrepSearchResults {
        searchWithStatistics(pattern, in: directory, options: options).results
    }

    /// Same as ``search(_:in:options:)`` but also returns internal
    /// statistics about the native side of the search. Used by tests to
    /// verify that cancellation actually stops the native search; not part
    /// of the supported public API.
    static func searchWithStatistics(
        _ pattern: String,
        in directory: URL,
        options: RipgrepOptions = .init()
    ) -> (results: RipgrepSearchResults, statistics: SearchStatistics) {
        let session = SearchSession()
        let statistics = SearchStatistics()
        let context = SearchContext(session: session, statistics: statistics)

        let searchTask = Task.detached(priority: .utility) {
            defer { statistics.markFinished() }
            do {
                try SearchBridge.run(
                    pattern: pattern,
                    root: directory,
                    options: options,
                    context: context
                )
                session.finish(with: nil)
            } catch {
                session.finish(with: error)
            }
        }

        // If the detached task itself is cancelled, stop the native search;
        // nothing else observes that cancellation.
        let results = RipgrepSearchResults(session: session) { [weak session] in
            session?.stop()
            searchTask.cancel()
        }
        return (results, statistics)
    }
}

/// The `AsyncSequence` returned by ``Ripgrep/search(_:in:options:)``.
///
/// Single pass, single consumer: call `makeAsyncIterator()` once. Matches
/// are produced under strict backpressure — the native filesystem search is
/// parked between consumer requests, so at most one match is ever buffered.
public struct RipgrepSearchResults: AsyncSequence, Sendable {
    public typealias Element = RipgrepMatch

    let session: SearchSession
    let onConsumerGone: @Sendable () -> Void

    init(session: SearchSession, onConsumerGone: @escaping @Sendable () -> Void) {
        self.session = session
        self.onConsumerGone = onConsumerGone
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(session: session, onConsumerGone: onConsumerGone)
    }

    /// Requests that the native search stop as soon as practical. Calling
    /// this is optional — stopping iteration or dropping the sequence also
    /// stops the search — but explicit cancellation is deterministic and not
    /// subject to object lifetime timing. Idempotent.
    public func cancel() {
        onConsumerGone()
    }

    public final class Iterator: AsyncIteratorProtocol, Sendable {
        let session: SearchSession
        let onConsumerGone: @Sendable () -> Void
        private let consumerToken: SearchSession.ConsumerToken?

        init(session: SearchSession, onConsumerGone: @escaping @Sendable () -> Void) {
            self.session = session
            self.onConsumerGone = onConsumerGone
            self.consumerToken = session.claimConsumerToken()
        }

        public func next() async throws -> RipgrepMatch? {
            if consumerToken == nil {
                // A second iterator was requested; treat as finished rather
                // than corrupting the single-consumer contract.
                return nil
            }
            return try await session.next()
        }

        deinit {
            // Releasing the consumer token unblocks the parked producer via
            // liveness polling; this callback also asks the native search to
            // cancel right away instead of at the next poll interval.
            onConsumerGone()
        }
    }
}
