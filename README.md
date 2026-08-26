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
        from: "0.1.0"
    )
]
```

The package ships a committed `Artifacts/CRipgrep.xcframework` containing the
compiled Rust code (macOS arm64 + x86_64), so consuming projects build
without a Rust toolchain.

## API

### `Ripgrep.search(_:in:options:)`

Returns an `AsyncThrowingStream<RipgrepMatch, Error>`. The native search runs
on a background task; matches are delivered serially as they are discovered —
results are streamed, never accumulated up front.

A line containing several regex matches produces one `RipgrepMatch` per
match, all sharing the same `lineNumber` and `line`.

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
- **Cancellation**: stopping iteration (`break`) or cancelling the consuming
  task stops the native search as soon as practical. Cancellation is not
  reported as an error.
- **Concurrency**: one search delivers results serially. Independent searches
  may run concurrently; there is no shared mutable state between searches.
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

## Building the native library

Only needed when changing the Rust code:

```bash
./Scripts/build-xcframework.sh
```

Requirements: Rust with the `aarch64-apple-darwin` and
`x86_64-apple-darwin` targets (`rustup target add ...` is performed by the
script automatically) and Xcode's command line tools.

## Development

```bash
./Scripts/build-xcframework.sh   # rebuild Artifacts/CRipgrep.xcframework
swift test                       # Swift test suite

cd Native/ripgrep-ffi
cargo test                       # Rust test suite
cargo clippy && cargo fmt --check
```

Or run everything at once:

```bash
./Scripts/verify.sh
```

## Architecture

```
Swift application
        │
        ▼
Public Swift API (Ripgrep, RipgrepMatch, RipgrepOptions)
        │
        ▼
CRipgrep module (ripgrep_ffi.h, small stable C ABI)
        │
        ▼
Rust FFI crate (panic containment, ownership rules, callback bridge)
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
