#![allow(clippy::missing_safety_doc, unused_imports)]

//! C FFI for the voting functionality.
//!
//! Follows the same patterns as `lib.rs` and `ffi.rs`:
//! - Functions: `#[unsafe(no_mangle)] pub unsafe extern "C" fn zcashlc_voting_*()`
//! - Error handling: `catch_panic()` + `unwrap_exc_or_null()` / `unwrap_exc_or()`
//! - Opaque pointers: `Box::into_raw(Box::new(obj))` to create, `Box::from_raw(ptr)` to free
//! - Complex types: JSON serialization via serde across the FFI boundary
//! - Simple types: `#[repr(C)]` structs

pub mod db;
pub mod delegation;
pub mod ffi_types;
mod helpers;
mod json;
pub mod notes;
mod progress;
pub mod recovery;
pub mod rounds;
pub mod share_tracking;
pub mod tree;
mod util;
pub mod vote;

pub use db::*;
pub use delegation::*;
pub use ffi_types::*;
pub use notes::*;
pub use recovery::*;
pub use rounds::*;
pub use share_tracking::*;
pub use tree::*;
pub use vote::*;
