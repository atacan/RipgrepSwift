//! Integration tests for the safe Rust search core.
//!
//! These run without any FFI or Swift involvement, per the plan's guidance
//! that most behavior should be testable from plain Rust.

use std::ops::ControlFlow;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;

use ripgrep_ffi::search::{collect_matches, search, SearchOptions, SearchOutcome, SearchProgress};
use tempfile::TempDir;

fn fixture(files: &[(&str, &str)]) -> TempDir {
    let dir = TempDir::new().expect("create temp fixture");
    for (relative_path, contents) in files {
        let target = dir.path().join(relative_path);
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent).expect("create fixture directory");
        }
        std::fs::write(&target, contents).expect("write fixture file");
    }
    // The `ignore` crate only honors .gitignore inside a git repository
    // (require_git defaults to true), so fixtures that exercise ignore
    // semantics include an empty .git directory.
    std::fs::create_dir_all(dir.path().join(".git")).expect("create .git");
    dir
}

fn default_options() -> SearchOptions {
    SearchOptions::default()
}

#[test]
fn literal_ascii_match() {
    let root = fixture(&[
        ("one.txt", "hello\nTODO: first\n"),
        ("two.txt", "nothing\n"),
    ]);

    let matches = collect_matches(root.path(), "TODO", default_options()).expect("search");

    assert_eq!(matches.len(), 1);
    let (path, line_number, line, start, end) = &matches[0];
    assert_eq!(path.file_name().unwrap(), "one.txt");
    assert_eq!(*line_number, 2);
    assert_eq!(line, "TODO: first");
    assert_eq!(*start, 0);
    assert_eq!(*end, 4);
}

#[test]
fn regex_alternation_and_multiple_files() {
    let root = fixture(&[("a.txt", "FIXME now\n"), ("b.txt", "TODO later\nFIXME\n")]);

    let matches = collect_matches(root.path(), "TODO|FIXME", default_options()).expect("search");

    assert_eq!(matches.len(), 3);
    let names: Vec<&str> = matches
        .iter()
        .map(|m| m.0.file_name().unwrap().to_str().unwrap())
        .collect();
    assert_eq!(names, vec!["b.txt", "b.txt", "a.txt"]);
}

#[test]
fn multiple_matches_on_one_line() {
    let root = fixture(&[("multi.txt", "TODO fix TODO\n")]);

    let matches = collect_matches(root.path(), "TODO", default_options()).expect("search");

    assert_eq!(matches.len(), 2);
    assert_eq!(matches[0].3, 0);
    assert_eq!(matches[0].4, 4);
    assert_eq!(matches[1].3, 9);
    assert_eq!(matches[1].4, 13);
}

#[test]
fn unicode_byte_offsets() {
    // café = 5 bytes (é is 2), 日本語 = 9 bytes, 🚀 = 4 bytes.
    let root = fixture(&[("uni.txt", "café TODO 日本語 FIXME 🚀\n")]);

    let matches = collect_matches(root.path(), "TODO|FIXME", default_options()).expect("search");

    assert_eq!(matches.len(), 2);
    assert_eq!(matches[0].1, 1);
    assert_eq!(matches[0].2, "café TODO 日本語 FIXME 🚀");
    assert_eq!(matches[0].3, 6, "after \"café \" (5 bytes + space)");
    assert_eq!(matches[0].4, 10);
    // café(5) + " "(1) + TODO(4) + " "(1) + 日本語(9) + " "(1) = 21
    assert_eq!(matches[1].3, 21, "after \"café TODO 日本語 \"");
    assert_eq!(matches[1].4, 26);
}

#[test]
fn combining_characters_count_toward_byte_offsets() {
    // "cafe" + U+0301 combining acute = 6 bytes total for "café".
    let root = fixture(&[("combining.txt", "cafe\u{301} TODO\n")]);

    let matches = collect_matches(root.path(), "TODO", default_options()).expect("search");

    assert_eq!(matches.len(), 1);
    assert_eq!(matches[0].2, "cafe\u{301} TODO");
    assert_eq!(matches[0].3, 7);
    assert_eq!(matches[0].4, 11);
}

#[test]
fn case_insensitive_option() {
    let root = fixture(&[("case.txt", "todo lowercase\nTodo mixed\n")]);

    let sensitive = collect_matches(root.path(), "TODO", default_options()).unwrap();
    assert_eq!(sensitive.len(), 0);

    let insensitive = collect_matches(
        root.path(),
        "TODO",
        SearchOptions {
            case_insensitive: true,
            ..default_options()
        },
    )
    .unwrap();
    assert_eq!(insensitive.len(), 2);
}

#[test]
fn invalid_pattern_is_rejected() {
    let root = fixture(&[("x.txt", "content\n")]);

    let error =
        collect_matches(root.path(), "(unclosed", default_options()).expect_err("must fail");

    assert!(matches!(
        error,
        ripgrep_ffi::error::SearchError::InvalidPattern(_)
    ));
}

#[test]
fn nonexistent_root_is_an_io_error() {
    let missing = std::env::temp_dir().join("ripgrep-ffi-does-not-exist-8347");

    let error = collect_matches(&missing, "x", default_options()).expect_err("must fail");

    assert!(matches!(error, ripgrep_ffi::error::SearchError::Io(_)));
}

#[test]
fn gitignore_respected_by_default() {
    let root = fixture(&[
        (".gitignore", "ignored.txt\nvendor/\n"),
        ("visible.txt", "needle visible\n"),
        ("ignored.txt", "needle ignored\n"),
        ("vendor/dependency.swift", "needle vendored\n"),
    ]);

    let matches = collect_matches(root.path(), "needle", default_options()).unwrap();
    let names: Vec<String> = matches
        .iter()
        .map(|m| m.0.to_string_lossy().into_owned())
        .collect();

    assert_eq!(names.len(), 1, "{names:?}");
    assert!(names[0].contains("visible.txt"), "{names:?}");
}

#[test]
fn gitignore_can_be_disabled() {
    let root = fixture(&[
        (".gitignore", "ignored.txt\n"),
        ("visible.txt", "needle visible\n"),
        ("ignored.txt", "needle ignored\n"),
    ]);

    let matches = collect_matches(
        root.path(),
        "needle",
        SearchOptions {
            respect_gitignore: false,
            ..default_options()
        },
    )
    .unwrap();

    assert_eq!(matches.len(), 2);
}

#[test]
fn nested_ignore_file_applies_to_subtree() {
    let root = fixture(&[
        ("src/.gitignore", "generated.swift\n"),
        ("src/included.swift", "needle included\n"),
        ("src/generated.swift", "needle generated\n"),
    ]);

    let matches = collect_matches(root.path(), "needle", default_options()).unwrap();

    assert_eq!(matches.len(), 1);
    assert!(matches[0].0.to_string_lossy().contains("included.swift"));
}

#[test]
fn negated_ignore_pattern_keeps_file() {
    let root = fixture(&[
        (".gitignore", "*.log\n!important.log\n"),
        ("noise.log", "needle noise\n"),
        ("important.log", "needle important\n"),
    ]);

    let matches = collect_matches(root.path(), "needle", default_options()).unwrap();

    assert_eq!(matches.len(), 1);
    assert!(matches[0].0.to_string_lossy().contains("important.log"));
}

#[test]
fn hidden_files_excluded_by_default() {
    let root = fixture(&[
        (".hidden.txt", "needle hidden\n"),
        (".hidden/inside.txt", "needle inside\n"),
        ("visible.txt", "needle visible\n"),
    ]);

    let matches = collect_matches(root.path(), "needle", default_options()).unwrap();

    assert_eq!(matches.len(), 1);
    assert!(matches[0].0.to_string_lossy().contains("visible.txt"));
}

#[test]
fn hidden_files_included_when_requested() {
    let root = fixture(&[
        (".hidden.txt", "needle hidden\n"),
        ("visible.txt", "needle visible\n"),
    ]);

    let matches = collect_matches(
        root.path(),
        "needle",
        SearchOptions {
            include_hidden: true,
            ..default_options()
        },
    )
    .unwrap();

    assert_eq!(matches.len(), 2);
}

#[test]
fn cancellation_stops_search_after_n_matches() {
    let mut contents = String::new();
    for index in 0..50_000 {
        contents.push_str(&format!("needle {index}\n"));
    }
    let root = fixture(&[("big.txt", contents.as_str())]);

    let mut seen = 0usize;
    let outcome = search(
        root.path(),
        "needle",
        default_options(),
        &AtomicBool::new(false),
        |_| {
            seen += 1;
            if seen >= 10 {
                ControlFlow::Break(())
            } else {
                ControlFlow::Continue(())
            }
        },
        |_| {},
    )
    .expect("search runs");

    assert_eq!(outcome, SearchOutcome::Cancelled);
    assert_eq!(seen, 10);
}

#[test]
fn completion_reported_when_not_cancelled() {
    let root = fixture(&[("small.txt", "needle once\n")]);

    let mut calls = 0usize;
    let outcome = search(
        root.path(),
        "needle",
        default_options(),
        &AtomicBool::new(false),
        |_| {
            calls += 1;
            ControlFlow::Continue(())
        },
        |_| {},
    )
    .expect("search runs");

    assert_eq!(outcome, SearchOutcome::Completed);
    assert_eq!(calls, 1);
}

#[test]
fn preset_cancel_flag_stops_search_before_any_match() {
    let root = fixture(&[("a.txt", "needle a\n"), ("b.txt", "needle b\n")]);

    let mut calls = 0usize;
    let outcome = search(
        root.path(),
        "needle",
        default_options(),
        &AtomicBool::new(true),
        |_| {
            calls += 1;
            ControlFlow::Continue(())
        },
        |_| {},
    )
    .expect("search runs");

    // The flag short-circuits traversal; nothing is reported and the
    // outcome is cancellation rather than an error or completion.
    assert_eq!(outcome, SearchOutcome::Cancelled);
    assert_eq!(calls, 0);
}

#[test]
fn external_cancel_flag_stops_running_search_between_and_within_files() {
    let root = fixture(&[
        ("a.txt", "needle a\n"),
        ("b.txt", "needle b\n"),
        ("c.txt", "no match here\n"),
        ("d.txt", "needle d\n"),
    ]);

    let cancel = std::sync::Arc::new(AtomicBool::new(false));
    let canceller = {
        let cancel = cancel.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(1));
            cancel.store(true, Ordering::Release);
        })
    };

    let mut seen = 0usize;
    let outcome = search(
        root.path(),
        "needle",
        default_options(),
        &cancel,
        |_| {
            seen += 1;
            ControlFlow::Continue(())
        },
        |_| {},
    )
    .expect("search runs");

    canceller.join().expect("canceller");
    assert_eq!(outcome, SearchOutcome::Cancelled);
    assert!(seen < 4, "search must not have completed: {seen}");
}

#[test]
fn cancellation_interrupts_single_large_file_without_matches() {
    // One multi-megabyte file with no matches at all. The searcher never
    // invokes the match callback, so only the per-chunk check inside the
    // reader can stop it before the whole file is read.
    let line = "alpha beta gamma delta epsilon zeta eta theta\n";
    let contents = line.repeat(400_000); // ~18 MB
    let root = fixture(&[("huge.txt", contents.as_str())]);
    let total_bytes = std::fs::metadata(root.path().join("huge.txt"))
        .unwrap()
        .len();

    let cancel = std::sync::Arc::new(AtomicBool::new(false));
    let progress_seen = std::sync::Arc::new(AtomicU64::new(0));

    let canceller = {
        let cancel = cancel.clone();
        let progress_seen = progress_seen.clone();
        std::thread::spawn(move || {
            // Wait until reading has demonstrably started, then cancel.
            while progress_seen.load(Ordering::Acquire) == 0 {
                std::thread::sleep(Duration::from_micros(100));
            }
            cancel.store(true, Ordering::Release);
        })
    };

    let mut matches = 0usize;
    let outcome = search(
        root.path(),
        "zzz-never-present-zzz",
        default_options(),
        &cancel,
        |_m| {
            matches += 1;
            ControlFlow::Continue(())
        },
        |progress: SearchProgress| {
            progress_seen.store(progress.bytes_searched, Ordering::Release);
        },
    )
    .expect("search runs");

    canceller.join().expect("canceller");

    assert_eq!(matches, 0);
    assert_eq!(outcome, SearchOutcome::Cancelled);
    // The decisive assertion: the file was NOT read to the end. Only the
    // chunk-level in-file cancellation can guarantee this for a matchless
    // file.
    let final_bytes = progress_seen.load(Ordering::Acquire);
    assert!(
        final_bytes < total_bytes,
        "cancelled after {final_bytes} of {total_bytes} bytes"
    );
}

#[test]
fn progress_callback_counts_files_and_bytes_exactly() {
    let root = fixture(&[
        ("a.txt", "one two three\n"),
        ("b.txt", "four five six seven\n"),
    ]);

    let cancel = AtomicBool::new(false);
    let mut calls = Vec::new();
    let outcome = search(
        root.path(),
        "two",
        default_options(),
        &cancel,
        |_m| ControlFlow::Continue(()),
        |progress: SearchProgress| calls.push(progress),
    )
    .expect("search runs");

    assert_eq!(outcome, SearchOutcome::Completed);
    assert!(!calls.is_empty());
    let last = calls.last().unwrap();
    assert_eq!(last.files_visited, 2);
    let expected_bytes: u64 = std::fs::read(root.path().join("a.txt")).unwrap().len() as u64
        + std::fs::read(root.path().join("b.txt")).unwrap().len() as u64;
    assert_eq!(last.bytes_searched, expected_bytes);
    // Snapshots are cumulative and monotonic.
    for pair in calls.windows(2) {
        assert!(pair[0].bytes_searched <= pair[1].bytes_searched);
        assert!(pair[0].files_visited <= pair[1].files_visited);
    }
}

#[cfg(unix)]
#[test]
fn unreadable_file_is_skipped_without_failing_search() {
    use std::os::unix::fs::PermissionsExt;

    let root = fixture(&[
        ("readable.txt", "needle readable\n"),
        ("locked.txt", "needle locked\n"),
    ]);
    let locked = root.path().join("locked.txt");
    let mut permissions = std::fs::metadata(&locked).unwrap().permissions();
    permissions.set_mode(0o000);
    std::fs::set_permissions(&locked, permissions).unwrap();

    // Note: tests must not run as root, otherwise mode 000 is still readable.
    let result = collect_matches(root.path(), "needle", default_options());

    let mut permissions = std::fs::metadata(&locked).unwrap().permissions();
    permissions.set_mode(0o644);
    std::fs::set_permissions(&locked, permissions).unwrap();

    if nix_uid_is_root() {
        return; // permission tricks are meaningless as root
    }

    let matches = result.expect("search must succeed despite the unreadable file");
    assert_eq!(matches.len(), 1);
    assert!(matches[0].0.to_string_lossy().contains("readable.txt"));
}

#[cfg(unix)]
fn nix_uid_is_root() -> bool {
    unsafe { libc_getuid() == 0 }
}

#[cfg(unix)]
unsafe fn libc_getuid() -> u32 {
    extern "C" {
        fn getuid() -> u32;
    }
    getuid()
}
