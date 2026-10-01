//! Smoke tests for the exported C ABI itself (`Phase 2` verification).
//!
//! These exercise `rg_search` exactly the way Swift does: borrowed byte
//! ranges, a C callback, a context pointer, a cancellation token, and an
//! error out-parameter.

use std::ffi::c_char;
use std::os::unix::ffi::OsStrExt;
use std::ptr;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::Duration;

use ripgrep_ffi::ffi::{
    rg_cancel_token_cancel, rg_cancel_token_create, rg_cancel_token_free, rg_free_string, rg_match,
    rg_progress_callback_t, rg_search, rg_search_options, rg_status,
};
use tempfile::TempDir;

fn default_c_options() -> rg_search_options {
    rg_search_options {
        include_hidden: false,
        follow_symlinks: false,
        respect_gitignore: true,
        case_insensitive: false,
    }
}

extern "C" fn counting_callback(context: *mut std::ffi::c_void, _m: *const rg_match) -> bool {
    let counter = unsafe { &*(context as *const AtomicUsize) };
    counter.fetch_add(1, Ordering::SeqCst);
    true
}

extern "C" fn cancelling_callback(_context: *mut std::ffi::c_void, _m: *const rg_match) -> bool {
    false
}

extern "C" fn progress_callback(
    context: *mut std::ffi::c_void,
    files_visited: u64,
    bytes_searched: u64,
) {
    // The context points at two atomics packed in an array:
    // [0] = files visited, [1] = bytes searched.
    let counters = unsafe { &*(context as *const [AtomicUsize; 2]) };
    counters[0].store(files_visited as usize, Ordering::SeqCst);
    counters[1].store(bytes_searched as usize, Ordering::SeqCst);
}

fn no_progress() -> rg_progress_callback_t {
    None
}

/// Runs `rg_search` with all parameters spelled out.
#[allow(clippy::too_many_arguments)]
unsafe fn run_search(
    root: &[u8],
    pattern: &[u8],
    options: &rg_search_options,
    cancel_token: *const ripgrep_ffi::ffi::rg_cancel_token,
    callback: ripgrep_ffi::ffi::rg_match_callback_t,
    context: *mut std::ffi::c_void,
    progress: rg_progress_callback_t,
    progress_context: *mut std::ffi::c_void,
    error_message: &mut *mut c_char,
) -> rg_status {
    unsafe {
        rg_search(
            root.as_ptr(),
            root.len(),
            pattern.as_ptr(),
            pattern.len(),
            options,
            cancel_token,
            callback,
            context,
            progress,
            progress_context,
            error_message,
        )
    }
}

#[test]
fn successful_search_returns_ok_and_delivers_matches() {
    let dir = TempDir::new().unwrap();
    std::fs::write(dir.path().join("a.txt"), "first TODO here\nsecond line\n").unwrap();

    let counter = AtomicUsize::new(0);
    let mut error_message: *mut c_char = ptr::null_mut();

    let status = unsafe {
        run_search(
            dir.path().as_os_str().as_bytes(),
            b"TODO",
            &default_c_options(),
            ptr::null(),
            Some(counting_callback),
            &counter as *const AtomicUsize as *mut std::ffi::c_void,
            no_progress(),
            ptr::null_mut(),
            &mut error_message,
        )
    };

    assert_eq!(status, rg_status::RG_STATUS_OK);
    assert!(error_message.is_null());
    assert_eq!(counter.load(Ordering::SeqCst), 1);
}

#[test]
fn null_root_is_invalid_argument() {
    let mut error_message: *mut c_char = ptr::null_mut();

    let status = unsafe {
        run_search(
            b"",
            b"x",
            &default_c_options(),
            ptr::null(),
            Some(counting_callback),
            ptr::null_mut(),
            no_progress(),
            ptr::null_mut(),
            &mut error_message,
        )
    };

    // An empty (hence null-based) root is rejected.
    assert_eq!(status, rg_status::RG_STATUS_INVALID_ARGUMENT);

    // The failure must have produced a freeable message.
    assert!(!error_message.is_null());
    unsafe {
        let message = std::ffi::CStr::from_ptr(error_message).to_string_lossy();
        assert!(!message.is_empty());
        rg_free_string(error_message);
    }
}

#[test]
fn invalid_pattern_returns_invalid_pattern_with_message() {
    let dir = TempDir::new().unwrap();
    let root_bytes = dir.path().as_os_str().as_bytes();

    let mut error_message: *mut c_char = ptr::null_mut();

    let status = unsafe {
        run_search(
            root_bytes,
            b"(unclosed",
            &default_c_options(),
            ptr::null(),
            Some(counting_callback),
            ptr::null_mut(),
            no_progress(),
            ptr::null_mut(),
            &mut error_message,
        )
    };

    assert_eq!(status, rg_status::RG_STATUS_INVALID_PATTERN);
    assert!(!error_message.is_null());
    unsafe { rg_free_string(error_message) };
}

#[test]
fn callback_returning_false_yields_cancelled() {
    let dir = TempDir::new().unwrap();
    let mut contents = String::new();
    for index in 0..100_000 {
        contents.push_str(&format!("needle {index}\n"));
    }
    std::fs::write(dir.path().join("big.txt"), contents).unwrap();
    let root_bytes = dir.path().as_os_str().as_bytes();

    let mut error_message: *mut c_char = ptr::null_mut();

    let status = unsafe {
        run_search(
            root_bytes,
            b"needle",
            &default_c_options(),
            ptr::null(),
            Some(cancelling_callback),
            ptr::null_mut(),
            no_progress(),
            ptr::null_mut(),
            &mut error_message,
        )
    };

    assert_eq!(status, rg_status::RG_STATUS_CANCELLED);
    assert!(error_message.is_null());
}

#[test]
fn missing_root_is_io_error() {
    let missing = std::env::temp_dir().join("ripgrep-ffi-missing-root-9912");
    let root_bytes = missing.as_os_str().as_bytes();

    let mut error_message: *mut c_char = ptr::null_mut();

    let status = unsafe {
        run_search(
            root_bytes,
            b"x",
            &default_c_options(),
            ptr::null(),
            Some(counting_callback),
            ptr::null_mut(),
            no_progress(),
            ptr::null_mut(),
            &mut error_message,
        )
    };

    assert_eq!(status, rg_status::RG_STATUS_IO_ERROR);
    assert!(!error_message.is_null());
    unsafe { rg_free_string(error_message) };
}

#[test]
fn free_string_accepts_null() {
    unsafe { rg_free_string(ptr::null_mut()) };
}

// MARK: Cancellation tokens

#[test]
fn token_create_and_free_round_trip() {
    let token = rg_cancel_token_create();
    assert!(!token.is_null());
    unsafe { rg_cancel_token_free(token) };
}

#[test]
fn cancelling_a_token_makes_subsequent_searches_stop_immediately() {
    let dir = TempDir::new().unwrap();
    let mut contents = String::new();
    for index in 0..100_000 {
        contents.push_str(&format!("needle {index}\n"));
    }
    std::fs::write(dir.path().join("big.txt"), contents).unwrap();
    let root_bytes = dir.path().as_os_str().as_bytes();

    let token = rg_cancel_token_create();
    // Cancel repeatedly: cancellation must be idempotent.
    unsafe { rg_cancel_token_cancel(token) };
    unsafe { rg_cancel_token_cancel(token) };
    unsafe { rg_cancel_token_cancel(token) };

    let counter = AtomicUsize::new(0);
    let mut error_message: *mut c_char = ptr::null_mut();

    let status = unsafe {
        run_search(
            root_bytes,
            b"needle",
            &default_c_options(),
            token,
            Some(counting_callback),
            &counter as *const AtomicUsize as *mut std::ffi::c_void,
            no_progress(),
            ptr::null_mut(),
            &mut error_message,
        )
    };

    assert_eq!(status, rg_status::RG_STATUS_CANCELLED);
    assert!(error_message.is_null());
    // Cancelled before traversal began, so nothing was ever reported.
    assert_eq!(counter.load(Ordering::SeqCst), 0);

    unsafe { rg_cancel_token_free(token) };
}

#[test]
fn uncancelled_token_allows_completion() {
    let dir = TempDir::new().unwrap();
    std::fs::write(dir.path().join("a.txt"), "TODO here\n").unwrap();
    let root_bytes = dir.path().as_os_str().as_bytes();

    let token = rg_cancel_token_create();
    let counter = AtomicUsize::new(0);
    let mut error_message: *mut c_char = ptr::null_mut();

    let status = unsafe {
        run_search(
            root_bytes,
            b"TODO",
            &default_c_options(),
            token,
            Some(counting_callback),
            &counter as *const AtomicUsize as *mut std::ffi::c_void,
            no_progress(),
            ptr::null_mut(),
            &mut error_message,
        )
    };

    assert_eq!(status, rg_status::RG_STATUS_OK);
    assert_eq!(counter.load(Ordering::SeqCst), 1);

    unsafe { rg_cancel_token_free(token) };
}

#[test]
fn null_token_functions_are_safe_noops() {
    unsafe { rg_cancel_token_cancel(ptr::null_mut()) };
    unsafe { rg_cancel_token_free(ptr::null_mut()) };
}

#[test]
fn token_cancelled_from_another_thread_stops_running_search() {
    let dir = TempDir::new().unwrap();
    let mut contents = String::new();
    for index in 0..2_000_000 {
        contents.push_str(&format!("needle {index}\n"));
    }
    std::fs::write(dir.path().join("big.txt"), contents).unwrap();
    let root_bytes = dir.path().as_os_str().as_bytes();

    let token = rg_cancel_token_create();
    let counter: &'static AtomicUsize = Box::leak(Box::new(AtomicUsize::new(0)));
    let search_finished: &'static AtomicBool = Box::leak(Box::new(AtomicBool::new(false)));

    // Raw pointers are not Send; carry the token address as an integer.
    // This is exactly the "cancel from another thread" scenario the token
    // is designed for.
    let token_address = token as usize;
    let canceller = std::thread::spawn(move || {
        let canceller_token = token_address as *mut ripgrep_ffi::ffi::rg_cancel_token;
        // Wait until the search has demonstrably started delivering
        // matches, then cancel from this unrelated thread.
        while counter.load(Ordering::SeqCst) == 0 && !search_finished.load(Ordering::SeqCst) {
            std::thread::sleep(Duration::from_micros(50));
        }
        if !search_finished.load(Ordering::SeqCst) {
            unsafe { rg_cancel_token_cancel(canceller_token) };
        }
    });

    let mut error_message: *mut c_char = ptr::null_mut();
    let status = unsafe {
        run_search(
            root_bytes,
            b"needle",
            &default_c_options(),
            token,
            Some(counting_callback),
            (counter as *const AtomicUsize) as *mut std::ffi::c_void,
            no_progress(),
            ptr::null_mut(),
            &mut error_message,
        )
    };
    search_finished.store(true, Ordering::SeqCst);

    // A full scan would deliver 2,000,000 callbacks; the cross-thread
    // cancellation must have stopped it far earlier. If the search happened
    // to complete before cancellation landed, OK is also acceptable and the
    // canceller observes the finished flag instead of cancelling.
    assert!(matches!(
        status,
        rg_status::RG_STATUS_CANCELLED | rg_status::RG_STATUS_OK
    ));
    assert!(error_message.is_null());
    assert!(counter.load(Ordering::SeqCst) < 2_000_000);

    canceller.join().expect("canceller thread");
    unsafe { rg_cancel_token_free(token) };
}

#[test]
fn repeated_searches_with_fresh_tokens_do_not_crash() {
    let dir = TempDir::new().unwrap();
    std::fs::write(dir.path().join("a.txt"), "needle once\n").unwrap();
    let root_bytes = dir.path().as_os_str().as_bytes();
    let match_counter: &'static AtomicUsize = Box::leak(Box::new(AtomicUsize::new(0)));

    for _ in 0..100 {
        let token = rg_cancel_token_create();
        let mut error_message: *mut c_char = ptr::null_mut();
        let status = unsafe {
            run_search(
                root_bytes,
                b"needle",
                &default_c_options(),
                token,
                Some(counting_callback),
                (match_counter as *const AtomicUsize) as *mut std::ffi::c_void,
                no_progress(),
                ptr::null_mut(),
                &mut error_message,
            )
        };
        assert_eq!(status, rg_status::RG_STATUS_OK);
        assert!(error_message.is_null());
        unsafe { rg_cancel_token_free(token) };
    }
}

#[test]
fn progress_callback_reports_files_and_bytes() {
    let dir = TempDir::new().unwrap();
    std::fs::write(dir.path().join("a.txt"), "first TODO here\nsecond line\n").unwrap();
    std::fs::write(dir.path().join("b.txt"), "another TODO line\n").unwrap();
    let root_bytes = dir.path().as_os_str().as_bytes();

    let counters = Box::leak(Box::new([AtomicUsize::new(0), AtomicUsize::new(0)]));
    let match_counter: &'static AtomicUsize = Box::leak(Box::new(AtomicUsize::new(0)));
    let mut error_message: *mut c_char = ptr::null_mut();

    let status = unsafe {
        run_search(
            root_bytes,
            b"TODO",
            &default_c_options(),
            ptr::null(),
            Some(counting_callback),
            (match_counter as *const AtomicUsize) as *mut std::ffi::c_void,
            Some(progress_callback),
            counters.as_ptr() as *mut std::ffi::c_void,
            &mut error_message,
        )
    };

    assert_eq!(status, rg_status::RG_STATUS_OK);
    assert!(
        counters[0].load(Ordering::SeqCst) >= 2,
        "both files visited"
    );
    assert!(counters[1].load(Ordering::SeqCst) > 0, "bytes were counted");
}

// MARK: Borrowed glob configuration (original rg_search ABI stays intact)
fn slices(patterns: &[&[u8]]) -> Vec<ripgrep_ffi::ffi::rg_utf8_slice> {
    patterns
        .iter()
        .map(|p| ripgrep_ffi::ffi::rg_utf8_slice {
            data: p.as_ptr(),
            len: p.len(),
        })
        .collect()
}
fn run_glob_search(
    root: &[u8],
    globs: *const ripgrep_ffi::ffi::rg_glob_options,
) -> (rg_status, usize, usize, usize, Option<String>) {
    let counter = AtomicUsize::new(0);
    let progress = [AtomicUsize::new(0), AtomicUsize::new(0)];
    let mut error = ptr::null_mut();
    let status = unsafe {
        ripgrep_ffi::ffi::rg_search_with_globs(
            root.as_ptr(),
            root.len(),
            b"needle".as_ptr(),
            6,
            &default_c_options(),
            globs,
            ptr::null(),
            Some(counting_callback),
            &counter as *const _ as *mut _,
            Some(progress_callback),
            &progress as *const _ as *mut _,
            &mut error,
        )
    };
    let message = if error.is_null() {
        None
    } else {
        let message = unsafe { std::ffi::CStr::from_ptr(error) }
            .to_string_lossy()
            .into_owned();
        unsafe { rg_free_string(error) };
        Some(message)
    };
    (
        status,
        counter.load(Ordering::SeqCst),
        progress[0].load(Ordering::SeqCst),
        progress[1].load(Ordering::SeqCst),
        message,
    )
}
#[test]
fn glob_ffi_borrowed_arrays_filter_and_prune_before_reads() {
    use ripgrep_ffi::ffi::rg_glob_options;
    let root = TempDir::new().unwrap();
    std::fs::create_dir_all(root.path().join("Generated/deep")).unwrap();
    for name in [
        "日本 語.swift",
        "lib.rs",
        "skip.txt",
        "Generated/deep/a.swift",
    ] {
        std::fs::write(root.path().join(name), "needle\n").unwrap();
    }
    let includes = slices(&[b"**/*.swift", b"**/*.rs"]);
    let excludes = slices(&[b"Generated/", b"*.rs"]);
    let globs = rg_glob_options {
        includes: includes.as_ptr(),
        includes_len: includes.len(),
        excludes: excludes.as_ptr(),
        excludes_len: excludes.len(),
    };
    let result = run_glob_search(root.path().as_os_str().as_bytes(), &globs);
    assert_eq!(result, (rg_status::RG_STATUS_OK, 1, 1, 7, None));
    assert_eq!(includes[0].len, b"**/*.swift".len());
    assert_eq!(
        run_glob_search(root.path().as_os_str().as_bytes(), &globs),
        result
    );
}
#[test]
fn glob_ffi_null_options_and_empty_arrays_preserve_unfiltered_behavior() {
    use ripgrep_ffi::ffi::rg_glob_options;
    let root = TempDir::new().unwrap();
    std::fs::write(root.path().join("a.swift"), "needle\n").unwrap();
    std::fs::write(root.path().join("a.rs"), "needle\n").unwrap();
    let globs = rg_glob_options {
        includes: ptr::null(),
        includes_len: 0,
        excludes: ptr::null(),
        excludes_len: 0,
    };
    let result = run_glob_search(root.path().as_os_str().as_bytes(), &globs);
    assert_eq!(result, (rg_status::RG_STATUS_OK, 2, 2, 14, None));
    assert_eq!(
        run_glob_search(root.path().as_os_str().as_bytes(), ptr::null()),
        result
    );
}
#[test]
fn glob_ffi_invalid_syntax_reports_new_status_and_freeable_message() {
    use ripgrep_ffi::ffi::rg_glob_options;
    let root = TempDir::new().unwrap();
    std::fs::write(root.path().join("a.swift"), "needle").unwrap();
    let invalid = slices(&[b"["]);
    for exclude in [false, true] {
        let mut globs = rg_glob_options {
            includes: invalid.as_ptr(),
            includes_len: 1,
            excludes: ptr::null(),
            excludes_len: 0,
        };
        if exclude {
            globs.excludes = invalid.as_ptr();
            globs.excludes_len = 1;
            globs.includes = ptr::null();
            globs.includes_len = 0;
        }
        let (status, matches, files, bytes, message) =
            run_glob_search(root.path().as_os_str().as_bytes(), &globs);
        assert_eq!(status, rg_status::RG_STATUS_INVALID_GLOB);
        assert_eq!((matches, files, bytes), (0, 0, 0));
        let message = message.unwrap();
        assert!(message.contains(if exclude { "exclude" } else { "include" }));
        assert!(message.contains('['));
    }
}
#[test]
fn glob_ffi_rejects_invalid_utf8_null_ranges_and_oversized_counts() {
    use ripgrep_ffi::ffi::{rg_glob_options, rg_utf8_slice};
    let root = TempDir::new().unwrap();
    for invalid in [
        rg_utf8_slice {
            data: b"\xff".as_ptr(),
            len: 1,
        },
        rg_utf8_slice {
            data: ptr::null(),
            len: 1,
        },
        rg_utf8_slice {
            data: b"a".as_ptr(),
            len: usize::MAX,
        },
    ] {
        for exclude in [false, true] {
            let globs = if exclude {
                rg_glob_options {
                    includes: ptr::null(),
                    includes_len: 0,
                    excludes: &invalid,
                    excludes_len: 1,
                }
            } else {
                rg_glob_options {
                    includes: &invalid,
                    includes_len: 1,
                    excludes: ptr::null(),
                    excludes_len: 0,
                }
            };
            assert_eq!(
                run_glob_search(root.path().as_os_str().as_bytes(), &globs).0,
                rg_status::RG_STATUS_INVALID_ARGUMENT
            );
        }
    }
    for count in [1, usize::MAX] {
        let globs = rg_glob_options {
            includes: ptr::null(),
            includes_len: count,
            excludes: ptr::null(),
            excludes_len: 0,
        };
        assert_eq!(
            run_glob_search(root.path().as_os_str().as_bytes(), &globs).0,
            rg_status::RG_STATUS_INVALID_ARGUMENT
        );
    }
    let empty = rg_utf8_slice {
        data: ptr::null(),
        len: 0,
    };
    let globs = rg_glob_options {
        includes: &empty,
        includes_len: 1,
        excludes: ptr::null(),
        excludes_len: 0,
    };
    assert_eq!(
        run_glob_search(root.path().as_os_str().as_bytes(), &globs).0,
        rg_status::RG_STATUS_INVALID_GLOB
    );
}
#[test]
fn glob_ffi_filtered_search_retains_callback_cancellation() {
    use ripgrep_ffi::ffi::rg_glob_options;
    let root = TempDir::new().unwrap();
    std::fs::write(root.path().join("a.swift"), "needle\n".repeat(1000)).unwrap();
    let includes = slices(&[b"*.swift"]);
    let globs = rg_glob_options {
        includes: includes.as_ptr(),
        includes_len: 1,
        excludes: ptr::null(),
        excludes_len: 0,
    };
    let mut error = ptr::null_mut();
    let bytes = root.path().as_os_str().as_bytes();
    let status = unsafe {
        ripgrep_ffi::ffi::rg_search_with_globs(
            bytes.as_ptr(),
            bytes.len(),
            b"needle".as_ptr(),
            6,
            &default_c_options(),
            &globs,
            ptr::null(),
            Some(cancelling_callback),
            ptr::null_mut(),
            None,
            ptr::null_mut(),
            &mut error,
        )
    };
    assert_eq!(status, rg_status::RG_STATUS_CANCELLED);
    assert!(error.is_null());
}
