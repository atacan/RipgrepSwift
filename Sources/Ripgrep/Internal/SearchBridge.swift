import CRipgrep
import Foundation

/// Internal bridge between the public Swift API and the `rg_search` C ABI.
///
/// All unsafe interoperability lives in this file:
///
/// * UTF-8 conversion of the root path and pattern;
/// * population of `rg_search_options`;
/// * the `@convention(c)` match callback, which copies borrowed memory
///   immediately;
/// * exact retain/release balancing for the callback context (`defer`);
/// * translation of C status codes into ``RipgrepError``;
/// * freeing of native error strings via `rg_free_string`.
enum SearchBridge {
    /// Runs a synchronous native search **on the calling thread**. Callers
    /// are responsible for arranging a background executor. Returns normally
    /// when the search completes or is cancelled; throws ``RipgrepError``
    /// on failure.
    static func run(
        pattern: String,
        root: URL,
        options: RipgrepOptions,
        context: SearchContext
    ) throws {
        let rootBytes = Array(root.path.utf8)
        let patternBytes = Array(pattern.utf8)

        // Defense in depth: the FFI rejects empty roots, but failing fast
        // here keeps the error deterministic for every caller.
        guard !rootBytes.isEmpty else {
            throw RipgrepError.invalidArgument("search root path must not be empty")
        }

        var cOptions = rg_search_options(
            include_hidden: options.includeHidden,
            follow_symlinks: options.followSymbolicLinks,
            respect_gitignore: options.respectGitIgnore,
            case_insensitive: options.caseInsensitive
        )

        // The context must outlive every callback invocation. The retain is
        // balanced exactly once on every exit path by the deferred release.
        let retainedContext = Unmanaged.passRetained(context)
        defer { retainedContext.release() }

        var errorMessage: UnsafeMutablePointer<CChar>?
        let status: rg_status = rootBytes.withUnsafeBufferPointer { rootBuffer in
            patternBytes.withUnsafeBufferPointer { patternBuffer in
                rg_search(
                    rootBuffer.baseAddress,
                    rootBuffer.count,
                    patternBuffer.baseAddress,
                    patternBuffer.count,
                    &cOptions,
                    matchCallback,
                    Unmanaged.passUnretained(context).toOpaque(),
                    &errorMessage
                )
            }
        }

        if let errorMessage {
            defer { rg_free_string(errorMessage) }
            let message = String(cString: errorMessage)
            switch status {
            case RG_STATUS_INVALID_PATTERN:
                throw RipgrepError.invalidPattern(message)
            case RG_STATUS_INVALID_ARGUMENT:
                throw RipgrepError.invalidArgument(message)
            case RG_STATUS_IO_ERROR:
                throw RipgrepError.io(message)
            default:
                throw RipgrepError.internalError(message)
            }
        }

        // OK and CANCELLED are both normal outcomes; cancellation is not an
        // error from the consumer's point of view.
        switch status {
        case RG_STATUS_OK, RG_STATUS_CANCELLED:
            return
        default:
            throw RipgrepError.internalError("unexpected native status \(status.rawValue)")
        }
    }

    private static let matchCallback:
        @convention(c) (
            UnsafeMutableRawPointer?,
            UnsafePointer<rg_match>?
        ) -> Bool = { contextPointer, matchPointer in
            guard let contextPointer, let matchPointer else { return false }
            let context = Unmanaged<SearchContext>
                .fromOpaque(contextPointer)
                .takeUnretainedValue()

            let cMatch = matchPointer.pointee

            // `path` and `line` are borrowed and valid only for the duration
            // of this callback; copy them immediately.
            let pathBytes = UnsafeBufferPointer(start: cMatch.path, count: cMatch.path_len)
            let lineBytes = UnsafeBufferPointer(start: cMatch.line, count: cMatch.line_len)
            let path = String(decoding: pathBytes, as: UTF8.self)
            let line = String(decoding: lineBytes, as: UTF8.self)

            let match = RipgrepMatch(
                fileURL: URL(fileURLWithPath: path),
                lineNumber: cMatch.line_number,
                line: line,
                matchStart: cMatch.match_start,
                matchEnd: cMatch.match_end
            )
            return context.session.deliver(match, from: context)
        }
}

/// Internal instrumentation describing what actually happened on the
/// native side of one search. Exposed for tests via
/// ``Ripgrep/searchWithStatistics(_:in:options:)`` so cancellation behavior
/// can be verified beyond what the consumer receives.
final class SearchStatistics: @unchecked Sendable {
    private let lock = NSLock()
    private var _deliveredMatchCount = 0
    private var _finished = false

    /// Number of times the native layer invoked the match callback,
    /// whether or not the consumer ultimately observed each match.
    var deliveredMatchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _deliveredMatchCount
    }

    /// True once the native search has fully unwound (completed, been
    /// cancelled, or failed).
    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _finished
    }

    func recordNativeCallback() {
        lock.lock()
        _deliveredMatchCount += 1
        lock.unlock()
    }

    func markFinished() {
        lock.lock()
        _finished = true
        lock.unlock()
    }
}

/// State shared between the async sequence machinery and the synchronous
/// native search.
///
/// The session implements strict consumer backpressure: the native callback
/// parks inside `deliver(match:)` until the consumer has asked for another
/// element, so the native search can never outrun consumption and at most
/// one produced match is ever buffered.
///
/// Access from multiple threads is guarded by a single `NSCondition`.
final class SearchSession: @unchecked Sendable {

    // MARK: State guarded by `condition`

    private let condition = NSCondition()
    private var waiter: CheckedContinuation<Result<RipgrepMatch?, Error>, Never>?
    private var finished = false
    private var failure: Error?
    private var consumerRequestedCancellation = false

    // MARK: Consumer liveness

    /// Identity token held strongly by the live iterator. When every
    /// consumer-side structure has been released (break, dropped sequence,
    /// cancelled task), this weak reference dies and the parked producer
    /// aborts the native search instead of waiting forever.
    final class ConsumerToken: Sendable {}

    private weak var consumerToken: ConsumerToken?
    private var tokenClaimed = false

    /// Hands out the single consumer token. A session supports exactly one
    /// consuming iterator; a second claim returns nil.
    func claimConsumerToken() -> ConsumerToken? {
        condition.lock()
        defer { condition.unlock() }
        if tokenClaimed {
            return nil
        }
        tokenClaimed = true
        let token = ConsumerToken()
        consumerToken = token
        return token
    }

    private var consumerIsAlive: Bool {
        consumerToken != nil || !tokenClaimed
    }

    // MARK: Producer side (called from the native callback thread)

    /// Parks until the consumer is waiting for another element, then hands
    /// over `match` by resuming it. Returns whether the native search should
    /// continue.
    func deliver(_ match: RipgrepMatch, from context: SearchContext) -> Bool {
        // Every native callback counts, even ones that end up suppressed.
        context.statistics.recordNativeCallback()

        while true {
            condition.lock()
            if consumerRequestedCancellation || finished || !consumerIsAlive {
                condition.unlock()
                return false
            }
            if let waitingConsumer = waiter {
                waiter = nil
                condition.unlock()
                waitingConsumer.resume(returning: .success(match))
                return true
            }
            // No consumer is waiting: park. Backpressure means the search
            // makes no progress at all until `next()` is called again.
            // Bounded waits re-check liveness so an abandoned consumer
            // cannot park the producer forever.
            _ = condition.wait(until: .now.addingTimeInterval(0.1))
            condition.unlock()
        }
    }

    /// Called by the producer task after the native search fully unwound.
    /// Wakes any parked consumer so iteration can end.
    func finish(with error: Error?) {
        condition.lock()
        finished = true
        failure = error
        let parkedConsumer = waiter
        waiter = nil
        let outcome: Result<RipgrepMatch?, Error> = error.map { .failure($0) } ?? .success(nil)
        condition.unlock()
        parkedConsumer?.resume(returning: outcome)
    }

    // MARK: Consumer side

    /// Returns the next match, or nil when the search ended (completed or
    /// cancelled). Throws on native failures.
    func next() async throws -> RipgrepMatch? {
        // Fast path without parking.
        if let immediate = poll() {
            return try immediate.get()
        }

        let outcome: Result<RipgrepMatch?, Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<RipgrepMatch?, Error>, Never>) in
                switch registerWaiter(continuation) {
                case .registered:
                    break
                case .immediate(let outcome):
                    continuation.resume(returning: outcome)
                }
            }
        } onCancel: { [self] in
            // Task cancellation ends iteration silently (like
            // AsyncThrowingStream) and stops the native search.
            abortWaiter()
        }
        return try outcome.get()
    }

    private enum WaitOutcome {
        case registered
        case immediate(Result<RipgrepMatch?, Error>)
    }

    /// Synchronously checks whether an element/end is already available;
    /// otherwise registers the continuation for the producer to resume.
    private func pollOrRegister(_ continuation: CheckedContinuation<Result<RipgrepMatch?, Error>, Never>) -> WaitOutcome {
        precondition(waiter == nil, "SearchSession supports one concurrent next() call")
        if !finished && failure == nil && !consumerRequestedCancellation {
            waiter = continuation
            condition.broadcast()
            return .registered
        }
        if let error = failure {
            return .immediate(.failure(error))
        }
        return .immediate(.success(nil))
    }

    /// Brief-lock check used before suspending.
    private func poll() -> Result<RipgrepMatch?, Error>? {
        condition.lock()
        defer { condition.unlock() }
        if finished || consumerRequestedCancellation {
            return failure.map { .failure($0) } ?? .success(nil)
        }
        return nil
    }

    private func registerWaiter(_ continuation: CheckedContinuation<Result<RipgrepMatch?, Error>, Never>) -> WaitOutcome {
        condition.lock()
        defer { condition.unlock() }
        return pollOrRegister(continuation)
    }

    /// Resumes any suspended `next()` with nil and requests cancellation of
    /// the native search. Safe to call multiple times.
    private func abortWaiter() {
        condition.lock()
        consumerRequestedCancellation = true
        let parkedConsumer = waiter
        waiter = nil
        condition.unlock()
        parkedConsumer?.resume(returning: .success(nil))
    }

    /// Requests that the native search stop as soon as practical and wakes
    /// any suspended `next()` with nil. Safe to call multiple times.
    func stop() {
        abortWaiter()
    }
}

/// The object passed through the C ABI as the callback context. It only
/// glues the opaque pointer back onto the session and statistics.
final class SearchContext: @unchecked Sendable {
    let session: SearchSession
    let statistics: SearchStatistics

    init(session: SearchSession, statistics: SearchStatistics) {
        self.session = session
        self.statistics = statistics
    }
}
