//! Safe Rust search core built on ripgrep's reusable crates.
//!
//! This module contains no FFI. It walks a directory tree with the `ignore`
//! crate, searches each file with the `grep` crates, and reports every
//! individual regular-expression match through a caller-supplied closure.
//!
//! Cancellation is driven by an externally owned [`AtomicBool`] that is
//! checked independently of match callbacks:
//!
//! * between files, before each directory entry is processed;
//! * inside a file, before every read chunk (via a cancellation-aware
//!   reader), so even one huge file with no matches stops reading shortly
//!   after cancellation is requested;
//! * when a match callback returns [`ControlFlow::Break`].
//!
//! Progress (files visited and bytes read so far) is reported through an
//! optional callback so embedders can instrument searches.

use std::cell::Cell;
use std::fs::File;
use std::io::Read;
use std::ops::ControlFlow;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

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

/// Traversal progress snapshot delivered to the progress callback.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SearchProgress {
    /// Number of regular files whose search has started.
    pub files_visited: u64,
    /// Total number of bytes read across all searched files so far.
    pub bytes_searched: u64,
}

/// Result of a full search run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SearchOutcome {
    /// Every file was searched to completion.
    Completed,
    /// The search was cancelled, either by the consumer's callback or by
    /// the external cancellation flag.
    Cancelled,
}

/// Searches `root` for `pattern`, invoking `on_match` for every individual
/// regex match (a line containing three matches produces three callbacks).
///
/// `cancel` is observed continuously and independently of `on_match`:
///
/// * before each directory entry during traversal;
/// * before each read chunk while scanning a file, so cancellation takes
///   effect inside long individual-file searches even when no matches are
///   being produced. The granularity is one read chunk (kilobytes), not a
///   single line or regex evaluation; the current chunk completes first.
///
/// Returning [`ControlFlow::Break`] from `on_match` also cancels the search.
/// In every cancelled case the function returns
/// [`SearchOutcome::Cancelled`]; `on_progress`, when provided, receives a
/// cumulative snapshot after each read chunk.
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
pub fn search<F, P>(
    root: &Path,
    pattern: &str,
    options: SearchOptions,
    cancel: &AtomicBool,
    mut on_match: F,
    mut on_progress: P,
) -> Result<SearchOutcome, crate::error::SearchError>
where
    F: FnMut(SearchMatch<'_>) -> ControlFlow<()>,
    P: FnMut(SearchProgress),
{
    if !root.exists() {
        return Err(crate::error::SearchError::Io(format!(
            "search root {} does not exist",
            root.display()
        )));
    }

    if cancel.load(Ordering::Acquire) {
        return Ok(SearchOutcome::Cancelled);
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

    let cancelled_by_callback = Cell::new(false);
    let files_visited = Cell::new(0u64);
    let bytes_searched = Cell::new(0u64);

    for entry in walker_builder.build() {
        if cancelled_by_callback.get() || cancel.load(Ordering::Acquire) {
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

        files_visited.set(files_visited.get() + 1);

        let sink = CallbackSink {
            matcher: &matcher,
            path,
            callback: &mut on_match,
            cancelled: &cancelled_by_callback,
        };

        // Opening the file ourselves lets the reader observe cancellation
        // before every chunk, which `search_path` alone cannot offer. A
        // failure to open is skipped like any other per-entry error.
        if let Ok(file) = File::open(path) {
            let mut reader = CancellationReader {
                inner: file,
                cancel,
                bytes_searched: &bytes_searched,
                files_visited: files_visited.get(),
                progress: &mut on_progress,
            };
            match searcher.search_reader(&matcher, &mut reader, sink) {
                Err(error) if is_cancellation_error(&error) => break,
                // Any other per-file error must not abort the whole
                // search; skip the file and keep going.
                _ => {}
            }
        }
    }

    let cancelled = cancelled_by_callback.get() || cancel.load(Ordering::Acquire);
    Ok(if cancelled {
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

/// Wraps a file reader so that cancellation is observed before every read
/// chunk, not just between files or at match callbacks. Byte counts are
/// accumulated and reported through the progress callback.
struct CancellationReader<'a, R, P> {
    inner: R,
    cancel: &'a AtomicBool,
    bytes_searched: &'a Cell<u64>,
    files_visited: u64,
    progress: &'a mut P,
}

impl<R, P> Read for CancellationReader<'_, R, P>
where
    R: Read,
    P: FnMut(SearchProgress),
{
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if self.cancel.load(Ordering::Acquire) {
            return Err(std::io::Error::other(SearchCancelled));
        }
        let read = self.inner.read(buf)?;
        if read > 0 {
            self.bytes_searched
                .set(self.bytes_searched.get() + read as u64);
            (self.progress)(SearchProgress {
                files_visited: self.files_visited,
                bytes_searched: self.bytes_searched.get(),
            });
        }
        Ok(read)
    }
}

/// Marker error used to unwind out of the searcher once cancellation has
/// been requested mid-file. It never escapes this module: it is recognized
/// and converted into [`SearchOutcome::Cancelled`] by the traversal loop.
#[derive(Debug)]
struct SearchCancelled;

impl std::fmt::Display for SearchCancelled {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "search cancelled")
    }
}

impl std::error::Error for SearchCancelled {}

fn is_cancellation_error(error: &std::io::Error) -> bool {
    error
        .get_ref()
        .is_some_and(|inner| inner.is::<SearchCancelled>())
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
    let outcome = search(
        root,
        pattern,
        options,
        &AtomicBool::new(false),
        |m| {
            collected.push((
                m.path.to_path_buf(),
                m.line_number,
                String::from_utf8_lossy(m.line).into_owned(),
                m.match_start,
                m.match_end,
            ));
            ControlFlow::Continue(())
        },
        |_| {},
    )?;
    debug_assert_eq!(outcome, SearchOutcome::Completed);
    Ok(collected)
}
