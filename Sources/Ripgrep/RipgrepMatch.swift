import Foundation

/// A single regular-expression match reported by a search.
///
/// `matchStart` and `matchEnd` are zero-based **UTF-8 byte offsets** within
/// the UTF-8 encoded ``line`` — the natural unit of ripgrep's engine. They
/// are not Swift `String.Index` or character positions. A convenience
/// conversion can be added later; byte offsets are preserved here so no
/// information is lost at the FFI boundary.
///
/// A line containing several regex matches produces one ``RipgrepMatch``
/// per match, all sharing the same ``lineNumber`` and ``line``.
public struct RipgrepMatch: Sendable, Equatable {
    /// The file that contains the match.
    public let fileURL: URL

    /// Human-oriented, 1-based line number of the matched line.
    public let lineNumber: UInt64

    /// The full matched line with its terminator removed.
    public let line: String

    /// Byte offset of the first byte of the match within `line`.
    public let matchStart: Int

    /// Byte offset one past the last byte of the match within `line`.
    public let matchEnd: Int

    init(
        fileURL: URL,
        lineNumber: UInt64,
        line: String,
        matchStart: Int,
        matchEnd: Int
    ) {
        self.fileURL = fileURL
        self.lineNumber = lineNumber
        self.line = line
        self.matchStart = matchStart
        self.matchEnd = matchEnd
    }
}
