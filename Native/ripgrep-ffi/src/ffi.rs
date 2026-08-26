//! The exported C ABI.
//!
//! Rules enforced by this module:
//!
//! * No Rust type other than the `#[repr(C)]` structs below ever crosses the
//!   boundary.
//! * All input byte ranges are borrowed for the duration of the call only.
//! * Match data delivered to the callback borrows Rust-owned buffers that
//!   may be reused after the callback returns; receivers must copy.
//! * Panics are contained with `catch_unwind` and surface as
//!   `RG_STATUS_INTERNAL_ERROR`; nothing unwinds into the caller.
//! * Error strings are allocated with `CString::into_raw` and can only be
//!   released via `rg_free_string`.

use std::ffi::{c_char, CString};
use std::ops::ControlFlow;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use std::ptr;

use crate::search::{self, SearchMatch, SearchOptions, SearchOutcome};

/// Mirrors `rg_search_options_t` in ripgrep_ffi.h.
#[repr(C)]
pub struct rg_search_options {
    pub include_hidden: bool,
    pub follow_symlinks: bool,
    pub respect_gitignore: bool,
    pub case_insensitive: bool,
}

/// Mirrors `rg_match_t` in ripgrep_ffi.h.
///
/// `path` and `line` are borrowed and valid only inside the callback.
#[repr(C)]
pub struct rg_match {
    pub path: *const u8,
    pub path_len: usize,
    pub line_number: u64,
    pub line: *const u8,
    pub line_len: usize,
    pub match_start: usize,
    pub match_end: usize,
}

/// Mirrors `rg_match_callback_t` in ripgrep_ffi.h.
#[allow(non_camel_case_types)]
pub type rg_match_callback_t =
    Option<unsafe extern "C" fn(context: *mut std::ffi::c_void, m: *const rg_match) -> bool>;

/// Mirrors `rg_status_t` in ripgrep_ffi.h.
#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(non_camel_case_types)]
pub enum rg_status {
    RG_STATUS_OK = 0,
    RG_STATUS_CANCELLED = 1,
    RG_STATUS_INVALID_ARGUMENT = 2,
    RG_STATUS_INVALID_PATTERN = 3,
    RG_STATUS_IO_ERROR = 4,
    RG_STATUS_INTERNAL_ERROR = 255,
}

impl From<&crate::error::SearchError> for rg_status {
    fn from(error: &crate::error::SearchError) -> Self {
        match error {
            crate::error::SearchError::InvalidPattern(_) => rg_status::RG_STATUS_INVALID_PATTERN,
            crate::error::SearchError::Io(_) => rg_status::RG_STATUS_IO_ERROR,
        }
    }
}

impl From<SearchOutcome> for rg_status {
    fn from(outcome: SearchOutcome) -> Self {
        match outcome {
            SearchOutcome::Completed => rg_status::RG_STATUS_OK,
            SearchOutcome::Cancelled => rg_status::RG_STATUS_CANCELLED,
        }
    }
}

/// # Safety
///
/// * `root`/`pattern` must point to at least their stated number of readable
///   bytes for the duration of the call (a null pointer with zero length is
///   accepted for an empty pattern).
/// * `options` must point to a valid `rg_search_options`.
/// * `context` is passed through to `callback` untouched.
///
/// See the header for ownership rules.
#[no_mangle]
pub unsafe extern "C" fn rg_search(
    root: *const u8,
    root_len: usize,
    pattern: *const u8,
    pattern_len: usize,
    options: *const rg_search_options,
    callback: rg_match_callback_t,
    context: *mut std::ffi::c_void,
    error_message: *mut *mut c_char,
) -> rg_status {
    if let Some(slot) = unsafe { error_message.as_mut() } {
        *slot = ptr::null_mut();
    }

    let outcome = catch_unwind(AssertUnwindSafe(|| unsafe {
        rg_search_impl(
            root,
            root_len,
            pattern,
            pattern_len,
            options,
            callback,
            context,
            error_message,
        )
    }));

    match outcome {
        Ok(status) => status,
        Err(payload) => {
            set_error_message(
                error_message,
                &format!("internal panic: {}", panic_message(&payload)),
            );
            rg_status::RG_STATUS_INTERNAL_ERROR
        }
    }
}

/// # Safety
/// Caller must uphold the same contracts as [`rg_search`]; this function is
/// only called from within `catch_unwind`.
#[allow(clippy::too_many_arguments)]
unsafe fn rg_search_impl(
    root: *const u8,
    root_len: usize,
    pattern: *const u8,
    pattern_len: usize,
    options: *const rg_search_options,
    callback: rg_match_callback_t,
    context: *mut std::ffi::c_void,
    error_message: *mut *mut c_char,
) -> rg_status {
    if root.is_null() || root_len == 0 || options.is_null() || callback.is_none() {
        set_error_message(error_message, "invalid argument: missing required input");
        return rg_status::RG_STATUS_INVALID_ARGUMENT;
    }

    let Some(root_str) = decode_utf8(root, root_len) else {
        set_error_message(
            error_message,
            "invalid argument: root path is not valid UTF-8",
        );
        return rg_status::RG_STATUS_INVALID_ARGUMENT;
    };
    let Some(pattern_str) = decode_utf8(pattern, pattern_len) else {
        set_error_message(
            error_message,
            "invalid argument: pattern is not valid UTF-8",
        );
        return rg_status::RG_STATUS_INVALID_ARGUMENT;
    };

    let opts = unsafe { &*options };
    let search_options = SearchOptions {
        include_hidden: opts.include_hidden,
        follow_symlinks: opts.follow_symlinks,
        respect_gitignore: opts.respect_gitignore,
        case_insensitive: opts.case_insensitive,
    };

    // Checked non-null above.
    let callback = callback.unwrap_unchecked();

    let result = search::search(Path::new(&root_str), &pattern_str, search_options, |m| {
        let c_match = build_c_match(&m);
        let continue_search = unsafe { callback(context, &c_match) };
        if continue_search {
            ControlFlow::Continue(())
        } else {
            ControlFlow::Break(())
        }
    });

    match result {
        Ok(outcome) => outcome.into(),
        Err(error) => {
            let status = (&error).into();
            set_error_message(error_message, &error.to_string());
            status
        }
    }
}

/// # Safety
/// `value` must be null or a pointer previously produced by
/// `set_error_message` that has not been freed yet.
#[no_mangle]
pub unsafe extern "C" fn rg_free_string(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}

fn decode_utf8(pointer: *const u8, length: usize) -> Option<String> {
    if length == 0 {
        return Some(String::new());
    }
    if pointer.is_null() {
        return None;
    }
    let bytes = unsafe { std::slice::from_raw_parts(pointer, length) };
    str::from_utf8(bytes).ok().map(str::to_owned)
}

fn build_c_match(m: &SearchMatch<'_>) -> rg_match {
    // Both buffers are borrowed and remain valid for the duration of the
    // callback: `line` points into the searcher's buffer and the path bytes
    // point into the walker's live directory entry. Receivers must copy
    // before returning; Rust may reuse both afterwards.
    let path_bytes = m.path.as_os_str().as_encoded_bytes();
    rg_match {
        path: path_bytes.as_ptr(),
        path_len: path_bytes.len(),
        line_number: m.line_number,
        line: m.line.as_ptr(),
        line_len: m.line.len(),
        match_start: m.match_start,
        match_end: m.match_end,
    }
}

fn set_error_message(slot: *mut *mut c_char, message: &str) {
    if slot.is_null() {
        return;
    }
    let sanitized = message.replace('\0', "");
    let Ok(c_string) = CString::new(sanitized) else {
        return;
    };
    unsafe {
        *slot = c_string.into_raw();
    }
}

fn panic_message(payload: &Box<dyn std::any::Any + Send>) -> String {
    if let Some(text) = payload.downcast_ref::<&str>() {
        return (*text).to_string();
    }
    if let Some(text) = payload.downcast_ref::<String>() {
        return text.clone();
    }
    "unknown panic".to_string()
}
