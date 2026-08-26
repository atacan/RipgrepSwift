//! Smoke tests for the exported C ABI itself (`Phase 2` verification).
//!
//! These exercise `rg_search` exactly the way Swift does: borrowed byte
//! ranges, a C callback, a context pointer, and an error out-parameter.

use std::ffi::c_char;
use std::os::unix::ffi::OsStrExt;
use std::ptr;
use std::sync::atomic::{AtomicUsize, Ordering};

use ripgrep_ffi::ffi::{rg_free_string, rg_match, rg_search, rg_search_options, rg_status};
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

#[test]
fn successful_search_returns_ok_and_delivers_matches() {
    let dir = TempDir::new().unwrap();
    std::fs::write(dir.path().join("a.txt"), "first TODO here\nsecond line\n").unwrap();

    let counter = AtomicUsize::new(0);
    let mut error_message: *mut c_char = ptr::null_mut();

    let status = unsafe {
        rg_search(
            dir.path().as_os_str().as_bytes().as_ptr(),
            dir.path().as_os_str().as_bytes().len(),
            b"TODO".as_ptr(),
            4,
            &default_c_options(),
            Some(counting_callback),
            &counter as *const AtomicUsize as *mut std::ffi::c_void,
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
        rg_search(
            ptr::null(),
            0,
            b"x".as_ptr(),
            1,
            &default_c_options(),
            Some(counting_callback),
            ptr::null_mut(),
            &mut error_message,
        )
    };

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
        rg_search(
            root_bytes.as_ptr(),
            root_bytes.len(),
            b"(unclosed".as_ptr(),
            9,
            &default_c_options(),
            Some(counting_callback),
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
        rg_search(
            root_bytes.as_ptr(),
            root_bytes.len(),
            b"needle".as_ptr(),
            6,
            &default_c_options(),
            Some(cancelling_callback),
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
        rg_search(
            root_bytes.as_ptr(),
            root_bytes.len(),
            b"x".as_ptr(),
            1,
            &default_c_options(),
            Some(counting_callback),
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
