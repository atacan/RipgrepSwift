//! Path filtering across the safe core and the native walker.
use ripgrep_ffi::error::SearchError;
use ripgrep_ffi::search::{collect_matches, search, SearchOptions, SearchOutcome, SearchProgress};
use std::collections::BTreeSet;
use std::ops::ControlFlow;
use std::sync::atomic::{AtomicBool, Ordering};
use tempfile::TempDir;

fn fixture(files: &[(&str, &str)]) -> TempDir {
    let root = TempDir::new().unwrap();
    std::fs::create_dir(root.path().join(".git")).unwrap();
    for (path, contents) in files {
        let path = root.path().join(path);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, contents).unwrap();
    }
    root
}
fn options(includes: &[&str], excludes: &[&str]) -> SearchOptions {
    SearchOptions {
        include_globs: includes.iter().map(|s| s.to_string()).collect(),
        exclude_globs: excludes.iter().map(|s| s.to_string()).collect(),
        ..SearchOptions::default()
    }
}
fn paths(root: &std::path::Path, options: SearchOptions) -> BTreeSet<String> {
    collect_matches(root, "needle", options)
        .unwrap()
        .into_iter()
        .map(|m| {
            m.0.strip_prefix(root)
                .unwrap()
                .to_str()
                .unwrap()
                .to_string()
        })
        .collect()
}
fn expected(paths: &[&str]) -> BTreeSet<String> {
    paths.iter().map(|s| s.to_string()).collect()
}

#[test]
fn glob_includes_are_ored_at_root_and_nested_with_spaces_and_unicode() {
    let root = fixture(&[
        ("main.swift", "needle"),
        ("src/deep/日本 語.swift", "needle"),
        ("src/lib.rs", "needle"),
        ("notes.txt", "needle"),
    ]);
    assert_eq!(
        paths(root.path(), options(&["**/*.swift"], &[])),
        expected(&["main.swift", "src/deep/日本 語.swift"])
    );
    assert_eq!(
        paths(root.path(), options(&["**/*.swift", "**/*.rs"], &[])),
        expected(&["main.swift", "src/deep/日本 語.swift", "src/lib.rs"])
    );
    assert_eq!(
        paths(root.path(), options(&["**/日本 語.swift"], &[])),
        expected(&["src/deep/日本 語.swift"])
    );
}
#[test]
fn glob_excludes_are_ored_and_always_win() {
    let root = fixture(&[
        ("a.swift", "needle"),
        ("b.rs", "needle"),
        ("c.txt", "needle"),
        ("Generated/a.swift", "needle"),
    ]);
    assert_eq!(
        paths(root.path(), options(&[], &["**/*.rs"])),
        expected(&["a.swift", "c.txt", "Generated/a.swift"])
    );
    assert_eq!(
        paths(root.path(), options(&[], &["**/*.rs", "Generated/"])),
        expected(&["a.swift", "c.txt"])
    );
    assert_eq!(
        paths(
            root.path(),
            options(&["**/*.swift", "Generated/**"], &["Generated/", "a.swift"])
        ),
        expected(&[])
    );
    assert_eq!(
        paths(
            root.path(),
            options(&["Generated/**", "**/*.swift"], &["a.swift", "Generated/"])
        ),
        expected(&[])
    );
}
#[test]
fn glob_anchoring_directory_and_content_patterns() {
    let root = fixture(&[
        ("a.swift", "needle"),
        ("src/a.swift", "needle"),
        ("src/deep/a.swift", "needle"),
        ("other/src/a.swift", "needle"),
    ]);
    assert_eq!(
        paths(root.path(), options(&["/a.swift"], &[])),
        expected(&["a.swift"])
    );
    assert_eq!(
        paths(root.path(), options(&["src/*.swift"], &[])),
        expected(&["src/a.swift"])
    );
    assert_eq!(
        paths(root.path(), options(&["src/**"], &[])),
        expected(&["src/a.swift", "src/deep/a.swift"])
    );
    assert_eq!(paths(root.path(), options(&["src/"], &[])), expected(&[]));
    assert_eq!(
        paths(root.path(), options(&[], &["src/"])),
        expected(&["a.swift"])
    );
    assert_eq!(
        paths(root.path(), options(&[], &["src/**"])),
        expected(&["a.swift", "other/src/a.swift"])
    );
}
#[test]
fn glob_filters_preserve_gitignore_ignore_negation_and_hidden_handling() {
    let root = fixture(&[
        (".gitignore", "ignored.swift\n*.log\n!keep.log\n"),
        (".ignore", "other.swift\n"),
        ("src/.ignore", "generated.swift\n"),
        ("src/generated.swift", "needle"),
        ("ignored.swift", "needle"),
        ("other.swift", "needle"),
        ("noise.log", "needle"),
        ("keep.log", "needle"),
        ("visible.swift", "needle"),
        (".hidden.swift", "needle"),
        (".hidden/a.swift", "needle"),
        ("excluded.swift", "needle"),
    ]);
    let mut opts = options(&["**/*.swift", "*.log"], &["excluded.swift"]);
    assert_eq!(
        paths(root.path(), opts.clone()),
        expected(&["visible.swift", "keep.log"])
    );
    opts.include_hidden = true;
    assert_eq!(
        paths(root.path(), opts.clone()),
        expected(&[
            "visible.swift",
            "keep.log",
            ".hidden.swift",
            ".hidden/a.swift"
        ])
    );
    opts.respect_gitignore = false;
    assert_eq!(
        paths(root.path(), opts),
        expected(&[
            "visible.swift",
            "keep.log",
            ".hidden.swift",
            ".hidden/a.swift",
            "ignored.swift",
            "other.swift",
            "noise.log",
            "src/generated.swift"
        ])
    );
}
#[test]
fn glob_directory_exclusion_prevents_searching_and_reading_descendants() {
    let root = fixture(&[
        ("kept.swift", "needle\n"),
        ("Generated/deep/a.swift", "needle\n"),
        ("Generated/b.txt", "never matches\n"),
    ]);
    let mut progress = SearchProgress {
        files_visited: 0,
        bytes_searched: 0,
    };
    let outcome = search(
        root.path(),
        "needle",
        options(&[], &["Generated/"]),
        &AtomicBool::new(false),
        |_| ControlFlow::Continue(()),
        |p| progress = p,
    )
    .unwrap();
    assert_eq!(outcome, SearchOutcome::Completed);
    assert_eq!(progress.files_visited, 1);
    assert_eq!(progress.bytes_searched, 7);
}
#[test]
fn glob_invalid_patterns_fail_before_matches_or_progress() {
    let root = fixture(&[("a.swift", "needle")]);
    for pattern in [
        "[", "{a,b", "", "   ", "!a.swift", "#comment", "a\nb", "a\rb", "a\0b",
    ] {
        for opts in [options(&[pattern], &[]), options(&[], &[pattern])] {
            let result = search(
                root.path(),
                "needle",
                opts,
                &AtomicBool::new(false),
                |_| panic!("no match on invalid glob"),
                |_| panic!("no reads on invalid glob"),
            );
            assert!(
                matches!(result, Err(SearchError::InvalidGlob(_))),
                "{pattern:?}: {result:?}"
            );
        }
    }
}
#[test]
fn glob_empty_arrays_preserve_existing_matches_exactly() {
    let root = fixture(&[
        ("a.swift", "needle"),
        ("nested/b.txt", "needle"),
        (".hidden", "needle"),
        (".gitignore", "ignored.rs"),
        ("ignored.rs", "needle"),
    ]);
    assert_eq!(
        collect_matches(root.path(), "needle", SearchOptions::default()).unwrap(),
        collect_matches(root.path(), "needle", options(&[], &[])).unwrap()
    );
}
#[test]
fn glob_single_file_roots_are_filtered_relative_to_parent() {
    let root = fixture(&[("a.swift", "needle")]);
    let file = root.path().join("a.swift");
    assert_eq!(
        collect_matches(&file, "needle", options(&["/a.swift"], &[]))
            .unwrap()
            .len(),
        1
    );
    assert!(collect_matches(&file, "needle", options(&["*.rs"], &[]))
        .unwrap()
        .is_empty());
    assert!(collect_matches(&file, "needle", options(&[], &["a.swift"]))
        .unwrap()
        .is_empty());
}
#[test]
fn glob_literal_escaped_prefixes_and_case_sensitivity() {
    let root = fixture(&[
        ("!a.swift", "needle"),
        ("#b.swift", "needle"),
        ("C.SWIFT", "NEEDLE"),
    ]);
    assert_eq!(
        paths(root.path(), options(&["\\!a.swift", "\\#b.swift"], &[])),
        expected(&["!a.swift", "#b.swift"])
    );
    assert_eq!(
        paths(root.path(), options(&[], &["\\!a.swift", "\\#b.swift"])),
        expected(&[])
    );
    let mut opts = options(&["*.swift"], &[]);
    opts.case_insensitive = true;
    assert_eq!(
        paths(root.path(), opts),
        expected(&["!a.swift", "#b.swift"])
    );
}
#[cfg(unix)]
#[test]
fn glob_symlink_paths_compose_with_following_and_pruning() {
    let root = fixture(&[("visible.swift", "needle")]);
    let target = fixture(&[("a.swift", "needle"), ("a.txt", "needle")]);
    std::os::unix::fs::symlink(target.path(), root.path().join("linked")).unwrap();
    let mut opts = options(&["linked/**/*.swift"], &[]);
    assert!(paths(root.path(), opts.clone()).is_empty());
    opts.follow_symlinks = true;
    assert_eq!(
        paths(root.path(), opts.clone()),
        expected(&["linked/a.swift"])
    );
    opts.exclude_globs = vec!["linked/".into()];
    assert!(paths(root.path(), opts).is_empty());
}
#[test]
fn glob_filtered_search_can_cancel_on_callback_and_inside_matchless_file() {
    let root = fixture(&[
        ("kept.swift", &"needle\n".repeat(1000)),
        ("excluded.txt", "needle"),
    ]);
    let mut count = 0;
    let outcome = search(
        root.path(),
        "needle",
        options(&["*.swift"], &[]),
        &AtomicBool::new(false),
        |_| {
            count += 1;
            ControlFlow::Break(())
        },
        |_| {},
    )
    .unwrap();
    assert_eq!(outcome, SearchOutcome::Cancelled);
    assert_eq!(count, 1);
    let contents = "no matches here\n".repeat(100_000);
    std::fs::write(root.path().join("kept.swift"), &contents).unwrap();
    let cancel = AtomicBool::new(false);
    let mut bytes = 0;
    let outcome = search(
        root.path(),
        "needle",
        options(&["*.swift"], &[]),
        &cancel,
        |_| panic!("no matches"),
        |p| {
            bytes = p.bytes_searched;
            cancel.store(true, Ordering::Release);
        },
    )
    .unwrap();
    assert_eq!(outcome, SearchOutcome::Cancelled);
    assert!(bytes > 0 && bytes < contents.len() as u64);
}
#[test]
fn glob_concurrent_searches_keep_independent_filters() {
    let root = fixture(&[
        ("a.swift", "needle"),
        ("b.rs", "needle"),
        ("c.txt", "needle"),
    ]);
    std::thread::scope(|scope| {
        let a = scope.spawn(|| paths(root.path(), options(&["*.swift"], &[])));
        let b = scope.spawn(|| paths(root.path(), options(&["*.rs"], &[])));
        assert_eq!(a.join().unwrap(), expected(&["a.swift"]));
        assert_eq!(b.join().unwrap(), expected(&["b.rs"]));
    });
}

#[test]
fn glob_relative_root_has_the_same_anchoring_as_an_absolute_root() {
    let cwd = std::env::current_dir().unwrap();
    let root = TempDir::new_in(&cwd).unwrap();
    std::fs::create_dir(root.path().join("src")).unwrap();
    std::fs::write(root.path().join("a.swift"), "needle").unwrap();
    std::fs::write(root.path().join("src/a.swift"), "needle").unwrap();
    let relative = root.path().strip_prefix(&cwd).unwrap();
    for opts in [
        options(&["/a.swift"], &[]),
        options(&["src/**"], &[]),
        options(&[], &["src/"]),
    ] {
        assert_eq!(paths(relative, opts.clone()), paths(root.path(), opts));
    }
}
