# RipgrepSwift

Native Swift filesystem search powered by [ripgrep](https://github.com/BurntSushi/ripgrep)'s
Rust libraries — **no `rg` executable required**.

RipgrepSwift embeds ripgrep's reusable crates (`grep`, `ignore`) as a static
library behind a small C ABI and wraps them in an async, streaming Swift API.

```swift
import Ripgrep

let root = URL(fileURLWithPath: "/path/to/project")

for try await match in Ripgrep.search("TODO|FIXME", in: root) {
    print("\(match.fileURL.path):\(match.lineNumber):\(match.line)")
}
```

## Installation

```swift
dependencies: [
    .package(
        url: "https://github.com/atacan/RipgrepSwift.git",
        from: "0.1.1"
    )
]
```

The default package manifest resolves the compiled Rust code (macOS arm64 +
x86_64) from a GitHub Release asset, so consuming projects build without a
Rust toolchain. To build against a locally built XCFramework instead, set
`RIPGREP_XCFRAMEWORK_PATH` (see [Building the native library](#building-the-native-library)).

## API

### `Ripgrep.search(_:in:options:)`

Returns a `RipgrepSearchResults: AsyncSequence`. **Startup is lazy**: calling
`Ripgrep.search(...)` only constructs the search description. Filesystem
traversal begins exactly once, when the single consuming iterator is created
(explicitly or via `for try await`). Consequences:

- Creating the sequence and dropping it without iterating starts no native
  work at all — nothing to leak, nothing to clean up.
- Calling `cancel()` before iteration permanently prevents startup; later
  iteration simply ends with `nil`.
- Requesting a second iterator returns an already-finished iterator; it
  neither restarts nor corrupts the first search.

The native search runs on its **own dedicated background thread** (a
Foundation `Thread` at `.utility` quality of service) — never on the Swift
cooperative executor pool. Only that producer thread ever blocks; consumer
code suspends through continuations, so awaiting results occupies no
cooperative worker.

Delivery is **strictly backpressured**: the native filesystem search is
parked between consumer requests and cannot advance until your code asks for
the next match (`for try await`). At most one produced match is ever
buffered, so memory use stays constant regardless of tree size or result
count — nothing accumulates.

A line containing several regex matches produces one `RipgrepMatch` per
match, all sharing the same `lineNumber` and `line`.

The sequence supports exactly **one** consuming iterator (single pass), like
most streaming APIs.

### `RipgrepMatch`

| Property | Meaning |
| --- | --- |
| `fileURL` | File containing the match |
| `lineNumber` | Human-oriented, 1-based line number |
| `line` | Full matched line, terminator removed |
| `matchStart` | Zero-based **UTF-8 byte offset** of the match within `line` |
| `matchEnd` | Byte offset one past the match's last byte |

Match offsets are UTF-8 byte offsets — ripgrep's natural unit — *not* Swift
`String.Index` or character positions:

```swift
// "日本語 TODO" → matchStart == 10, matchEnd == 14
```

### `RipgrepOptions`

```swift
var options = RipgrepOptions()
options.includeHidden = true       // default: false
options.caseInsensitive = true     // default: false
options.followSymbolicLinks = true // default: false
options.respectGitIgnore = false   // default: true

for try await match in Ripgrep.search("important", in: root, options: options) {
    // ...
}
```

Defaults mirror the `rg` command line. See below for exact semantics.

### Errors

All failures surface as `RipgrepError`: `.invalidPattern(String)`,
`.invalidArgument(String)`, `.io(String)`, `.internalError(String)`. Numeric
C status codes are never exposed.

## Behavior

- **Ignore files**: with `respectGitIgnore == true` (the default),
  `.gitignore`, `.git/info/exclude`, global git ignore files, and `.ignore`
  files are honored exactly like `rg`. Nested ignore files apply to their
  subtree; negated patterns (`!keep.txt`) work. Ignore handling requires a
  git repository for git-specific files (as `rg` does).
- **Hidden files**: skipped by default; pass `includeHidden: true` to include
  dotfiles and dot-directories (including `.git` contents, like `rg --hidden`).
- **Binary files**: once a NUL byte is observed in a file (ripgrep's default
  "quit" detection), searching that file stops silently.
- **Cancellation**: stopping iteration (`break`), cancelling the consuming
  task, dropping the live iterator, or calling `cancel()` explicitly stops
  the native search. Cancellation is **native and independent of match
  callbacks**: an explicit cancellation token is observed by the Rust core

  - between files during traversal,
  - before every read chunk *inside* a file — so even a single huge file
    containing no matches at all stops reading well before its end, and
  - immediately when the producer is parked on the backpressure gate.

  Cancellation granularity is one read chunk (kilobytes) within a file; the
  chunk in flight when cancellation lands finishes first. It is not
  reported as an error: iteration ends with `nil`, and `rg_search` returns
  `RG_STATUS_CANCELLED`. Dropping the sequence without ever iterating never
  starts a search in the first place (lazy startup).
- **Concurrency**: one search delivers results serially to a single
  consumer from its own dedicated producer thread. Independent searches run
  concurrently on their own threads; there is no shared mutable state
  between searches.
- **Paths**: v1 supports paths representable as UTF-8 via `URL`. Paths Rust
  discovers that are not valid UTF-8 are skipped rather than corrupted.
- **Unreadable files**: individual traversal/read errors are skipped so one
  bad file does not abort a search (mirroring `rg`'s resilience). A missing
  root is reported as `.io`.

## Not implemented (yet)

This first version intentionally implements a small slice of ripgrep:
fixed-string matching, PCRE2, replacement, glob/type filters, context lines,
multiline patterns, archive searching, parallel traversal, and JSON output
are not available yet.

## Reproducible native builds

The Rust toolchain is pinned via `Native/ripgrep-ffi/rust-toolchain.toml`,
and `Cargo.lock` is committed, so release artifacts build reproducibly. CI
installs the same pinned toolchain.

## Building the native library

Only needed when changing the Rust code:

```bash
./Scripts/build-xcframework.sh
```

Requirements: Rust with the `aarch64-apple-darwin` and
`x86_64-apple-darwin` targets (`rustup target add ...` is performed by the
script automatically) and Xcode's command line tools.

The script creates `Artifacts/CRipgrep.xcframework`. `Artifacts/` is never
committed to git — the binary is distributed as a GitHub Release asset.

To build this package against your freshly built framework, point SwiftPM at
it with the environment variable:

```bash
RIPGREP_XCFRAMEWORK_PATH=Artifacts/CRipgrep.xcframework swift build
```

Without the variable, the manifest downloads the released zip.

## Development

```bash
./Scripts/build-xcframework.sh   # rebuild Artifacts/CRipgrep.xcframework
RIPGREP_XCFRAMEWORK_PATH=Artifacts/CRipgrep.xcframework swift test

cd Native/ripgrep-ffi
cargo test                       # Rust test suite
cargo clippy && cargo fmt --check
```

Or run everything at once (builds the framework, exports the env var, runs
all checks):

```bash
./Scripts/verify.sh
```

## GitHub Releases

The XCFramework is published as a release asset so consumers never need
Rust installed:

```bash
./Scripts/build-xcframework.sh
./Scripts/package-release.sh 0.1.1 atacan/RipgrepSwift
gh release create 0.1.1 Release/CRipgrep.xcframework.zip --title "0.1.1"
```

`package-release.sh` prints the SwiftPM checksum. **Release checklist** (in
this order, so `Package.swift` only ever references an asset that exists):

1. Verify everything locally: `./Scripts/verify.sh`.
2. Build and package the zip (commands above) and note the checksum.
3. Update the `url:`/`checksum:` in `Package.swift` to the new tag and
   printed checksum, and bump the installation snippet in this README.
4. Commit that release-ready source state and tag it.
5. Create the GitHub release with exactly the zip that was checksummed —
   release assets are immutable once consumers have cached the checksum.
6. Run `./Scripts/verify-release-consumer.sh <tag>` to verify a fresh,
   cache-free consumer resolves the remote binary, links it, and runs a
   real search with no environment override.

## Verifying the released binary

Development builds test against a freshly built local XCFramework (see
above). To verify what a real SwiftPM consumer downloads instead:

```bash
./Scripts/verify-release-consumer.sh 0.1.1
```

This creates a fresh temporary executable package depending on this repo at
the given ref, requires that `RIPGREP_XCFRAMEWORK_PATH` is unset, lets
SwiftPM download the GitHub Release XCFramework named by `Package.swift`,
checks the downloaded binary exports the current ABI symbols, compiles
against it, runs a real search consuming results, exercises cancellation,
and fails on any problem. It also runs automatically for published
releases via the `Release verification` GitHub Actions workflow.

The fixture itself lives in `Scripts/release-consumer/main.swift` and is
validated before any tag is created: `./Scripts/verify.sh` (part of the
release checklist's first step) compiles and runs it against the freshly
built local XCFramework via `Scripts/check-release-consumer-fixture.sh`.

## Architecture

```
Swift application
        │
        ▼
Public Swift API (Ripgrep, RipgrepSearchResults, RipgrepMatch, RipgrepOptions)
  lazy start · strict backpressure · dedicated producer Thread · cancellation
        │
        ▼
CRipgrep module (ripgrep_ffi.h, small stable C ABI)
        │
        ▼
Rust FFI crate (panic containment, ownership rules,
                rg_cancel_token_t native cancellation)
        │
   ┌────┴─────┐
   ▼          ▼
 grep      ignore
(regex/   (traversal,
 search)   .gitignore)
```

The Rust core is directly unit/integration tested without FFI; the C layer is
a thin conversion boundary with documented ownership rules.

## License

MIT — see [LICENSE](LICENSE).
