import Foundation

/// The public entry point for ripgrep-style searches.
///
/// Searches are executed in-process against ripgrep's Rust search
/// infrastructure — no `rg` executable is required. Delivery is strictly
/// pull-based: the native search cannot advance past its next match until
/// the consumer asks for another element, so results are never accumulated
/// and memory use stays constant regardless of tree size.
///
/// # Startup is lazy
///
/// ``search(_:in:options:)`` only constructs the search description. No
/// filesystem traversal begins until the single consuming iterator exists
/// (that is, `makeAsyncIterator()` runs — explicitly or via `for try
/// await`). Creating the returned sequence and dropping it without
/// iteration therefore starts no native work at all.
public enum Ripgrep {
    /// Searches `directory` recursively for `pattern` and streams every
    /// individual regular-expression match.
    ///
    /// The native traversal starts when this sequence's iterator is created
    /// — not before. A line containing several matches yields one
    /// ``RipgrepMatch`` per match. Matches arrive serially under strict
    /// backpressure; the calling thread or actor is never blocked by the
    /// native search, which runs on its own dedicated background thread.
    ///
    /// Stopping iteration early (for example with `break`), cancelling the
    /// consuming task, or calling ``RipgrepSearchResults/cancel()``
    /// stops the native search as soon as practical — between files and,
    /// within a file, before each read chunk — even when the remaining data
    /// contains no matches at all. Cancellation is not reported as an
    /// error: iteration simply ends with `nil`. Thrown errors are
    /// ``RipgrepError`` values.
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
    /// verify that startup, backpressure, and cancellation behave as
    /// documented; not part of the supported public API.
    static func searchWithStatistics(
        _ pattern: String,
        in directory: URL,
        options: RipgrepOptions = .init()
    ) -> (results: RipgrepSearchResults, statistics: SearchStatistics) {
        let statistics = SearchStatistics()
        let results = makeSearchResults(
            pattern,
            in: directory,
            options: options,
            statistics: statistics
        )
        return (results, statistics)
    }

    /// Builds an unstarted search around a caller-supplied statistics
    /// object. Internal test hook: it lets tests observe that dropping the
    /// result without iterating never starts a producer.
    static func makeSearchResults(
        _ pattern: String,
        in directory: URL,
        options: RipgrepOptions,
        statistics: SearchStatistics
    ) -> RipgrepSearchResults {
        let session = SearchSession(
            pattern: pattern,
            root: directory,
            options: options,
            statistics: statistics
        )
        return RipgrepSearchResults(session: session)
    }
}

/// The `AsyncSequence` returned by ``Ripgrep/search(_:in:options:)``.
///
/// # Lifecycle
///
/// * **Lazy start**: constructing this value does nothing on its own; the
///   native producer starts exactly once, when ``makeAsyncIterator()`` runs.
///   Dropping the sequence without an iterator leaves no native work
///   behind, and calling ``cancel()`` before iteration prevents startup
///   entirely.
/// * **Single consumer**: exactly one iterator may consume the sequence; a
///   second ``makeAsyncIterator()`` call returns an already-finished
///   iterator and does not disturb or restart the first one.
/// * **Strict backpressure**: the native search is parked between consumer
///   requests, so at most one match is ever buffered.
/// * **Deterministic teardown**: releasing the live iterator (after
///   `break`, dropping it, or task cancellation) cancels the native search
///   immediately — no reliance on timed liveness checks.
public struct RipgrepSearchResults: AsyncSequence, Sendable {
    public typealias Element = RipgrepMatch

    let session: SearchSession

    init(session: SearchSession) {
        self.session = session
    }

    /// Creates the single consuming iterator and lazily starts the native
    /// producer. A second call returns an already-finished iterator; it
    /// neither restarts nor corrupts the first search.
    public func makeAsyncIterator() -> Iterator {
        Iterator(session: session, consumerToken: session.beginConsumption())
    }

    /// Requests that the native search stop as soon as practical.
    ///
    /// Guarantees:
    ///
    /// * Called before any iterator exists, it permanently prevents the
    ///   producer from starting; later iteration ends immediately with nil.
    /// * Called after iteration began, it signals the native cancellation
    ///   token. Rust observes it between files and before each read chunk
    ///   within a file, so even one huge matchless file stops reading well
    ///   before its end; a producer parked on backpressure wakes at once.
    /// * Idempotent, thread-safe, and never reported as an error.
    ///
    /// Calling it is optional — breaking out of iteration, dropping the
    /// iterator, or cancelling the consuming task cancels the search too.
    public func cancel() {
        session.requestCancellation()
    }

    public final class Iterator: AsyncIteratorProtocol, Sendable {
        let session: SearchSession
        private let consumerToken: SearchSession.ConsumerToken?

        init(session: SearchSession, consumerToken: SearchSession.ConsumerToken?) {
            self.session = session
            self.consumerToken = consumerToken
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
            // Releasing the last iterator reference is what makes "break",
            // "drop", and task cancellation deterministic: the parked or
            // scanning producer is cancelled right away instead of being
            // observed through lifetime polling.
            if consumerToken != nil {
                session.requestCancellation()
            }
        }
    }
}
