use anyhow::anyhow;
use ffi_helpers::panic::catch_panic;
use zcash_voting as voting;

use crate::unwrap_exc_or_null;

use super::helpers::{bytes_from_ptr, json_to_boxed_slice, str_from_ptr};

/// Classify a parsed PIR snapshot height using the shared `zcash_voting` policy.
///
/// `has_reported_height == 0` treats `reported_height` as missing.
///
/// Returns JSON-encoded `PirSnapshotEndpointDiagnostic`, or null on error.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_classify_pir_snapshot_height(
    endpoint: *const u8,
    endpoint_len: usize,
    expected_snapshot_height: u64,
    reported_height: u64,
    has_reported_height: u8,
) -> *mut crate::ffi::BoxedSlice {
    let res = catch_panic(|| {
        let endpoint = unsafe { str_from_ptr(endpoint, endpoint_len) }?;
        let diagnostic = voting::pir_snapshot::classify_pir_snapshot_height(
            endpoint,
            expected_snapshot_height,
            (has_reported_height != 0).then_some(reported_height),
        );
        json_to_boxed_slice(&diagnostic)
    });
    unwrap_exc_or_null(res)
}

/// Select an exact-height PIR endpoint from normalized diagnostics.
///
/// `diagnostics_json` must be a JSON-encoded `Vec<PirSnapshotEndpointDiagnostic>`.
/// `match_index` is caller-provided entropy reduced over exact-height matches.
///
/// Returns JSON-encoded `PirSnapshotResolution`, or null on error.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn zcashlc_voting_select_pir_snapshot_endpoint(
    diagnostics_json: *const u8,
    diagnostics_json_len: usize,
    expected_snapshot_height: u64,
    match_index: u64,
) -> *mut crate::ffi::BoxedSlice {
    let res = catch_panic(|| {
        let bytes = unsafe { bytes_from_ptr(diagnostics_json, diagnostics_json_len) }?;
        let diagnostics: Vec<voting::pir_snapshot::PirSnapshotEndpointDiagnostic> =
            serde_json::from_slice(bytes)
                .map_err(|e| anyhow!("invalid PIR diagnostics JSON: {}", e))?;
        let resolution = voting::pir_snapshot::select_pir_snapshot_endpoint(
            &diagnostics,
            expected_snapshot_height,
            match_index,
        )
        .map_err(|e| anyhow!("select_pir_snapshot_endpoint failed: {}", e))?;
        json_to_boxed_slice(&resolution)
    });
    unwrap_exc_or_null(res)
}

#[cfg(test)]
mod tests {
    use serde::Serialize;
    use serde::de::DeserializeOwned;

    use super::*;

    fn decode_boxed_json<T: DeserializeOwned>(ptr: *mut crate::ffi::BoxedSlice) -> T {
        assert!(!ptr.is_null(), "expected non-null BoxedSlice");
        let slice = unsafe { (*ptr).as_slice() };
        let value = serde_json::from_slice(slice).expect("json");
        unsafe { crate::ffi::zcashlc_free_boxed_slice(ptr) };
        value
    }

    fn json_bytes<T: Serialize>(value: &T) -> Vec<u8> {
        serde_json::to_vec(value).expect("json")
    }

    fn diagnostic(
        endpoint: &str,
        status: voting::pir_snapshot::PirSnapshotEndpointStatus,
        reported_height: Option<u64>,
    ) -> voting::pir_snapshot::PirSnapshotEndpointDiagnostic {
        voting::pir_snapshot::PirSnapshotEndpointDiagnostic {
            endpoint: endpoint.to_string(),
            status,
            reported_height,
            http_status_code: None,
            message: None,
        }
    }

    #[test]
    fn classify_snapshot_height_uses_shared_statuses() {
        let endpoint = b"https://match.example.com";
        let diagnostic: voting::pir_snapshot::PirSnapshotEndpointDiagnostic =
            decode_boxed_json(unsafe {
                zcashlc_voting_classify_pir_snapshot_height(
                    endpoint.as_ptr(),
                    endpoint.len(),
                    100,
                    99,
                    1,
                )
            });

        assert_eq!(diagnostic.endpoint, "https://match.example.com");
        assert_eq!(
            diagnostic.status,
            voting::pir_snapshot::PirSnapshotEndpointStatus::Behind
        );
        assert_eq!(diagnostic.reported_height, Some(99));
    }

    #[test]
    fn select_snapshot_endpoint_uses_exact_matches() {
        let diagnostics = json_bytes(&vec![
            diagnostic(
                "https://behind.example.com",
                voting::pir_snapshot::PirSnapshotEndpointStatus::Behind,
                Some(99),
            ),
            diagnostic(
                "https://one.example.com",
                voting::pir_snapshot::PirSnapshotEndpointStatus::Matched,
                Some(100),
            ),
            diagnostic(
                "https://two.example.com",
                voting::pir_snapshot::PirSnapshotEndpointStatus::Matched,
                Some(100),
            ),
        ]);

        let resolution: voting::pir_snapshot::PirSnapshotResolution = decode_boxed_json(unsafe {
            zcashlc_voting_select_pir_snapshot_endpoint(
                diagnostics.as_ptr(),
                diagnostics.len(),
                100,
                5,
            )
        });

        assert_eq!(resolution.endpoint, "https://two.example.com");
        assert_eq!(resolution.selected_match_index, 1);
    }

    #[test]
    fn select_snapshot_endpoint_rejects_without_exact_match() {
        let diagnostics = json_bytes(&vec![diagnostic(
            "https://ahead.example.com",
            voting::pir_snapshot::PirSnapshotEndpointStatus::Ahead,
            Some(101),
        )]);

        let ptr = unsafe {
            zcashlc_voting_select_pir_snapshot_endpoint(
                diagnostics.as_ptr(),
                diagnostics.len(),
                100,
                0,
            )
        };
        assert!(ptr.is_null());
    }
}
