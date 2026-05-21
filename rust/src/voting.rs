//! C FFI for the voting functionality.
//!
//! Implementation is split into submodules for navigation. Exported FFI functions
//! keep their stable C symbols with `#[unsafe(no_mangle)]`.

mod constants;
pub mod db;
pub mod delegation;
pub mod ffi_types;
pub mod helpers;
pub mod json;
pub mod note_bundling;
pub mod notes;
pub mod pir_snapshot;
pub mod progress;
pub mod recovery;
pub mod rounds;
pub mod share_policy;
pub mod share_tracking;
pub mod share_workflow;
#[cfg(test)]
pub(crate) mod test_helpers;
pub mod tree;
pub mod util;
pub mod vote;
