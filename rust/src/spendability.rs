//! C FFI for spendability PIR — network-only call.
//!
//! DB read/write operations are handled by the new `zcashlc_*` functions
//! in `lib.rs` that go through `wallet_db()` and share the `@DBActor`
//! connection.

use std::panic::AssertUnwindSafe;

use anyhow::anyhow;
use ffi_helpers::panic::catch_panic;
use serde::Serialize;

use crate::unwrap_exc_or_null;

pub(crate) unsafe fn str_from_ptr(ptr: *const u8, len: usize) -> anyhow::Result<String> {
    let bytes = unsafe { std::slice::from_raw_parts(ptr, len) };
    Ok(std::str::from_utf8(bytes)?.to_string())
}

pub(crate) fn json_to_boxed_slice<T: Serialize>(
    value: &T,
) -> anyhow::Result<*mut crate::ffi::BoxedSlice> {
    let json = serde_json::to_vec(value)?;
    Ok(crate::ffi::BoxedSlice::some(json))
}

#[derive(Serialize)]
struct NullifierCheckResult {
    earliest_height: u64,
    latest_height: u64,
    /// Parallel to the input nullifiers: true = spent.
    spent: Vec<bool>,
}

/// Checks nullifiers against the PIR server. No database access.
///
/// `nullifiers_json` is a JSON array of byte arrays (each 32 elements),
/// e.g. `[[0,1,...,31],[0,1,...,31]]`.
///
/// Returns JSON `NullifierCheckResult`, or null on error.
///
/// # Safety
///
/// Pointer/length pairs must be valid UTF-8 slices.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_check_nullifiers_pir(
    pir_server_url: *const u8,
    pir_server_url_len: usize,
    nullifiers_json: *const u8,
    nullifiers_json_len: usize,
    progress_callback: Option<unsafe extern "C" fn(f64, *mut std::ffi::c_void)>,
    progress_context: *mut std::ffi::c_void,
) -> *mut crate::ffi::BoxedSlice {
    let progress_context = AssertUnwindSafe(progress_context);
    let res = catch_panic(|| {
        let url = unsafe { str_from_ptr(pir_server_url, pir_server_url_len) }?;
        let nf_bytes = unsafe { std::slice::from_raw_parts(nullifiers_json, nullifiers_json_len) };

        let nf_vecs: Vec<Vec<u8>> = serde_json::from_slice(nf_bytes)
            .map_err(|e| anyhow!("failed to parse nullifiers JSON: {e}"))?;

        let nullifiers: Vec<[u8; 32]> = nf_vecs
            .into_iter()
            .map(|v| {
                v.try_into()
                    .map_err(|_| anyhow!("nullifier must be exactly 32 bytes"))
            })
            .collect::<anyhow::Result<Vec<_>>>()?;

        let client = spend_client::SpendClientBlocking::connect(&url)
            .map_err(|e| anyhow!("PIR connect failed: {e}"))?;

        let spent = client
            .check_nullifiers(&nullifiers, |progress| {
                if let Some(cb) = progress_callback {
                    unsafe { cb(progress, *progress_context) };
                }
            })
            .map_err(|e| anyhow!("PIR check failed: {e}"))?;

        let metadata = client.metadata();
        let result = NullifierCheckResult {
            earliest_height: metadata.earliest_height,
            latest_height: metadata.latest_height,
            spent,
        };

        json_to_boxed_slice(&result)
    });
    unwrap_exc_or_null(res)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serialize_nullifier_check_result() {
        let result = NullifierCheckResult {
            earliest_height: 100,
            latest_height: 200,
            spent: vec![true, false, true],
        };
        let json: serde_json::Value = serde_json::to_value(&result).unwrap();
        assert_eq!(json["earliest_height"], 100);
        assert_eq!(json["latest_height"], 200);
        assert_eq!(json["spent"], serde_json::json!([true, false, true]));
    }

    #[test]
    fn serialize_empty_nullifier_check_result() {
        let result = NullifierCheckResult {
            earliest_height: 0,
            latest_height: 0,
            spent: vec![],
        };
        let json: serde_json::Value = serde_json::to_value(&result).unwrap();
        assert_eq!(json["spent"], serde_json::json!([]));
    }
}
