import CRipgrep
import Foundation

/// Internal bridge between the public Swift API and the `rg_search` C ABI.
///
/// All unsafe interoperability lives in this file:
///
/// * UTF-8 conversion of the root path and pattern;
/// * population of `rg_search_options`;
/// * the `@convention(c)` match and progress callbacks, which copy borrowed
///   memory immediately (progress values are plain integers);
/// * exact retain/release balancing for the callback context (`defer`);
/// * translation of C status codes into ``RipgrepError``;
/// * freeing of native error strings via `rg_free_string`.
enum SearchBridge {
    /// Runs a synchronous native search **on the calling thread**. Callers
    /// are responsible for arranging a dedicated blocking context (the
    /// session runs it on its own `Thread`). Returns normally when the
    /// search completes or is cancelled; throws ``RipgrepError`` on failure.
    static func run(
        pattern: String,
        root: URL,
        options: RipgrepOptions,
        cancelToken: OpaquePointer?,
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
                    cancelToken,
                    matchCallback,
                    Unmanaged.passUnretained(context).toOpaque(),
                    progressCallback,
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
            return context.session.deliver(match)
        }

    private static let progressCallback:
        @convention(c) (
            UnsafeMutableRawPointer?,
            UInt64,
            UInt64
        ) -> Void = { contextPointer, filesVisited, bytesSearched in
            guard let contextPointer else { return }
            let context = Unmanaged<SearchContext>
                .fromOpaque(contextPointer)
                .takeUnretainedValue()
            context.statistics.recordProgress(
                filesVisited: Int(filesVisited),
                bytesSearched: Int(bytesSearched)
            )
        }
}

/// Internal instrumentation describing what actually happened on the
/// native side of one search. Exposed for tests via
/// ``Ripgrep/searchWithStatistics(_:in:options:)`` so lifecycle behavior
/// can be verified beyond what the consumer receives.
final class SearchStatistics: @unchecked Sendable {
    private let lock = NSLock()
    private var _deliveredMatchCount = 0
    private var _finished = false
    private var _producerStartCount = 0
    private var _filesVisited = 0
    private var _bytesSearched = 0

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

    /// Number of times the producer was actually started. Lazy startup
    /// guarantees this is 0 until an iterator claims the session and at
    /// most 1 forever.
    var producerStartCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _producerStartCount
    }

    /// Latest cumulative count of regular files whose search has started,
    /// as reported by the native progress callback.
    var filesVisited: Int {
        lock.lock()
        defer { lock.unlock() }
        return _filesVisited
    }

    /// Latest cumulative number of bytes read by the native search, as
    /// reported by the native progress callback.
    var bytesSearched: Int {
        lock.lock()
        defer { lock.unlock() }
        return _bytesSearched
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

    func recordProducerStarted() {
        lock.lock()
        _producerStartCount += 1
        lock.unlock()
    }

    func recordProgress(filesVisited: Int, bytesSearched: Int) {
        lock.lock()
        _filesVisited = max(_filesVisited, filesVisited)
        _bytesSearched = max(_bytesSearched, bytesSearched)
        lock.unlock()
    }
}

/// State machine shared between the async sequence machinery and the
/// blocking native search.
///
/// # Lifecycle states
///
/// ```
/// notStarted ──beginConsumption──▶ running ──producer unwind──▶ completed / failed
///     │                              │
///     └── requestCancellation ───────┴──▶ cancelled (flag; producer stops)
/// ```
///
/// * `notStarted`: nothing exists except the search description. The
///   native token and producer thread do not exist yet.
/// * `running`: exactly one dedicated `Thread` executes the synchronous
///   Rust search. The thread parks inside ``deliver(_:)-swift.method``
///   whenever no consumer demand is outstanding — strict backpressure.
/// * `completed` / `failed`: terminal phases set when the producer
///   unwinds. A waiting consumer is woken with nil or the error.
///
/// `cancelled` is a flag layered on top of the phases rather than a phase
/// itself: cancellation can precede startup (and then prevents it), race
/// with completion, or interrupt a running search. Completion stays
/// distinguishable from cancellation internally even though both surface
/// to consumers as a clean end of iteration.
///
/// All state transitions happen under one `NSCondition`. Every transition
/// that could unblock the other side broadcasts, so there is no polling
/// anywhere: a parked producer waits indefinitely but is always woken by
/// new demand (`next()`), cancellation, or producer completion.
///
/// Access from multiple threads is serialized by that single condition.
final class SearchSession: @unchecked Sendable {

    // MARK: State guarded by `condition`

    private enum Phase {
        /// No producer exists yet; only the search description does.
        case notStarted
        /// The dedicated producer thread is executing the native search.
        case running
        /// The producer unwound after scanning everything.
        case completed
        /// The producer unwound after a native failure.
        case failed(Error)
    }

    private let condition = NSCondition()
    private var phase: Phase = .notStarted
    private var cancelled = false
    private var waiter: CheckedContinuation<Result<RipgrepMatch?, Error>, Never>?

    // MARK: Consumer identity

    /// Identity token held strongly by the live iterator. It enforces the
    /// single-consumer contract; liveness is *not* derived from it. An
    /// abandoned consumer cancels deterministically through
    /// `Iterator.deinit` instead of being observed via deallocation polls.
    final class ConsumerToken: Sendable {}

    private var consumerToken: ConsumerToken?
    private var tokenClaimed = false

    // MARK: Producer resources

    /// Native cancellation token handed to `rg_search`; created exactly
    /// when the producer starts and freed exactly when it unwinds.
    private var nativeCancelToken: OpaquePointer?
    /// Strong reference keeping the producer thread alive until it exits.
    private var producerThread: Thread?

    // MARK: Search description (immutable after init)

    private let pattern: String
    private let root: URL
    private let options: RipgrepOptions
    private let statistics: SearchStatistics

    init(
        pattern: String,
        root: URL,
        options: RipgrepOptions,
        statistics: SearchStatistics
    ) {
        self.pattern = pattern
        self.root = root
        self.options = options
        self.statistics = statistics
    }

    // MARK: Consumer side

    /// Claims the single consumer slot and lazily starts the producer.
    ///
    /// Returns nil if another iterator already claimed the slot; in that
    /// case nothing is started and the caller's iterator must behave as
    /// finished. If cancellation was requested before the first claim, the
    /// slot is still claimed (so the sequence reads as finished) but the
    /// producer is never started.
    func beginConsumption() -> ConsumerToken? {
        condition.lock()
        defer { condition.unlock() }
        if tokenClaimed {
            return nil
        }
        tokenClaimed = true
        let token = ConsumerToken()
        consumerToken = token
        startProducerIfNeededLocked()
        return token
    }

    /// Starts the dedicated producer thread exactly once, unless
    /// cancellation already prevented it. Called with `condition` held.
    private func startProducerIfNeededLocked() {
        guard case .notStarted = phase, !cancelled else { return }
        phase = .running
        statistics.recordProducerStarted()

        // Failure to allocate a native token degrades gracefully: the
        // search still runs, it just cannot be cancelled natively before
        // its next backpressure wake-up. In practice this never happens.
        nativeCancelToken = rg_cancel_token_create()

        let context = SearchContext(session: self, statistics: statistics)
        let cancelToken = SendableCancelToken(nativeCancelToken)
        let pattern = self.pattern
        let root = self.root
        let options = self.options

        let thread = Thread {
            defer { context.statistics.markFinished() }
            do {
                try SearchBridge.run(
                    pattern: pattern,
                    root: root,
                    options: options,
                    cancelToken: cancelToken.pointer,
                    context: context
                )
                self.finish(with: nil)
            } catch {
                self.finish(with: error)
            }
        }
        thread.name = "org.atacan.RipgrepSwift.search"
        thread.qualityOfService = .utility
        producerThread = thread
        thread.start()
    }

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
            requestCancellation()
        }
        return try outcome.get()
    }

    private enum WaitOutcome {
        case registered
        case immediate(Result<RipgrepMatch?, Error>)
    }

    /// Registers the continuation unless an outcome is already available.
    /// Broadcasting wakes a producer parked for lack of demand.
    private func registerWaiter(_ continuation: CheckedContinuation<Result<RipgrepMatch?, Error>, Never>) -> WaitOutcome {
        condition.lock()
        defer { condition.unlock() }
        precondition(waiter == nil, "SearchSession supports one concurrent next() call")
        if let immediate = pollOutcomeLocked() {
            return .immediate(immediate)
        }
        waiter = continuation
        condition.broadcast()
        return .registered
    }

    /// Brief-lock check used before suspending.
    private func poll() -> Result<RipgrepMatch?, Error>? {
        condition.lock()
        defer { condition.unlock() }
        return pollOutcomeLocked()
    }

    /// Non-nil when the sequence has ended (or failed) without needing the
    /// producer's help. Called with `condition` held.
    private func pollOutcomeLocked() -> Result<RipgrepMatch?, Error>? {
        if case .failed(let error) = phase {
            return .failure(error)
        }
        if cancelled || isTerminalLocked() {
            return .success(nil)
        }
        return nil
    }

    private func isTerminalLocked() -> Bool {
        switch phase {
        case .completed, .failed:
            return true
        case .notStarted, .running:
            return false
        }
    }

    // MARK: Producer side (called from the dedicated producer thread)

    /// Parks until the consumer is waiting for another element, then hands
    /// over `match` by resuming it. Returns whether the native search should
    /// continue.
    ///
    /// The indefinite wait is safe because every event that can resolve it
    /// — new demand, cancellation, or shutdown — broadcasts on the same
    /// condition while holding the lock.
    func deliver(_ match: RipgrepMatch) -> Bool {
        // Every native callback counts, even ones that end up suppressed.
        statistics.recordNativeCallback()

        condition.lock()
        while true {
            if cancelled || isTerminalLocked() {
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
            condition.wait()
        }
    }

    /// Called by the producer thread after the native search fully unwound.
    /// Wakes any parked consumer, releases the native token, and forgets
    /// the thread reference so the session/thread cycle can break.
    func finish(with error: Error?) {
        let tokenToFree: OpaquePointer?
        let parkedConsumer: CheckedContinuation<Result<RipgrepMatch?, Error>, Never>?
        let outcome: Result<RipgrepMatch?, Error>

        condition.lock()
        if isTerminalLocked() {
            condition.unlock()
            return
        }
        phase = error.map(Phase.failed) ?? .completed
        parkedConsumer = waiter
        waiter = nil
        outcome = error.map { .failure($0) } ?? .success(nil)
        tokenToFree = nativeCancelToken
        nativeCancelToken = nil
        producerThread = nil
        condition.broadcast()
        condition.unlock()

        if let tokenToFree {
            rg_cancel_token_free(tokenToFree)
        }
        parkedConsumer?.resume(returning: outcome)
    }

    // MARK: Cancellation

    /// Requests that the native search stop as soon as practical and wakes
    /// any suspended `next()` and any parked producer. Safe to call any
    /// number of times from any thread at any point in the lifecycle:
    ///
    /// * before the first `beginConsumption`, it permanently prevents
    ///   producer startup;
    /// * while the producer is parked on backpressure, it wakes it;
    /// * while the producer is scanning, it signals the native cancellation
    ///   token, which Rust observes between files and before each read
    ///   chunk within a file.
    ///
    /// The token store happens under `condition`, which serializes against
    /// the free in `finish(with:)`: either this call sees the live pointer
    /// first, or `finish` has already taken ownership of it.
    func requestCancellation() {
        let parkedConsumer: CheckedContinuation<Result<RipgrepMatch?, Error>, Never>?

        condition.lock()
        if isTerminalLocked() {
            condition.unlock()
            return
        }
        cancelled = true
        if let token = nativeCancelToken {
            rg_cancel_token_cancel(token)
        }
        parkedConsumer = waiter
        waiter = nil
        condition.broadcast()
        condition.unlock()

        parkedConsumer?.resume(returning: .success(nil))
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

/// Sendable carrier for the native cancellation-token pointer so it can be
/// captured by the producer thread's block. The pointer itself stays owned
/// by the session, which frees it exactly once in ``SearchSession/finish(with:)``.
struct SendableCancelToken: @unchecked Sendable {
    let pointer: OpaquePointer?

    init(_ pointer: OpaquePointer?) {
        self.pointer = pointer
    }
}
