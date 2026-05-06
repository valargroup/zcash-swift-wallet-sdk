//! C FFI for the voting functionality.
//!
//! Implementation is split into submodules for navigation. Exported FFI functions
//! keep their stable C symbols with `#[unsafe(no_mangle)]`.

mod helpers;

pub mod db;
pub mod delegation;
pub mod rounds;
pub mod share_tracking;
