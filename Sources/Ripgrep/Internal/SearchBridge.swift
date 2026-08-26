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
            return context.emit(match)
        }
}

/// State shared between the async stream machinery and the synchronous
/// native search. Access from multiple threads is guarded by a lock.
final class SearchContext: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let continuation: AsyncThrowingStream<RipgrepMatch, Error>.Continuation

    init(continuation: AsyncThrowingStream<RipgrepMatch, Error>.Continuation) {
        self.continuation = continuation
    }

    /// Marks the search as cancelled; the native callback will report
    /// `false` at (or before) its next invocation.
    func requestCancellation() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled || Task.isCancelled
    }

    /// Delivers one match to the stream. Returns whether the native search
    /// should continue.
    func emit(_ match: RipgrepMatch) -> Bool {
        if isCancelled {
            return false
        }
        switch continuation.yield(match) {
        case .enqueued:
            return !isCancelled
        case .dropped, .terminated:
            return false
        @unknown default:
            return false
        }
    }

    func finish() {
        continuation.finish()
    }

    func finish(throwing error: Error) {
        continuation.finish(throwing: error)
    }
}
