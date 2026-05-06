//! Shared unsafe helpers for voting FFI (byte ranges from C callers).

use anyhow::anyhow;

/// When `len > 0`, `ptr` must be non-null and valid for reads for `len` bytes, and the
/// memory must not be mutated for the duration of the call. The returned slice must not
/// outlive the underlying allocation.
pub(super) unsafe fn bytes_from_ptr<'a>(ptr: *const u8, len: usize) -> anyhow::Result<&'a [u8]> {
    if len == 0 {
        return Ok(&[]);
    }
    if ptr.is_null() {
        return Err(anyhow!("null pointer with non-zero length"));
    }
    Ok(unsafe { std::slice::from_raw_parts(ptr, len) })
}

/// UTF-8 string from `(ptr, len)` without requiring a trailing NUL.
pub(super) unsafe fn str_from_ptr<'a>(ptr: *const u8, len: usize) -> anyhow::Result<&'a str> {
    let bytes = unsafe { bytes_from_ptr(ptr, len)? };
    Ok(std::str::from_utf8(bytes)?)
}
