/// Errors reported by ``Ripgrep/search(_:in:options:)``.
///
/// The numeric C status codes are an implementation detail and are never
/// exposed publicly.
public enum RipgrepError: Error, Sendable, Equatable {
    /// The regular expression could not be compiled.
    case invalidPattern(String)

    /// An input argument was unusable (for example a nonexistent or empty
    /// search root path).
    case invalidArgument(String)

    /// A filesystem-level failure prevented the search from running.
    case io(String)

    /// An unexpected native failure. This indicates a bug; please report it.
    case internalError(String)
}
