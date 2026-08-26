//! Rust implementation behind the RipgrepSwift package.
//!
//! The crate is split in two halves:
//!
//! * [`search`] — a safe, idiomatic Rust search core built on the `grep`
//!   and `ignore` crates. It is directly unit/integration testable without
//!   any FFI involved.
//! * [`ffi`] — the exported C ABI (`rg_search`, `rg_free_string`). It only
//!   converts types, contains panics, and delegates to [`search`].

pub mod error;
pub mod ffi;
pub mod search;
