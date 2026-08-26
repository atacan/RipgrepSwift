//! Error type for the safe Rust search core.
//!
//! The FFI layer maps these onto stable `rg_status_t` values; nothing from
//! this module crosses the C ABI directly.

use std::fmt;

/// Failures that can occur while configuring or running a search.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SearchError {
    /// The regular expression failed to compile.
    InvalidPattern(String),
    /// A filesystem-level problem prevented the search from running
    /// (for example, a nonexistent search root).
    Io(String),
}

impl fmt::Display for SearchError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SearchError::InvalidPattern(message) => write!(f, "invalid pattern: {message}"),
            SearchError::Io(message) => write!(f, "io error: {message}"),
        }
    }
}

impl std::error::Error for SearchError {}
