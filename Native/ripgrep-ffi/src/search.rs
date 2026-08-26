//! Safe Rust search core built on ripgrep's reusable crates.
//!
//! This module contains no FFI. It walks a directory tree with the `ignore`
//! crate, searches each file with the `grep` crates, and reports every
//! individual regular-expression match through a caller-supplied closure.
//! Cancellation flows back through `ControlFlow::Break`.

use std::cell::Cell;
use std::ops::ControlFlow;
use std::path::{Path, PathBuf};

use grep_matcher::{Match, Matcher};
use grep_regex::RegexMatcherBuilder;
use grep_searcher::{BinaryDetection, SearcherBuilder, Sink, SinkMatch};
use ignore::WalkBuilder;

/// Configuration for a single search run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SearchOptions {
    /// When true, hidden files and directories (dotfiles) are traversed.
    pub include_hidden: bool,
    /// When true, symbolic links are followed.
    pub follow_symlinks: bool,
    /// When true (the default), `.gitignore`/`.ignore`/global/exclude files
    /// are respected. When false, all ignore handling is disabled.
    pub respect_gitignore: bool,
    /// When true, the pattern matches case-insensitively.
    pub case_insensitive: bool,
}

impl Default for SearchOptions {
    fn default() -> Self {
        SearchOptions {
            include_hidden: false,
            follow_symlinks: false,
            respect_gitignore: true,
            case_insensitive: false,
        }
    }
}

/// One concrete regular-expression hit inside a single line of one file.
///
/// `line` is the matched line with its terminator removed, and the offsets
/// are zero-based UTF-8 byte offsets into that line.
#[derive(Debug)]
pub struct SearchMatch<'a> {
    pub path: &'a Path,
    pub line_number: u64,
    pub line: &'a [u8],
    pub match_start: usize,
    pub match_end: usize,
}

/// Result of a full search run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SearchOutcome {
    /// Every file was searched to completion.
    Completed,
    /// The consumer cancelled the search via its callback.
    Cancelled,
}

/// Searches `root` for `pattern`, invoking `on_match` for every individual
/// regex match (a line containing three matches produces three callbacks).
///
/// Returning `ControlFlow::Break` from `on_match` cancels the search as soon
/// as practical; the function then returns [`SearchOutcome::Cancelled`].
///
/// Traversal notes:
///
/// * Only regular files are searched; directories, symlinks (unless
///   followed), and special files are skipped.
/// * Paths that are not valid UTF-8 are skipped. This is a documented v1
///   limitation of the library contract.
/// * Errors on individual entries during traversal (for example unreadable
///   files or permission errors) are skipped so one bad file cannot abort an
///   entire search, mirroring ripgrep's resilience.
/// * Files are treated as binary once a NUL byte is observed (ripgrep's
///   default "quit" strategy); searching of such a file stops silently at
///   that point.
pub fn search<F>(
    root: &Path,
    pattern: &str,
    options: SearchOptions,
    mut on_match: F,
) -> Result<SearchOutcome, crate::error::SearchError>
where
    F: FnMut(SearchMatch<'_>) -> ControlFlow<()>,
{
    if !root.exists() {
        return Err(crate::error::SearchError::Io(format!(
            "search root {} does not exist",
            root.display()
        )));
    }

    let matcher = RegexMatcherBuilder::new()
        .case_insensitive(options.case_insensitive)
        .build(pattern)
        .map_err(|error| crate::error::SearchError::InvalidPattern(error.to_string()))?;

    let mut searcher_builder = SearcherBuilder::new();
    searcher_builder.binary_detection(BinaryDetection::quit(b'\x00'));
    let mut searcher = searcher_builder.build();

    let mut walker_builder = WalkBuilder::new(root);
    walker_builder.hidden(!options.include_hidden);
    walker_builder.follow_links(options.follow_symlinks);
    if !options.respect_gitignore {
        walker_builder.ignore(false);
        walker_builder.git_ignore(false);
        walker_builder.git_global(false);
        walker_builder.git_exclude(false);
        walker_builder.parents(false);
    }

    let cancelled = Cell::new(false);

    for entry in walker_builder.build() {
        if cancelled.get() {
            break;
        }
        let entry = match entry {
            Ok(entry) => entry,
            Err(_) => continue,
        };
        let Some(file_type) = entry.file_type() else {
            continue;
        };
        if !file_type.is_file() {
            continue;
        }
        let path: &Path = entry.path();
        if path.to_str().is_none() {
            // Skip paths that are not valid UTF-8; documented v1 behavior.
            continue;
        }

        let sink = CallbackSink {
            matcher: &matcher,
            path,
            callback: &mut on_match,
            cancelled: &cancelled,
        };

        // Errors while reading an individual file must not abort the whole
        // search; skip the file and keep going.
        let _ = searcher.search_path(&matcher, path, sink);
    }

    Ok(if cancelled.get() {
        SearchOutcome::Cancelled
    } else {
        SearchOutcome::Completed
    })
}

struct CallbackSink<'a, 'b, M: Matcher, F> {
    matcher: &'a M,
    path: &'b Path,
    callback: &'a mut F,
    cancelled: &'a Cell<bool>,
}

impl<M, F> Sink for CallbackSink<'_, '_, M, F>
where
    M: Matcher,
    F: FnMut(SearchMatch<'_>) -> ControlFlow<()>,
{
    type Error = std::io::Error;

    fn matched(
        &mut self,
        _searcher: &grep_searcher::Searcher,
        mat: &SinkMatch<'_>,
    ) -> Result<bool, Self::Error> {
        let line = strip_line_terminator(mat.bytes());
        let line_number = mat.line_number().unwrap_or(0);
        let mut broke = false;

        self.matcher
            .find_iter(line, |m: Match| {
                let outcome = (self.callback)(SearchMatch {
                    path: self.path,
                    line_number,
                    line,
                    match_start: m.start(),
                    match_end: m.end(),
                });
                match outcome {
                    ControlFlow::Continue(()) => true,
                    ControlFlow::Break(()) => {
                        broke = true;
                        false
                    }
                }
            })
            .map_err(|error| std::io::Error::other(error.to_string()))?;

        if broke {
            self.cancelled.set(true);
            return Ok(false);
        }
        Ok(true)
    }
}

/// Removes a single trailing `\n` or `\r\n` from a line delivered by the
/// searcher. All reported offsets index into the returned slice.
fn strip_line_terminator(bytes: &[u8]) -> &[u8] {
    let mut end = bytes.len();
    if end > 0 && bytes[end - 1] == b'\n' {
        end -= 1;
    }
    if end > 0 && bytes[end - 1] == b'\r' {
        end -= 1;
    }
    &bytes[..end]
}

/// Convenience type for [`collect_matches`]: `(path, line_number, line,
/// match_start, match_end)`.
pub type CollectedMatch = (PathBuf, u64, String, usize, usize);

/// Convenience wrapper used by tests: collects matches into a vector.
#[allow(dead_code)]
pub fn collect_matches(
    root: &Path,
    pattern: &str,
    options: SearchOptions,
) -> Result<Vec<CollectedMatch>, crate::error::SearchError> {
    let mut collected = Vec::new();
    let outcome = search(root, pattern, options, |m| {
        collected.push((
            m.path.to_path_buf(),
            m.line_number,
            String::from_utf8_lossy(m.line).into_owned(),
            m.match_start,
            m.match_end,
        ));
        ControlFlow::Continue(())
    })?;
    debug_assert_eq!(outcome, SearchOutcome::Completed);
    Ok(collected)
}
