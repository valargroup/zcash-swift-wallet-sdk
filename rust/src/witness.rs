//! C FFI for witness PIR — network-only call.
//!
//! DB read/write operations are handled by the `zcashlc_*` functions in `lib.rs`
//! that go through `wallet_db()` and share the `@DBActor` connection.

use std::panic::AssertUnwindSafe;

use anyhow::anyhow;
use ffi_helpers::panic::catch_panic;
use serde::{Deserialize, Serialize};

use crate::spendability::{json_to_boxed_slice, str_from_ptr};
use crate::unwrap_exc_or_null;

#[derive(Deserialize)]
struct PositionInput {
    note_id: i64,
    position: u64,
}

#[derive(Serialize)]
struct WitnessEntry {
    note_id: i64,
    position: u64,
    /// 32 siblings, each 32 bytes, hex-encoded.
    siblings: Vec<String>,
    anchor_height: u64,
    anchor_root: String,
}

#[derive(Serialize)]
struct WitnessCheckResult {
    witnesses: Vec<WitnessEntry>,
}

/// Fetches note commitment witnesses from the PIR server. No database access.
///
/// `positions_json` is a JSON array of `{"note_id": i64, "position": u64}`.
///
/// Returns JSON `WitnessCheckResult`, or null on error.
///
/// # Safety
///
/// Pointer/length pairs must be valid UTF-8 slices.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_fetch_pir_witnesses(
    pir_server_url: *const u8,
    pir_server_url_len: usize,
    positions_json: *const u8,
    positions_json_len: usize,
    progress_callback: Option<unsafe extern "C" fn(f64, *mut std::ffi::c_void)>,
    progress_context: *mut std::ffi::c_void,
) -> *mut crate::ffi::BoxedSlice {
    let progress_context = AssertUnwindSafe(progress_context);
    let res = catch_panic(|| {
        let t0 = std::time::Instant::now();
        let url = unsafe { str_from_ptr(pir_server_url, pir_server_url_len) }?;
        let pos_bytes = unsafe { std::slice::from_raw_parts(positions_json, positions_json_len) };

        let inputs: Vec<PositionInput> = serde_json::from_slice(pos_bytes)
            .map_err(|e| anyhow!("failed to parse positions JSON: {e}"))?;

        if inputs.is_empty() {
            return json_to_boxed_slice(&WitnessCheckResult { witnesses: vec![] });
        }

        tracing::info!(num_notes = inputs.len(), url = %url, "witness FFI: starting");

        let t1 = std::time::Instant::now();
        let client = witness_client::WitnessClientBlocking::connect(&url)
            .map_err(|e| anyhow!("witness PIR connect failed: {e}"))?;
        tracing::info!(
            elapsed_ms = t1.elapsed().as_millis(),
            "witness FFI: connected"
        );

        let anchor_height = client.anchor_height();
        let positions: Vec<u64> = inputs.iter().map(|i| i.position).collect();

        let t2 = std::time::Instant::now();
        let pir_witnesses = client
            .get_witnesses(&positions, |frac| {
                if let Some(cb) = progress_callback {
                    unsafe { cb(frac, *progress_context) };
                }
            })
            .map_err(|e| anyhow!("PIR witness batch query failed: {e}"))?;
        tracing::info!(
            elapsed_ms = t2.elapsed().as_millis(),
            count = pir_witnesses.len(),
            "witness FFI: queries complete",
        );

        let witnesses: Vec<WitnessEntry> = inputs
            .iter()
            .zip(pir_witnesses.iter())
            .map(|(input, w)| WitnessEntry {
                note_id: input.note_id,
                position: input.position,
                siblings: w.siblings.iter().map(hex::encode).collect(),
                anchor_height,
                anchor_root: hex::encode(w.anchor_root),
            })
            .collect();

        tracing::info!(
            total_ms = t0.elapsed().as_millis(),
            num_witnesses = witnesses.len(),
            "witness FFI: done",
        );

        json_to_boxed_slice(&WitnessCheckResult { witnesses })
    });
    unwrap_exc_or_null(res)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serialize_witness_check_result() {
        let result = WitnessCheckResult {
            witnesses: vec![WitnessEntry {
                note_id: 42,
                position: 1000,
                siblings: vec!["aa".repeat(32)],
                anchor_height: 3200000,
                anchor_root: "bb".repeat(32),
            }],
        };
        let json: serde_json::Value = serde_json::to_value(&result).unwrap();
        assert_eq!(json["witnesses"][0]["note_id"], 42);
        assert_eq!(json["witnesses"][0]["position"], 1000);
        assert_eq!(json["witnesses"][0]["anchor_height"], 3200000);
    }

    #[test]
    fn serialize_empty_witness_check_result() {
        let result = WitnessCheckResult { witnesses: vec![] };
        let json: serde_json::Value = serde_json::to_value(&result).unwrap();
        assert_eq!(json["witnesses"], serde_json::json!([]));
    }
}
