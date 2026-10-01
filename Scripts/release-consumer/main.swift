// The Swift fixture executed by Scripts/verify-release-consumer.sh and
// compiled + run locally by Scripts/check-release-consumer-fixture.sh.
// Kept as a tracked file so pre-release validation exercises exactly the
// source that ships to release consumers.
import Foundation
import Ripgrep

// Fixture with several matches spread across multiple files.
let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("rg-release-consumer-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
for index in 0..<3 {
    let lines = (0..<20_000).map { "line \($0) needle here\n" }.joined()
    try Data(lines.utf8).write(to: root.appendingPathComponent("file\(index).txt"))
}

// 1. A real search whose results are actually consumed.
var count = 0
for try await match in Ripgrep.search("needle", in: root) {
    precondition(match.line.contains("needle"), "unexpected line: \(match.line)")
    count += 1
    if count == 100 { break }
}
precondition(count == 100, "expected to consume 100 matches, got \(count)")

// 2. Exercise cancellation: cancel() before iteration prevents startup.
let cancelled = Ripgrep.search("needle", in: root)
cancelled.cancel()
let first = try await cancelled.makeAsyncIterator().next()
precondition(first == nil, "cancelled search must end immediately")

#if RIPGREP_VERIFY_GLOBS
// 3. Require the new binary's traversal filtering and error mapping to work.
let filteredOptions = RipgrepOptions(
    includeGlobs: ["*.txt"], excludeGlobs: ["file1.txt", "file2.txt"]
)
var filteredCount = 0
for try await match in Ripgrep.search("needle", in: root, options: filteredOptions) {
    precondition(match.fileURL.lastPathComponent == "file0.txt")
    filteredCount += 1
}
precondition(filteredCount == 20_000)
do {
    for try await _ in Ripgrep.search("needle", in: root, options: .init(includeGlobs: ["["])) {
        preconditionFailure("invalid glob delivered a match")
    }
    preconditionFailure("invalid glob succeeded")
} catch RipgrepError.invalidGlob(let message) {
    precondition(message.contains("["))
}
#endif

print("release consumer verification passed: consumed \(count) matches, cancellation clean")
